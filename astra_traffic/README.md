# ASTRA motorway traffic (traffic_PW, traffic_LW)

Daily vehicles (both directions) summed over three Swiss transit counting
stations: Chiasso/Mendrisio, Simplon and Gotthard. Not used by the dashboard.
These are the WAI inputs `traffic_PW` (`PW+.Busse/Car`, < 3.5 t) and
`traffic_LW` (`LW`, > 3.5 t) in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm). `Gesamtergebnis` is all
vehicles.

- **Source:** Federal Roads Office (ASTRA),
  <https://www.astra.admin.ch/de/woechentliche-verkehrsentwicklung>: the
  weekly workbook "Wöchentliche Verkehrsentwicklung – Stand DD.MM.YYYY.xlsx"
  (one sheet per counting station, daily data since 2024-01-01). The file
  name carries the date, so the script reads the page and takes the link
  with the latest "Stand" date.
- **History:** `wai_ind`'s aggregate, `data/dataset/ASTRA_traffic_extended.csv`
  (2006-01-01 to 2026-02-08), is the fixed history. It is read from
  `../wai_ind/` (read-only) or from a path given as argument. Only days after
  its end are appended.

```
Rscript astra_traffic/acquire_astra_traffic.R [<history csv>]
```

| file | committed | |
| --- | --- | --- |
| `astra_traffic.csv` | yes | history plus appended days: date, `PW+.Busse/Car`, `LW`, `Gesamtergebnis`, `filled` |
| `raw/` | no | the downloaded workbook |

## How the aggregate is built

As in `wai_ind`'s `data/ASTRA/traffic/` scripts. The current stations
`MENDRISIO S (AS)`, `SIMPLON, JOSEFGALERIE S` and `GOTTHARDTUNNEL` are read
from their sheets (name in C4, daily rows from row 123), multiplied by
`wai_ind`'s stitch factors (`traffic_extended_stitch_log.csv`), and summed.
Each factor as logged is already cumulative: it was estimated against the
already stitched predecessor, so Mendrisio's is not multiplied again by
Chiasso-Brogeda's.

`wai_ind` filled missing station days with a state-space model (KFAS). Here
a missing station day is filled from the other two stations: their sum that
day times the station's median ratio to them over the previous 28 complete
days. Such days are flagged in `filled`.

## Checks (a failed check stops the run)

1. The page links a "Stand" workbook, and each of the three stations is on
   exactly one sheet.
2. On the overlap with the history from 2024-04 on (before that, the history
   uses Chiasso-Brogeda), the rebuilt aggregate must equal the history.

## First run (2026-10-25)

Workbook "Stand 18.10.2026". On 679 days, 2024-04-01 to 2026-02-08, the
rebuilt aggregate equals the history (median relative difference 1e-15 in
all three series), so the method is the original one. 252 days appended,
2026-02-09 to 2026-10-18, none needing a fill.

The station data in this workbook equal those of the 2026-02-08 workbook
`wai_ind` used: Simplon and Gotthard on every day, Mendrisio on 98% of days,
the rest corrected by 1–3 vehicles.
