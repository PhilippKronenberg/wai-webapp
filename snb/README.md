# SNB data portal

Two series from the Swiss National Bank's data portal, adopted in #36 as
candidate high-frequency inputs. Not used by the dashboard (`index.html` reads
only `wai_data.csv`); an adopted series is wired into the index in
[`mfbdfm`](https://github.com/PhilippKronenberg/mfbdfm)'s data prep, not here.

- **Source:** SNB data portal cube API, <https://data.snb.ch/>. No auth, no API
  key. The data is at `/api/cube/<cubeId>/data/csv/en` and the dimension labels
  at `/api/cube/<cubeId>/dimensions/en`.
- **Terms:** the SNB
  [disclaimer and copyright notice](https://www.snb.ch/en/srv/disclaimer_copyright)
  permits saving, transmitting and otherwise using the data **for
  non-commercial purposes, with reference to the source**. That is narrower
  than this repository's `LICENSE-DATA` (CC BY 4.0, which permits commercial
  use), so **CC BY 4.0 does not extend to this folder** — `LICENSE-DATA` names
  it as out of scope. Attribute to the Swiss National Bank and keep use
  non-commercial.

## Files

| file | |
| --- | --- |
| `fetch_snb.mjs` | downloads both cubes and writes the CSVs (Node, no dependencies) |
| `snb_policy_rates.csv` | cube `snbgwdzid`: `date, series_code, series, value` |
| `chf_effective_exchange_rate.csv` | cube `devwkieffid`: `date, basis_code, basis, country_group_code, country_group, value` |
| `publishing_dates.csv` | each cube's `PublishingDate`, span and row count as downloaded |

Refresh from the repository root:

```
node snb/fetch_snb.mjs
```

## The two cubes, and their cadence

| cube | content | frequency | published |
| --- | --- | --- | --- |
| `snbgwdzid` | SNB policy rate, SARON fixing at the close, special rate, sight-deposit rates below and above the threshold, discount in basis points, threshold factor | daily | weekly, at a ~3-day lag |
| `devwkieffid` | effective (trade-weighted) CHF exchange-rate index, nominal and real (CPI- and PPI-based), overall and euro-area | daily | **monthly** |

`snbgwdzid` is the one whose cadence genuinely fits a weekly index: Monday
publication with data through the preceding Friday.

**`devwkieffid` is daily data published monthly.** Its last observation is
exactly month end and it appears about a week later, so early in a month it is
up to ~5 weeks stale. Daily granularity is not daily timeliness.

## Reading the CSVs

- Dimension codes (`LZ`, `SARON`, `N`, `K`, `P`, `G`, `E`, …) are internal
  identifiers and are resolved to labels at download time through
  `/dimensions/en`, so each row carries both the code and its label.
- `chf_effective_exchange_rate.csv` keeps the **index level only**. The cube
  also carries the day-on-day percentage change (`D2 = V`), which is derivable
  from the level and is dropped to keep the file small.
- The cube is a full grid and most of its cells are empty; empty values are
  dropped rather than written as blanks. A date absent for a series is a date
  the SNB does not publish, not a zero.
- `publishing_dates.csv` exists because **`PublishingDate` is the only revision
  metadata the cube API offers.** There is no vintage history: a re-download
  silently replaces the previous numbers. Real-time vintages would have to be
  accumulated by snapshotting from now on, which this script does not do — it
  overwrites.

## Traps the script handles, and why

- **The portal answers HTTP 200 with its Angular HTML shell for any
  unrecognised `/api/...` path.** `/api/topics/en` and `/api/cube/list/en` look
  like successes and are the index page. `fetch_snb.mjs` checks the body, never
  the status code.
- Cube CSVs are **semicolon-separated, UTF-8 with a BOM and CRLF**, with two
  metadata lines (`CubeId`, `PublishingDate`), a blank line, and only then the
  real `Date;<dims>;Value` header. The output is ordinary LF comma-separated
  CSV.
- Cube dates come as `YYYY-MM-DD`, `YYYY-MM`, `YYYY` **and `YYYY-Qn`**. The
  last is not a parseable date and is silently dropped by anything that just
  calls `Date.parse`; `normalizeDate` maps all four to the first day of the
  period, and the run prints a count if it dropped anything.
- An unknown dimension code aborts the run rather than being written through as
  a bare code.

Adopted cubes and the rejection of `snbmonagg`, `bakredsekbm` and `zikredvol`
are the owner's decision in #36; the survey that produced the shortlist is in
that issue.
