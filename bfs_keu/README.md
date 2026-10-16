# BFS turnover statistics (KEU)

Monthly turnover and production indices for the Swiss secondary and tertiary
sector, by NOGA branch and by retail commodity group, from 2000-01. Not used by
the dashboard (`index.html` reads only `wai_data.csv`); kept here, next to
`rhine_cargo`, `bfe_energy` and `zefix`, as a candidate indicator — this is the
broadest *monthly* activity measure in the opendata.swiss catalogue and the
first of the monthly anchors adopted in #32 (A7).

- **Source:** Bundesamt für Statistik (BFS), *Statistik der Umsätze im
  sekundären und tertiären Sektor – monatliche Zeitreihen* (dataflow
  `CH1.KEU:DF_KEU_M1`),
  <https://opendata.swiss/de/dataset/statistik-der-umsatze-im-sekundaren-und-tertiaren-sektor-monatliche-zeitreihen1>.
  Underlying survey: *Konjunkturerhebung Umsatz* (KEU). Legal basis:
  [Bundesstatistikgesetz](https://www.admin.ch/opc/de/classified-compilation/19920252/index.html).
- **Coverage:** 2000-01 → 2026-08 as fetched on 2026-10-16, monthly. The last
  month **differs by branch**, see below; retail is six weeks behind, the
  whole-economy aggregate four months.
- **Licence:** opendata.swiss `terms_by` — "Open use. Must provide the source."
  Credited as required: **Bundesamt für Statistik (BFS)**. `LICENSE-DATA`
  (CC BY 4.0) covers `wai_data.csv` and `wai_meta.json` only and does not
  extend to this folder, so nothing here is relicensed by being committed.

**The catalogue offers no file to download.** This dataset's resources are four
HTML asset pages and four links into the stats.swiss data explorer — unlike
`ogd51` or Zefix there is no CSV URL. The explorer is a .Stat Suite front end,
and the script reads the SDMX REST service behind it,
`https://disseminate.stats.swiss/rest`, which the catalogue does not advertise;
it was read off the explorer's own JavaScript bundle. Anyone re-pointing this
script should know that is where the endpoint came from.

## Files

| file | |
| --- | --- |
| `acquire_bfs_keu.mjs` | downloads the cube and writes both CSVs (Node built-ins only, no dependencies) |
| `bfs_keu_turnover_monthly.csv` | `date, noga, adjustment, indicator, measure, value, status` — 126,948 rows, about 4.4 MB |
| `bfs_keu_codes.csv` | `dimension, code, parent, label` — the German labels for all 104 codes used, once each |

Refresh from the repository root:

```sh
node bfs_keu/acquire_bfs_keu.mjs
node bfs_keu/acquire_bfs_keu.mjs --measures all
node bfs_keu/acquire_bfs_keu.mjs --cache /tmp/bfs_keu
```

The whole cube arrives as one 17 MB request and there is no date-filtered
refresh worth having, so `--cache` keeps the download and re-parses from it.

**The labels are normalised out of the data file**, the same split `zefix`
makes: the codes are meaningless on their own, and carrying 90-character German
branch names on 126,948 rows would cost several megabytes to say what a code
already determines. The script fails if the data ever uses a code the
codelists do not describe, so the two files cannot drift apart.

## Reading the CSVs

- One row per **month, branch, adjustment, indicator and measure**, long
  format, sorted, LF line endings, no BOM. Monthly periods are dated to the
  **first of the month**, as in `rhine_cargo` and `bfe_energy`, so every date
  here is a real `YYYY-MM-DD`.
- `value` is an **index with 2021 = 100** and is passed through as the
  publisher's own text, never reparsed and reformatted, so no float round-trip
  can move a digit. The base year is not stated anywhere in the dataset's
  metadata; it was established by arithmetic — the 2021 annual mean is 100.00
  to four decimals in **all 796** series, every one of which has a complete
  2021.
- `measure` is `IX`, the index, on every committed row. The publisher also
  serves its own percent changes (`VARM-12` year on year for `N` and `W`,
  `VARM-1` month on month for `Y`) and `--measures all` writes them, which
  takes the file from 4.4 MB to 9.1 MB. They are **not committed** because they
  are first differences of this same index and a transformation of two lines
  reproduces them — to within the index's own 2-decimal rounding, since the
  publisher computes them from unrounded values, so the last digit can differ.
  The `measure` column exists anyway, so `--measures all` adds rows rather than
  changing the schema.
- `adjustment` is `N` unadjusted, `W` calendar-adjusted, `Y` calendar- and
  seasonally-adjusted. `indicator` is `UTOT` total turnover (nominal), `UINL`
  domestic, `UEXP` foreign, `PTOT` production / total turnover in **real**
  terms. Full labels are in `bfs_keu_codes.csv`.
- `status` is the publisher's observation status: `A` normal, `P`
  **provisional**. 2,559 of the committed rows are provisional, all of them in
  the last five months (2026-04 onwards as fetched), so the most recent end of
  every series is the part most likely to be revised.
- **A valueless observation is dropped, not zero-filled**, as `rhine_cargo`
  drops unreported months: 9,397 cells carry status `L` (the value exists but
  is not published, i.e. suppressed) and 11,945 status `M` (the value cannot
  exist). Neither is a zero and neither is in the file.

## Caveats that matter before modelling on this

- **The last month differs by branch.** Retail (`47` and its 18 sub-codes) runs
  to 2026-08; 41 branch codes end 2026-07 and 30 — including the whole-economy
  aggregate `B-NxK` — end 2026-06. Taking the file's maximum date as the
  vintage of every series would be wrong.
- **The histories are mostly short.** Only 16 of the 90 NOGA codes start
  2000-01; 29 start 2010-10, 3 start 2014-01 and **42 start 2021-01**. Against
  a WAI that begins in 1990, the deep breakdowns buy very little.
- **`noga` is a hierarchy, and summing it double-counts.** `parent` in
  `bfs_keu_codes.csv` gives the tree: four codes are roots (`B-F` secondary
  sector, `B-NxK` total economy excluding finance and insurance, `G-NxK` and
  `H-NxK` two cuts of the tertiary sector) and the rest nest up to four levels
  deep under them. These are index numbers in any case, so they do not add —
  the aggregate is the publisher's own, not a sum of its parts. One parent code
  (`G-N`, tertiary sector including finance) appears only as a parent: it has
  no observations of its own.
- **Not every series exists for every branch.** `B-NxK` is published
  unadjusted only, with no `PTOT`, so there is no seasonally adjusted
  whole-economy index in this dataset; retail carries all nine
  adjustment-by-indicator combinations. There are 796 series in all, where the
  full cross would be 1,080.
- `UEXP` (foreign turnover) exists for only **52 of the 90 branches** —
  industry and wholesale, never retail — and starts in 2010-10 rather than
  2000-01. Where it exists it ends in the same month as that branch's `UTOT`;
  the file's latest `UEXP` month is 2026-07 only because the branches that
  reach 2026-08 are the retail ones, which have none.
- Revisions are not versioned by the publisher: a refresh rewrites the whole
  file, so a vintage is only recoverable from this repository's git history.
  That matters more here than for the other folders, because provisional
  months are explicitly flagged and they do move.
