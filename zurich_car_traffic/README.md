# Zurich car traffic index (aufkommen_miv)

Daily motor traffic at selected City of Zurich counting stations, relative
to the mean 2019 level of the same type of day (weekday or weekend), × 100.
Not used by the dashboard. This is the WAI input `aufkommen_miv` in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

- **Source:** Stadt Zürich Open Data,
  [Daten der Verkehrszählung zum motorisierten Individualverkehr](https://data.stadt-zuerich.ch/dataset/sid_dav_verkehrszaehlung_miv_od2031)
  (`sid_dav_verkehrszaehlung_miv_OD2031_<year>.csv`). Hourly per station and
  direction since 2012, updated daily with two days' latency. About
  0.4–0.5 GB per year.
- **Method:** `wai_ind`'s `data/verkehrszählung_StatistikZH/Mobility_CarTraffic_updated.R`
  (documented in its `README_Mobility_CarTraffic_updated.md`), a replication
  of the Canton of Zurich's covid19monitoring `Mobility_CarTraffic.R`. Valid
  rows, two inherited station drop lists, directions summed per hour,
  station-days with at least 21 hours, summed over stations, indexed on the
  2019 weekday and weekend means.
- **History:** `wai_ind`'s `data/dataset/ktzh_Mobility_CarTraffic_indexed.csv`
  (2012-01-01 to 2026-02-09) is the fixed history, read from `../wai_ind/`
  (read-only) or a path given as argument. Only 2019 (the benchmark) and the
  years after the history are downloaded. `WAI_FULL=TRUE` rebuilds 2012 to
  today.

```
Rscript zurich_car_traffic/acquire_zurich_car_traffic.R [<history csv>]
```

| file | committed | |
| --- | --- | --- |
| `Mobility_CarTraffic_indexed.csv` | yes | history plus appended days; layout of `wai_ind`'s `ktzh_Mobility_CarTraffic_indexed.csv` (`;`, `DD.MM.YYYY`) |
| `raw/` | no | the yearly files; past years cached, the current one downloaded on every run |

**Downloads:** data.stadt-zuerich.ch has two address forms per file. Either
can be broken for a given file (October 2026: the id form fails for this
dataset's 2026 file). The script tries the API's link first, then the id
form.

## First run (2026-10-25)

2019 benchmark: 1,320,608 vehicles per weekday, 1,084,483 per weekend day.
Against the history on 400 days (2019 and 2026-01-01 to 2026-02-08), the
rebuilt index matches to a median relative difference of 8e-11. 253 days
appended, 2026-02-10 to 2026-10-21.

The Canton of Zurich's own covid19monitoring repository for car counts
(`covid19monitoring_mobility_VerkehrsmessstellenKantonZH`) reads raw Excel
files from an internal file server of the cantonal civil engineering office.
Those are not public, so the city's open data are the only automatable
route.
