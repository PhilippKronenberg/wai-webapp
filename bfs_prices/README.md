# Swiss consumer prices, core inflation and producer prices (BFS)

The three WAI price inputs, monthly from the Federal Statistical Office (BFS),
in the layout of the Datastream export they replace. Not used by the
dashboard. These are inputs to
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

| column in `bfs_prices.csv` | WAI input | BFS source (asset) | coverage (2026-10-25) |
| --- | --- | --- | --- |
| `SW CPI NADJ` | `SWCONPRCE` | LIK, Totalindex auf allen Basen seit Einführung (`su-d-05.02.10`) | 1921-01 – 2026-09 |
| `SW PPI (2025M12=100) NADJ` | `SWPROPRCE` | Produzentenpreisindex (PPI), Total (`su-q-05.04.03.01-ppi-ipp`) | 1963-01 – 2026-09 |
| `SW CORE INFLATION 1 NADJ` | `SWCPCOREF` | LIK (Dez 2025=100), Detailresultate, Warenkorbstruktur 2025, inkl. Sondergliederungen (`su-d-05.02.66`, LIK25B25) | 2000-05 – 2026-09 |

All three are on base **December 2025 = 100**.

## Files

| file | |
| --- | --- |
| `acquire_bfs_prices.R` | downloads the three files, builds the series, writes the CSV (needs R and `readxl`) |
| `bfs_prices.csv` | output in the layout of `wai_ind`'s `data/DATASTREAM/datastream_econ.csv`: `;`-separated, first column `Name` with dates `DD.MM.YYYY` on the 15th, one column per series, empty for missing |

```
Rscript bfs_prices/acquire_bfs_prices.R
```

Download route: `https://www.bfs.admin.ch/bfsstatic/dam/assets/orderNr:<asset>/master`
always serves the newest release. The `bfs.admin.ch/asset/de/...` pages answer
scripts with HTML.

## Not seasonally adjusted, deliberately

BFS publishes all three unadjusted. Datastream's CPI and PPI were seasonally
adjusted (`SADJ`). By the owner's decision (2026-10-25) this pipeline stays a
pure download (`NADJ`), and seasonal adjustment belongs in mfbdfm's data prep
(X-13), as it always did for core inflation.

## How each series is built

- **CPI:** the long-series file holds the total CPI on every original base
  (June 1914 = 100 … December 2025 = 100). The newest base is used wherever it
  exists, and each older base is rescaled at the month the newer one starts,
  extending the series back to 1921.
- **PPI:** BFS back-computes every base to 1963, so the newest base column is
  used directly. It is found by its `<YYYY>` marker, so a future rebase is
  picked up.
- **Core inflation 1:** the CPI excluding fresh and seasonal products and
  energy and fuels, i.e. BFS's special aggregate "Kerninflation 1"
  (`1170_103`). Every run **rebuilds it from the subgroups** for the months of
  the current weight year, as
  `(100·R_total − w_fresh·R_fresh − w_energy·R_energy) / (100 − w_fresh − w_energy)`
  with `R` relative to the previous December, and stops if that misses BFS's
  aggregate by more than 0.001. It reproduces the aggregate to 0.00014,
  which is the published rounding (2025 and 2026 checked).

### Why core inflation comes from the 2025-basket file

The 2020-basket detail file (`su-d-05.02.67`) ends in December 2025. The 2025
basket **redefined** "fresh and seasonal products" (weight 4.8% in 2025, 10.7%
in 2026), and the 2025-basket file back-casts the new definition to 2000. The
Datastream series the WAI used is that back-cast. Measured against it:

| core inflation 1, 2000-05 – 2026-02 | level drift | y/y cor | m/m cor |
| --- | --- | --- | --- |
| 2025-basket file (used) | 6.4e-5 | 0.99998 | 0.999 |
| 2020-basket file, chained into 2025 at Dec 2025 | 8.5e-3 | 0.942 | 0.41 |

When BFS introduces the next basket, `core_order_nr` in the script must move
to its detail file.

## Checked against the series they replace (2026-10-25)

Against Datastream (`datastream_econ.csv`), 2000 onwards:

| | vs | y/y cor | mean abs. y/y diff | m/m cor |
| --- | --- | --- | --- | --- |
| CPI | `SW CPI SADJ` | 0.99926 | 0.031 pp | 0.73 (seasonal pattern) |
| PPI | `SW PPI (2025M12=100) SADJ` | 0.99964 | 0.039 pp | 0.91 (seasonal pattern) |
| core inflation 1 | `SW CORE INFLATION 1 NADJ` | 0.99998 | 0.003 pp | 0.999 |

These series are also more current than the Datastream export: to 2026-09,
against 2026-01/02.

The I14Y dataset `36506626` (wages and consumer prices) is annual and was not
used.
