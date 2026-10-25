# VSMI volatility index (the WAI input `VIX`)

The WAI input called `VIX` is SIX's **VSMI** (ISIN CH0019900841, symbol
V3X), the 30-day implied volatility of the SMI from Eurex SMI options, not
the CBOE VIX. CBOE's VIX is in [`markets/`](../markets/). Not used by the
dashboard.

- **History:** `wai_ind`'s `data/VIX/VIX.csv` (`Date;ISIN;Indexvalue`,
  1999-01-04 to 2026-04-08) is the fixed base. It is read from `../wai_ind/`
  (read-only) or a path given as argument.
- **New days:** SIX, the request behind the chart on the
  [VSMI page](https://www.six-group.com/en/market-data/indices/global/strategy/vsmi-volatility.html):
  `https://www.six-group.com/fqs/charts.json?…&where=ValorId=CH0019900841CHF9&netting=1440&fromdate=…&todate=…`.
  It returns the daily closes since 1999. The date keys must be lowercase;
  with `fromDate` the endpoint silently returns only the last day.
- **Terms:** "(c) SIX Group Ltd. All rights reserved." `VIX.csv` is
  **gitignored**; run the script locally to get it.

```
Rscript vsmi/acquire_vsmi.R [<history csv>]
```

Output `VIX.csv`: history plus appended days, same layout and file name as
`wai_ind`'s.

## First run (2026-10-25): no gaps

SIX's history covers the whole span, so the appended days join the history
without a hole: 139 days, 2026-04-09 to 2026-10-23.

Against the history on its 6871 common days, SIX's closes are equal (median
difference 0). Small differences on 22% of days are rounding: the chart has
three decimals in the early years, the history four. 19 days differ by more
than 0.1%, nearly all holidays such as 3 October, when trading is thin.
The history also has 21 rows on Swiss holidays (2 January, Ascension, Whit
Monday, 1 August) that the chart does not.
