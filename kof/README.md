# KOF series (`mfbdfm` collection)

The KOF Time Series Database collection `mfbdfm`, curated on the KOF TS
Explorer (<https://ts-explorer.kof.ethz.ch/collections?collection=mfbdfm>).
Not used by the dashboard. These are inputs to the WAI, which is estimated
upstream in [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

- **Source:** KOF Swiss Economic Institute, ETH Zurich, KOF Time Series
  Database API (<https://tsdb-api.kof.ethz.ch/v2/docs>), read with the
  [`tsdbapi`](https://github.com/KOF-ch/tsdbapi-R) R package.

## Two modes

The same collection is kept by two accounts, and the script reads either.

| | **public** (default) | **private** (`--private`) |
| --- | --- | --- |
| account | open account `0945fec6-…` | `kphilipp` |
| credentials | **none**, so it runs unattended anywhere | login, or `TSDBAPI_API_KEY` |
| series | only those KOF has made public: **5 of 9** on 2026-10-25 | all 9 |
| vintages | released only | **including not-yet-released ones** |
| output | `kof/public/` | `kof/private/`, never committed |

The four manufacturing sub-sector series (`ch.kof.inu.ng08.fx.sector_mig.*`:
capital goods, durable and non-durable consumer goods, intermediate goods) are
not public. Public mode skips them, and says so in the log.

**Private output can hold embargoed data, and the model does not use it.** On
2026-10-25 the private collection already held the October values, scheduled
for release on 2026-11-04. `kof_release.csv` carries a `released` column, and a
run warns when any series is pre-release.

**Released vintages only.** Every run also writes `kof_series_released.csv`
and `kof_release_used.csv`. For a series whose current vintage is not released
(`release_time` still ahead), the whole vintage is replaced by the latest
released one: the vintage valid on the day before its `vintage_date` is read,
stepping further back if that one is not released either. Cutting only the
newest month would not do, because a vintage can also revise past months (KOF
re-estimates the seasonal adjustment). If no released vintage is found, the
run stops. `dataset/assemble_dataset.R` reads **only**
`kof_series_released.csv`, and only series recorded there as released with a
release time that has passed. Without that file it does not use the download.
`kof_series.csv` remains the raw read and must not feed the model.

Verified 2026-10-25: on the 5 shared series, public and private differ only by
the newer month and the seasonal-adjustment revision it brings (at most 2.2
points).

## Files

| file | |
| --- | --- |
| `acquire_kof.R` | downloads the collection and writes the CSVs (needs R, `tsdbapi`, `zoo`, `lubridate`) |
| `acquire_kof_loggedin.R` | the private mode with your own KOF login (OAuth in the browser) instead of an API key; interactive only |
| `<mode>/kof_series.csv` | `key, date, value, frequency`, one row per observation; `date` is the first day of the period |
| `<mode>/kof_metadata.csv` | one row per series, nested metadata flattened to `parent.child` columns |
| `<mode>/kof_release.csv` | vintage date, release time and `released` per series, for the current vintage |
| `<mode>/kof_series_released.csv` | as `kof_series.csv`, released vintages only: **what the model dataset uses** |
| `<mode>/kof_release_used.csv` | per series, the vintage in `kof_series_released.csv`, its release time, `released`, and `replaced` (TRUE if the current vintage was pre-release) |

**Both output folders are gitignored.** `private/` must stay that way.
`public/` is held back only until KOF's terms for republishing public series
in this public repository are confirmed; then delete its line in
`kof/.gitignore` and commit it like the other pipelines' data.

## Running it

`tsdbapi` is not on CRAN:

```r
remotes::install_github("KOF-ch/tsdbapi-R")
```

From anywhere; the output path is resolved from the script's own location:

```
Rscript kof/acquire_kof.R                          # public, into kof/public/
Rscript kof/acquire_kof.R --private                # all series, into kof/private/
Rscript kof/acquire_kof.R --private <dir> 2026-01-15   # the vintage valid on a past date
```

For unattended private runs, create a key once, interactively, with
`tsdbapi::create_user_api_key()` (this invalidates any older key). Put
`TSDBAPI_API_KEY=<key>` in `~/.Renviron` and **never commit it**. Without a
key, `--private` stops with that instruction instead of waiting on a login.

To use your own KOF login instead of a key, run this in an interactive
session (RStudio) from the repository root:

```r
source("kof/acquire_kof_loggedin.R")
```

It signs in through the browser (tsdbapi `access_type = "auth"`, OAuth) and
otherwise runs `acquire_kof.R`'s private mode unchanged, into `kof/private/`.
Set `kof_valid_on` or `kof_out_dir` before sourcing to change the vintage or
the folder.

## Reading the CSV

- **The values are KOF's balances as published, which can be negative.**
  mfbdfm's raw dataset stores the same series shifted by +100, so that its
  `diff(log(x))` transformation is defined. Add 100 before comparing with, or
  feeding into, that dataset. Checked 2026-10-25: with the shift, the 9
  series match mfbdfm's April 2026 raw data to a median absolute difference of
  0.01–0.09 points, against series standard deviations of 9–30. The larger
  differences, 1–4 points on average, sit in the most recent year. They are
  seasonal-adjustment revisions (`d11`): KOF re-estimates the seasonal factors
  each month and revises recent history.
- Regular series carry their `frequency` (12 monthly, 4 quarterly, 1 annual).
  Irregular or daily series, which `tsdbapi` returns as `xts`, have an empty
  `frequency` and their own dates.
- Missing values inside a series' range are omitted, not written as zero.

Relation to #37: that issue tried KOF's open-data service
(`datenservice.kof.ethz.ch`), which has been refusing connections. This
pipeline uses the Time Series Database API instead.
