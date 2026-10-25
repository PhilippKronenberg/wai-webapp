# German truck-toll mileage index (Lkw-Maut-Fahrleistungsindex)

Daily mileage index of large trucks on German motorways (Destatis, BALM,
Deutsche Bundesbank), 2021 = 100. Not used by the dashboard. This is the WAI
input `Lkw-Maut-Fahrleistungsindex_DE` in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

| file | |
| --- | --- |
| `Destatis_Truck_toll_mileage.csv` | the WAI input: calendar and seasonally adjusted index (KSB), centred 7-day average; layout of `wai_ind`'s file of the same name (`;<name>`, `DD.MM.YYYY;value`) |
| `destatis_maut_daily.csv` | the whole table: `date, unadjusted, ksb, ksb_ma7` |

- **Source:** Destatis,
  <https://www.destatis.de/DE/Themen/Branchen-Unternehmen/Industrie-Verarbeitendes-Gewerbe/Tabellen/Lkw-Maut-Fahrleistungsindex-Daten.html>.
  The link `…/Tabellen/Lkw-Maut-Fahrleistungsindex-Daten.xlsx` forwards to
  this page. The page links the workbook
  `statistischer-bericht-lkw-maut-fahrleistungsindex-5421901.xlsx`, whose
  version (`v=30`) changes with each update, so the script reads the link
  from the page every time. Table `42191-b01`.
- **Coverage:** daily from 2008-01-01, updated weekly on Thursdays. The
  7-day average ends three days before the index.
- **Terms:** Data licence Germany – attribution – version 2.0 (Destatis).

```
Rscript destatis_maut/acquire_destatis_maut.R
```

## Which series the WAI used

The old file is Destatis' own **"gleitender 7-Tage-Durchschnitt KSB"**, the
centred 7-day average of the calendar and seasonally adjusted index. Compared
on 6642 days with the 2026-10-22 release:

| | |
| --- | --- |
| 2008–2020 | identical to one decimal on every day |
| 2021–2026 | median difference 0.2 index points, 95% within 1.2; no bias (yearly mean differences −0.005 to +0.019) |
| correlation of 7-day changes, 2021–2026 | 0.92 |

The differences since 2021 are revisions: the Bundesbank re-estimates the
experimental daily seasonal adjustment with every weekly release, which
moves the most recent years. KSB itself (correlation 0.95) and a trailing
7-day mean (0.99) match far worse, so the published centred average is the
right column.
