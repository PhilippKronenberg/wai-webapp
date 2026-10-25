# Passenger counts at Zurich Hardbrücke (oev_freq_hardbruecke)

Daily persons entering and leaving Zurich Hardbrücke station, all VBZ
counting lines. Not used by the dashboard. This is the WAI input
`oev_freq_hardbruecke` (`total_in + total_out`) in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

- **Source:** Stadt Zürich Open Data,
  [VBZ Passagierfrequenzen Hardbrücke](https://data.stadt-zuerich.ch/dataset/vbz_frequenzen_hardbruecke),
  one CSV per year since 2020, updated daily. The download URLs are taken
  from the dataset's CKAN API. The short links
  `…/dataset/vbz_frequenzen_hardbruecke/download/<file>` forward to a broken
  address for 2020, 2021 and 2023 (October 2026); the form with package and
  resource ids works for every year.
- **Method:** `wai_ind`'s `data/oev_frequency_SBB_hard/create_daily_frequency_hardbruecke.R`.
  In and out are summed per timestamp and counting line, then per day (days
  cut in UTC). It descends from the Canton of Zurich's
  `Mobility_VBZ_Hardbruecke.R`
  ([statistikZH/covid19monitoring_mobility_VBZHardbruecke](https://github.com/statistikZH/covid19monitoring_mobility_VBZHardbruecke),
  archived 2022). The current day is left out because it is still being
  counted.

```
Rscript zurich_hardbruecke/acquire_zurich_hardbruecke.R [<old csv to compare with>]
```

| file | committed | |
| --- | --- | --- |
| `daily_frequency_hardbruecke.csv` | yes | `date, total_in, total_out`; same layout as `wai_ind`'s `ktzh_daily_frequency_hardbruecke.csv` |
| `raw/` | no | the yearly files (about 200 MB); past years are cached, the current one is downloaded on every run |

## First run (2026-10-25)

2020-01-01 to 2026-10-24. Against `wai_ind`'s file (to 2026-02-11):
**identical on all 2205 common days** in every year.
