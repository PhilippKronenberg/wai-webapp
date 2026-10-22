// Run from the repository root.

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
//
// Acquire two SNB data-portal cubes (wai-webapp #36, decided in #36 by the owner)
//
//   snbgwdzid    SNB policy rate, SARON fixing, special rate, sight-deposit
//                rates and the threshold factor. Daily observations, released
//                weekly (Monday ~10:00) with data to the preceding Friday.
//   devwkieffid  Trade-weighted (effective) CHF exchange-rate index, nominal
//                and real. Daily observations, released monthly, with the last
//                observation at the end of the preceding month.
//
// Writes one tidy CSV per cube, snb_series.csv (the dimension codes resolved
// to names, once, rather than repeated on every row) and snb_vintages.json,
// which records each cube's PublishingDate -- the only vintage marker the
// portal offers.
//
// Node built-ins only, like everything else that runs in this repository.
//
// Source
//   https://data.snb.ch/api/cube/<cubeId>/data/csv/en   the data
//   https://data.snb.ch/api/cube/<cubeId>/dimensions/en the dimension labels
//   Publisher  Swiss National Bank, data portal (data.snb.ch)
//   Licence    non-commercial use with attribution; see README.md. NOT covered
//              by this repository's LICENSE-DATA.
//
// Four things about the portal that this script handles rather than assumes
// away, all of them found the hard way (see the survey comment on #36):
//
// 1. An unrecognised /api/... path returns HTTP 200 and the portal's Angular
//    index page, not a 404. Checking the status code is not enough, so every
//    response is checked for the shape it is supposed to have -- a CSV must
//    open with a CubeId line, the dimensions JSON must parse and carry the
//    cube id we asked for.
//
// 2. Cube CSVs are semicolon-separated, UTF-8 with a BOM and CRLF line
//    endings, and carry two metadata lines (CubeId, PublishingDate) and a
//    blank line before the real header. The BOM and the CR are stripped here;
//    what is written out is plain LF, comma-separated UTF-8 without a BOM.
//
// 3. Dimension items nest. devwkieffid's "Real/Nominal" dimension has an item
//    "R" (Real) whose children are "K" (CPI-based) and "P" (PPI-based), and
//    the data carries only the leaves -- "R" never appears in a data row. The
//    label map is therefore built from leaves, with the parent names joined
//    on, so "K" resolves to "Real, CPI-based" rather than to nothing.
//
// 4. Dates come in several shapes across the portal (YYYY-MM-DD, YYYY-MM,
//    YYYY and YYYY-Qn). Both cubes here are daily, so a row whose date is not
//    YYYY-MM-DD is a signal that the cube changed shape: the script stops
//    rather than writing something that looks fine.
//
// Rows whose Value is empty are dropped. The cubes are published as a full
// cross-product of their dimensions, so most rows are empty padding: 41020
// rows of snbgwdzid carry 18930 observations.
//
// The data CSVs carry the dimension codes and not the resolved names, because
// a name is 40-odd bytes repeated across 100'000 rows and the two files are
// committed. The names are in snb_series.csv, keyed by the same series_id.
//
// Usage
//   node snb/acquire_snb_cubes.mjs             download and rewrite both CSVs
//   node snb/acquire_snb_cubes.mjs <outdir>    write to another directory
//
// Nothing is written unless the script is run, and only into that directory.
//
//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

import { writeFileSync } from 'node:fs';
import { join } from 'node:path';


// SETTINGS ----------------------------------------------------------------

const API = 'https://data.snb.ch/api/cube';

const CUBES = [
  {
    id: 'snbgwdzid',
    file: 'snb_policy_rates.csv',
    label: 'SNB policy rate, SARON fixing and sight-deposit rates',
    // Every series in the cube is a rate in per cent except the two below.
    unitOverrides: { ZIABP: 'basis points', FREI: 'factor' },
    defaultUnit: 'percent',
  },
  {
    id: 'devwkieffid',
    file: 'snb_chf_effective_index.csv',
    label: 'Effective (trade-weighted) CHF exchange-rate index',
    // D2 says whether a row is the index itself or its day-on-day change.
    unitByDimension: { D2: { I: 'index', V: 'percent' } },
    defaultUnit: 'index',
  },
];

const DEFAULT_OUTDIR = 'snb';

// The portal is not fussy about the client, but identify ourselves anyway.
const HEADERS = { 'User-Agent': 'wai-webapp/snb-acquire (+https://github.com/PhilippKronenberg/wai-webapp)' };


// FETCHING ----------------------------------------------------------------

async function get(url) {
  const res = await fetch(url, { headers: HEADERS });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return await res.text();
}

// The portal answers unknown /api/ paths with its HTML shell and HTTP 200,
// so each response is checked for the shape it should have.
async function fetchCubeCsv(cubeId) {
  const body = await get(`${API}/${cubeId}/data/csv/en`);
  const text = body.replace(/^﻿/, '').replace(/\r\n/g, '\n');
  if (!/^"CubeId";/.test(text)) {
    throw new Error(`${cubeId}: the CSV endpoint did not return a cube CSV ` +
      `(starts with ${JSON.stringify(text.slice(0, 40))}) -- the portal returns ` +
      'its HTML shell with HTTP 200 for paths it does not recognise.');
  }
  return text;
}

async function fetchDimensions(cubeId) {
  const body = await get(`${API}/${cubeId}/dimensions/en`);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new Error(`${cubeId}: the dimensions endpoint did not return JSON ` +
      '-- most likely the portal HTML shell with HTTP 200.');
  }
  if (parsed.cubeId !== cubeId || !Array.isArray(parsed.dimensions)) {
    throw new Error(`${cubeId}: dimensions JSON is for ${parsed.cubeId ?? 'no cube'}.`);
  }
  return parsed.dimensions;
}


// PARSING -----------------------------------------------------------------

// Splits a semicolon-separated line with quoted fields. The portal quotes
// every field and never embeds a semicolon, but doubled quotes are handled
// in case it ever does.
function splitRow(line) {
  const out = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ';') { out.push(field); field = ''; }
    else field += ch;
  }
  out.push(field);
  return out.map((f) => f.trim());
}

// Metadata lines, blank line, header, data. Returns the metadata as a map
// alongside the header and rows.
function parseCubeCsv(cubeId, text) {
  const [head, ...rest] = text.split('\n\n');
  const body = rest.join('\n\n');
  const meta = Object.fromEntries(
    head.split('\n').filter(Boolean).map(splitRow).map(([k, v]) => [k, v]),
  );
  const lines = body.split('\n').filter((l) => l.trim() !== '');
  if (lines.length < 2) throw new Error(`${cubeId}: CSV has no data rows.`);
  const header = splitRow(lines[0]);
  if (header[0] !== 'Date' || header[header.length - 1] !== 'Value') {
    throw new Error(`${cubeId}: unexpected header ${header.join(';')}.`);
  }
  const rows = lines.slice(1).map(splitRow);
  return { meta, header, rows };
}

// Flattens the nested dimension tree into leaf code -> label, keeping the
// parent names: devwkieffid's "K" is a child of "Real" and means
// "Real, CPI-based". Only leaves ever appear in the data.
function leafLabels(items, prefix = []) {
  const out = new Map();
  for (const item of items) {
    const path = [...prefix, item.name];
    if (Array.isArray(item.dimensionItems) && item.dimensionItems.length) {
      for (const [k, v] of leafLabels(item.dimensionItems, path)) out.set(k, v);
    } else {
      out.set(item.id, path.join(', '));
    }
  }
  return out;
}

function labelMaps(dimensions) {
  const maps = new Map();
  for (const dim of dimensions) maps.set(dim.id, {
    name: dim.name,
    labels: leafLabels(dim.dimensionItems ?? []),
  });
  return maps;
}


// WRITING -----------------------------------------------------------------

function csvField(value) {
  const s = String(value);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function toCsv(header, rows) {
  const lines = [header.join(',')];
  for (const row of rows) lines.push(row.map(csvField).join(','));
  return `${lines.join('\n')}\n`;
}


// ASSEMBLY ----------------------------------------------------------------

function unitFor(cube, dimCodes, dimIds) {
  if (cube.unitByDimension) {
    for (const [dimId, byCode] of Object.entries(cube.unitByDimension)) {
      const code = dimCodes[dimIds.indexOf(dimId)];
      if (byCode[code]) return byCode[code];
    }
  }
  if (cube.unitOverrides && cube.unitOverrides[dimCodes[0]]) {
    return cube.unitOverrides[dimCodes[0]];
  }
  return cube.defaultUnit;
}

async function acquire(cube, outdir) {
  const [csvText, dimensions] = await Promise.all([
    fetchCubeCsv(cube.id),
    fetchDimensions(cube.id),
  ]);
  const { meta, header, rows } = parseCubeCsv(cube.id, csvText);
  const maps = labelMaps(dimensions);
  const dimIds = header.slice(1, -1);

  for (const dimId of dimIds) {
    if (!maps.has(dimId)) throw new Error(`${cube.id}: no labels for dimension ${dimId}.`);
  }

  const out = [];
  const unknown = new Set();
  const series = new Map();
  for (const row of rows) {
    const [date, ...rest] = row;
    const value = rest.pop();
    if (value === '') continue;               // cross-product padding
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new Error(`${cube.id}: date ${JSON.stringify(date)} is not YYYY-MM-DD. ` +
        'Portal cubes also use YYYY-MM, YYYY and YYYY-Qn; this one was daily ' +
        'and something about it has changed.');
    }
    const id = rest.join('.');
    if (!series.has(id)) {
      const labels = rest.map((code, i) => {
        const label = maps.get(dimIds[i]).labels.get(code);
        if (label === undefined) unknown.add(`${dimIds[i]}=${code}`);
        return label ?? code;
      });
      series.set(id, {
        id,
        name: labels.join(', '),
        unit: unitFor(cube, rest, dimIds),
        first: date,
        last: date,
        n: 0,
      });
    }
    const s = series.get(id);
    if (date < s.first) s.first = date;
    if (date > s.last) s.last = date;
    s.n++;
    out.push([date, id, value]);
  }

  if (unknown.size) {
    throw new Error(`${cube.id}: dimension codes present in the data but not in ` +
      `/dimensions/: ${[...unknown].join(', ')}.`);
  }
  if (!out.length) throw new Error(`${cube.id}: every value was empty.`);

  out.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));

  const path = join(outdir, cube.file);
  writeFileSync(path, toCsv(['date', 'series_id', 'value'], out));

  const dates = out.map((r) => r[0]);
  return {
    summary: {
      cube_id: cube.id,
      label: cube.label,
      csv: cube.file,
      publishing_date: meta.PublishingDate ?? null,
      observations: out.length,
      series: series.size,
      first_date: dates[0],
      last_date: dates[dates.length - 1],
    },
    series: [...series.values()]
      .sort((a, b) => (a.id < b.id ? -1 : 1))
      .map((s) => [cube.id, s.id, s.name, s.unit, s.first, s.last, s.n]),
  };
}

async function main() {
  const outdir = process.argv[2] ?? DEFAULT_OUTDIR;
  const summaries = [];
  const seriesRows = [];
  for (const cube of CUBES) {
    const { summary, series } = await acquire(cube, outdir);
    summaries.push(summary);
    seriesRows.push(...series);
    console.log(`${summary.cube_id}: ${summary.observations} observations in ` +
      `${summary.series} series, ${summary.first_date} to ${summary.last_date}, ` +
      `published ${summary.publishing_date} -> ${join(outdir, summary.csv)}`);
  }

  const seriesPath = join(outdir, 'snb_series.csv');
  writeFileSync(seriesPath, toCsv(
    ['cube_id', 'series_id', 'series', 'unit', 'first_date', 'last_date', 'observations'],
    seriesRows,
  ));
  console.log(`series dictionary -> ${seriesPath}`);

  // The PublishingDate is the only vintage marker the portal gives, and it is
  // in the CSV header that the tidy output drops. Keep it beside the data.
  const vintages = {
    retrieved_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    source: 'https://data.snb.ch/',
    note: 'publishing_date is the SNB cube PublishingDate at the time of download, in SNB local time.',
    cubes: summaries,
  };
  const vintagePath = join(outdir, 'snb_vintages.json');
  writeFileSync(vintagePath, `${JSON.stringify(vintages, null, 2)}\n`);
  console.log(`vintages -> ${vintagePath}`);
}

await main();
