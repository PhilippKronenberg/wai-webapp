# Market series: SMI and VIX

Daily closes of the Swiss Market Index and the CBOE Volatility Index. Not
used by the dashboard. These are candidate sources for the WAI inputs
`SWISSMI` and `VIX` in [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

| file | committed | source |
| --- | --- | --- |
| `smi_daily.csv` | **no** | Yahoo Finance chart endpoint, symbol `^SSMI`, daily close from 1990-11-09 |
| `vix_daily.csv` | yes | CBOE, `https://cdn.cboe.com/api/global/us_indices/daily_prices/VIX_History.csv`, from 1990-01-02; FRED `VIXCLS` as fallback |

```
Rscript markets/acquire_markets.R
```

`smi_daily.csv` is gitignored. SIX licenses the use of its index data, and
Yahoo's terms do not allow redistribution. Run the script locally to get it.

## SMI against the Datastream series used so far

`SWISSMI` came from Datastream ("SWISS MARKET (SMI) - PRICE INDEX"), which is
no longer accessible. On the 8873 common days, 1990-11-09 to 2026-03-12:

- **95.4% of days are identical** (median relative difference 3e-8);
- daily log changes correlate 0.99958;
- 6 days differ by more than 0.5%, all single days between 1992 and 2010;
- Datastream also has 347 holiday rows carrying the previous close, which
  Yahoo leaves out.

`FINANSW` and `INDUSSW` are Datastream-constructed sector indices. They have
no free source and are discontinued.

## VIX: the WAI's "VIX" is the VSMI

`data_meta.csv` lists `VIX` as the CBOE Volatility Index, but `wai_ind`'s
`data/VIX/VIX.csv` (`Date;ISIN;Indexvalue`, 1999-01-04 to 2026-04-08) has ISIN
**CH0019900841**. SIX's reference service gives that as **VSMI** (symbol
`V3X`), the SMI volatility index computed from Eurex SMI options. Against the
CBOE VIX on 6743 common days, levels correlate 0.89 and daily changes only
0.40.

- **CBOE VIX** (here): free, complete, current. Using it changes the input
  from Swiss to US implied volatility.
- **VSMI:** SIX's `fqs/charts.json` endpoint gives the latest close only
  (`where=ValorId=CH0019900841CHF9`). History requires a SIX licence. A
  pipeline could append one close per day to the existing history, but it
  cannot fill the gap since 2026-04-08.

Which one the WAI should use is a modelling decision (#50).

## FRED

FRED's `VIXCLS` is the same CBOE close. From the machine this was built on,
`fred.stlouisfed.org` reset every connection (2026-10-25), so CBOE is the
primary source and FRED only the fallback.
