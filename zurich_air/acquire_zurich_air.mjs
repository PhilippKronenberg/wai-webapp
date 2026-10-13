#!/usr/bin/env node
//
//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
//
// Acquire the City of Zurich daily air-quality measurements (wai-webapp #38)
//
// Downloads the per-year CSVs of "Taeglich aktualisierte
// Luftqualitaetsmessungen, seit 1983" from Umwelt- und Gesundheitsschutz
// Zuerich (UGZ) and writes them out as one tidy long CSV: one row per day,
// station, pollutant and statistic.
//
// Source
//   https://opendata.swiss/de/dataset/taglich-aktualisierte-luftqualitatsmessungen-seit-1983
//   Files    https://data.stadt-zuerich.ch/dataset/ugz_luftschadstoffmessung_tageswerte
//   Period   day; 1983 to the previous day
//   Updated  daily, 30 minutes after midnight (UTC+1)
//   Licence  opendata.swiss terms_open (free use, attribution not required)
//
// Node built-ins only, no dependencies. This repository has no build step and
// no node_modules, and a side script is not the thing that gets to introduce
// one. That is also why the per-year CSVs are read rather than the complete
// Parquet file the publisher also offers: Parquet would need a library.
//
// Four things about the source that this script handles rather than assumes
// away:
//
// 1. The resource list on opendata.swiss does not show every year (2022, 2002
//    and 1997 were missing from it when #38 was written). The files are there
//    all the same, so the years are enumerated 1983..current rather than read
//    off that list, and a gap in the middle is a hard error rather than a
//    silently short CSV.
//
// 2. A year that does not exist answers 500 with a CKAN HTML error page, not
//    404. Every response is therefore checked for the expected CSV header
//    before it is parsed. Only the current year is allowed to be absent: in
//    the first minutes of 1 January its file does not exist yet.
//
// 3. Missing values are the literal `NA`, unquoted, with the status still
//    "bereinigt" - a day that was measured but did not pass quality control.
//    Those rows are dropped, as in rhine_cargo: an absent row means not
//    measured or not of sufficient quality, never zero.
//
// 4. Ozone arrives as three parameters, not one: `O3` is the daily mean,
//    `O3_max_h1` the highest hourly mean of the day, and `O3_nb_h1>120` the
//    number of hourly means above the 120 ug/m3 limit. They are split into a
//    `pollutant` of `O3` and three different `statistic` values, so that
//    `pollutant` is a clean dimension and no row has to be recognised by a
//    suffix on its parameter name.
//
// Usage
//   node zurich_air/acquire_zurich_air.mjs
//   node zurich_air/acquire_zurich_air.mjs <output.csv>
//   node zurich_air/acquire_zurich_air.mjs <output.csv> --cache <dir>
//
// With --cache the downloads are kept in <dir> and reused on the next run,
// which is how to re-parse without hitting the server 40-odd times. Nothing
// is written unless the script is run, and only to the paths given.
//
//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";

// ------------------------------------------------------------------ settings

const BASE =
  "https://data.stadt-zuerich.ch/dataset/ugz_luftschadstoffmessung_tageswerte/download";

// "uzg", not "ugz". The publisher's own spelling of the metadata file; the
// data files are "ugz_". Correcting it here would 500.
const META_URL = `${BASE}/uzg_ogd_metadaten.json`;
const yearUrl = (year) => `${BASE}/ugz_ogd_air_d1_${year}.csv`;

const FIRST_YEAR = 1983;
const DEFAULT_OUT = join("zurich_air", "zurich_air.csv");

// The publisher's column order, which is asserted rather than searched for: a
// reordered or renamed header means the file changed shape and the parse below
// is no longer the right one.
const SOURCE_HEADER = [
  "Datum", "Standort", "Parameter", "Intervall", "Einheit", "Wert", "Status",
];
const OUT_COLUMNS = [
  "date", "station", "pollutant", "statistic", "value", "unit", "status",
];

// Only daily values are expected in this dataset. The output has no interval
// column, so anything else would be silently mixed in with the daily means.
const EXPECTED_INTERVAL = "d1";

// Parameters that are a statistic of another pollutant rather than a pollutant
// of their own. Everything not listed here is that pollutant's daily mean.
const DERIVED_STATISTICS = {
  O3_max_h1: { pollutant: "O3", statistic: "max_hourly_mean" },
  "O3_nb_h1>120": { pollutant: "O3", statistic: "hours_above_120" },
};
const DEFAULT_STATISTIC = "daily_mean";

// Values that stand for "no measurement" in the source.
const MISSING = new Set(["", "NA", "NaN", "null", "-"]);

const RETRIES = 3;
const RETRY_WAIT_MS = 4000;

// ------------------------------------------------------------------- helpers

const notes = [];
const note = (msg) => notes.push(msg);
const die = (msg) => {
  console.error(`FATAL: ${msg}`);
  process.exit(1);
};

const stripBom = (s) => (s.charCodeAt(0) === 0xfeff ? s.slice(1) : s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Fetch a URL as text, retrying transient failures. Returns null on failure. */
async function download(url, what) {
  for (let attempt = 1; attempt <= RETRIES; attempt++) {
    try {
      const res = await fetch(url, { redirect: "follow" });
      if (res.ok) return await res.text();
      // A year that does not exist answers 500, so a bad status is not on its
      // own evidence of a server problem; retry anyway and let the caller
      // decide what an eventual failure means.
      note(`${what}: HTTP ${res.status} (attempt ${attempt}/${RETRIES})`);
    } catch (e) {
      note(`${what}: ${e.message} (attempt ${attempt}/${RETRIES})`);
    }
    if (attempt < RETRIES) await sleep(RETRY_WAIT_MS * attempt);
  }
  return null;
}

/**
 * Parse RFC 4180 CSV into an array of arrays.
 *
 * The source quotes its text fields and leaves its numbers bare, so a split on
 * "," would leave every string wrapped in quotes. Small enough files that
 * parsing the whole text at once is fine.
 */
function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { quoted = false; }
      } else {
        field += c;
      }
      continue;
    }
    if (c === '"') { quoted = true; }
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
    else if (c !== "\r") { field += c; }
  }
  if (field !== "" || row.length > 0) { row.push(field); rows.push(row); }
  return rows;
}

// --------------------------------------------------------------------- parse

/**
 * Turn one year's CSV into output rows, checking everything the output format
 * assumes: the header, the interval, the timestamp, and that a value that is
 * not marked missing really is a number.
 */
function parseYear(year, text, state) {
  const rows = parseCsv(stripBom(text));
  if (rows.length === 0) die(`${year}: file is empty`);

  const header = rows[0].map((h) => h.trim());
  if (header.join(",") !== SOURCE_HEADER.join(",")) {
    die(`${year}: unexpected header [${header.join(", ")}], expected `
      + `[${SOURCE_HEADER.join(", ")}]. The source layout has changed.`);
  }

  // Midnight in Central European winter time, with or without seconds: the
  // metadata documents "2025-03-15T14:00:00+01:00" while the files currently
  // write "2025-01-01T00:00+0100". Both are accepted; a timestamp that is not
  // the start of a day in +01:00 is not, because the output keeps the date
  // only and would quietly shift it.
  const stamp = /^(\d{4})-(\d{2})-(\d{2})T00:00(?::00)?\+01:?00$/;

  const out = [];
  for (let i = 1; i < rows.length; i++) {
    const r = rows[i];
    if (r.length === 1 && r[0].trim() === "") continue;    // trailing newline
    if (r.length !== SOURCE_HEADER.length) {
      die(`${year}: line ${i + 1} has ${r.length} fields, expected `
        + `${SOURCE_HEADER.length}`);
    }
    const [datum, station, parameter, interval, unit, value, status] =
      r.map((f) => f.trim());

    const m = stamp.exec(datum);
    if (!m) die(`${year}: line ${i + 1} has timestamp "${datum}", which is not `
      + `midnight UTC+01:00`);
    if (m[1] !== String(year)) {
      die(`${year}: line ${i + 1} is dated ${m[1]}, in the file for ${year}`);
    }
    if (interval !== EXPECTED_INTERVAL) {
      die(`${year}: line ${i + 1} has interval "${interval}", expected `
        + `"${EXPECTED_INTERVAL}". This dataset is meant to be daily only.`);
    }

    const date = `${m[1]}-${m[2]}-${m[3]}`;
    const derived = DERIVED_STATISTICS[parameter];
    const pollutant = derived ? derived.pollutant : parameter;
    const statistic = derived ? derived.statistic : DEFAULT_STATISTIC;

    state.stations.add(station);
    state.parameters.add(parameter);
    const unitKey = `${pollutant}\u0000${statistic}`;
    if (!state.units.has(unitKey)) state.units.set(unitKey, new Set());
    state.units.get(unitKey).add(unit);

    if (MISSING.has(value)) {
      state.dropped.set(unitKey, (state.dropped.get(unitKey) ?? 0) + 1);
      continue;
    }
    if (!Number.isFinite(Number(value))) {
      die(`${year}: line ${i + 1} has value "${value}" for ${parameter} at `
        + `${station}, which is neither a number nor a missing marker. Add it `
        + `to MISSING if the publisher has started using it for one.`);
    }
    state.statuses.set(status, (state.statuses.get(status) ?? 0) + 1);

    // The value text is passed through verbatim rather than reformatted, so
    // the CSV says exactly what the publisher said and no float round-trip
    // can move a digit.
    out.push([date, station, pollutant, statistic, value, unit, status]);
  }
  return out;
}

// ----------------------------------------------------------------------- run

const args = process.argv.slice(2);
let cacheDir = null;
const positional = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--cache") {
    cacheDir = args[++i];
    if (!cacheDir) die("--cache needs a directory");
  } else if (args[i].startsWith("--")) {
    die(`unknown option ${args[i]}`);
  } else {
    positional.push(args[i]);
  }
}
if (positional.length > 1) die("at most one output path");
const outFile = positional[0] ?? DEFAULT_OUT;
if (cacheDir) mkdirSync(cacheDir, { recursive: true });

/** Read from the cache if it is there, otherwise download and populate it. */
async function fetchCached(url, what, name) {
  const cached = cacheDir ? join(cacheDir, name) : null;
  if (cached && existsSync(cached)) {
    console.log(`Reusing ${cached}`);
    return readFileSync(cached, "utf8");
  }
  console.log(`Downloading ${url}`);
  const text = await download(url, what);
  if (text !== null && cached) writeFileSync(cached, text);
  return text;
}

// The metadata JSON is not needed to parse the data; it is read so that a
// station or a parameter the README does not document shows up as a note
// rather than silently appearing in the CSV.
const metaText = await fetchCached(META_URL, "metadata", "uzg_ogd_metadaten.json");
let meta = null;
if (metaText === null) {
  note("metadata JSON could not be fetched; station and parameter names were "
    + "not cross-checked.");
} else {
  try {
    meta = JSON.parse(stripBom(metaText));
  } catch (e) {
    note(`metadata JSON does not parse (${e.message}); names not cross-checked.`);
  }
}
const metaStations = new Set((meta?.Standorte ?? []).map((s) => s.ID));
const metaParameters = new Map(
  (meta?.Parameter ?? []).map((p) => [p.ID, p]),
);

const thisYear = new Date().getUTCFullYear();
const state = {
  stations: new Set(),
  parameters: new Set(),
  units: new Map(),
  dropped: new Map(),
  statuses: new Map(),
};

const data = [];
for (let year = FIRST_YEAR; year <= thisYear; year++) {
  const text = await fetchCached(yearUrl(year), `${year}`, `ugz_ogd_air_d1_${year}.csv`);
  // A CKAN error page is HTML and arrives with a 500; the header check in
  // parseYear would call it a layout change, which is the wrong diagnosis.
  const looksLikeCsv = text !== null && stripBom(text).startsWith('"Datum"');
  if (!looksLikeCsv) {
    if (year === thisYear) {
      note(`${year} is not published yet; the CSV ends with ${year - 1}.`);
      continue;
    }
    die(`${year} could not be fetched as CSV. Every year from ${FIRST_YEAR} to `
      + `last year must be present - a gap would make the output quietly `
      + `short. Retry, or pass --cache to reuse what did download.`);
  }
  const rows = parseYear(year, text, state);
  console.log(`  ${year}: ${rows.length} rows`);
  data.push(...rows);
}
if (data.length === 0) die("no rows parsed");

// Sort into the order the file is published in: by date, then station, then
// pollutant, then statistic.
const key = (r) => `${r[0]}\u0000${r[1]}\u0000${r[2]}\u0000${r[3]}`;
data.sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));

// One measurement per day, station, pollutant and statistic. A duplicate would
// mean either a double-published day or a parameter mapped onto a statistic
// something else already occupies, and both are mistakes worth stopping for.
for (let i = 1; i < data.length; i++) {
  if (key(data[i]) === key(data[i - 1])) {
    die(`duplicate row for ${key(data[i]).replace(/\u0000/g, " / ")}`);
  }
}

// The output is written unquoted, so no field may contain a comma, a quote or
// a newline. Checked rather than assumed: station IDs and status words come
// from the publisher and could acquire one.
for (const row of data) {
  for (const field of row) {
    if (/[",\r\n]/.test(field)) {
      die(`field "${field}" contains a comma, quote or newline; the output `
        + `would need quoting`);
    }
  }
}

// Cross-checks against the metadata, reported rather than fatal: a new station
// or parameter is the publisher extending the dataset, not a broken parse.
for (const s of [...state.stations].sort()) {
  if (metaStations.size > 0 && !metaStations.has(s)) {
    note(`station "${s}" is in the data but not in the metadata's Standorte; `
      + `the README's station list needs it.`);
  }
}
for (const p of [...state.parameters].sort()) {
  if (metaParameters.size > 0 && !metaParameters.has(p)) {
    note(`parameter "${p}" is in the data but not in the metadata's Parameter; `
      + `the README's pollutant list needs it.`);
  }
}
for (const [k, units] of [...state.units].sort()) {
  const [pollutant, statistic] = k.split("\u0000");
  if (units.size > 1) {
    note(`${pollutant} / ${statistic} is reported in more than one unit `
      + `(${[...units].join(", ")}); the unit column distinguishes them.`);
  }
  const param = [...metaParameters.keys()].find(
    (id) => (DERIVED_STATISTICS[id]?.pollutant ?? id) === pollutant
      && (DERIVED_STATISTICS[id]?.statistic ?? DEFAULT_STATISTIC) === statistic,
  );
  const declared = param ? metaParameters.get(param).Einheit : null;
  if (declared && !units.has(declared)) {
    note(`${pollutant} / ${statistic} is written as "${[...units].join(", ")}" `
      + `in the data but declared "${declared}" in the metadata.`);
  }
}

const text = `${OUT_COLUMNS.join(",")}\n`
  + data.map((r) => r.join(",")).join("\n") + "\n";
mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, text, "utf8");

// ------------------------------------------------------------------- summary

const droppedTotal = [...state.dropped.values()].reduce((a, b) => a + b, 0);
console.log(`\nWrote ${data.length} rows to ${outFile}`);
console.log(`  ${data[0][0]} to ${data[data.length - 1][0]}, `
  + `${state.stations.size} stations, ${state.units.size} pollutant/statistic `
  + `combinations`);
console.log(`  dropped ${droppedTotal} rows with no value (NA)`);
console.log(`  status: ${[...state.statuses].map(([s, n]) => `${s} ${n}`).join(", ")}`);
for (const [k, units] of [...state.units].sort()) {
  const n = data.filter((r) => `${r[2]}\u0000${r[3]}` === k).length;
  console.log(`  ${k.replace("\u0000", " / ")}: ${n} rows [${[...units].join(", ")}]`);
}
if (notes.length > 0) {
  console.log(`\n${notes.length} note(s):`);
  for (const n of notes) console.log(`  - ${n}`);
}
