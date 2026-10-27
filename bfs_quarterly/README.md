# BFS quarterly labour-market and services-turnover tables

The quarterly BFS series requested in #39: employment and full-time
equivalents, job vacancies, the employment-outlook indicator, recruitment
difficulty, and the quarterly services turnover statistics. Not used by the
dashboard (`index.html` reads only `wai_data.csv`); kept here, next to
`bfs_keu`, `rhine_cargo` and `zefix`, as candidate indicators. Nothing in this
folder touches `index.html` or `wai_data.csv`.

- **Source:** Bundesamt für Statistik (BFS), STAT-TAB, read through the PxWeb
  API `https://www.pxweb.bfs.admin.ch/api/v1/de/` — the machine-readable route
  into BFS that #36 found. Underlying surveys: *Beschäftigungsstatistik*
  (BESTA) for the eight labour tables, *Dienstleistungsumsatzstatistik* (DUS)
  for the turnover one.
- **Coverage:** 1991Q3 → 2026Q2 at the longest (BESTA employees), see the table
  below. Fetched 2026-10-27.
- **Licence:** opendata.swiss `terms_by` — "Open use. Must provide the source."
  Credited as required: **Bundesamt für Statistik (BFS)**. The PxWeb API
  carries **no licence field per cube**, so this is BFS's catalogue-wide term
  for its STAT-TAB cubes rather than something read off each of the nine.
  `LICENSE-DATA` (CC BY 4.0) covers `wai_data.csv` and `wai_meta.json` only and
  does not extend to this folder, so nothing here is relicensed by being
  committed.

## Run it

```
node bfs_quarterly/acquire_bfs_quarterly.mjs                   # fetch, rewrite the CSVs
node bfs_quarterly/acquire_bfs_quarterly.mjs --cache           # keep/reuse raw responses in raw/
node bfs_quarterly/acquire_bfs_quarterly.mjs --only besta_vacancies_region
node bfs_quarterly/acquire_bfs_quarterly.mjs --out /tmp/bfsq   # write elsewhere
```

Node built-ins only, no dependencies, ~2 minutes for all nine cubes. The API
rate-limits at roughly 30 requests per 10 seconds — 12 in parallel earns
`429 - Too many requests in too short timeframe` on most of them — so requests
are serial and paced, and a 429 is retried rather than written out as data.

## What is here

One long CSV per cube. Every file has `date` (the quarter's **first day**,
`YYYY-MM-DD`), one column per dimension, `value`, and `status` (PxWeb's missing
marker, usually `...`, empty when the observation exists).

| file | STAT-TAB cube | title | coverage | rows | dimensions besides date |
| --- | --- | --- | --- | --- | --- |
| `besta_employees_division.csv` | `px-x-0602000000_101` | Beschäftigte nach Wirtschaftsabteilung, Beschäftigungsgrad und Geschlecht | 1991Q3–2026Q2 | 84 000 | `division` (60), `employment_level` (10) |
| `besta_employees_region.csv` | `px-x-0602000000_102` | Beschäftigte nach Grossregion, Wirtschaftssektor, Beschäftigungsgrad und Geschlecht | 1995Q3–2026Q2 | 17 856 | `region` (8), `sector` (3), `employment_level` (6) |
| `besta_vacancies_division.csv` | `px-x-0602000000_103` | Offene Stellen nach ausgewählten Wirtschaftsabteilungen | 1992Q2–2026Q2 | 8 220 | `measure` (3), `division` (20) |
| `besta_vacancies_region.csv` | `px-x-0602000000_104` | Offene Stellen nach Grossregion | 1997Q1–2026Q2 | 2 832 | `measure` (3), `region` (8) |
| `besta_outlook_division.csv` | `px-x-0602000000_105` | Betriebe nach voraussichtlicher Beschäftigungsentwicklung und ausgewählten Wirtschaftsabteilungen | 2004Q1–2026Q2 | 18 000 | `division` (20), `outlook` (5), `weighting` (2) |
| `besta_outlook_region.csv` | `px-x-0602000000_106` | Betriebe nach voraussichtlicher Beschäftigungsentwicklung und Grossregion | 2004Q1–2026Q2 | 7 200 | `region` (8), `outlook` (5), `weighting` (2) |
| `besta_recruiting_division.csv` | `px-x-0602000000_107` | Betriebe nach Schwierigkeiten bei der Personalrekrutierung, ausgewählten Wirtschaftsabteilungen und Ausbildungsniveau | 2004Q1–2026Q2 | 72 000 | `division` (20), `education` (4), `difficulty` (5), `weighting` (2) |
| `besta_recruiting_region.csv` | `px-x-0602000000_108` | Betriebe nach Schwierigkeiten bei der Personalrekrutierung, Grossregion und Ausbildungsniveau | 2004Q1–2026Q2 | 28 800 | `region` (8), `education` (4), `difficulty` (5), `weighting` (2) |
| `dus_turnover_quarterly.csv` | `px-x-0603030000_102` | Dienstleistungsumsatzstatistik – vierteljährliche Zeitreihen | 2010Q1–2022Q4 | 16 224 | `adjustment` (4), `measure` (2), `turnover` (3), `branch` (13) |

`bfs_quarterly_codes.csv` (`dimension,code,label`) holds the German label of
every code in those files, once each. The codes carry no meaning on their own —
`division` is a NOGA range (`5-96` is the total, `10-33` the manufacturing
aggregate), `region` is a Grossregion number with `0` for Switzerland — so they
are normalised out into that file, the same split `bfs_keu` and `zefix` make.

### Units and seasonal adjustment

The PxWeb API carries no unit field, so units come from the code labels:

- **`besta_employees_*`:** persons, not thousands (Switzerland, all employment
  levels, 2026Q2: 5 698 064). `employment_level` is where the adjustment lives:
  `TOT` total, `1` full-time, `2` part-time (`2.1`/`2.2` its two bands), `3`
  **total seasonally adjusted**, `4` full-time equivalents, `4.1` the FTE
  index, `4.2` **FTE seasonally adjusted**. Raw and seasonally adjusted are
  therefore both present, as categories of one variable rather than separate
  tables.
- **`besta_vacancies_*`:** `measure` `1` vacancies (count), `2` index
  (2015Q2 = 100), `3` rate in percent. Unadjusted.
- **`besta_outlook_*`:** percent of firms, by `weighting` `1` employees or `2`
  establishments. `outlook` `1`–`4` are the response shares (keep, raise,
  reduce, no answer) and **`outlook = 5` is the
  *Indikator der Beschäftigungsaussichten*** #39 asks for separately — it is a
  category of this variable, not a cube of its own. Unadjusted.
- **`besta_recruiting_*`:** percent of firms, same `weighting`, by
  `education` (4 levels) and `difficulty` (`1` found easily … `5` no answer).
  Unadjusted.
- **`dus_turnover_quarterly`:** `measure` `ind` index or `var` percent change;
  `adjustment` `brut` unadjusted, `ca` calendar-adjusted, `sa` **seasonally
  adjusted**, `tr` trend; `turnover` total, domestic or export.

**Release lag:** BESTA's 2026Q2 values were published 2026-08-27 (the employees
cube 2026-09-01), i.e. about eight weeks after the quarter ends. **The DUS
quarterly cube stopped:** it ends 2022Q4 and was last updated 2023-08-07. It is
written out because #39 asks for it, but it is not a live series.

**`Geschlecht` is pinned to its total** in the two employee cubes. #39 asks for
the national total plus the industry breakdown and explicitly skips the
sex/nationality/age cuts, which are cuts of the same survey and add no activity
signal. Every other variable is taken whole.

### How the numbers were checked

The flat `value` array json-stat2 returns is indexed by the product of the
dimension sizes, so a wrong stride produces a file that looks perfectly
well-formed and is scrambled. Two identities the data must satisfy were
checked after the fetch and both hold exactly: the seven Grossregionen's
vacancy counts sum to the Switzerland row in all 93 quarters that have one, and
sector 2 plus sector 3 employees sum to the `Sektoren 2-3` total in all 124
quarters. The script also refuses a response whose value count does not match
the declared dimension product, and refuses a cube that has grown a variable it
does not map, rather than dropping it silently.

## What is not here

Of the series #39 lists, these nine are the ones this API has. **The others are
in no cube of this database.** `GET /api/v1/de/` returns all 635 cube ids it
holds (with no titles; `GET /api/v1/de/<id>` gives the title of the one cube
inside, which is how the list was searched), and an id that does not exist
answers `Bad Request` rather than an empty list — so the absence is the
database's, not a missed page of results:

- **Erwerbstätige (ETS)**, total and in full-time equivalents, raw and
  seasonally adjusted, and by sector and section.
- **Erwerbslosenquote / Erwerbslose gemäss ILO (SAKE)**, raw and seasonally
  adjusted.
- **Quartalschätzungen der Nominallohnentwicklung.**
- **Ausländische Grenzgänger/-innen** by working canton and industry (only the
  2025–2055 *scenarios* cube is in the API, which is a projection, not a
  measurement).
- **Ankünfte und Logiernächte in Ferienwohnungen und Kollektivunterkünften**
  and **auf Campingplätzen** (the API has the hotel cubes, which #32 covers
  already, not the parahotel ones).
- **Schweizerischer Wohnimmobilienpreisindex (IMPI).**
- **Umsätze im sekundären und tertiären Sektor, quarterly.** The *monthly* KEU
  is in `bfs_keu`, taken over the SDMX service behind the stats.swiss explorer
  (`disseminate.stats.swiss/rest`, dataflow `CH1.KEU:DF_KEU_M1`). The quarterly
  companion is most likely reachable the same way, which is the obvious next
  step for it and is not the route this folder uses.

Each of those is a BFS asset download (ODS/CSV/XLSX) or an SDMX dataflow, each
needing its own `orderNr` or dataflow id and its own parser. They are the
remainder of #39 and are not in this change.
