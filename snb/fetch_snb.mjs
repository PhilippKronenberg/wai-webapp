#!/usr/bin/env node
// Download the two adopted SNB data-portal cubes and write them as tidy CSVs.
//
// Run from the repository root:
//
//     node snb/fetch_snb.mjs
//
// Node built-ins only, like tools/validate-data.mjs - this repository has no
// dependencies and CI must not be the thing that introduces one.
//
// Adopted cubes (issue #36):
//   snbgwdzid    SNB policy rate, SARON fixing, sight-deposit rates. Daily,
//                published weekly at a ~3-day lag.
//   devwkieffid  Trade-weighted (effective) CHF exchange-rate index, nominal
//                and real. Daily granularity, published monthly.
//
// Traps this script handles deliberately; see README.md for the full list.
//   - The portal answers HTTP 200 with its Angular HTML shell for any
//     unrecognised /api/... path, so the body is checked, never the status.
//   - Cube CSVs are semicolon-separated, UTF-8 with a BOM and CRLF, with two
//     metadata lines before a blank line and the real header.
//   - Dimension codes (LZ, SARON, N, K, P, G, E, ...) are meaningless on their
//     own and are resolved through /dimensions/en at download time.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DIR = dirname(fileURLToPath(import.meta.url));
const API = 'https://data.snb.ch/api/cube';

// Each cube says which dimension combinations to keep and how to name the
// columns of its output file. `keep` returns null to drop a row.
const CUBES = [
  {
    id: 'snbgwdzid',
    file: 'snb_policy_rates.csv',
    columns: ['date', 'series_code', 'series', 'value'],
    keep: (dims, labels) => [dims.D0, labels.D0[dims.D0]],
  },
  {
    id: 'devwkieffid',
    file: 'chf_effective_exchange_rate.csv',
    columns: ['date', 'basis_code', 'basis', 'country_group_code', 'country_group', 'value'],
    // D2 = I is the index level; D2 = V is its day-on-day percentage change,
    // which is derivable from the level and is dropped to keep the file small.
    keep: (dims, labels) =>
      dims.D2 === 'I'
        ? [dims.D0, labels.D0[dims.D0], dims.D1, labels.D1[dims.D1]]
        : null,
  },
];

async function get(url) {
  const res = await fetch(url, { headers: { accept: '*/*' } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  const body = await res.text();
  // The 200-plus-HTML-shell trap. An unknown API path looks like a success.
  if (/^\s*<(!doctype|html)/i.test(body)) {
    throw new Error(`${url}: answered with the portal HTML shell, not data`);
  }
  return body;
}

// The dimension tree nests: devwkieffid's D0 has Real -> {CPI-based, PPI-based}
// and the data uses the leaf codes. Flatten every level into one code -> label
// map, qualifying children with their parent so "Real" is not lost.
function flattenItems(items, prefix, into) {
  for (const item of items ?? []) {
    const label = prefix ? `${prefix} - ${item.name}` : item.name;
    if (item.dimensionItems?.length) {
      flattenItems(item.dimensionItems, label, into);
    } else {
      into[item.id] = label.replace(/\s+/g, ' ').trim();
    }
  }
  return into;
}

async function dimensionLabels(cubeId) {
  const tree = JSON.parse(await get(`${API}/${cubeId}/dimensions/en`));
  const labels = {};
  for (const dim of tree.dimensions ?? []) {
    labels[dim.id] = flattenItems(dim.dimensionItems, '', {});
  }
  return labels;
}

// Cube dates come as YYYY-MM-DD, YYYY-MM, YYYY or YYYY-Qn. Normalise all four
// to the first day of the period so the output is a parseable date everywhere;
// YYYY-Qn in particular is not a date and is silently dropped by anything that
// just calls Date.parse on it.
function normalizeDate(raw) {
  let m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  if (m) return raw;
  m = /^(\d{4})-(\d{2})$/.exec(raw);
  if (m) return `${m[1]}-${m[2]}-01`;
  m = /^(\d{4})-Q([1-4])$/.exec(raw);
  if (m) return `${m[1]}-${String((Number(m[2]) - 1) * 3 + 1).padStart(2, '0')}-01`;
  m = /^(\d{4})$/.exec(raw);
  if (m) return `${m[1]}-01-01`;
  return null;
}

function splitCubeCsv(body, cubeId) {
  const lines = body.replace(/^﻿/, '').split(/\r?\n/);
  const meta = {};
  let i = 0;
  for (; i < lines.length && lines[i].trim() !== ''; i++) {
    const [key, value] = lines[i].split(';').map((s) => s.replace(/^"|"$/g, ''));
    meta[key] = value;
  }
  if (meta.CubeId !== cubeId) {
    throw new Error(`${cubeId}: body does not start with its own CubeId line`);
  }
  const header = lines[++i].split(';').map((s) => s.replace(/^"|"$/g, ''));
  if (header[0] !== 'Date' || header[header.length - 1] !== 'Value') {
    throw new Error(`${cubeId}: unexpected header ${header.join(';')}`);
  }
  return { meta, header, rows: lines.slice(i + 1) };
}

function csvQuote(value) {
  return /[",\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

const vintages = [];

for (const cube of CUBES) {
  process.stdout.write(`${cube.id}: `);
  const labels = await dimensionLabels(cube.id);
  const { meta, header, rows } = splitCubeCsv(
    await get(`${API}/${cube.id}/data/csv/en`),
    cube.id,
  );
  const dimIds = header.slice(1, -1);

  const out = [];
  let skipped = 0;
  for (const line of rows) {
    if (!line.trim()) continue;
    const cells = line.split(';').map((s) => s.replace(/^"|"$/g, ''));
    const value = cells[cells.length - 1];
    if (value === '') continue; // the cube is a full grid; most cells are empty
    const date = normalizeDate(cells[0]);
    if (date === null) {
      skipped++;
      continue;
    }
    const dims = {};
    dimIds.forEach((id, k) => {
      dims[id] = cells[k + 1];
    });
    for (const [id, code] of Object.entries(dims)) {
      if (!labels[id]?.[code]) throw new Error(`${cube.id}: unknown ${id} code "${code}"`);
    }
    const fields = cube.keep(dims, labels);
    if (fields === null) continue;
    out.push([date, ...fields, value]);
  }
  if (out.length === 0) throw new Error(`${cube.id}: no rows survived parsing`);
  out.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));

  const body = [
    cube.columns.join(','),
    ...out.map((r) => r.map(csvQuote).join(',')),
  ].join('\n');
  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(join(OUT_DIR, cube.file), body + '\n');

  vintages.push({
    cube_id: cube.id,
    file: cube.file,
    publishing_date: meta.PublishingDate ?? '',
    first_date: out[0][0],
    last_date: out[out.length - 1][0],
    rows: out.length,
    retrieved: new Date().toISOString().slice(0, 10),
  });
  console.log(
    `${out.length} rows, ${out[0][0]} to ${out[out.length - 1][0]}, ` +
      `published ${meta.PublishingDate}${skipped ? `, ${skipped} unparseable dates dropped` : ''}`,
  );
}

// PublishingDate is the only revision metadata the cube API offers - there is
// no vintage history - so it is recorded next to the data rather than left in
// the HTTP response that produced it.
const vintageCols = [
  'cube_id',
  'file',
  'publishing_date',
  'first_date',
  'last_date',
  'rows',
  'retrieved',
];
writeFileSync(
  join(OUT_DIR, 'publishing_dates.csv'),
  [
    vintageCols.join(','),
    ...vintages.map((v) => vintageCols.map((c) => csvQuote(String(v[c]))).join(',')),
  ].join('\n') + '\n',
);
console.log('publishing_dates.csv written');
