# KOF series (`mfbdfm` collection)

Every time series in the KOF Time Series Database collection `mfbdfm`, owned by
`kphilipp` and curated on the KOF TS Explorer
(<https://ts-explorer.kof.ethz.ch/collections?collection=mfbdfm>). Not used by
the dashboard. These are candidate inputs for the WAI, which is estimated
upstream in [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

- **Source:** KOF Swiss Economic Institute, ETH Zurich, KOF Time Series
  Database API (<https://tsdb-api.kof.ethz.ch/v2/docs>), read with the
  [`tsdbapi`](https://github.com/KOF-ch/tsdbapi-R) R package.
- **Coverage:** whatever the collection holds; it is curated on the TS
  Explorer, not in this repository. Add or remove series there.

## Files

| file | |
| --- | --- |
| `acquire_kof.R` | downloads the collection and writes the CSVs (needs R, `tsdbapi`, `zoo`, `lubridate`) |
| `kof_series.csv` | output: `key, date, value, frequency`, one row per observation; `date` is the first day of the period |
| `kof_metadata.csv` | output: one row per series, nested metadata flattened to `parent.child` columns |
| `kof_release.csv` | output: the vintage and release information of what was downloaded |

**The three CSVs are gitignored** (`kof/.gitignore`). Unlike the other
pipelines' open data, a KOF collection can hold series KOF does not license
for redistribution, and this repository is public. Remove a file from the
ignore list only once it is confirmed that every series in it may be published.

## Running it

`tsdbapi` is not on CRAN:

```r
remotes::install_github("KOF-ch/tsdbapi-R")
```

The collection belongs to a KOF user, so reading it needs credentials.

- **Interactively**, `tsdbapi` opens KOF's login page.
- **Unattended** (scheduled, CI), set an API key in `TSDBAPI_API_KEY`. Create
  it once, interactively, with `tsdbapi::create_user_api_key()`; this
  invalidates any older key. Put `TSDBAPI_API_KEY=<key>` in `~/.Renviron`, or
  in a repository secret for GitHub Actions. **Never commit it.** Without a key
  a non-interactive run stops with that instruction instead of waiting on a
  login nobody can answer.

From the repository root:

```
Rscript kof/acquire_kof.R                         # latest vintage, into kof/
Rscript kof/acquire_kof.R <output_dir>            # elsewhere
Rscript kof/acquire_kof.R <output_dir> 2026-01-15 # the vintage valid on a past date
```

## Reading the CSV

- Regular series carry their `frequency` (12 monthly, 4 quarterly, 1 annual),
  and `date` is the first day of the period. Irregular or daily series, which
  `tsdbapi` returns as `xts`, have an empty `frequency` and their own dates.
- Missing values inside a series' range are omitted, not written as zero.
- `valid_on` selects a vintage. For external users KOF shows a vintage only
  once it has been released, usually a few days after its vintage date.

Relation to #37: that issue tried KOF's open-data service
(`datenservice.kof.ethz.ch`), which has been refusing connections. This
pipeline uses the authenticated Time Series Database API instead.
