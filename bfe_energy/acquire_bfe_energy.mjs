// Acquire the BFE energy series adopted in #32 (A1, A2, A4, A13).
//
// Four open CSVs from the Bundesamt fuer Energie, downloaded and rewritten as
// tidy long files, one per series:
//
//   electricity_balance_weekly   ogd51   weekly national electricity balance
//   electricity_consumption_daily ogd103 daily Landesverbrauch / Endverbrauch
//   electricity_flows_daily      ogd107  daily cross-border flows, by neighbour
//   degree_days_monthly          ogd105  monthly heating and cooling degree days
//
// The first three are activity; the fourth is the weather control the
// electricity series need, which is why it comes along (#32, A13).
//
// Node built-ins only, no dependencies -- the same reason
// tools/validate-data.mjs is written the way it is, and it means the committed
// CSVs are the verified output of a script this repository can actually run.
//
// Five things about the sources that are handled here rather than assumed away:
//
// 1. The catalogue's URL for ogd51 is wrong. opendata.swiss lists
//    `https://www.bfe-ogd.ch/ogd51_wochenstatistik_elektrizitaetsbilanz.csv`,
//    which answers S3 `NoSuchKey`; the file is one directory down, under
//    `/ogd51/`. The old `uvek-gis.admin.ch` copy still resolves and is a trap:
//    it is frozen, and its first line is a notice saying so ("Diese Daten
//    werden nicht mehr weitergefuehrt"), which a naive parser reads as a header.
//
// 2. ogd51 has a definitional break at 2025-01-01. Before it, thermal, wind
//    and photovoltaic generation are lumped into `Erzeugung_andere`; from it,
//    they are reported separately and `Erzeugung_andere` is empty. Both shapes
//    are passed through as the publisher reports them and the empty cells are
//    dropped, so `erzeugung_andere` simply ends in 2024 and the three split
//    measures simply begin in 2025. They are NOT summed into a spliced series:
//    that is a modelling choice and it belongs in mfbdfm, not in a download
//    script.
//
// 3. ogd51's weekly grid has holes. It is Wednesday data, but one observation
//    falls on a Tuesday (2009-10-27) and three gaps are longer than a week
//    (a missing week in October 2004, four missing weeks in December 2007).
//    Nothing here reindexes onto a regular grid -- an absent week is absent,
//    not zero.
//
// 4. ogd103 and ogd107 arrive with a UTF-8 BOM and CRLF line endings, ogd51
//    with CRLF and no BOM. All of it is normalised on the way in; the CSVs
//    written out are LF with no BOM.
//
// 5. Values are passed through as the publisher's own text, never reparsed and
//    reformatted, so no float round-trip can move a digit. Negative flows in
//    ogd107 (`-0.00`) therefore survive verbatim.
//
// Every column each series is expected to have is declared below, and a column
// that has gone missing is a hard error rather than a silently shorter file.
//
// Usage, from the repository root:
//   node bfe_energy/acquire_bfe_energy.mjs
//   node bfe_energy/acquire_bfe_energy.mjs --series electricity_flows_daily
//   node bfe_energy/acquire_bfe_energy.mjs --cache /tmp/bfe
//   node bfe_energy/acquire_bfe_energy.mjs --out-dir /tmp/out
//
// With --cache the downloads are kept in that directory and reused if already
// present, which is how to re-parse without hitting the server again.

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// bfe-ogd.ch answers plain clients, but opendata.swiss itself returns 403
// without a browser User-Agent and the BFE host sits behind the same estate,
// so one is sent here too.
const USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/120.0.0.0 Safari/537.36";

const HERE = dirname(fileURLToPath(import.meta.url));

// SERIES ------------------------------------------------------------------

// `measures` maps the publisher's column name to the row it becomes. Listing
// them explicitly is what turns a renamed or dropped column into an error.
const SERIES = {
  electricity_balance_weekly: {
    url: "https://www.bfe-ogd.ch/ogd51/ogd51_wochenstatistik_elektrizitaetsbilanz.csv",
    cacheName: "ogd51_wochenstatistik_elektrizitaetsbilanz.csv",
    out: "bfe_electricity_balance_weekly.csv",
    dataset: "ENSTAT Wochenstatistik Elektrizitaetsbilanz (ogd51)",
    dateColumn: "Datum",
    header: ["date", "measure", "value", "unit"],
    measures: {
      Erzeugung_laufwerk_GWh: "erzeugung_laufwerk",
      Erzeugung_speicherwerk_GWh: "erzeugung_speicherwerk",
      Erzeugung_kernkraftwerk_GWh: "erzeugung_kernkraftwerk",
      Erzeugung_thermisch_GWh: "erzeugung_thermisch",
      Erzeugung_windkraftwerk_GWh: "erzeugung_windkraftwerk",
      Erzeugung_photovoltaik_GWh: "erzeugung_photovoltaik",
      Erzeugung_andere_GWh: "erzeugung_andere",
      Verbrauch_speicherpumpen_GWh: "verbrauch_speicherpumpen",
      Erzeugung_netto_GWh: "erzeugung_netto",
      Einfuhr_GWh: "einfuhr",
      Ausfuhr_GWh: "ausfuhr",
      Landesverbrauch_GWh: "landesverbrauch",
    },
    unit: "GWh",
    row: (date, measure, value, unit) => [date, measure, value, unit],
  },

  electricity_consumption_daily: {
    url: "https://www.bfe-ogd.ch/ogd103_stromverbrauch_swissgrid_lv_und_endv.csv",
    cacheName: "ogd103_stromverbrauch_swissgrid_lv_und_endv.csv",
    out: "bfe_electricity_consumption_daily.csv",
    dataset: "energiedashboard.ch Landesverbrauch und Endverbrauch (ogd103)",
    dateColumn: "Datum",
    header: ["date", "measure", "value", "unit"],
    measures: {
      Landesverbrauch_GWh: "landesverbrauch",
      Endverbrauch_GWh: "endverbrauch",
    },
    unit: "GWh",
    row: (date, measure, value, unit) => [date, measure, value, unit],
  },

  electricity_flows_daily: {
    url: "https://www.bfe-ogd.ch/ogd107_strom_import_export.csv",
    cacheName: "ogd107_strom_import_export.csv",
    out: "bfe_electricity_flows_daily.csv",
    dataset:
      "energiedashboard.ch Taegliche Fluesse in die und aus der Schweiz, Strom (ogd107)",
    dateColumn: "Date",
    header: ["date", "measure", "counterparty", "value", "unit"],
    // `XX_CH` is a flow into Switzerland, `CH_XX` one out of it. `Nettoimport`
    // is the balance over all four borders and has no counterparty, so that
    // cell is left empty -- as rhine_cargo leaves `commodity` empty on its
    // headline rows.
    measures: {
      AT_CH_GWh: ["import", "AT"],
      DE_CH_GWh: ["import", "DE"],
      FR_CH_GWh: ["import", "FR"],
      IT_CH_GWh: ["import", "IT"],
      CH_AT_GWh: ["export", "AT"],
      CH_DE_GWh: ["export", "DE"],
      CH_FR_GWh: ["export", "FR"],
      CH_IT_GWh: ["export", "IT"],
      Nettoimport: ["nettoimport", ""],
    },
    unit: "GWh",
    row: (date, measure, value, unit) => [
      date,
      measure[0],
      measure[1],
      value,
      unit,
    ],
  },

  degree_days_monthly: {
    url: "https://www.bfe-ogd.ch/ogd105_heizgradtage_k%C3%BChlgradtage.csv",
    cacheName: "ogd105_heizgradtage_kuehlgradtage.csv",
    out: "bfe_degree_days_monthly.csv",
    dataset: "Monatliche Heizgradtage und Kuehlgradtage, gewichtet (ogd105)",
    // The only one of the four not keyed by a date: it carries `Jahr` and
    // `Monat`, which are turned into the first of the month, and kept
    // alongside it as rhine_cargo keeps them.
    yearColumn: "Jahr",
    monthColumn: "Monat",
    header: ["date", "year", "month", "measure", "value", "unit"],
    measures: {
      HGT: "heizgradtage",
      CDD: "kuehlgradtage",
    },
    unit: "degree_days",
    row: (date, measure, value, unit, extra) => [
      date,
      extra.year,
      extra.month,
      measure,
      value,
      unit,
    ],
  },
};

// HELPERS -----------------------------------------------------------------

/** Split one CSV line, honouring the double quotes ogd51 puts round its header. */
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

/** Parse a whole CSV into { header, rows }, dropping the BOM and any CR. */
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

/** A tidy-CSV field. Nothing written here needs quoting, but say so in code. */
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
  // The dead uvek-gis mirror answers 200 with a notice where the header should
  // be, and an S3 miss answers 200 with XML on some of these paths. Either way
  // the first line is not a header, so check rather than parse the apology.
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

function buildRows(spec, csv) {
  const { header, rows } = csv;
  const want = Object.keys(spec.measures);
  const missing = want.filter((c) => !header.includes(c));
  if (missing.length > 0) {
    throw new Error(
      `${spec.dataset}: expected column(s) ${missing.join(", ")} not in ` +
        `[${header.join(", ")}] -- the layout has changed`,
    );
  }

  const dateIdx = spec.dateColumn ? header.indexOf(spec.dateColumn) : -1;
  const yearIdx = spec.yearColumn ? header.indexOf(spec.yearColumn) : -1;
  const monthIdx = spec.monthColumn ? header.indexOf(spec.monthColumn) : -1;
  if (spec.dateColumn && dateIdx === -1) {
    throw new Error(`${spec.dataset}: no '${spec.dateColumn}' column`);
  }
  if (spec.yearColumn && (yearIdx === -1 || monthIdx === -1)) {
    throw new Error(`${spec.dataset}: no '${spec.yearColumn}'/'${spec.monthColumn}' columns`);
  }

  const out = [];
  let dropped = 0;
  for (const row of rows) {
    let date;
    let extra = {};
    if (dateIdx !== -1) {
      date = row[dateIdx];
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
        throw new Error(`${spec.dataset}: unparseable date '${date}'`);
      }
    } else {
      const year = Number(row[yearIdx]);
      const month = Number(row[monthIdx]);
      if (!Number.isInteger(year) || !(month >= 1 && month <= 12)) {
        throw new Error(
          `${spec.dataset}: unparseable year/month '${row[yearIdx]}'/'${row[monthIdx]}'`,
        );
      }
      date = `${year}-${String(month).padStart(2, "0")}-01`;
      extra = { year, month };
    }

    for (const [column, measure] of Object.entries(spec.measures)) {
      const value = row[header.indexOf(column)] ?? "";
      // An empty cell is a value the publisher does not report: the three
      // split generation measures before 2025, `Erzeugung_andere` after it.
      // Dropped, never zero-filled, as rhine_cargo drops unreported months.
      if (value === "") {
        dropped += 1;
        continue;
      }
      if (!/^-?\d+(\.\d+)?$/.test(value)) {
        throw new Error(
          `${spec.dataset}: ${date} ${column}: value '${value}' is not a plain number`,
        );
      }
      out.push(spec.row(date, measure, value, spec.unit, extra));
    }
  }

  // Deterministic order, so a refresh that changes no data produces no diff.
  out.sort((a, b) => a.join("\u0000").localeCompare(b.join("\u0000")));
  return { rows: out, dropped };
}

async function acquire(key, { cacheDir, outDir }) {
  const spec = SERIES[key];
  console.log(`${key}:`);
  const text = await fetchText(spec.url, cacheDir, spec.cacheName);
  const csv = parseCsv(text);
  const { rows, dropped } = buildRows(spec, csv);
  if (rows.length === 0) throw new Error(`${spec.dataset}: no rows parsed`);

  const body = [spec.header.join(","), ...rows.map((r) => r.map(csvField).join(","))];
  const outPath = join(outDir, spec.out);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(outPath, `${body.join("\n")}\n`);

  const dates = rows.map((r) => r[0]);
  console.log(
    `  wrote ${rows.length} rows to ${outPath} ` +
      `(${dates[0]} to ${dates[dates.length - 1]}, ` +
      `${new Set(dates).size} periods, ${dropped} empty cells dropped)`,
  );
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
    console.error(
      "usage: acquire_bfe_energy.mjs [--series <key>]... [--cache <dir>] [--out-dir <dir>]",
    );
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

for (const key of keys) {
  await acquire(key, { cacheDir, outDir });
}
