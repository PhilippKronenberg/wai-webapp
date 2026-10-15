// Acquire the Zefix daily register-entry series adopted in #32 (A6).
//
// Two series from the Zurich statistical office, each covering Switzerland as
// a whole alongside the canton:
//
//   bankruptcies        Konkurseroeffnungen, by NOGA section
//   new_registrations   Neugruendungen, by NOGA section
//
// Daily dates, refreshed weekly. The appeal for a weekly index is that these
// are national business dynamics at daily resolution with a weekly cadence,
// and almost nothing else in the catalogue is (#32).
//
// Node built-ins only, no dependencies, as zurich_air and bfe_energy.
//
// The sources are already tidy and long, so this script is mostly a
// normalisation. Four things it does rather than copying the files through:
//
// 1. It takes the 60-character German branch label off every row. The label,
//    the sector code and the sector label are all functions of
//    `br_abschnitt_code` -- one-to-one, and the script checks that on every
//    run -- so repeating them 135,622 times costs about 7 MB per file and
//    carries no information. They go to `zefix_noga_sections.csv` instead,
//    once per section. Each series file drops from 10.6 MB to about 3 MB.
//
// 2. The publisher's total row is `br_abschnitt_code = "NA"`, labelled "Alle
//    Branchen". That becomes an **empty** `noga_section`, the convention
//    rhine_cargo uses for its headline rows and bfe_energy for a flow with no
//    counterparty, so a total can never be mistaken for a section called NA.
//
// 3. It checks the publisher's total against the sum of its own sections, for
//    every date and location. That holds exactly today, on all 7,138 pairs of
//    both files. A mismatch is a hard error: it means either a section has
//    been added that the total excludes, or a revision landed half-applied,
//    and which of those it is, is a judgement call for a human rather than
//    something a download script should average over.
//
// 4. The files are not sorted at source -- they open in 2026 and end in 2017 --
//    so the output is sorted by date, location and section. A refresh that
//    changes no data then produces no diff.
//
// Counts pass through as the publisher's own text. A zero is a real
// observation here (no bankruptcy in that section that day), not a missing
// value, so unlike zurich_air nothing is dropped: the daily grid is complete
// and stays complete.
//
// Usage, from the repository root:
//   node zefix/acquire_zefix.mjs
//   node zefix/acquire_zefix.mjs --series bankruptcies
//   node zefix/acquire_zefix.mjs --cache /tmp/zefix
//   node zefix/acquire_zefix.mjs --out-dir /tmp/out

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/120.0.0.0 Safari/537.36";

const HERE = dirname(fileURLToPath(import.meta.url));

const BASE = "https://www.web.statistik.zh.ch/ogd/data";

const SERIES = {
  bankruptcies: {
    url: `${BASE}/KANTON_ZUERICH_ZEFIX_Konkurse.csv`,
    cacheName: "KANTON_ZUERICH_ZEFIX_Konkurse.csv",
    out: "zefix_bankruptcies_daily.csv",
    dataset: "Zefix Konkurseroeffnungen nach Branchen (ZH und CH)",
  },
  new_registrations: {
    url: `${BASE}/KANTON_ZUERICH_ZEFIX_Neugruendungen.csv`,
    cacheName: "KANTON_ZUERICH_ZEFIX_Neugruendungen.csv",
    out: "zefix_new_registrations_daily.csv",
    dataset: "Zefix Neugruendungen nach Branchen (ZH und CH)",
  },
};

const SECTIONS_OUT = "zefix_noga_sections.csv";

// The columns both sources are expected to have. A renamed or dropped one is
// an error rather than a silently emptier file.
const REQUIRED = [
  "br_abschnitt_desc",
  "br_abschnitt_code",
  "wirtschaftssektor_desc",
  "wirtschaftssektor_code",
  "location",
  "date",
  "value",
];

// HELPERS -----------------------------------------------------------------

/** Split one CSV line. The branch labels contain commas, so quotes matter. */
function splitCsvLine(line) {
  const out = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const c = line[i];
    if (quoted) {
      if (c === '"') {
        if (line[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          quoted = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      quoted = true;
    } else if (c === ",") {
      out.push(field);
      field = "";
    } else {
      field += c;
    }
  }
  out.push(field);
  return out;
}

function parseCsv(text) {
  const lines = text
    .replace(/^﻿/, "")
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "");
  if (lines.length === 0) throw new Error("empty CSV");
  const header = splitCsvLine(lines[0]).map((h) => h.trim());
  const rows = lines.slice(1).map((l) => splitCsvLine(l).map((v) => v.trim()));
  return { header, rows };
}

function csvField(value) {
  const s = String(value);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

async function fetchText(url, cacheDir, cacheName) {
  const cached = cacheDir ? join(cacheDir, cacheName) : null;
  if (cached && existsSync(cached)) {
    console.log(`  reusing ${cached}`);
    return readFileSync(cached, "utf8");
  }
  console.log(`  downloading ${url}`);
  const res = await fetch(url, { headers: { "User-Agent": USER_AGENT } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status} ${res.statusText}`);
  const text = await res.text();
  if (/^\s*</.test(text)) {
    throw new Error(`${url}: served markup, not CSV (first bytes: ${text.slice(0, 80)})`);
  }
  if (cached) {
    mkdirSync(cacheDir, { recursive: true });
    writeFileSync(cached, text);
  }
  return text;
}

// ACQUIRE -----------------------------------------------------------------

/**
 * Turn one source file into its long rows, and collect the section lookup.
 *
 * `sections` is shared across both series: the two files carry the same 19
 * sections, and disagreeing about one of them would itself be a finding.
 */
function buildRows(spec, csv, sections) {
  const { header, rows } = csv;
  const missing = REQUIRED.filter((c) => !header.includes(c));
  if (missing.length > 0) {
    throw new Error(
      `${spec.dataset}: expected column(s) ${missing.join(", ")} not in ` +
        `[${header.join(", ")}] -- the layout has changed`,
    );
  }
  const idx = Object.fromEntries(REQUIRED.map((c) => [c, header.indexOf(c)]));

  const out = [];
  // date|location -> { total, parts }, for the integrity check below.
  const totals = new Map();

  for (const row of rows) {
    const date = row[idx.date];
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new Error(`${spec.dataset}: unparseable date '${date}'`);
    }
    const location = row[idx.location];
    if (location === "") throw new Error(`${spec.dataset}: ${date}: empty location`);

    const value = row[idx.value];
    if (!/^-?\d+$/.test(value)) {
      throw new Error(
        `${spec.dataset}: ${date} ${location}: count '${value}' is not an integer`,
      );
    }

    const code = row[idx.br_abschnitt_code];
    const isTotal = code === "NA";
    // The publisher's own total; kept, but as an empty section.
    const section = isTotal ? "" : code;
    if (!isTotal) {
      const label = [
        row[idx.br_abschnitt_desc],
        row[idx.wirtschaftssektor_code],
        row[idx.wirtschaftssektor_desc],
      ];
      const seen = sections.get(code);
      if (seen === undefined) {
        sections.set(code, label);
      } else if (seen.join("\u0000") !== label.join("\u0000")) {
        // The whole point of the lookup table is that this cannot happen.
        throw new Error(
          `${spec.dataset}: section '${code}' labelled two ways ` +
            `(${seen.join(" / ")}) vs (${label.join(" / ")})`,
        );
      }
    }

    const key = `${date}|${location}`;
    const acc = totals.get(key) ?? { total: 0, parts: 0, hasTotal: false };
    if (isTotal) {
      acc.total += Number(value);
      acc.hasTotal = true;
    } else {
      acc.parts += Number(value);
    }
    totals.set(key, acc);

    out.push([date, location, section, value]);
  }

  // The publisher's total against the publisher's own sections.
  for (const [key, acc] of totals) {
    if (acc.hasTotal && acc.total !== acc.parts) {
      const [date, location] = key.split("|");
      throw new Error(
        `${spec.dataset}: ${date} ${location}: 'Alle Branchen' is ${acc.total} ` +
          `but the sections sum to ${acc.parts}. Either a section was added ` +
          `outside the total or a revision landed half-applied; decide which ` +
          `before committing a CSV.`,
      );
    }
  }

  out.sort((a, b) => a.join("\u0000").localeCompare(b.join("\u0000")));
  return { rows: out, periods: new Set(out.map((r) => r[0])).size };
}

function writeCsv(outDir, name, header, rows) {
  mkdirSync(outDir, { recursive: true });
  const body = [header.join(","), ...rows.map((r) => r.map(csvField).join(","))];
  const path = join(outDir, name);
  writeFileSync(path, `${body.join("\n")}\n`);
  return path;
}

// RUN ---------------------------------------------------------------------

const argv = process.argv.slice(2);
let cacheDir = null;
let outDir = HERE;
const wanted = [];
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === "--cache") cacheDir = argv[++i];
  else if (arg === "--out-dir") outDir = argv[++i];
  else if (arg === "--series") wanted.push(argv[++i]);
  else {
    console.error(`unknown argument: ${arg}`);
    console.error("usage: acquire_zefix.mjs [--series <key>]... [--cache <dir>] [--out-dir <dir>]");
    console.error(`series: ${Object.keys(SERIES).join(", ")}`);
    process.exit(2);
  }
}

const keys = wanted.length > 0 ? wanted : Object.keys(SERIES);
for (const key of keys) {
  if (!SERIES[key]) {
    console.error(`unknown series '${key}'; known: ${Object.keys(SERIES).join(", ")}`);
    process.exit(2);
  }
}

const sections = new Map();
for (const key of keys) {
  const spec = SERIES[key];
  console.log(`${key}:`);
  const csv = parseCsv(await fetchText(spec.url, cacheDir, spec.cacheName));
  const { rows, periods } = buildRows(spec, csv, sections);
  if (rows.length === 0) throw new Error(`${spec.dataset}: no rows parsed`);
  const path = writeCsv(outDir, spec.out, ["date", "location", "noga_section", "value"], rows);
  const dates = rows.map((r) => r[0]);
  console.log(
    `  wrote ${rows.length} rows to ${path} ` +
      `(${dates[0]} to ${dates[dates.length - 1]}, ${periods} days, ` +
      `total ${rows.reduce((s, r) => s + (r[2] === "" ? Number(r[3]) : 0), 0)} entries ` +
      `across all locations)`,
  );
}

// The lookup is written from whatever sections the series just read carried,
// so running one series alone still produces a lookup consistent with it.
const sectionRows = [...sections.entries()]
  .map(([code, label]) => [code, ...label])
  .sort((a, b) => a[0].localeCompare(b[0]));
const sectionsPath = writeCsv(
  outDir,
  SECTIONS_OUT,
  ["noga_section", "section_de", "sector_code", "sector_de"],
  sectionRows,
);
console.log(`sections: wrote ${sectionRows.length} rows to ${sectionsPath}`);
