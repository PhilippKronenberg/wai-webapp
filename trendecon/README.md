# trendEcon indicator (`trendecon`)

trendEcon's daily, seasonally adjusted Google Trends indicator of the
perceived economic situation in Switzerland. It is the WAI input `trendecon`
in [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm). Not used by the
dashboard.

- **Source:** [trendecon/data](https://github.com/trendecon/data),
  `data/ch/trendecon_sa.csv`, updated daily.
- **Output:** `trendecon_sa.csv` (`time,value`), unchanged from the source,
  the layout `wai_ind`'s data/dataset file has.

```
Rscript trendecon/acquire_trendecon.R
```

The run stops if the columns change, dates are missing or duplicated, or the
newest day is more than 14 days old. `wai_ind`'s copy ended 2025-08-22; the
2026-10-25 download runs to 2026-10-25.
