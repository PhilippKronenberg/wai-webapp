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

First run (2026-10-25): 105 vintages, 2000q2 to 2026q2 (latest released
2026-06-01). Read with `get_real_time_gdp_vintages()`, they are identical to
the files in mfbdfm's `inst/extdata`; only the line endings differ.
