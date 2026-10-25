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

## Not a drop-in replacement for the WAI's trade inputs

The WAI uses `ch.ozd.e.wa.index.re.d11` / `ch.ozd.i.wa.index.re.d11` (real,
seasonally adjusted export/import indices, 1997 = 100, today from KOF's
database). Compared on 2012-01 to 2025-11 (167 months) with
`seasonalAdjusted_Real_Value` of the total:

| | level correlation | m/m log-growth correlation | growth volatility, BAZG / WAI |
| --- | --- | --- | --- |
| imports | 0.89 | 0.78 | 1.18 |
| exports | 0.38 | 0.57 | 1.87 |

Imports are close. Exports are not the same series: a different total
definition or adjustment, with exports dominated by volatile pharma. The BAZG
history also starts in 2012, not 1997. Switching the WAI to this source is
therefore a modelling decision (#50), not a re-sourcing. The chain index
columns match even less well, so `Real_Value` is the candidate if it is done.
