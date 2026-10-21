#!/usr/bin/env node
// Scrape SECO's monthly labour-market report and write the long monthly series
// it publishes as a tidy CSV.
//
// Run from the repository root:
//
//     node seco_amstat/scrape_seco_amstat.mjs
//
// Node built-ins only, like tools/validate-data.mjs - this repository has no
// dependencies and CI must not be the thing that introduces one.
//
// Why a PDF scraper and not an API (issue #36): amstat.ch is a MicroStrategy
// dossier with no CSV/SDMX endpoint whose login returns 401 from outside, and
// arbeit.swiss publishes these numbers as PDF only. The SNB data portal mirrors
// them (cube amarbma) but lands about three weeks after month end against
// SECO's own five days, and the five days are the reason for scraping.
//
// The report is produced with LaTeX and carries no /ToUnicode map, so its text
// is glyph indices rather than characters. They turn out to be a fixed offset
// from ASCII, which this script derives at run time and refuses to guess: see
// `decodeOffset`. Because a wrong offset would yield plausible-looking wrong
// digits rather than an error, every series is checked against the annual mean
// the report prints itself, and the newest value against the front table.
// Exit 1 is a scrape that produced wrong or missing data; exit 2 is a scrape
// that could not run at all.

import { writeFileSync, mkdirSync } from 'node:fs';
import { inflateSync } from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DIR = dirname(fileURLToPath(import.meta.url));
const INDEX_URL =
  'https://www.arbeit.swiss/de/informationszentrum/arbeitsmarktstatistik-schweiz';
// arbeit.swiss answers a bare client with a challenge page; a desktop User-Agent
// is the whole difference between HTML and no HTML. Same finding as #32.
const UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36';

const MONTHS_DE = {
  Januar: 1, Februar: 2, 'März': 3, April: 4, Mai: 5, Juni: 6,
  Juli: 7, August: 8, September: 9, Oktober: 10, November: 11, Dezember: 12,
};

// Every "... seit 2004" table in the report, with the series name it becomes.
// `decimals` distinguishes the rates (one decimal, comma in the PDF) from the
// counts, and drives the tolerance of the annual-mean check.
const TABLES = [
  { table: 16, series: 'unemployed', unit: 'persons', decimals: 0, title: /Arbeitsloseseit2004/ },
  { table: 17, series: 'unemployment_rate', unit: 'percent', decimals: 1, title: /Arbeitslosenquoteseit2004/ },
  { table: 21, series: 'jobseekers', unit: 'persons', decimals: 0, title: /Stellensuchendeseit2004/ },
  { table: 22, series: 'jobseeker_rate', unit: 'percent', decimals: 1, title: /Stellensuchendenquoteseit2004/ },
  { table: 23, series: 'benefit_exhaustions', unit: 'persons', decimals: 0, title: /Aussteuerungen.*seit2004/ },
  { table: 25, series: 'vacancies_notified', unit: 'positions', decimals: 0, title: /OffeneStellenseit2004/ },
  { table: 26, series: 'short_time_work_units', unit: 'company_divisions', decimals: 0, title: /AbgerechneteKurzarbeit,Betriebsabteilungenseit2004/ },
  { table: 27, series: 'short_time_work_workers', unit: 'persons', decimals: 0, title: /AbgerechneteKurzarbeit,betroffeneArbeitnehmerseit2004/ },
];

function die(code, message) {
  console.error(`scrape_seco_amstat: ${message}`);
  process.exit(code);
}

async function get(url, asBuffer = false) {
  const res = await fetch(url, { headers: { 'user-agent': UA, accept: '*/*' } });
  if (!res.ok) die(2, `${url}: HTTP ${res.status}`);
  return asBuffer ? Buffer.from(await res.arrayBuffer()) : await res.text();
}

// ---------------------------------------------------------------- find the PDF

// The filenames are opaque UUIDs with no constructable pattern, so the current
// report has to be found by scraping the page every month.
function findLatestReport(html) {
  const re =
    /<a[^>]+href="([^"]*fileservice[^"]*\.pdf)"[^>]*>([\s\S]*?)<\/a>/g;
  const found = [];
  let m;
  while ((m = re.exec(html))) {
    const text = m[2].replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
    const t = /Die Lage auf dem Arbeitsmarkt\s+(?:im\s+)?(\w+)\s+(\d{4})/.exec(text);
    if (!t) continue;
    const month = MONTHS_DE[t[1]];
    if (!month) continue;
    const published = /(\d{2})\.(\d{2})\.(\d{4})/.exec(text);
    found.push({
      url: new URL(m[1], INDEX_URL).href,
      year: Number(t[2]),
      month,
      title: text.replace(/\s*PDF.*$/, ''),
      published: published ? `${published[3]}-${published[2]}-${published[1]}` : '',
    });
  }
  if (found.length === 0) die(2, 'no "Die Lage auf dem Arbeitsmarkt" PDF found on the index page');
  found.sort((a, b) => b.year - a.year || b.month - a.month);
  return found[0];
}

// --------------------------------------------------------------- read the PDF

// Kerns inside a TJ array: a column break in these tables is about -1100 or
// more, the apostrophe in 140'480 is about +73, and a word space in prose is
// about -277. Anything at or beyond this is treated as a new cell.
const COLUMN_GAP = 300;

function contentStreams(pdf) {
  const streams = [];
  let i = 0;
  for (;;) {
    const s = pdf.indexOf('stream', i);
    if (s < 0) break;
    let p = s + 6;
    if (pdf[p] === 0x0d) p++;
    if (pdf[p] === 0x0a) p++;
    const e = pdf.indexOf('endstream', p);
    if (e < 0) break;
    i = e + 9;
    try {
      const text = inflateSync(pdf.subarray(p, e)).toString('latin1');
      if (text.includes('BT') && (text.includes('TJ') || text.includes('Tj'))) {
        streams.push(text);
      }
    } catch {
      // Image and font streams use other filters; they carry no text.
    }
  }
  if (streams.length === 0) die(2, 'no inflatable content stream in the PDF');
  return streams;
}

// Glyph indices sit at a constant offset from ASCII in this report's subset
// fonts. Derive the offset rather than trusting last month's: score every
// candidate by how much of the report's own boilerplate it reproduces.
const ANCHORS = ['Tabelle', 'Arbeitslose', 'Kurzarbeit', 'Quelle', 'SECO'];
function decodeOffset(streams) {
  const sample = streams.join('\n');
  const glyphs = [];
  const hx = /<([0-9A-Fa-f]{4,})>/g;
  let m;
  while ((m = hx.exec(sample))) {
    const s = m[1];
    for (let k = 0; k + 4 <= s.length; k += 4) glyphs.push(parseInt(s.slice(k, k + 4), 16));
    glyphs.push(-1); // string boundary, so anchors cannot span two strings
  }
  let best = { offset: null, score: 0 };
  for (let offset = 0; offset <= 0x40; offset++) {
    const text = glyphs
      .map((g) => {
        if (g < 0) return '\n';
        const c = g + offset;
        return c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '\u0000';
      })
      .join('');
    let score = 0;
    for (const a of ANCHORS) score += text.split(a).length - 1;
    if (score > best.score) best = { offset, score };
  }
  if (best.offset === null || best.score < ANCHORS.length) {
    die(2, 'could not derive the glyph-to-ASCII offset; the report\'s fonts have changed');
  }
  return best.offset;
}

// Walk each content stream keeping the text and line matrices, so every shown
// string gets a position. Row grouping depends on it: without it a whole table
// collapses into one unsplittable blob of digits.
function extractItems(streams, offset) {
  const dec = (g) => {
    const c = g + offset;
    return c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '?';
  };
  const pages = [];
  for (const stream of streams) {
    const items = [];
    // Only the translation of a cm matters here, and tables live at page level.
    const stack = [];
    let ox = 0, oy = 0;
    let tx = 0, ty = 0, lx = 0, ly = 0, leading = 0;
    const tok =
      /(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (cm|Tm)|(-?[\d.]+) (-?[\d.]+) (Td|TD)|(-?[\d.]+) TL|(T\*)|(q|Q|BT|ET)|\[((?:[^\]\\]|\\.)*)\]\s*TJ|((?:<[0-9A-Fa-f]*>|\((?:\\.|[^\\()])*\))\s*Tj)/g;
    let m;
    while ((m = tok.exec(stream))) {
      if (m[7] === 'cm') {
        ox += parseFloat(m[5]);
        oy += parseFloat(m[6]);
      } else if (m[7] === 'Tm') {
        tx = lx = parseFloat(m[5]);
        ty = ly = parseFloat(m[6]);
      } else if (m[10]) {
        lx += parseFloat(m[8]);
        ly += parseFloat(m[9]);
        tx = lx;
        ty = ly;
        if (m[10] === 'TD') leading = -parseFloat(m[9]);
      } else if (m[11] !== undefined) {
        leading = parseFloat(m[11]);
      } else if (m[12]) {
        ly -= leading;
        tx = lx;
        ty = ly;
      } else if (m[13] === 'q') {
        stack.push([ox, oy]);
      } else if (m[13] === 'Q') {
        const top = stack.pop();
        if (top) [ox, oy] = top;
      } else if (m[13] === 'BT') {
        tx = ty = lx = ly = 0;
      } else if (m[14] !== undefined || m[15] !== undefined) {
        // One TJ array can hold a whole table row: the twelve monthly values
        // separated by large negative kerns, with small ones inside a number
        // around the thousands apostrophe. Split on the column-sized gaps only,
        // or the row arrives as one unsplittable run of digits.
        const body = m[14] ?? m[15];
        const parts = [];
        let text = '';
        const inner = /<([0-9A-Fa-f]*)>|(-?[\d.]+)/g;
        let p;
        while ((p = inner.exec(body))) {
          if (p[1] !== undefined) {
            for (let k = 0; k + 4 <= p[1].length; k += 4) {
              text += dec(parseInt(p[1].slice(k, k + 4), 16));
            }
          } else if (parseFloat(p[2]) <= -COLUMN_GAP) {
            parts.push(text);
            text = '';
          }
        }
        parts.push(text);
        // Nudge the x of each part so the row sorts left to right. Glyph widths
        // are not tracked, and the nudge stays far below one column.
        parts.forEach((part, k) => {
          if (part.trim() !== '') items.push({ x: ox + tx + k * 0.01, y: oy + ty, text: part.trim() });
        });
      }
    }
    if (items.length) pages.push(items);
  }
  return pages;
}

// Group a page's items into visual rows: same baseline, left to right.
function rowsOf(items) {
  const byY = new Map();
  for (const it of items) {
    const key = Math.round(it.y * 2) / 2;
    if (!byY.has(key)) byY.set(key, []);
    byY.get(key).push(it);
  }
  return [...byY.keys()]
    .sort((a, b) => b - a)
    .map((k) => byY.get(k).sort((a, b) => a.x - b.x).map((it) => it.text));
}

// -------------------------------------------------------------- parse a table

function parseNumber(text, decimals) {
  // 140'480 arrives as 140?480: the thousands apostrophe is outside the ASCII
  // window the glyph offset covers. Decimal separators are inconsistent in the
  // report itself (both "-0,8" and "-0.5" occur), so both are accepted.
  const cleaned = text.replace(/[^\d.,-]/g, '');
  if (!/\d/.test(cleaned)) return null;
  if (decimals === 0) {
    const digits = cleaned.replace(/[^\d-]/g, '');
    return digits === '' ? null : Number(digits);
  }
  const n = Number(cleaned.replace(',', '.').replace(/(?!^)-/g, ''));
  return Number.isFinite(n) ? n : null;
}

function parseHistoryTable(pages, spec) {
  const head = new RegExp(`^Tabelle${spec.table}:`);
  for (const items of pages) {
    const rows = rowsOf(items);
    const start = rows.findIndex((r) => head.test(r.join('')));
    if (start < 0) continue;
    const joined = rows[start].join('');
    if (!spec.title.test(joined)) {
      die(1, `table ${spec.table} is titled "${joined}", not ${spec.title}`);
    }
    const observations = [];
    const means = [];
    for (let i = start + 1; i < rows.length; i++) {
      const row = rows[i];
      if (/^Quelle:/.test(row.join(''))) break;
      const year = /^(20\d\d)$/.exec(row[0]);
      if (!year) continue;
      const cells = row.slice(1).map((c) => parseNumber(c, spec.decimals));
      const months = cells.slice(0, 12).filter((v) => v !== null);
      // A full year prints a 13th cell: the annual mean. Partial years do not.
      const mean = cells.length > 12 ? cells[12] : null;
      months.forEach((value, k) => {
        observations.push({ year: Number(year[1]), month: k + 1, value });
      });
      if (mean !== null && months.length === 12) {
        means.push({ year: Number(year[1]), printed: mean, months });
      }
    }
    if (observations.length === 0) die(1, `table ${spec.table}: no year rows parsed`);
    return { observations, means };
  }
  die(1, `table ${spec.table} (${spec.series}) not found in the report`);
}

// ------------------------------------------------------------------ run

const report = findLatestReport(await get(INDEX_URL));
console.log(`report: ${report.title} (${report.year}-${String(report.month).padStart(2, '0')})`);
console.log(`  ${report.url}`);

const pdf = await get(report.url, true);
if (pdf.subarray(0, 5).toString('latin1') !== '%PDF-') die(2, 'downloaded file is not a PDF');
const streams = contentStreams(pdf);
const offset = decodeOffset(streams);
console.log(`  ${streams.length} content streams, glyph offset 0x${offset.toString(16)}`);
const pages = extractItems(streams, offset);

// When the report's layout moves, the fastest way to see what the scraper is
// actually reading is to print the rows it reconstructed:
//   SECO_DEBUG='Tabelle16|TotalArbeitslose' node seco_amstat/scrape_seco_amstat.mjs
// Datenstand is the cut-off the short-time-work tables are settled to; it is
// printed under them and is the closest thing to a vintage marker on offer.
const allText = pages.map((p) => rowsOf(p).map((r) => r.join(' ')).join('\n')).join('\n');
const datenstand = /Datenstand:(\d{2})\.(\d{2})\.(\d{4})/.exec(allText);

if (process.env.SECO_DEBUG) {
  const want = new RegExp(process.env.SECO_DEBUG);
  pages.forEach((items, i) => {
    for (const row of rowsOf(items)) {
      const line = row.join(' ');
      if (want.test(line)) console.error(`[stream ${i + 1}] ${line}`);
    }
  });
}

const rowsOut = [];
const problems = [];
for (const spec of TABLES) {
  const { observations, means } = parseHistoryTable(pages, spec);

  // The report prints each full year's mean. Recomputing it from the twelve
  // monthly values is the check that the glyphs decoded to the right digits:
  // a wrong offset produces wrong numbers, not an error.
  const tol = spec.decimals === 0 ? 1 : 0.06;
  for (const m of means) {
    const mine = m.months.reduce((a, b) => a + b, 0) / 12;
    if (Math.abs(mine - m.printed) > tol) {
      problems.push(
        `${spec.series} ${m.year}: mean of months ${mine.toFixed(2)} ` +
          `but the report prints ${m.printed}`,
      );
    }
  }
  if (means.length === 0 && spec.decimals === 0) {
    // Tables 26 and 27 print no mean column; they are covered by the ordering
    // and front-table checks only. Not fatal, but worth saying out loud.
    console.log(`  ${spec.series}: no annual-mean column to check against`);
  }

  observations.sort((a, b) => a.year - b.year || a.month - b.month);
  const first = observations[0];
  const last = observations[observations.length - 1];
  if (first.year !== 2004 || first.month !== 1) {
    problems.push(`${spec.series}: starts ${first.year}-${first.month}, expected 2004-01`);
  }
  console.log(
    `  ${spec.series}: ${observations.length} months, ` +
      `${first.year}-${String(first.month).padStart(2, '0')} to ` +
      `${last.year}-${String(last.month).padStart(2, '0')}` +
      `${means.length ? `, ${means.length} annual means checked` : ''}`,
  );
  for (const o of observations) {
    // The figures are end-of-month: stocks are counted on the last day of the
    // month (SECO's Stichtag) and the short-time-work flows cover the month
    // that ends on it. The date is therefore the last day of the month.
    const date = new Date(Date.UTC(o.year, o.month, 0)).toISOString().slice(0, 10);
    rowsOut.push({
      date,
      month: `${o.year}-${String(o.month).padStart(2, '0')}`,
      series: spec.series,
      value: o.value,
      unit: spec.unit,
      decimals: spec.decimals,
    });
  }
}

// Cross-check the newest unemployment figure against table 1 on the front
// page, which is laid out completely differently. If the history table and the
// front table agree, the table was read in the right place.
// The stub "Total Arbeitslose" is set over two baselines, so the row carrying
// the numbers begins with "Total" alone. One printed page is also split across
// several content streams, with the title and the body of table 1 landing in
// different ones, so this scans forward in document order from the title
// rather than expecting both in the same stream.
const docRows = pages.flatMap((items) => rowsOf(items).map((r) => r.join(' ')));
const titleAt = docRows.findIndex((r) => /^Tabelle1:/.test(r));
const frontRow =
  titleAt < 0
    ? null
    : docRows.slice(titleAt).find((r) => /^Total(\s+[\d?'.,+-]+){3,}/.test(r)) ?? null;
const latest = rowsOut
  .filter((r) => r.series === 'unemployed')
  .sort((a, b) => (a.month < b.month ? -1 : 1))
  .pop();
if (!frontRow) {
  problems.push('table 1 row "Total Arbeitslose" not found, cannot cross-check the newest value');
} else {
  const firstNumber = /^Total\s+(\d[\d?'.,]*)/.exec(frontRow);
  const front = firstNumber ? parseNumber(firstNumber[1], 0) : null;
  if (front !== latest.value) {
    problems.push(
      `newest unemployed ${latest.value} (table 16) disagrees with table 1 (${front})`,
    );
  } else {
    console.log(`  cross-check: table 1 and table 16 agree on ${front} for ${latest.month}`);
  }
}

if (problems.length) {
  for (const p of problems) console.error(`  FAIL ${p}`);
  die(1, `${problems.length} check(s) failed; nothing written`);
}

rowsOut.sort(
  (a, b) => (a.series < b.series ? -1 : a.series > b.series ? 1 : a.month < b.month ? -1 : 1),
);
mkdirSync(OUT_DIR, { recursive: true });
const cols = ['date', 'month', 'series', 'value', 'unit'];
writeFileSync(
  join(OUT_DIR, 'seco_amstat.csv'),
  [
    cols.join(','),
    // The rates are published to one decimal; keep the published precision
    // rather than letting 3,0 become a bare 3.
    ...rowsOut.map((r) =>
      cols.map((c) => (c === 'value' ? r.value.toFixed(r.decimals) : r[c])).join(','),
    ),
  ].join('\n') + '\n',
);

const sourceCols = ['report', 'reference_month', 'published', 'datenstand', 'url', 'rows', 'retrieved'];
const source = {
  report: report.title,
  reference_month: `${report.year}-${String(report.month).padStart(2, '0')}`,
  published: report.published,
  datenstand: datenstand ? `${datenstand[3]}-${datenstand[2]}-${datenstand[1]}` : '',
  url: report.url,
  rows: rowsOut.length,
  retrieved: new Date().toISOString().slice(0, 10),
};
writeFileSync(
  join(OUT_DIR, 'source.csv'),
  [sourceCols.join(','), sourceCols.map((c) => `"${String(source[c]).replace(/"/g, '""')}"`).join(',')].join('\n') +
    '\n',
);
console.log(`seco_amstat.csv: ${rowsOut.length} rows; source.csv written`);
