# Swiss Rhine ports cargo

Monthly tonnage handled at the Swiss Rhine ports, by transport category and
commodity group. Not used by the dashboard (`index.html` reads only
`wai_data.csv`); kept here as a candidate high-frequency indicator.

- **Source:** Statistisches Amt des Kantons Basel-Stadt, web table t11.4.02
  "Umschlag nach Warengattung",
  <https://statistik.bs.ch/files/webtabellen/t11-4-02.xlsx>. Data collected
  by Schweizerische Rheinhäfen (full census).
- **Coverage:** 2001-01 onwards, monthly; updated monthly by the publisher.

## Files

| file | |
| --- | --- |
| `acquire_rhine_cargo.R` | downloads the workbook and writes the CSV (needs R and `readxl`) |
| `rhine_cargo.csv` | output: `date, year, month, direction, classification, nst_code, commodity, tonnes` |

Refresh from the repository root:

```
Rscript rhine_cargo/acquire_rhine_cargo.R
```

## Reading the CSV

- `direction == "gesamtumschlag"` with an empty `commodity` is the headline
  monthly series; `zufuhr` / `abfuhr` with an empty `commodity` are the two
  transport categories; the remaining rows break each down by commodity.
- **Classification break in 2024.** From 2024 the groups are NST-2007 (with
  `nst_code`), before that the unnumbered NSTR groups. 2024 and 2025 are
  published in both schemes, so those months appear twice, distinguished by
  `classification`. The two schemes are not mapped onto each other because
  their group boundaries differ.
- A month the publisher has not yet reported is absent, not zero.

Moved from mfbdfm (#142, PR #143), where it was first built.
