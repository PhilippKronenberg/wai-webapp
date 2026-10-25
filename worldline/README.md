# Worldline card payments (Monitoring Consumption Switzerland)

Daily card-payment series built from Worldline's acquiring data. Not used by
the dashboard. These are inputs to
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm) via `wai_ind`.

| file | WAI input | rule |
| --- | --- | --- |
| `ktzh_non_online_retail.csv` | `stat_einkauf` | `Channel == POS`, summed over every payment method and cardholder origin |
| `ktzh_credit_card_transactions_swiss.csv` | none yet (candidate for `anz_kktrans_ch`, see below) | `Payment method == Credit`, `Channel` E-comm + POS, summed over cardholder origins |
| `worldline_daily.csv` | none | the full table of the original builder: credit, POS, and domestic/foreign × credit/debit |

The rules are those of `create_swiss_consumption_time_series.js` in `wai_ind`
(`data/Swiss Consumption Monitoring/`), which built the files used so far. The
two `ktzh_*` files keep that layout (`Date;<name>`, `DD.MM.YYYY`), so they
replace `wai_ind`'s `data/dataset/` files of the same name directly.

- **Source:** Monitoring Consumption Switzerland (University of St. Gallen,
  UNIL–E4S, Novalytica; data from Worldline), <https://monitoringconsumption.com>.
  Public Switch Drive share
  <https://drive.switch.ch/index.php/s/yLISs3KVE7ASE68>, folder
  `2_ACQUIRING DATA`, file `ACQ_Transaction_Type.csv`. The script reads it over
  the share's WebDAV endpoint, with no login.
- **Coverage:** daily from 2019-01-01, updated weekly (the 2026-10-19 update
  runs to 2026-10-18).
- **Units:** `Scaled Value` is turnover divided by the average daily turnover
  (all payment means) of January 2020. It is an index, not CHF, whatever the
  inherited column name says.
- **Terms:** the share and its README state no licence. Credit Monitoring
  Consumption Switzerland and Worldline when using the series. The raw file
  (`raw/`) is not committed.

```
Rscript worldline/acquire_worldline.R [<dir with the old ktzh_*.csv files>]
```

With a directory, the new series are compared with the old files on their
overlap. A median difference above 1% stops the run.

## Checks (a failed check stops the run)

1. The expected columns and dimensions are present, and there are no total
   rows that a sum would count twice. The file has none: Debit's channel
   `All` on 75 early days and Mobile's `all/all` fall outside both filters.
2. The newest date is at most 21 days old.
3. The comparison with old files, if given.

## First run (2026-10-25), against `wai_ind`'s files to 2026-02-08

| | days compared | identical | weekly growth correlation |
| --- | --- | --- | --- |
| non-online retail | 2596 | 2019–2023 all; 82% overall | 0.99993 |
| credit cards | 2596 | 2019–2023 all; 83% overall | 0.99959 |

Since 2024 the source revises past days slightly (median relative change
around 1e-4).

**The newest days of each release are incomplete.** The old file's last day,
2026-02-08, is now 25% (retail) and 37% (credit) higher. The days before it
are 1–3% higher. Expect the last few days of every update to be revised up.

## `anz_kktrans_ch` is a different series

`anz_kktrans_ch` (Swiss Payment Association, weekly number of credit-card
transactions, thousands) covers only 2020 in `wai_ind`. The Worldline credit
series here is daily and current, and measures turnover, not counts. Whether
it should replace `anz_kktrans_ch` is a modelling decision.
`ACQ_Transaction_Type.csv` also has `Scaled Number of Transactions` if counts
are wanted.
