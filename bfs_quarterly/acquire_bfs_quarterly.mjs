// Acquire the quarterly BFS labour-market and services-turnover tables
// requested in #39.
//
// Nine STAT-TAB cubes, all quarterly, all from the BFS PxWeb API
// (`https://www.pxweb.bfs.admin.ch/api/v1/de/`) that #36 found to be the clean
// machine-readable route into BFS. One tidy long CSV per cube, plus one file
// holding the label of every code used in them:
//
//   besta_employees_division.csv      px-x-0602000000_101
//   besta_employees_region.csv        px-x-0602000000_102
//   besta_vacancies_division.csv      px-x-0602000000_103
//   besta_vacancies_region.csv        px-x-0602000000_104
//   besta_outlook_division.csv        px-x-0602000000_105
//   besta_outlook_region.csv          px-x-0602000000_106
//   besta_recruiting_division.csv     px-x-0602000000_107
//   besta_recruiting_region.csv       px-x-0602000000_108
//   dus_turnover_quarterly.csv        px-x-0603030000_102
//   bfs_quarterly_codes.csv           labels for every code above, once each
//
// Node built-ins only, no dependencies -- the same reason
// tools/validate-data.mjs is written the way it is, and it means the committed
// CSVs are the verified output of a script this repository can actually run.
//
// Six things about the source that are handled here rather than assumed away:
//
// 1. The cube ids are not guessable and the catalogue's titles do not carry
//    them, so they were read off the API itself: `GET /api/v1/de/` lists 635
//    cube ids with no titles, and `GET /api/v1/de/<id>` returns the title of
//    the one cube inside. An id that does not exist answers `Bad Request`, not
//    an empty list, which is how the list above was confirmed to be the whole
//    database rather than a page of it.
//
// 2. Of the series #39 asks for, these nine are the ones the API has. ETS
//    (Erwerbstätige), SAKE (Erwerbslosenquote), the quarterly wage estimates,
//    Grenzgänger, Parahotellerie/Camping, IMPI and the *quarterly* KEU
//    turnover are in no cube of this database -- see README.md, "What is not
//    here".
//
// 3. PxWeb caps a single response, so every cube is fetched in chunks of
//    quarters sized to keep each request near `CELLS_PER_REQUEST` cells, and
//    the chunks are concatenated. The time variable is the one chunked
//    because it is the only one whose values are always independent rows.
//
// 4. The API rate-limits hard: 12 requests in parallel earns
//    `429 - Too many requests in too short timeframe` on most of them. The
//    requests are therefore serial, paced by `PACE_MS`, and a 429 is retried
//    with a backoff instead of being written to disk as if it were data.
//
// 5. `Geschlecht` is pinned to its total. #39 asks for the national total plus
//    the industry breakdown and explicitly skips the sex/nationality/age cuts,
//    which are cuts of the same survey and add no activity signal. Every other
//    variable is taken whole: `Beschäftigungsgrad` carries the full-time
//    equivalents and the seasonally adjusted variants, and the employment
//    outlook indicator #39 asks for separately is a *category* of the
//    `Voraussichtliche Beschäftigungsentwicklung` variable, not a cube of its
//    own.
//
// 6. json-stat2 returns one flat `value` array indexed by the product of the
//    dimension sizes in `id` order, with missing observations as `null` and
//    their reason, when there is one, in `status` keyed by the same flat
//    index. The index arithmetic is done from `size` rather than assumed, and
//    a response whose value count does not match that product is an error
//    rather than a silently shifted record.
//
// Usage
//   node bfs_quarterly/acquire_bfs_quarterly.mjs            fetch and write
//   node bfs_quarterly/acquire_bfs_quarterly.mjs --cache     keep/reuse the
//                                                            raw responses
//   node bfs_quarterly/acquire_bfs_quarterly.mjs --out DIR   write elsewhere
//   node bfs_quarterly/acquire_bfs_quarterly.mjs --only KEY  one cube only

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const API = 'https://www.pxweb.bfs.admin.ch/api/v1/de'
const CELLS_PER_REQUEST = 8000
const PACE_MS = 500
const MAX_ATTEMPTS = 6

// One entry per cube. `dims` renames the PxWeb variable codes to the CSV
// column names and fixes the column order; a variable mapped to `null` is
// pinned to the single value in `pin` instead of becoming a column.
const CUBES = [
  {
    key: 'besta_employees_division',
    table: 'px-x-0602000000_101',
    dims: { Wirtschaftsabteilung: 'division', 'Beschäftigungsgrad': 'employment_level', Geschlecht: null },
    pin: { Geschlecht: 'TOT' },
  },
  {
    key: 'besta_employees_region',
    table: 'px-x-0602000000_102',
    dims: { Grossregion: 'region', Wirtschaftssektor: 'sector', 'Beschäftigungsgrad': 'employment_level', Geschlecht: null },
    pin: { Geschlecht: 'TOT' },
  },
  {
    key: 'besta_vacancies_division',
    table: 'px-x-0602000000_103',
    dims: { 'Offene Stellen': 'measure', Wirtschaftsabteilung: 'division' },
  },
  {
    key: 'besta_vacancies_region',
    table: 'px-x-0602000000_104',
    dims: { 'Offene Stellen': 'measure', Grossregion: 'region' },
  },
  {
    key: 'besta_outlook_division',
    table: 'px-x-0602000000_105',
    dims: { Wirtschaftsabteilung: 'division', 'Voraussichtliche Beschäftigungsentwicklung': 'outlook', Gewichtung: 'weighting' },
  },
  {
    key: 'besta_outlook_region',
    table: 'px-x-0602000000_106',
    dims: { Grossregion: 'region', 'Voraussichtliche Beschäftigungsentwicklung': 'outlook', Gewichtung: 'weighting' },
  },
  {
    key: 'besta_recruiting_division',
    table: 'px-x-0602000000_107',
    dims: { Wirtschaftsabteilung: 'division', Ausbildungsniveau: 'education', Schwierigkeiten: 'difficulty', Gewichtung: 'weighting' },
  },
  {
    key: 'besta_recruiting_region',
    table: 'px-x-0602000000_108',
    dims: { Grossregion: 'region', Ausbildungsniveau: 'education', Schwierigkeiten: 'difficulty', Gewichtung: 'weighting' },
  },
  {
    key: 'dus_turnover_quarterly',
    table: 'px-x-0603030000_102',
    dims: { Bereinigung: 'adjustment', 'Indizes / Veränderungen': 'measure', Umsatz: 'turnover', Branche: 'branch' },
  },
]

const argv = process.argv.slice(2)
const flag = (name) => argv.includes(name)
const value = (name) => {
  const i = argv.indexOf(name)
  return i === -1 ? null : argv[i + 1]
}
const CACHE = flag('--cache')
const OUT = resolve(value('--out') ?? HERE)
const ONLY = value('--only')
const CACHE_DIR = join(OUT, 'raw')

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// The time variable is whichever variable holds values that look like 2026Q2.
const TIME_VALUE = /^\d{4}Q[1-4]$/

// 2026Q2 -> 2026-04-01. The quarter's first day, as everywhere else in this
// repository: wai_data.csv's dates are YYYY-MM-DD and nothing here invents a
// day of the month it cannot know.
function quarterToDate(q) {
  const year = q.slice(0, 4)
  const month = String((Number(q.slice(5)) - 1) * 3 + 1).padStart(2, '0')
  return `${year}-${month}-01`
}

async function getJson(url, label) {
  for (let attempt = 1; ; attempt++) {
    let res, text
    try {
      res = await fetch(url)
      text = await res.text()
    } catch (err) {
      if (attempt >= MAX_ATTEMPTS) throw new Error(`${label}: ${err.message}`)
      await sleep(PACE_MS * 4 * attempt)
      continue
    }
    if (res.ok && !text.startsWith('{"error"')) return JSON.parse(text)
    const rateLimited = res.status === 429 || text.includes('Too many requests')
    if (!rateLimited || attempt >= MAX_ATTEMPTS) {
      throw new Error(`${label}: HTTP ${res.status} ${text.slice(0, 200)}`)
    }
    await sleep(PACE_MS * 4 * attempt)
  }
}

async function postJson(url, body, label) {
  for (let attempt = 1; ; attempt++) {
    let res, text
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      })
      text = await res.text()
    } catch (err) {
      if (attempt >= MAX_ATTEMPTS) throw new Error(`${label}: ${err.message}`)
      await sleep(PACE_MS * 4 * attempt)
      continue
    }
    if (res.ok && !text.startsWith('{"error"')) return JSON.parse(text)
    const rateLimited = res.status === 429 || text.includes('Too many requests')
    if (!rateLimited || attempt >= MAX_ATTEMPTS) {
      throw new Error(`${label}: HTTP ${res.status} ${text.slice(0, 200)}`)
    }
    await sleep(PACE_MS * 4 * attempt)
  }
}

async function cached(name, produce) {
  const path = join(CACHE_DIR, name)
  if (CACHE && existsSync(path)) return JSON.parse(await readFile(path, 'utf8'))
  const data = await produce()
  if (CACHE) {
    await mkdir(CACHE_DIR, { recursive: true })
    await writeFile(path, JSON.stringify(data))
  }
  return data
}

// json-stat2 -> long rows. `dimOrder` is the response's own `id` list, so the
// flat `value` array is walked with the strides the response declares rather
// than with the order this script happens to have asked in.
function rowsFromJsonStat(doc, cube, timeCode) {
  const ids = doc.id ?? doc.dimension?.id
  const sizes = doc.size ?? doc.dimension?.size
  if (!ids || !sizes) throw new Error(`${cube.key}: response carries no dimension list`)
  const expected = sizes.reduce((a, b) => a * b, 1)
  if (doc.value.length !== expected) {
    throw new Error(`${cube.key}: ${doc.value.length} values for ${expected} cells`)
  }
  // Category codes per dimension, in index order.
  const codes = ids.map((id) => {
    const index = doc.dimension[id].category.index
    const out = []
    if (Array.isArray(index)) out.push(...index)
    else for (const [code, i] of Object.entries(index)) out[i] = code
    return out
  })
  const strides = sizes.map((_, i) => sizes.slice(i + 1).reduce((a, b) => a * b, 1))
  const columns = ids
    .filter((id) => id !== timeCode && cube.dims[id] !== null)
    .map((id) => ({ id, name: cube.dims[id], at: ids.indexOf(id) }))
  const timeAt = ids.indexOf(timeCode)
  const status = doc.status ?? {}

  const rows = []
  for (let flat = 0; flat < doc.value.length; flat++) {
    const at = (d) => Math.floor(flat / strides[d]) % sizes[d]
    const row = [quarterToDate(codes[timeAt][at(timeAt)])]
    for (const c of columns) row.push(codes[c.at][at(c.at)])
    const v = doc.value[flat]
    row.push(v === null || v === undefined ? '' : String(v))
    row.push(status[flat] ?? status[String(flat)] ?? '')
    rows.push(row)
  }
  return { rows, header: ['date', ...columns.map((c) => c.name), 'value', 'status'] }
}

function csvField(s) {
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

async function fetchCube(cube) {
  const meta = await cached(`${cube.key}.meta.json`, () =>
    getJson(`${API}/${cube.table}/${cube.table}.px`, `${cube.key} metadata`))

  const timeVar = meta.variables.find((v) => v.values.every((x) => TIME_VALUE.test(x)))
  if (!timeVar) throw new Error(`${cube.key}: no quarterly variable in the cube`)

  const known = new Set(Object.keys(cube.dims))
  for (const v of meta.variables) {
    if (v.code !== timeVar.code && !known.has(v.code)) {
      throw new Error(`${cube.key}: cube grew a variable this script does not map: ${v.code}`)
    }
  }

  // Cells per quarter, so the chunk size follows the cube rather than a guess.
  const perQuarter = meta.variables
    .filter((v) => v.code !== timeVar.code)
    .reduce((n, v) => n * (cube.pin?.[v.code] ? 1 : v.values.length), 1)
  const chunk = Math.max(1, Math.floor(CELLS_PER_REQUEST / perQuarter))

  const quarters = timeVar.values
  let header = null
  const rows = []
  for (let i = 0; i < quarters.length; i += chunk) {
    const slice = quarters.slice(i, i + chunk)
    const query = meta.variables.map((v) => {
      if (v.code === timeVar.code) {
        return { code: v.code, selection: { filter: 'item', values: slice } }
      }
      const pinned = cube.pin?.[v.code]
      return pinned
        ? { code: v.code, selection: { filter: 'item', values: [pinned] } }
        : { code: v.code, selection: { filter: 'all', values: ['*'] } }
    })
    const label = `${cube.key} ${slice[0]}..${slice[slice.length - 1]}`
    const doc = await cached(`${cube.key}.${slice[0]}.json`, async () => {
      const d = await postJson(`${API}/${cube.table}/${cube.table}.px`,
        { query, response: { format: 'json-stat2' } }, label)
      await sleep(PACE_MS)
      return d
    })
    const got = rowsFromJsonStat(doc, cube, timeVar.code)
    if (header && header.join() !== got.header.join()) {
      throw new Error(`${cube.key}: chunk ${label} has columns ${got.header.join()}`)
    }
    header = got.header
    rows.push(...got.rows)
    process.stderr.write(`  ${label}: ${got.rows.length} rows\n`)
  }

  // Series first, date within it. The key stops before `value` and `status`:
  // including them sorts a series by its own observations, which looks sorted
  // and is not.
  const keyEnd = header.length - 2
  const sortKey = (r) => r.slice(1, keyEnd).join('\u0000') + '\u0000' + r[0]
  rows.sort((a, b) => sortKey(a).localeCompare(sortKey(b)))

  const labels = []
  for (const v of meta.variables) {
    if (v.code === timeVar.code || cube.dims[v.code] === null) continue
    v.values.forEach((code, i) => labels.push([cube.dims[v.code], code, v.valueTexts[i]]))
  }
  return { cube, meta, header, rows, labels, quarters }
}

async function main() {
  const wanted = ONLY ? CUBES.filter((c) => c.key === ONLY) : CUBES
  if (!wanted.length) throw new Error(`--only ${ONLY}: no such cube`)
  await mkdir(OUT, { recursive: true })

  const codes = new Map()
  const summary = []
  for (const cube of wanted) {
    process.stderr.write(`${cube.key} (${cube.table})\n`)
    const got = await fetchCube(cube)
    const lines = [got.header.join(',')]
    for (const row of got.rows) lines.push(row.map(csvField).join(','))
    await writeFile(join(OUT, `${cube.key}.csv`), lines.join('\n') + '\n')
    for (const [dim, code, label] of got.labels) {
      codes.set(`${dim}\u0000${code}`, [dim, code, label])
    }
    const dates = got.rows.map((r) => r[0])
    summary.push({
      key: cube.key,
      table: cube.table,
      title: got.meta.title,
      rows: got.rows.length,
      first: dates.reduce((a, b) => (a < b ? a : b)),
      last: dates.reduce((a, b) => (a > b ? a : b)),
      observed: got.rows.filter((r) => r[got.header.indexOf('value')] !== '').length,
    })
  }

  const codeLines = ['dimension,code,label']
  for (const row of [...codes.values()].sort((a, b) =>
    a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]))) {
    codeLines.push(row.map(csvField).join(','))
  }
  await writeFile(join(OUT, 'bfs_quarterly_codes.csv'), codeLines.join('\n') + '\n')

  process.stderr.write('\n')
  for (const s of summary) {
    process.stderr.write(
      `${s.key.padEnd(26)} ${String(s.rows).padStart(7)} rows  ` +
      `${s.first} -> ${s.last}  ${s.observed} observed  ${s.title}\n`)
  }
}

await main()
