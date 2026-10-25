# Swissgrid electricity totals (Energieübersicht Schweiz)

Daily Swiss electricity end use, production and consumption, built from
Swissgrid's yearly quarter-hourly workbooks. Not used by the dashboard. These
are the WAI inputs `electricity_out` and `electricity_in` in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

| column | Swissgrid column (sheet `Zeitreihen0h15`) | WAI input |
| --- | --- | --- |
| `out.ch` | Summe endverbrauchte Energie Regelblock Schweiz | `electricity_out` |
| `in.ch` | Summe produzierte Energie Regelblock Schweiz | `electricity_in` |
| `out_incl_losses.ch` | Summe verbrauchte Energie Regelblock Schweiz | none |

All in kWh per day: the sum of the 96 quarter-hours, with days cut as in
`wai_ind`'s `data/Swissgrid/swissgrid.R`, whose reading this reproduces. The
layout is that of `wai_ind`'s `swissgrid_2009_2025.csv`.

- **Source:** Swissgrid,
  <https://www.swissgrid.ch/de/home/customers/topics/energy-data-ch.html>,
  `EnergieUebersichtCH-<year>.xls(x)`, one per year since 2009. The current
  year's workbook is updated during the year (2026 runs to 2026-09-30 on
  2026-10-25).
- **Finding the newest file:** the links carry an id (`/dam/jcr:<id>/`) that
  changes whenever a workbook is replaced. The script reads the page on every
  run and downloads a workbook again only when its link changed
  (`raw/manifest.csv`). The workbooks (about 450 MB) are not committed.

```
Rscript swissgrid/acquire_swissgrid.R [<old swissgrid csv to compare with>]
```

## Checks (a failed check stops the run)

1. The page lists a workbook for every year from 2009 to the current year.
2. Each workbook has the sheet, and columns B–D are end use, production and
   consumption.
3. No day before the last has fewer than 92 quarter-hours (92 and 100 are
   the DST days). A last day that is not complete is dropped.
4. With an old file given, every year is compared. A change above 2% stops
   the run.

## First run (2026-10-25), against `wai_ind`'s file to 2025-12-31

2009–2024 are **identical on every day**. 2025 is revised, by at most 0.47%
(end use), 0.14% (production) and 0.49% (incl. losses): Swissgrid replaced the
2025 workbook with final data.

## Comparison with opendata.swiss "Stromproduktion Swissgrid" (`ogd104`)

[energiedashboard.ch: Stromproduktion Swissgrid](https://opendata.swiss/de/dataset/energiedashboard-ch-stromproduktion-swissgrid)
(`https://www.bfe-ogd.ch/ogd104_stromproduktion_swissgrid.csv`): daily
production in GWh by energy source since 2015, one day behind. Compared with
`in.ch` (converted to GWh) on 4291 days, 2015-01-01 to 2026-09-30:

| | |
| --- | --- |
| correlation of daily log changes | 0.997 |
| correlation of weekly log changes | 0.997 |
| level, `ogd104` / Swissgrid (median) | 1.054 (2015) rising to 1.115 (2026) |

**The level gap is photovoltaics.** Leaving solar out of `ogd104`, the two
agree within 0–3% in every year from 2015 to 2024. The gap correlates 0.89
with `ogd104`'s solar production. `ogd104` counts all solar production,
including rooftop systems behind the meter, while the Swissgrid balance-zone
total sees only what reaches its measurement. Their difference grows with
rooftop solar. In 2025–26, `ogd104` excluding solar is 2% and 8% below
Swissgrid, so the two also differ outside solar in the most recent period.

For the WAI's week-on-week dynamics the two are interchangeable. `ogd104` is
much more current (1 day behind, against up to a few months for the current
workbook) and has the breakdown by source. The Swissgrid workbooks reproduce
the series the WAI was estimated on.
