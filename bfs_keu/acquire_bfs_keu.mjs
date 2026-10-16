// Acquire the BFS turnover statistics adopted in #32 (A7).
//
// Monthly turnover and production indices for the secondary and tertiary
// sector (Konjunkturerhebung Umsatz, KEU), by NOGA branch and retail commodity
// group, from 2000-01: the first of the monthly anchors the owner adopted, and
// the broadest monthly activity measure the opendata.swiss catalogue carries.
//
// Two files are written:
//
//   bfs_keu_turnover_monthly.csv   the observations, long format
//   bfs_keu_codes.csv              the labels for every code in them, once each
//
// Node built-ins only, no dependencies -- the same reason
// tools/validate-data.mjs is written the way it is, and it means the committed
// CSVs are the verified output of a script this repository can actually run.
//
// Six things about the source that are handled here rather than assumed away:
//
// 1. opendata.swiss publishes no CSV for this dataset. Its resources are four
//    HTML asset pages and four links into the stats.swiss data explorer, so
//    there is nothing to download in the way ogd51 or Zefix can be downloaded.
//    The explorer is a .Stat Suite front end and the SDMX REST service behind
//    it -- `disseminate.stats.swiss/rest` -- is what is used here. It is not
//    advertised in the catalogue; it was read off the explorer's own bundle.
//
// 2. The whole cube comes as one 17 MB request. There is no incremental or
//    date-filtered refresh worth having: `--cache` keeps the download so the
//    parse can be re-run without fetching again.
//
// 3. SDMX-CSV repeats the `DATAFLOW` column twice (once as the series key,
//    once empty at the end). Columns are therefore resolved by first
//    occurrence, and a row whose field count does not match the header is an
//    error rather than a silently shifted record.
//
// 4. The codes carry no meaning on their own and the labels are long German
//    branch names, so they are normalised out into `bfs_keu_codes.csv` --
//    the same split `zefix` makes, for the same reason. NOGA is hierarchical
//    and the parent code comes along, because without it the branch rows and
//    the aggregates they roll into cannot be told apart.
//
// 5. Each series carries the index plus exactly one percent change: year on
//    year for the unadjusted and calendar-adjusted variants, month on month
//    for the seasonally adjusted one. That pairing is checked, not assumed,
//    and only the index is written by default -- see `--measures` below.
//
// 6. An observation can be present with no value (`OBS_STATUS` L or M: not
//    applicable, or missing). Those rows are dropped rather than zero-filled,
//    as rhine_cargo drops unreported months, and the count is reported.
//
// Usage, from the repository root:
//   node bfs_keu/acquire_bfs_keu.mjs
//   node bfs_keu/acquire_bfs_keu.mjs --measures all
//   node bfs_keu/acquire_bfs_keu.mjs --cache /tmp/bfs_keu
//   node bfs_keu/acquire_bfs_keu.mjs --out-dir /tmp/out
//
// `--measures index` (the default) writes the index only. `--measures all`
// adds the publisher's own percent changes, which doubles the file for two
// series derivable from the index -- see the README.

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// opendata.swiss returns 403 to a plain client and the BFS estate behind it
// behaves the same way often enough that a browser User-Agent is sent here
// too, as in bfe_energy and zefix.
const USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/120.0.0.0 Safari/537.36";

const HERE = dirname(fileURLToPath(import.meta.url));

// SOURCE ------------------------------------------------------------------

const REST = "https://disseminate.stats.swiss/rest";
const AGENCY = "CH1.KEU";
const FLOW = "DF_KEU_M1";
const FLOW_VERSION = "1.0.0";
const DSD = "DSD_KEU_M1";

const DATA_URL =
  `${REST}/data/${AGENCY},${FLOW},${FLOW_VERSION}/all` +
  "?dimensionAtObservation=AllDimensions";
const STRUCTURE_URL =
  `${REST}/datastructure/${AGENCY}/${DSD}/latest?references=all&detail=full`;

const DATA_ACCEPT = "application/vnd.sdmx.data+csv;version=1.0.0";
const STRUCTURE_ACCEPT =
  "application/vnd.sdmx.structure+json;version=1.0;urn=false";

const DATA_OUT = "bfs_keu_turnover_monthly.csv";
const CODES_OUT = "bfs_keu_codes.csv";

const DATA_HEADER = [
  "date",
  "noga",
  "adjustment",
  "indicator",
  "measure",
  "value",
  "status",
];
const CODES_HEADER = ["dimension", "code", "parent", "label"];

// The SDMX-CSV columns this script reads. A column that has gone missing is a
// hard error rather than a silently shorter file.
const REQUIRED = [
  "NOGA",
  "ADJUSTMENT",
  "INDICATOR_KE",
  "UNIT_MEASURE",
  "FREQ",
  "TIME_PERIOD",
  "OBS_VALUE",
  "OBS_STATUS",
];

// Dimension -> codelist, for the labels. OBS_STATUS is an attribute rather
// than a dimension but is coded the same way and is just as unreadable raw.
const CODELISTS = {
  NOGA: "CL_NOGA_KE",
  ADJUSTMENT: "CL_SEASONAL_ADJUST",
  INDICATOR_KE: "CL_INDICATOR_KE",
  UNIT_MEASURE: "CL_PRICES_RESULT_TYPE",
  OBS_STATUS: "CL_OBS_STATUS",
};

// The index, and the one percent change each adjustment is published with.
const INDEX_MEASURE = "IX";
const CHANGE_FOR_ADJUSTMENT = {
  N: "VARM-12", // unadjusted, so year on year
  W: "VARM-12", // calendar adjusted, still year on year
  Y: "VARM-1", // calendar and seasonally adjusted, so month on month
};

// HELPERS -----------------------------------------------------------------

/** Split one CSV line, honouring double quotes. */
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

/** A tidy-CSV field. The German labels contain commas, so this one is used. */
function csvField(value) {
  const s = String(value);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

async function fetchText(url, accept, cacheDir, cacheName) {
  const cached = cacheDir ? join(cacheDir, cacheName) : null;
  if (cached && existsSync(cached)) {
    console.log(`  reusing ${cached}`);
    return readFileSync(cached, "utf8");
  }
  console.log(`  downloading ${url}`);
  const res = await fetch(url, {
    headers: {
      "User-Agent": USER_AGENT,
      Accept: accept,
      // The codelists are translated; without this the service answers in
      // whatever it considers default and the labels change language between
      // runs, which would show up as a diff in bfs_keu_codes.csv.
      "Accept-Language": "de",
    },
  });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status} ${res.statusText}`);
  const text = await res.text();
  if (cached) {
    mkdirSync(cacheDir, { recursive: true });
    writeFileSync(cached, text);
  }
  return text;
}

// STRUCTURE ---------------------------------------------------------------

/**
 * Read the codelists out of the SDMX structure document.
 * Returns dimension -> Map(code -> { label, parent }).
 */
function parseCodelists(text) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (err) {
    // A .Stat Suite front end answers HTML for a path it does not recognise,
    // so a parse failure here usually means the REST path has moved.
    throw new Error(
      `structure document is not JSON (first bytes: ${text.slice(0, 80)})`,
    );
  }
  const lists = doc?.data?.codelists;
  if (!Array.isArray(lists)) {
    throw new Error("structure document carries no codelists");
  }
  const byId = new Map(lists.map((cl) => [cl.id, cl]));
  const out = {};
  for (const [dimension, listId] of Object.entries(CODELISTS)) {
    const list = byId.get(listId);
    if (!list) {
      throw new Error(`structure document has no codelist ${listId}`);
    }
    const codes = new Map();
    for (const code of list.codes ?? []) {
      codes.set(code.id, {
        label: code.name ?? "",
        parent: code.parent ?? "",
      });
    }
    if (codes.size === 0) throw new Error(`codelist ${listId} is empty`);
    out[dimension] = codes;
  }
  return out;
}

// DATA --------------------------------------------------------------------

function columnIndices(header) {
  const idx = {};
  for (const name of REQUIRED) {
    // First occurrence: SDMX-CSV carries DATAFLOW twice, and a future layout
    // could repeat another column the same way.
    const at = header.indexOf(name);
    if (at === -1) {
      throw new Error(
        `expected column ${name} not in [${header.join(", ")}] -- ` +
          "the SDMX layout has changed",
      );
    }
    idx[name] = at;
  }
  return idx;
}

function buildRows(text, codes) {
  const lines = text
    .replace(/^﻿/, "")
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "");
  if (lines.length < 2) throw new Error("data document has no observations");
  const header = splitCsvLine(lines[0]).map((h) => h.trim());
  const idx = columnIndices(header);

  const rows = [];
  const seen = new Set();
  // (series key, period) -> the measures seen for it, for the pairing check.
  const measuresByKey = new Map();
  const emptyByStatus = new Map();
  const statuses = new Set();

  for (let i = 1; i < lines.length; i += 1) {
    const fields = splitCsvLine(lines[i]);
    if (fields.length !== header.length) {
      throw new Error(
        `line ${i + 1}: ${fields.length} fields where the header has ` +
          `${header.length} -- the record is shifted, not just unexpected`,
      );
    }
    const get = (name) => fields[idx[name]].trim();

    const freq = get("FREQ");
    if (freq !== "M") {
      throw new Error(
        `line ${i + 1}: FREQ '${freq}' -- this dataflow is monthly and the ` +
          "output is dated to the first of the month on that basis",
      );
    }

    const period = get("TIME_PERIOD");
    if (!/^\d{4}-\d{2}$/.test(period)) {
      throw new Error(`line ${i + 1}: unparseable TIME_PERIOD '${period}'`);
    }
    const month = Number(period.slice(5));
    if (!(month >= 1 && month <= 12)) {
      throw new Error(`line ${i + 1}: month out of range in '${period}'`);
    }
    // Monthly periods are dated to the first of the month, as in rhine_cargo
    // and bfe_energy, so every date in this repository is a real YYYY-MM-DD.
    const date = `${period}-01`;

    const noga = get("NOGA");
    const adjustment = get("ADJUSTMENT");
    const indicator = get("INDICATOR_KE");
    const measure = get("UNIT_MEASURE");
    const status = get("OBS_STATUS");
    const value = get("OBS_VALUE");

    for (const [dimension, code] of [
      ["NOGA", noga],
      ["ADJUSTMENT", adjustment],
      ["INDICATOR_KE", indicator],
      ["UNIT_MEASURE", measure],
      ["OBS_STATUS", status],
    ]) {
      if (!codes[dimension].has(code)) {
        throw new Error(
          `line ${i + 1}: ${dimension} code '${code}' is not in ` +
            `${CODELISTS[dimension]} -- a new code with no label`,
        );
      }
    }

    statuses.add(status);

    const key = [noga, adjustment, indicator, measure, period].join("\u0000");
    if (seen.has(key)) throw new Error(`duplicate observation: ${key}`);
    seen.add(key);

    const seriesKey = [noga, adjustment, indicator, period].join("\u0000");
    const have = measuresByKey.get(seriesKey);
    if (have) have.push(measure);
    else measuresByKey.set(seriesKey, [measure]);

    if (value === "") {
      // Present but not reported. Counted by status so the README can say
      // which kind of hole it is, then dropped.
      emptyByStatus.set(status, (emptyByStatus.get(status) ?? 0) + 1);
      continue;
    }
    if (!/^-?\d+(\.\d+)?$/.test(value)) {
      throw new Error(
        `line ${i + 1}: value '${value}' is not a plain number -- values are ` +
          "passed through as text and never reparsed, so this would corrupt",
      );
    }

    rows.push([date, noga, adjustment, indicator, measure, value, status]);
  }

  // Every series is published as the index plus the one percent change that
  // goes with its adjustment. If that stops holding, the claim in the README
  // that dropping the changes loses no period is no longer true, so fail.
  for (const [seriesKey, measures] of measuresByKey) {
    const [noga, adjustment, indicator, period] = seriesKey.split("\u0000");
    const want = CHANGE_FOR_ADJUSTMENT[adjustment];
    if (!want) {
      throw new Error(
        `ADJUSTMENT '${adjustment}' is not one of ` +
          `${Object.keys(CHANGE_FOR_ADJUSTMENT).join(", ")} ` +
          `(${noga} ${indicator} ${period})`,
      );
    }
    const sorted = [...measures].sort();
    const expected = [INDEX_MEASURE, want].sort();
    if (sorted.join("+") !== expected.join("+")) {
      throw new Error(
        `${noga} ${adjustment} ${indicator} ${period}: measures ` +
          `[${sorted.join(", ")}] where [${expected.join(", ")}] was ` +
          "expected -- the index/change pairing has changed",
      );
    }
  }

  return {
    rows,
    emptyByStatus,
    usedCodes: usedCodesFrom(statuses, measuresByKey),
  };
}

/**
 * The codes the download actually uses, so the lookup file lists neither
 * fewer nor more. Built from every observation, including the ones with no
 * value, so `--measures` does not change which codes are described.
 */
function usedCodesFrom(statuses, measuresByKey) {
  const used = {
    NOGA: new Set(),
    ADJUSTMENT: new Set(),
    INDICATOR_KE: new Set(),
    UNIT_MEASURE: new Set(),
    OBS_STATUS: new Set(),
  };
  for (const seriesKey of measuresByKey.keys()) {
    const [noga, adjustment, indicator] = seriesKey.split("\u0000");
    used.NOGA.add(noga);
    used.ADJUSTMENT.add(adjustment);
    used.INDICATOR_KE.add(indicator);
  }
  for (const measures of measuresByKey.values()) {
    for (const measure of measures) used.UNIT_MEASURE.add(measure);
  }
  for (const status of statuses) used.OBS_STATUS.add(status);
  return used;
}

function writeCsv(outDir, name, header, rows) {
  mkdirSync(outDir, { recursive: true });
  const body = [
    header.join(","),
    ...rows.map((r) => r.map(csvField).join(",")),
  ];
  const path = join(outDir, name);
  writeFileSync(path, `${body.join("\n")}\n`);
  return path;
}

// RUN ---------------------------------------------------------------------

const argv = process.argv.slice(2);
let cacheDir = null;
let outDir = HERE;
let measures = "index";
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === "--cache") cacheDir = argv[++i];
  else if (arg === "--out-dir") outDir = argv[++i];
  else if (arg === "--measures") measures = argv[++i];
  else {
    console.error(`unknown argument: ${arg}`);
    console.error(
      "usage: acquire_bfs_keu.mjs [--measures index|all] [--cache <dir>] " +
        "[--out-dir <dir>]",
    );
    process.exit(2);
  }
}
if (measures !== "index" && measures !== "all") {
  console.error(`--measures must be 'index' or 'all', not '${measures}'`);
  process.exit(2);
}

console.log(`${AGENCY}:${FLOW} (${FLOW_VERSION}):`);
const structure = await fetchText(
  STRUCTURE_URL,
  STRUCTURE_ACCEPT,
  cacheDir,
  `${DSD}_structure_de.json`,
);
const codes = parseCodelists(structure);
const data = await fetchText(
  DATA_URL,
  DATA_ACCEPT,
  cacheDir,
  `${FLOW}_all.csv`,
);
const { rows, emptyByStatus, usedCodes } = buildRows(data, codes);
if (rows.length === 0) throw new Error("no observations parsed");

const kept =
  measures === "all" ? rows : rows.filter((r) => r[4] === INDEX_MEASURE);
// Deterministic order, so a refresh that changes no data produces no diff.
const sortKey = (r) => [r[1], r[2], r[3], r[4], r[0]].join("\u0000");
kept.sort((a, b) => sortKey(a).localeCompare(sortKey(b)));

const dataPath = writeCsv(outDir, DATA_OUT, DATA_HEADER, kept);
const dates = kept.map((r) => r[0]).sort();
const empties = [...emptyByStatus.entries()]
  .sort()
  .map(([status, n]) => `${n} ${status}`)
  .join(", ");
console.log(
  `  wrote ${kept.length} rows to ${dataPath} ` +
    `(${dates[0]} to ${dates[dates.length - 1]}, ` +
    `${new Set(dates).size} months, ${usedCodes.NOGA.size} NOGA codes, ` +
    `measures=${measures}; ${empties || "no"} valueless observations dropped)`,
);

const codeRows = [];
for (const dimension of Object.keys(CODELISTS)) {
  for (const code of [...usedCodes[dimension]].sort()) {
    const { label, parent } = codes[dimension].get(code);
    // A parent outside the dataflow would make the hierarchy unresolvable
    // from this file alone, so it is kept but flagged in the log.
    codeRows.push([dimension, code, parent, label]);
  }
}
const codesPath = writeCsv(outDir, CODES_OUT, CODES_HEADER, codeRows);
const danglingParents = codeRows.filter(
  (r) => r[0] === "NOGA" && r[2] !== "" && !usedCodes.NOGA.has(r[2]),
).length;
console.log(
  `  wrote ${codeRows.length} rows to ${codesPath}` +
    (danglingParents > 0
      ? ` (${danglingParents} NOGA parents are codelist-only, i.e. carry no ` +
        "observations of their own)"
      : ""),
);
