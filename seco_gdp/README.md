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
(to 2026q1), while the 2026-09-03 release with 2026q2 was out. KOF's
time-series database carries SECO's releases openly (public access, no
key): `ch.seco.gdp.real.gdp.sa` (for `realtime_gdp.csv`) and
`ch.seco.gdp.real.gdp.ssa` (for `realtime_gdp_cssa.csv`, the WAI target).
If KOF's release is newer than the database's last one, the script appends
it as the next vintage, labelled by the quarter of its release date as the
database labels them. If KOF cannot be reached, the database alone is used.
Once SECO adds the release, the step does nothing.

On the 185 quarters both cover, KOF's values and the database's 2026-06-01
vintage have the same scale (level ratio 0.99994). Quarterly growth differs
by at most 0.3 percentage points, an ordinary revision between two releases.

First run (2026-10-25): 106 vintages, 2000q2 to 2026q3. The last one was
appended from KOF (released 2026-09-03, GDP to 2026q2: +1.53% q/q). Read
with `get_real_time_gdp_vintages()`, the 105 database vintages are identical
to the files in mfbdfm's `inst/extdata`; only the line endings differ.
