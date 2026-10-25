# SECO real-time GDP vintages (the WAI target)

Real-time vintages of Swiss real GDP, the target of the WAI model
(`ch.seco.gdp.real.gdp.ssa`, seasonally and sport-event adjusted). Not used
by the dashboard.

- **Source:** SECO, real-time database (an updated version of Indergand and
  Leist, 2014, *Swiss Journal of Economics and Statistics* 150(4)),
  <https://www.seco.admin.ch/dam/de/sd-web/MPCPHCXIDH6N/realtime-database.xlsx>.
- **Files:** `realtime_gdp.csv` (sheet `gdp`, with release dates) and
  `realtime_gdp_cssa.csv` (sheet `gdp_cssa`), in the format
  `mfbdfm::get_real_time_gdp_vintages()` reads. `dataset/data_prep_dataset.R`
  passes these files to it instead of the package's own copies.
- **Script:** a copy of mfbdfm's `data-raw/realtime_gdp.R` (mfbdfm #164). Only
  the output folder differs. It stops without writing if the vintages are not
  consecutive, release dates do not increase, the two sheets disagree, or the
  download has fewer vintages than the files it would replace.

```
Rscript seco_gdp/acquire_seco_gdp.R
```

## When the database lags behind SECO

SECO adds a release to `realtime-database.xlsx` only some time after
publishing it. On 2026-10-25 the database ended with the 2026-06-01 release
(to 2026q1), while the 2026-09-03 release with 2026q2 was out. If the
current release is newer than the database's last vintage, the script
appends it as the next vintage, labelled by the quarter of its release date
as the database labels them. Once SECO adds the release, the step does
nothing.

| | source |
| --- | --- |
| **values** | SECO's machine-readable feed, <https://scheduler.swissdatas.ch/scheduled/ch-seco-gdp.csv> (metadata: `ch-seco-gdp.json`): `structure == "gdp"`, `type == "real"`, CHF million; `seas_adj == "csa"` for `realtime_gdp.csv`, `"cssa"` (sport-event adjusted, the WAI target) for `realtime_gdp_cssa.csv` |
| **release date** | the date SECO's GDP page, <https://www.seco.admin.ch/de/bruttoinlandprodukt>, prints next to the release's files ("2026-2 BIP, Verwendungsseite, Sportevent-bereinigt", 3 September 2026) |
| fallback, values | KOF's public time-series database, `ch.seco.gdp.real.gdp.sa` / `.ssa`, if the feed fails |
| fallback, date | the feed's `updated_utc`, if the page cannot be read |

**Why the page's date.** The database dates its vintages by SECO's
publication, and its September releases fall at the start of the month
(05.09.2022, 04.09.2023, 03.09.2024). The page gives 3 September 2026 for
the 2026q2 release. The feed's `updated_utc` for the same release is
2026-08-28, which looks like the time the file was updated, not the release.
For real-time vintages the later, published date is the safe choice.

**Checks, 2026-10-26:** the feed's values equal the release's workbooks on
the page (`qna_e_csa.xlsx`, `qna_e_cssa.xlsx`, sheet `real_q`, column
`B1GQ`) and KOF's copy, both to 1e-14. Against the database's 2026-06-01
vintage they have the same scale (level ratio 0.99994), and quarterly growth
differs by at most 0.3 percentage points, an ordinary revision.

First run (2026-10-26): 106 vintages, 2000q2 to 2026q3. The last was
appended from the feed (released 2026-09-03, GDP to 2026q2: +1.53% q/q). Read
with `get_real_time_gdp_vintages()`, the 105 database vintages are identical
to the files in mfbdfm's `inst/extdata`; only the line endings differ.
