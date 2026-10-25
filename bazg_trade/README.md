# Swiss foreign trade in goods, seasonally adjusted (BAZG)

Monthly exports and imports of goods by CPA commodity group, including
BAZG's business-cycle total, as nominal and real values and chain indices,
each raw, working-day adjusted, seasonally adjusted and trend. Not used by the
dashboard. It is a candidate open source for the WAI's two trade inputs (see
below) in [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

- **Source:** Federal Office for Customs and Border Security (BAZG), foreign
  trade statistics, dataset
  [`BAZG_SA_CPA`](https://www.i14y.admin.ch/de/catalog/datasets/BAZG_SA_CPA/description)
  on I14Y: "Waren: Aussenhandel – Saisonbereinigte Daten nach CPA". Files at
  `https://ocean.bazg.admin.ch/open-data-reports/SA_CPA_{EXP,IMP}_en_v1/…csv`.
- **Coverage:** monthly from 2012-01, updated monthly. The 2026-10-13
  release runs to 2026-09, and its last 9 months are provisional.
- **Terms:** free to use with the source credited; commercial use needs the
  data owner's permission (BAZG terms as listed on opendata.swiss).

## Files

| file | |
| --- | --- |
| `acquire_bazg_trade.R` | downloads both directions and writes the CSV (base R only) |
| `bazg_trade_sa.csv` | output, one row per month × direction × CPA group: `date, direction, cpa, cpa_txt`, then the 12 value columns, `status` (`def`/`prov`), `updated` (BAZG release date) |
| `bazg_trade_wai.csv` | **the WAI's trade inputs**: total exports and imports from 1995, `date, direction`, then nominal raw, working-day adjusted, **seasonally adjusted** and trend (CHF), `status`, `updated` |

Refresh from anywhere; the output path follows the script's location:

```
Rscript bazg_trade/acquire_bazg_trade.R
```

## Reading the CSV

- `cpa == 0` is the **business-cycle total** ("konjunkturelles Total",
  Total 1). The other 61 codes are CPA commodity groups.
- `seasonalAdjusted_Real_Value` is the seasonally adjusted real value in CHF;
  `*_Chain_Index` the corresponding chain index.
- BAZG's source files also hold quarterly aggregates (period codes 24–27).
  They are dropped here, being sums of the months.
- Commas inside commodity names are written as " - ", so the file splits
  cleanly.

## The WAI's trade inputs: `bazg_trade_wai.csv`

The WAI used `ch.ozd.e.wa.index.re.d11` / `ch.ozd.i.wa.index.re.d11`: the
former OZD's real, seasonally adjusted export and import indices
(1997 = 100), read from KOF's database. They are not openly available, and
2026-10 they were not readable with the project's KOF account either. They
are replaced by the **seasonally adjusted nominal total** of exports and
imports (`seasonalAdjusted_Nominal_Value`), from 1995.

**Source:** [`BAZG_SA_LAND`](https://www.i14y.admin.ch/de/catalog/datasets/BAZG_SA_LAND/description),
seasonally adjusted data by country,
`https://ocean.bazg.admin.ch/open-data-reports/SA_COUNTRY_{EXP,IMP}_en_v1/…csv`.
Like every adjusted BAZG dataset it covers the business-cycle total (Total 1:
without gold bars, other precious metals, gems, art and antiques). The file
holds 49 large countries plus regional aggregates, not every country. The
total is the **sum of the six continents** (Europe, Africa, Asia, North
America, Central and South America, Oceania), which partition it. Middle
East (part of Asia), EU and Eurozone (part of Europe) are left out. Every run
checks that the unadjusted continents add up to the CPA file's total: exact
to rounding, except six import months in 2013–14 (up to 0.4%) whose later
corrections reached only one of the two files. BAZG adjusts each continent
separately, so the adjusted sum differs from the CPA file's adjusted total by
a few percent at most.

**Why this series (2026-10-25):** quarterly growth, 2012q2–2025q3, without
the COVID quarters 2020–21 (46 quarters), correlated with quarterly GDP
growth (SECO, latest vintage) and with the published WAI:

| | exports: GDP | exports: WAI | imports: GDP | imports: WAI |
| --- | --- | --- | --- | --- |
| old series (`ch.ozd.*`) | 0.24 | 0.39 | 0.43 | 0.35 |
| **nominal, seasonally adjusted (this file)** | **0.52** | **0.60** | **0.52** | **0.48** |
| nominal deflated by BFS export / import prices | 0.44 | 0.57 | 0.35 | 0.36 |
| BAZG real, seasonally adjusted (`bazg_trade_sa.csv`) | 0.19 | 0.26 | 0.31 | 0.24 |

Including 2020–21 all candidates are alike (0.56–0.78), since the collapse
of 2020 dominates. With 46 quarters, each correlation is uncertain by about
±0.12.

Against the old series itself, the nominal total matches month-to-month
growth best too: 0.85 for exports and 0.86 for imports, against 0.57 and
0.78 for BAZG's real series. Its level does not: nominal exports rose 44%
from 2012 to 2025, the old real index 3%. BAZG's real series and deflation
with BFS prices do not reproduce the old level either. BFS export prices for
manufactured goods fell 9% in CHF, while the old series implies a price rise
of about 40%, so its deflation cannot be rebuilt from open data.
