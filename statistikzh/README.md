# WAI inputs from the Canton of Zurich's covid19monitoring (statistikZH)

Three WAI inputs that can no longer be rebuilt from a current source. Their
publishers stopped, and their final data remain in the Canton of Zurich's
[covid19monitoring](https://github.com/statistikZH/covid19monitoring)
repositories. This script downloads them and writes them in the layout of
`wai_ind`'s `data/dataset` files. Not used by the dashboard.

| file | WAI input | repository | span | why no own pipeline |
| --- | --- | --- | --- | --- |
| `ktzh_Mobility_SBBHauptbahnhof.csv` | `oev_freq_hb` (trains in/out, Zurich HB) | [`…_mobility_SBBHauptbahnhof`](https://github.com/statistikZH/covid19monitoring_mobility_SBBHauptbahnhof) (archived) | 2019-08-01 – 2021-08-25 | SBB's dataset `anzahl-zuge-pro-haltestelle` no longer exists. SBB now publishes trains per line section only per year (`zugzahlen`) and per month (`zugzahlen_pro_monat`) |
| `ktzh_intervista_median_distance.csv` | `tages_distanz_median` (median daily distance, CH) | [`…_mobility_intervista`](https://github.com/statistikZH/covid19monitoring_mobility_intervista) (archived) | 2020-01-01 – 2021-07-04 | the intervista tracking panel ended |
| `ktzh_debit_ausland_SIX.csv` | `debiteinsatz_ausland` (debit cards abroad) | [`…_economy_SIX`](https://github.com/statistikZH/covid19monitoring_economy_SIX) | 2018-01-01 – 2021-10-02 | SIX's card data stopped. Monitoring Consumption's SIX issuing data ended in 2023 and has no "abroad" breakdown |

```
Rscript statistikzh/acquire_statistikzh.R
```

The script also reports whether each repository is archived and when it was
last pushed, so a revived repository would be noticed.

**Check (2026-10-25):** all three are identical to `wai_ind`'s files in value
(SBB 728 days, intervista 551, SIX 1370). The SBB file is also byte-identical.
The two others differ only in formatting: intervista has full precision
instead of 8 decimals, and SIX has no BOM.

`bezug_bargeld` and `stat_einkauf` are not here. `bezug_bargeld` in
`wai_ind` comes from Monitoring Consumption's ATM file, which runs to
2023-01-01, longer than statistikZH's copy (2021-10-02). `stat_einkauf` comes
from Worldline (`worldline/`).
