# Zurich daily air quality

Daily air-pollutant measurements at the City of Zurich monitoring stations,
1983 to the previous day. Not used by the dashboard (`index.html` reads only
`wai_data.csv`); kept here as a candidate high-frequency indicator — traffic
and combustion emissions move with activity, and these numbers arrive the next
morning.

- **Source:** Umwelt- und Gesundheitsschutz Zürich (UGZ), *Täglich
  aktualisierte Luftqualitätsmessungen, seit 1983*,
  <https://opendata.swiss/de/dataset/taglich-aktualisierte-luftqualitatsmessungen-seit-1983>.
  Files at
  <https://data.stadt-zuerich.ch/dataset/ugz_luftschadstoffmessung_tageswerte>.
- **Coverage:** 1983-01-01 onwards, daily; the publisher updates 30 minutes
  after midnight (UTC+1), so the newest day is yesterday.
- **Licence:** opendata.swiss *terms_open* — free use including commercial,
  attribution not required. Credited here anyway: **Umwelt- und
  Gesundheitsschutz Zürich, Open Data Zürich.**

## Files

| file | |
| --- | --- |
| `acquire_zurich_air.mjs` | downloads every per-year CSV and writes the tidy CSV (Node built-ins only, no dependencies) |
| `zurich_air.csv` | output: `date, station, pollutant, statistic, value, unit, status` |

Refresh from the repository root:

```sh
node zurich_air/acquire_zurich_air.mjs
node zurich_air/acquire_zurich_air.mjs zurich_air/zurich_air.csv --cache /tmp/ugz
```

With `--cache` the downloads are kept and reused, which is how to re-parse
without fetching 40-odd files again.

**The output is 22 MB, and the script rewrites it in full.** Every refresh
therefore adds about 2 MB to the repository's history permanently (that is the
compressed blob, not the file). Worth knowing before putting it on a schedule:
refresh when the data is actually needed, not as a habit.

## Reading the CSV

- One row per **day, station, pollutant and statistic**. Sorted by those four,
  ascending. LF line endings, no quoting, no BOM, dates `YYYY-MM-DD`.
- `date` is the day the measurement interval starts, in **Central European
  winter time (UTC+1, no daylight saving)** — the publisher's reference for the
  whole dataset, summer included. The source timestamps are all `T00:00+0100`
  and the time part is dropped after being checked.
- **An absent row means no value**: either the station does not measure that
  pollutant, or that day's value did not pass quality control. The source marks
  the latter `NA` and the script drops it (8247 rows at the time of writing),
  as `rhine_cargo` drops unreported months. Nothing is ever zero-filled.
- `status` is the publisher's: `bereinigt` — validated, and `provisorisch` —
  provisional, **subject to revision**. In practice the whole current year is
  provisional and everything before it is validated, so a refresh rewrites last
  year's numbers once at the turn of the year.
- `value` is passed through as the publisher's own text, not reparsed and
  reformatted, so no float round-trip can move a digit.

## Statistics

Most rows are a daily mean. Ozone also carries two statistics that are not
means, which is why `statistic` exists as a column rather than every row being
implicitly a mean:

| `statistic` | source parameter | meaning |
| --- | --- | --- |
| `daily_mean` | `O3`, `NO2`, … | mean of the day's hourly means |
| `max_hourly_mean` | `O3_max_h1` | highest hourly mean of the day |
| `hours_above_120` | `O3_nb_h1>120` | number of hourly means above 120 µg/m³, the Swiss one-hour ozone limit |

`hours_above_120` carries the unit `1` as the publisher writes it in the CSV —
it is a count. (The metadata JSON calls the same unit `nb`; the script reports
the disagreement rather than papering over it.)

## Pollutants

| `pollutant` | | `unit` | available |
| --- | --- | --- | --- |
| `NO2` | nitrogen dioxide | µg/m³ | 1983-01-01 → |
| `NO` | nitrogen monoxide | µg/m³ | 1983-01-01 → |
| `NOx` | nitrogen oxides | ppb | 1983-01-01 → |
| `O3` | ozone | µg/m³ | 1987-01-01 → |
| `PM10` | particulate matter < 10 µm | µg/m³ | 2001-01-04 → |
| `PM2.5` | particulate matter < 2.5 µm | µg/m³ | 2017-01-01 → |
| `PN` | particle number | 1/cm³ | 2008-02-08 → |
| `CO` | carbon **monoxide** | mg/m³ | 1983-01-01 → 2024-12-31 |
| `SO2` | sulphur dioxide | µg/m³ | 1983-01-01 → 2024-12-31 |

Two things to take from that table rather than discover later:

- **`CO` is carbon monoxide, not CO₂.** No CO₂ series is published here. This
  dataset was found while searching for one (#38).
- **`CO` and `SO2` stop at the end of 2024** in the published files, and
  neither was a usable indicator by then. At Stampfenbachstrasse the SO₂ annual
  mean falls from 58.2 µg/m³ in 1983 to 0.9 in 2024 and CO from 2.7 mg/m³ to
  0.3 — abatement, not activity, and in the end barely above the detection
  floor. `NO2` over the same span goes 58.7 → 18.2 µg/m³, so it carries a
  strong downward trend too: **none of these series is usable in levels.**

Units are mixed on purpose: `NOx` is in ppb while `NO` and `NO2` are in µg/m³,
which is the publisher's choice. Do not add `NO` and `NO2` up to get `NOx`.

## Stations

| `station` | | since | character |
| --- | --- | --- | --- |
| `Zch_Stampfenbachstrasse` | Stampfenbachstrasse 144, 445 m | 1983-01-01 | central, moderate traffic; the only station with the full history |
| `Zch_Schimmelstrasse` | Schimmelstrasse 21, 413 m | 1988-01-21 | urban main road, very heavy traffic |
| `Zch_Heubeeribüel` | Heubeeriweg 30, 610 m | 1992-06-27 | schoolyard on the city edge, little traffic — the local background |
| `Zch_Rosengartenstrasse` | Rosengartenstrasse 24, 433 m | 2013-10-04 | urban main road, very heavy traffic |

A fifth station, `Zch_Rosengartenbrücke`, appears in the dataset's metadata
JSON but measures traffic counts, not air quality, and so is absent from this
CSV.

## Notes on the source

- **The resource list is incomplete; the files are not.** When this was
  written, 1997, 2002 and 2022 did not appear in the published resource list,
  which looks like three gaps in the record. All three per-year CSVs exist and
  download normally. The script therefore enumerates 1983 to the current year
  itself instead of trusting that list, and treats a missing year as a hard
  error rather than writing a quietly short CSV.
- **A year that does not exist answers HTTP 500 with an HTML error page**, not
  404. Every response is checked for the expected CSV header before it is
  parsed. Only the current year may legitimately be absent — in the first
  minutes of 1 January it has not been published yet.
- The complete dataset is also offered as one Parquet file. The per-year CSVs
  are read instead because Parquet would need a library, and this repository
  has no dependencies.

Added for wai-webapp #38.
