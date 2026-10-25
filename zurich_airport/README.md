# Zurich Airport monthly arrivals and departures

Monthly totals of arrivals (Anflüge) and departures (Abflüge) at Zurich
Airport, read from Flughafen Zürich's monthly noise bulletins. Not used by the
dashboard. These are the source of the WAI inputs `zrh_airport_arrivals` and
`zrh_airport_departure` in [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).
Not to be confused with `zurich_air/`, which holds air-quality data.

- **Source:** Flughafen Zürich AG, *Lärmbulletin* (monthly PDF), listed under
  "Lärmbulletin Monat und Jahr" on
  <https://www.flughafen-zuerich.ch/de/unternehmen/verantwortung/laerm-und-schallschutz/laermmonitoring>.
  The movements table "Flugbewegungen auf Ab- und Anflugrouten" sits on the
  bulletin's first content page.
- **Coverage:** monthly from 2020-01; bulletins from 2021-01 (each carries
  about 13 months). On 2026-10-25: 69 bulletins, to **2026-09**.

## Files

| file | |
| --- | --- |
| `acquire_zurich_airport.R` | scans the page, downloads new bulletins, parses them, writes the CSV (needs R and `pdftools`) |
| `zrh_flights_monthly.csv` | monthly totals from the movements table (columns below) |
| `zrh_flights_daily.csv` | **the WAI inputs**: daily `departures` and `arrivals`, the sums over the runway tables, plus one column per runway and the `bulletin` |
| `pdf/` | cache of downloaded bulletins (gitignored) |

## The daily series (`zrh_flights_daily.csv`)

Each bulletin has one page per runway with a daily table for its month:
departures on runways 10, 16, 28, 32 and 34 (Bisenstarts, Süd-, West- and
Nordabflüge), and arrivals on 14, 16, 28 and 34 (Nord-, Ost- and
Südanflüge). The last value of each day's row is that runway's daily total.
Summed over the runways, they give the day's total departures and arrivals.
The pages are found by their titles, since the table of contents counts pages
differently from the PDF. Days are written `01.09` from 2026 and `1.09.25`
before; both are read.

These are **IFR** flights: VFR flights have no runway tables. Every month is
checked against the movements table's monthly IFR total (Total minus VFR), and
a deviation above 1% stops the run. First run (2026-10-25): 2,099 days,
2021-01-01 to 2026-09-30. 66 of 69 months equal the monthly IFR totals
exactly, the other 3 (2021-12, 2024-11, 2026-09) within 0.26%.

Against `wai_ind`'s daily file (`Flughafen_ZH_daily_anfluege_abfluege.csv`),
2021–2025: identical on **99.6%** of the 1,833 days. The 8 other days are
errors in that file, with implausibly low values such as 22 departures where
the bulletin shows 112. The dataset build (`dataset/`) uses this daily series
from 2021 and `wai_ind`'s file for 2019–2020, which the bulletins do not
cover.

```
Rscript zurich_airport/acquire_zurich_airport.R
```

Each run re-reads the page, so a new bulletin is picked up automatically, and
it only downloads bulletins not yet in `pdf/`.

## Columns

| column | |
| --- | --- |
| `date` | first day of the month |
| `arrivals`, `departures`, `total` | "Total Anflüge", "Total Abflüge" and their sum, **including VFR** |
| `arrivals_vfr`, `departures_vfr` | VFR flights (Sichtflüge) |
| `arrivals_ifr`, `departures_ifr` | totals minus VFR, i.e. IFR flights |
| `bulletin` | the bulletin the month was taken from (the newest that reports it) |
| `n_bulletins`, `revised` | how many bulletins reported the month, and whether they disagreed |

**Which to use for the WAI:** the `*_ifr` columns. `wai_ind`'s existing daily
series (`daily_anfluege_abfluege.csv`, extracted from the daily pages of the
same bulletins), summed to months, equals `arrivals_ifr` / `departures_ifr`
**exactly in 65 / 64 of 72 months** (2020–2025). The rest are within 1%
(at most 43 flights), and the correlation is 1.00000. The totals including VFR
run 150–400 flights a month higher.

## How the series is built, and its safeguards

- **Links are read off the page, never constructed.** The file names are
  irregular: `laermbulletin`, `lrmbulletin`, `24011laermbulletinjanuar`,
  `2307_…_korr`. The bulletin month is the leading YYMM.
- **Newest bulletin wins.** Months overlap across bulletins, and a newer one
  can correct an older value. Two months were revised up to 2026-09.
- **Every bulletin is verified against itself.** Arrivals + departures must
  equal the side table's "Gesamt" for each month of the bulletin's year (117
  bulletin-months checked). A mismatch stops the run.
- **Layout variants handled:** the table on page 3 or 4; thousands separators
  `’` or `,`; month labels `Mär`/`Mrz`, `Jun`/`Juni`, `Jul`/`Juli`; and the
  2021 bulletins' extra departure-route column.
- **Unreadable bulletins are skipped, never guessed.** Two (2405, 2503) have a
  scrambled PDF text layer; their months are covered by neighbouring
  bulletins. The run **stops** instead if any month would be left uncovered,
  or if the **newest** bulletin cannot be read, so the latest month is never
  dropped silently.

The bulletins' daily pages (per route) would also allow a daily series, which
is what the WAI uses after weekly aggregation. That is a possible follow-up.
