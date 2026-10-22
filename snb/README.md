# SNB data-portal series

Two cubes from the Swiss National Bank's data portal, adopted in #36 as
candidate high-frequency inputs. Not used by the dashboard (`index.html` reads
only `wai_data.csv`); wiring a series into the WAI happens in
[`mfbdfm`](https://github.com/PhilippKronenberg/mfbdfm)'s data prep, not here.

- **Source:** Swiss National Bank, <https://data.snb.ch/>, cube API
  `https://data.snb.ch/api/cube/<cubeId>/data/csv/en`.
- **Licence:** **not** CC BY 4.0 — see [Licence](#licence) below.

| cube | content | frequency | history | release |
| --- | --- | --- | --- | --- |
| `snbgwdzid` | SNB policy rate, SARON fixing, special rate, sight-deposit rates below and above the threshold, threshold factor, discount in basis points | daily | 2004-05-03 → | weekly, Monday ~10:00, data to the preceding Friday |
| `devwkieffid` | effective (trade-weighted) CHF exchange-rate index, nominal and real (CPI- and PPI-based), overall and euro-area, index and day-on-day change | daily | 1999-01-01 → | monthly, data to the end of the preceding month |

`snbgwdzid` is the only series in this folder whose cadence genuinely suits a
weekly index: daily observations at a ~3-day lag. **`devwkieffid` is daily data
on a monthly release** — early in a month its last observation is five weeks
old, which is much weaker than "daily" suggests.

## Files

| file | |
| --- | --- |
| `acquire_snb_cubes.mjs` | downloads both cubes and rewrites everything below (Node, no dependencies) |
| `snb_policy_rates.csv` | `date, series_id, value` — cube `snbgwdzid` |
| `snb_chf_effective_index.csv` | `date, series_id, value` — cube `devwkieffid` |
| `snb_series.csv` | `cube_id, series_id, series, unit, first_date, last_date, observations` |
| `snb_vintages.json` | each cube's `PublishingDate` as of the last download |

Refresh from the repository root:

```
node snb/acquire_snb_cubes.mjs
```

## Reading the CSVs

- `series_id` is the SNB dimension code — a single code for `snbgwdzid`
  (`LZ`, `SARON`, `ENG`, `ZIG`, `ZIGBL`, `ZIABP`, `FREI`), and the dot-joined
  codes of the three dimensions for `devwkieffid` (`N.G.I` is the nominal
  overall index, `K.E.V` the day-on-day change of the CPI-based real
  euro-area index). **`snb_series.csv` resolves every code to its name**, as
  the portal's `/dimensions/` endpoint gives it. The names are kept there
  rather than repeated on every one of ~100 000 rows.
- The portal publishes each cube as the full cross-product of its dimensions,
  most of which is empty. Empty values are dropped here, so a series simply
  starts at its first observation: the PPI-based real index runs 2000-11-30 →
  2025-09-30 while the CPI-based one is current, and the policy rate `LZ`
  only begins 2019-06-13, when it replaced the Libor target range.
- A missing day is a day the SNB did not publish — weekends, holidays, and in
  the FX cube the whole of the current month until the next release.
- `snb_vintages.json` carries the `PublishingDate` of each cube at download
  time. It is the **only** vintage marker the portal offers, and it is in the
  CSV header that the tidy output drops, which is why it is kept beside the
  data. There is no revision history: a re-download silently replaces earlier
  values.

## Licence

**The repository's `LICENSE-DATA` (CC BY 4.0) does not cover this folder,**
and `LICENSE-DATA`'s SCOPE paragraph names it as excluded.

The SNB's terms (<https://www.snb.ch/en/srv/disclaimer_copyright>) allow data
to be saved, translated, transmitted or otherwise used **for non-commercial
purposes, with reference to the source**. That is narrower than CC BY 4.0,
which permits commercial use, so the two cannot be conflated. Attribute as:

> Source: Swiss National Bank, data portal (data.snb.ch).

If you need these series for anything commercial, take them from the SNB
under its terms rather than from here.

## Traps

Three things about the portal that cost time when this was first built, all
handled in `acquire_snb_cubes.mjs` and all worth knowing before changing it:

- **An unrecognised `/api/...` path returns HTTP 200 and the portal's HTML
  shell**, not a 404. `/api/topics/en` and `/api/cube/list/en` both look like
  successes. Check the content, never the status code.
- **The cube CSVs are semicolon-separated, UTF-8 with a BOM and CRLF**, with
  two metadata lines and a blank line before the real header. Given this
  repository's history with line endings, the script strips all of that and
  writes plain LF UTF-8 without a BOM.
- **Dimension items nest, and only the leaves appear in the data.**
  `devwkieffid`'s `Real/Nominal` dimension has an item `R` whose children are
  `K` and `P`; `R` never occurs in a data row. A label map built from the top
  level resolves nothing.
- Dates differ by cube across the portal: `YYYY-MM-DD`, `YYYY-MM`, `YYYY` and
  `YYYY-Qn`. The last is not a parseable date. Both cubes here are daily and
  the script stops if a date stops looking like one.

Found in #36; see that issue for the full survey of the portal, including the
cubes that were looked at and not adopted (`snbmonagg`, `bakredsekbm`,
`zikredvol`) and the ones that look discontinued (`rendoblid`, `rendopar`).
