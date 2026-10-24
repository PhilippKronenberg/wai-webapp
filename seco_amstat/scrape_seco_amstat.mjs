// Run from the repository root.

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
//
// Scrape the monthly SECO labour-market figures off the arbeit.swiss PDFs
// (wai-webapp #36, route chosen by the owner over the SNB amarbma mirror
// because SECO publishes ~5 days after month end and the mirror ~3 weeks)
//
// SECO has no machine-readable route to these numbers. AMSTAT (amstat.ch) is
// a MicroStrategy dossier whose only export is through the BI widget and
// whose unauthenticated login returns 401 from outside; BFS STAT-TAB does not
// carry registered unemployment. What is left is the monthly PDF pair on
//
//   https://www.arbeit.swiss/de/informationszentrum/arbeitsmarktstatistik-schweiz
//
// Of the two, the "Leporello" fold-out is the one with tables; "Die Lage auf
// dem Arbeitsmarkt" is a chart deck whose numbers live in the plots. This
// script reads the Leporellos.
//
// The PDF filenames are opaque UUIDs under /api/media/fileservice/..., so
// there is nothing to construct: the page has to be scraped each month for
// the current links. That is what the first half of this script does.
//
// Node built-ins only, like everything else that runs in this repository --
// which means the PDF text extraction is done here, by inflating the content
// streams and reading the text-positioning operators. That is enough for
// these files because their text is literal strings in a standard encoding;
// it is not a general PDF parser and will not survive SECO switching tool.
// Every figure is therefore range-checked before it is written out, and a
// month that fails its checks is reported and left out rather than written.
//
// What is extracted, per Leporello, all at the national level:
//
//   unemployed, unemployment_rate, youth_unemployed, youth_unemployment_rate,
//   long_term_unemployed, job_seekers, vacancies_registered
//                                        for the Leporello's own month
//   benefit_exhaustions                  for an earlier month, stated in the
//                                        fold-out (currently 2 months back)
//   stw_establishments, stw_workers, stw_hours_lost, stw_compensation_chf
//                                        settled short-time work, for the
//                                        "Berichtsmonat" the fold-out states
//                                        (currently 3 months back)
//
// Three things worth knowing before using the output:
//
// 1. These are the RAW counts, as the owner asked. SECO's seasonally adjusted
//    figures are recomputed with X-13-ARIMA-SEATS at every new observation
//    and so are rewritten every month; seasonal adjustment belongs in mfbdfm.
//
// 2. Approved / pre-notified short-time work (Voranmeldungen) is NOT in these
//    PDFs. Only settled short-time work (abgerechnete Kurzarbeit) is, and it
//    runs three months behind and keeps being revised afterwards -- the
//    fold-out's own note says the last three months can still move by more
//    than 5%. The reported_in column is there for exactly that reason.
//
// 3. The page carries only the current year's Leporellos. Each run therefore
//    sees roughly 12 months at most, and history has to be accumulated by
//    keeping the CSV and rerunning monthly. Rows already in the CSV for
//    months no longer on the page are preserved on rerun.
//
// Usage
//   node seco_amstat/scrape_seco_amstat.mjs              scrape, download, rewrite the CSV
//   node seco_amstat/scrape_seco_amstat.mjs <out.csv>
//   node seco_amstat/scrape_seco_amstat.mjs <out.csv> <pdf-dir>
//
// The third form reuses Leporello PDFs already in <pdf-dir> instead of
// downloading them again, which is how to re-parse without hitting the
// server. Without it the PDFs go to a temporary directory and are not kept:
// arbeit.swiss's legal notice does not allow redistributing them, so they are
// deliberately not committed here. Exit status is 1 if any month failed.
//
//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { inflateSync } from 'node:zlib';


// SETTINGS ----------------------------------------------------------------

const PAGE = 'https://www.arbeit.swiss/de/informationszentrum/arbeitsmarktstatistik-schweiz';
const ORIGIN = 'https://www.arbeit.swiss';

const DEFAULT_OUT = join('seco_amstat', 'seco_amstat_monthly.csv');
const SOURCES_FILE = 'seco_amstat_sources.json';

const HEADERS = { 'User-Agent': 'wai-webapp/seco-amstat-scrape (+https://github.com/PhilippKronenberg/wai-webapp)' };

// German month names as the page and the fold-out spell them, matched on a
// prefix so that "Maerz", "Mrz" and a mis-decoded "M?rz" all still resolve.
const MONTHS = [
  [/^Jan/i, 1], [/^Feb/i, 2], [/^M\S*rz/i, 3], [/^Apr/i, 4], [/^Mai/i, 5], [/^Jun/i, 6],
  [/^Jul/i, 7], [/^Aug/i, 8], [/^Sep/i, 9], [/^Okt/i, 10], [/^Nov/i, 11], [/^Dez/i, 12],
];

// Left-column labels of the fold-out's national summary block, in the order
// they appear, with the series id each one carries and a plausible range.
// "- Quote" rows belong to the label above them, which is why they are here
// as a modifier rather than as a label of their own.
const SUMMARY = [
  { match: /^Arbeitslose$/, id: 'unemployed', unit: 'persons', min: 50000, max: 1000000,
    rate: { id: 'unemployment_rate', unit: 'percent', min: 0.5, max: 25 } },
  { match: /^Jugendarbeitslose$/, id: 'youth_unemployed', unit: 'persons', min: 2000, max: 200000,
    rate: { id: 'youth_unemployment_rate', unit: 'percent', min: 0.5, max: 25 } },
  { match: /^Langzeitarbeitslose$/, id: 'long_term_unemployed', unit: 'persons', min: 1000, max: 400000 },
  { match: /^Stellensuchende$/, id: 'job_seekers', unit: 'persons', min: 50000, max: 1000000 },
  { match: /^Offene Stellen$/, id: 'vacancies_registered', unit: 'vacancies', min: 1000, max: 300000 },
  // Reported for an earlier month, named in a header above the row.
  { match: /^Aussteuerungen$/, id: 'benefit_exhaustions', unit: 'persons', min: 100, max: 100000,
    datedAbove: true },
];

// The settled short-time work table: one "Total" row, four figures, for the
// Berichtsmonat the fold-out names.
const STW = [
  { id: 'stw_establishments', unit: 'establishments', min: 0, max: 200000 },
  { id: 'stw_workers', unit: 'persons', min: 0, max: 2000000 },
  { id: 'stw_hours_lost', unit: 'hours', min: 0, max: 200000000 },
  { id: 'stw_compensation_chf', unit: 'chf', min: 0, max: 5000000000 },
];


// THE PAGE ----------------------------------------------------------------

async function fetchText(url) {
  const res = await fetch(url, { headers: HEADERS });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return await res.text();
}

function monthNumber(name) {
  for (const [re, n] of MONTHS) if (re.test(name)) return n;
  return null;
}

// Anchors on the page look like
//   <a href="/api/media/fileservice/.../<uuid>.pdf" ...>Leporello September 2026 PDF | 06.10.2026</a>
// with the visible date sometimes absent. Returns one entry per Leporello.
function findLeporellos(html) {
  const out = [];
  const anchor = /<a\b[^>]*href="([^"]+\.pdf)"[^>]*>([\s\S]*?)<\/a>/gi;
  for (const m of html.matchAll(anchor)) {
    const text = m[2].replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
    const title = /Leporello\s+(\S+)\s+(\d{4})/i.exec(text);
    if (!title) continue;
    const month = monthNumber(title[1]);
    if (!month) continue;
    const pageDate = /(\d{2})\.(\d{2})\.(\d{4})/.exec(text);
    out.push({
      url: m[1].startsWith('http') ? m[1] : ORIGIN + m[1],
      title: text,
      month: `${title[2]}-${String(month).padStart(2, '0')}`,
      page_date: pageDate ? `${pageDate[3]}-${pageDate[2]}-${pageDate[1]}` : null,
    });
  }
  // Newest first, and never the same month twice.
  const seen = new Set();
  return out
    .sort((a, b) => (a.month < b.month ? 1 : -1))
    .filter((d) => (seen.has(d.month) ? false : seen.add(d.month)));
}


// THE PDFs ----------------------------------------------------------------

// Inflates every content stream and reads the text-showing operators out of
// it, keeping where on the page each string was drawn. Not a general PDF
// reader: it assumes literal strings in a single-byte encoding, which is what
// these files use. Text is decoded as latin1, which is what WinAnsi is for
// the characters that occur here.
function extractTokens(buffer) {
  const latin = buffer.toString('latin1');
  const tokens = [];
  let panel = 0;
  const streamStart = /stream\r?\n/g;
  for (const m of latin.matchAll(streamStart)) {
    const from = m.index + m[0].length;
    const to = latin.indexOf('endstream', from);
    if (to < 0) continue;
    let content;
    try {
      content = inflateSync(buffer.subarray(from, to)).toString('latin1');
    } catch {
      continue;                               // not a Flate stream, or not a stream at all
    }
    if (!/\bTj\b|\bTJ\b/.test(content)) continue;
    panel++;

    // Td and TD move the text cursor; Tm sets the whole text matrix and its
    // last two numbers are the position. TJ is an array of strings and
    // kerning numbers; Tj is a single string.
    const op = new RegExp(
      '(-?[\\d.]+)\\s+(-?[\\d.]+)\\s+T[dD]' +
      '|(-?[\\d.]+)\\s+(-?[\\d.]+)\\s+(-?[\\d.]+)\\s+(-?[\\d.]+)\\s+(-?[\\d.]+)\\s+(-?[\\d.]+)\\s+Tm' +
      '|\\[((?:[^\\]\\\\]|\\\\.)*)\\]\\s*TJ' +
      '|\\(((?:[^)\\\\]|\\\\.)*)\\)\\s*Tj',
      'g',
    );
    let x = 0;
    let y = 0;
    for (const t of content.matchAll(op)) {
      if (t[1] !== undefined) { x = Number(t[1]); y = Number(t[2]); continue; }
      if (t[3] !== undefined) { x = Number(t[7]); y = Number(t[8]); continue; }
      const raw = t[9] !== undefined
        ? [...t[9].matchAll(/\(((?:[^)\\]|\\.)*)\)/g)].map((s) => s[1]).join('')
        : t[10];
      const text = raw
        .replace(/\\(\d{1,3})/g, (_, oct) => String.fromCharCode(parseInt(oct, 8)))
        .replace(/\\([()\\])/g, '$1')
        .trim();
      if (text) tokens.push({ panel, x, y, text });
    }
  }
  return tokens;
}

// "140'480" -> 140480, " -1'064" -> -1064, "3.0" -> 3.0. Returns null for
// anything that is not a bare number, which is how the row readers below
// tell a figure from a label. The text is kept as well as the number,
// because the CSV should say 3.0 where SECO prints 3.0: Number() would
// write 3 and quietly claim a precision SECO did not publish.
function toFigure(text) {
  const cleaned = text.replace(/[’' \s]/g, '').replace(/^\+/, '');
  if (!/^-?\d+(\.\d+)?$/.test(cleaned)) return null;
  return { value: Number(cleaned), text: cleaned };
}

// The figures of a table row: numeric tokens to the right of the label, on
// the same line, within the width of the block. The tolerance on y is there
// because the fold-out sets some figures half a point off their row.
function figuresRightOf(tokens, label, { width = 260, tolerance = 1.6 } = {}) {
  return tokens
    .filter((t) => t.panel === label.panel
      && t.x > label.x
      && t.x <= label.x + width
      && Math.abs(t.y - label.y) <= tolerance)
    .sort((a, b) => a.x - b.x)
    .map((t) => toFigure(t.text))
    .filter((f) => f !== null);
}

function monthToken(text) {
  const m = /^(\S+)\s+(\d{4})$/.exec(text);
  if (!m) return null;
  const n = monthNumber(m[1]);
  return n ? `${m[2]}-${String(n).padStart(2, '0')}` : null;
}

// The month a fold-out is about: the month-and-year that its headers repeat
// most often. The other months it mentions (short-time work, exhaustions)
// each appear once.
function reportMonthOf(tokens) {
  const counts = new Map();
  for (const t of tokens) {
    const m = monthToken(t.text);
    if (m) counts.set(m, (counts.get(m) ?? 0) + 1);
  }
  let best = null;
  for (const [month, n] of counts) {
    if (!best || n > best.n || (n === best.n && month > best.month)) best = { month, n };
  }
  return best && best.n > 1 ? best.month : null;
}

// The month named in the header immediately above a row -- how the fold-out
// dates its exhaustions figures, which are not for the fold-out's own month.
function monthAbove(tokens, label) {
  const candidates = tokens
    .filter((t) => t.panel === label.panel
      && t.y > label.y && t.y < label.y + 40
      && t.x >= label.x && t.x <= label.x + 260
      && monthToken(t.text))
    .sort((a, b) => a.y - b.y);
  return candidates.length ? monthToken(candidates[0].text) : null;
}

function parseLeporello(tokens) {
  const problems = [];
  const rows = [];
  const reportMonth = reportMonthOf(tokens);
  if (!reportMonth) return { reportMonth: null, rows, problems: ['no month header found'] };

  const date = (month) => `${month}-01`;

  // --- the national summary block, in the left margin of the fold-out ---
  // Labels there sit at x ~ 10; the same words appear inside the charts
  // further right, which is what the x bound keeps out.
  const left = tokens
    .filter((t) => t.x <= 40)
    .sort((a, b) => b.y - a.y);

  for (const spec of SUMMARY) {
    const label = left.find((t) => spec.match.test(t.text));
    if (!label) { problems.push(`${spec.id}: label not found`); continue; }

    const figures = figuresRightOf(tokens, label);
    if (figures.length < 1) { problems.push(`${spec.id}: no figures on its row`); continue; }

    let month = reportMonth;
    if (spec.datedAbove) {
      month = monthAbove(tokens, label);
      if (!month) { problems.push(`${spec.id}: no month header above the row`); continue; }
    }
    rows.push({ date: date(month), series: spec.id, value: figures[0].text, number: figures[0].value, unit: spec.unit, spec });

    if (!spec.rate) continue;
    // The rate is the "- Quote" row directly under the level.
    const quote = left.find((t) => /^-\s*Quote/.test(t.text) && t.y < label.y && t.y > label.y - 25);
    if (!quote) { problems.push(`${spec.rate.id}: no "- Quote" row under ${spec.id}`); continue; }
    const rateFigures = figuresRightOf(tokens, quote);
    if (!rateFigures.length) { problems.push(`${spec.rate.id}: no figures on its row`); continue; }
    rows.push({
      date: date(month),
      series: spec.rate.id,
      value: rateFigures[0].text,
      number: rateFigures[0].value,
      unit: spec.rate.unit,
      spec: spec.rate,
    });
  }

  // --- settled short-time work, with the Berichtsmonat it states ---
  const stwHeader = tokens.find((t) => /Berichtsmonat/.test(t.text));
  if (!stwHeader) {
    problems.push('short-time work: no "Berichtsmonat" label');
  } else {
    const named = tokens
      .filter((t) => t.panel === stwHeader.panel
        && Math.abs(t.y - stwHeader.y) <= 1.6
        && t.x > stwHeader.x
        && monthToken(t.text))
      .sort((a, b) => a.x - b.x);
    const total = tokens
      .filter((t) => t.panel === stwHeader.panel && t.x <= 20 && /^Total$/.test(t.text))
      .sort((a, b) => b.y - a.y)[0];
    if (!named.length) problems.push('short-time work: Berichtsmonat names no month');
    else if (!total) problems.push('short-time work: no "Total" row');
    else {
      const month = monthToken(named[0].text);
      const figures = figuresRightOf(tokens, total);
      if (figures.length < STW.length) {
        problems.push(`short-time work: ${figures.length} figures on the Total row, expected ${STW.length}`);
      } else {
        STW.forEach((spec, i) => {
          rows.push({
            date: date(month),
            series: spec.id,
            value: figures[i].text,
            number: figures[i].value,
            unit: spec.unit,
            spec,
          });
        });
      }
    }
  }

  // --- range checks, and the one cross-check the fold-out allows ---
  for (const row of rows) {
    const { min, max } = row.spec;
    if (!Number.isFinite(row.number) || row.number < min || row.number > max) {
      problems.push(`${row.series}: ${row.value} is outside [${min}, ${max}]`);
    }
  }
  const value = (id) => rows.find((r) => r.series === id)?.number;
  if (value('job_seekers') !== undefined && value('unemployed') !== undefined
      && value('job_seekers') <= value('unemployed')) {
    problems.push('job_seekers is not above unemployed');
  }
  if (value('youth_unemployed') !== undefined && value('unemployed') !== undefined
      && value('youth_unemployed') >= value('unemployed')) {
    problems.push('youth_unemployed is not below unemployed');
  }
  // The vacancies total also appears at the head of the by-canton table.
  const cantonTotal = tokens
    .filter((t) => /^Total\*/.test(t.text))
    .map((t) => figuresRightOf(tokens, t)[0]?.value)
    .find((n) => n !== undefined);
  if (cantonTotal !== undefined && value('vacancies_registered') !== undefined
      && cantonTotal !== value('vacancies_registered')) {
    problems.push(`vacancies_registered ${value('vacancies_registered')} disagrees with the ` +
      `by-canton total ${cantonTotal}`);
  }

  return { reportMonth, rows: rows.map(({ spec, number, ...row }) => row), problems };
}


// THE CSV -----------------------------------------------------------------

function csvField(value) {
  const s = String(value);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

// Rows for months that are no longer on the page stay in the file: the page
// only ever shows the current year, so the CSV is the history.
function readExisting(path) {
  if (!existsSync(path)) return [];
  const lines = readFileSync(path, 'utf8').split('\n').filter((l) => l.trim() !== '');
  return lines.slice(1).map((line) => {
    const [date, series, value, unit, reportedIn] = line.split(',');
    return { date, series, value, unit, reported_in: reportedIn };
  });
}

function writeCsv(path, rows) {
  const header = ['date', 'series', 'value', 'unit', 'reported_in'];
  const body = rows
    .map((r) => [r.date, r.series, r.value, r.unit, r.reported_in].map(csvField).join(','));
  writeFileSync(path, `${header.join(',')}\n${body.join('\n')}\n`);
}


// ASSEMBLY ----------------------------------------------------------------

async function main() {
  const out = process.argv[2] ?? DEFAULT_OUT;
  const outdir = out.includes('/') ? out.slice(0, out.lastIndexOf('/')) : '.';
  const pdfDir = process.argv[3] ?? mkdtempSync(join(tmpdir(), 'seco-leporello-'));
  if (!existsSync(pdfDir)) mkdirSync(pdfDir, { recursive: true });

  console.log(`scraping ${PAGE}`);
  const documents = findLeporellos(await fetchText(PAGE));
  if (!documents.length) {
    throw new Error('no Leporello links on the page -- its markup or the naming has changed.');
  }
  console.log(`${documents.length} Leporello(s) linked: ${documents.map((d) => d.month).join(', ')}`);

  const fresh = [];
  const records = [];
  let failures = 0;

  for (const doc of documents.slice().reverse()) {
    const file = join(pdfDir, `leporello-${doc.month}.pdf`);
    let buffer;
    if (existsSync(file)) {
      buffer = readFileSync(file);
    } else {
      const res = await fetch(doc.url, { headers: HEADERS });
      if (!res.ok) {
        console.error(`${doc.month}: HTTP ${res.status} downloading the PDF`);
        records.push({ ...doc, status: `download failed: HTTP ${res.status}` });
        failures++;
        continue;
      }
      buffer = Buffer.from(await res.arrayBuffer());
      writeFileSync(file, buffer);
    }

    const record = {
      reported_in: doc.month,
      title: doc.title,
      page_date: doc.page_date,
      url: doc.url,
      bytes: buffer.length,
      sha256: createHash('sha256').update(buffer).digest('hex'),
    };

    if (buffer.subarray(0, 5).toString('latin1') !== '%PDF-') {
      record.status = 'not a PDF';
      records.push(record);
      failures++;
      console.error(`${doc.month}: the download is not a PDF`);
      continue;
    }

    const { reportMonth, rows, problems } = parseLeporello(extractTokens(buffer));
    if (reportMonth && reportMonth !== doc.month) {
      problems.unshift(`the fold-out is about ${reportMonth}, the link says ${doc.month}`);
    }
    if (problems.length) {
      record.status = `failed: ${problems.join('; ')}`;
      records.push(record);
      failures++;
      console.error(`${doc.month}: ${problems.join('; ')}`);
      continue;
    }

    record.status = 'ok';
    record.series_extracted = rows.length;
    records.push(record);
    for (const row of rows) fresh.push({ ...row, reported_in: doc.month });
    console.log(`${doc.month}: ${rows.length} figures`);
  }

  // Keep anything already in the CSV that this run did not re-read, then let
  // this run's figures win for the (month, series, vintage) it did read.
  const key = (r) => `${r.date}|${r.series}|${r.reported_in}`;
  const merged = new Map(readExisting(out).map((r) => [key(r), r]));
  for (const row of fresh) merged.set(key(row), row);
  const rows = [...merged.values()].sort((a, b) => (
    a.date < b.date ? -1 : a.date > b.date ? 1
      : a.series < b.series ? -1 : a.series > b.series ? 1
        : a.reported_in < b.reported_in ? -1 : 1));

  writeCsv(out, rows);
  console.log(`${rows.length} rows -> ${out}`);

  const sourcesPath = join(outdir, SOURCES_FILE);
  writeFileSync(sourcesPath, `${JSON.stringify({
    retrieved_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    source_page: PAGE,
    note: 'One entry per Leporello linked from the page at the time of the run. '
      + 'reported_in joins to the CSV column of the same name.',
    documents: records,
  }, null, 2)}\n`);
  console.log(`sources -> ${sourcesPath}`);

  if (failures) {
    console.error(`${failures} of ${documents.length} Leporellos did not yield figures.`);
    process.exitCode = 1;
  }
}

await main();
