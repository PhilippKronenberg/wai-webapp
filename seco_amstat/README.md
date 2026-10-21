# SECO labour-market statistics (AMSTAT)

Swiss registered unemployment, job seekers, notified vacancies, benefit
exhaustions and settled short-time work, monthly since 2004. Adopted in #36 as
candidate inputs. Not used by the dashboard (`index.html` reads only
`wai_data.csv`); an adopted series is wired into the index in
[`mfbdfm`](https://github.com/PhilippKronenberg/mfbdfm)'s data prep, not here.

- **Source:** SECO, *Die Lage auf dem Arbeitsmarkt*, the monthly report on
  <https://www.arbeit.swiss/de/informationszentrum/arbeitsmarktstatistik-schweiz>.
  Full census (*Vollerhebung*) of all RAV person dossiers, not a sample.
- **Cadence:** monthly, published in the first days of the following month
  (2026: 05.10., 04.09., 05.08., 03.07.).
- **Terms:** the arbeit.swiss
  [legal notice](https://www.arbeit.swiss/de/rechtliche-hinweise) transfers no
  rights in the content and asks for prior written consent for reproduction of
  any element. **This repository's `LICENSE-DATA` (CC BY 4.0) does not extend to
  this folder** — `LICENSE-DATA` names it as out of scope. Attribute to
  Staatssekretariat für Wirtschaft (SECO), Arbeitsmarktstatistik,
  <https://www.amstat.ch>.

## Files

| file | |
| --- | --- |
| `scrape_seco_amstat.mjs` | finds the current report, scrapes it, writes the CSV (Node, no dependencies) |
| `seco_amstat.csv` | output: `date, month, series, value, unit` |
| `source.csv` | which report the CSV came from: title, reference month, publication date, Datenstand, URL |

Refresh from the repository root:

```
node seco_amstat/scrape_seco_amstat.mjs
```

Exit 1 is a scrape that produced wrong or missing data; exit 2 is a scrape that
could not run at all. Nothing is written unless every check passes.

## Series

| `series` | from | unit | report table |
| --- | --- | --- | --- |
| `unemployed` | registered unemployed, total | persons | 16 |
| `unemployment_rate` | unemployment rate | percent | 17 |
| `jobseekers` | registered job seekers | persons | 21 |
| `jobseeker_rate` | job-seeker rate | percent | 22 |
| `benefit_exhaustions` | exhaustions of unemployment benefit | persons | 23 |
| `vacancies_notified` | notified job vacancies | positions | 25 |
| `short_time_work_units` | settled short-time work, company divisions | company divisions | 26 |
| `short_time_work_workers` | settled short-time work, workers affected | persons | 27 |

All eight are the **raw** series. The report's seasonally adjusted figures are
deliberately not taken: SECO recomputes them with X-13-ARIMA-SEATS at every new
observation, so in SECO's own words the adjusted values "can vary from one
month to the next". Seasonal adjustment belongs in `mfbdfm`, once, where it can
be done the same way every month.

**Approved / pre-notified short-time work (*Voranmeldungen*, bewilligte
Kurzarbeit) is not here, because the report does not contain it.** It appears
nowhere in the September 2026 edition under any of those names, and it is also
absent from the SNB's `amarbma` mirror. Only *settled* (abgerechnete) short-time
work is published in machine-readable or scrapable form at all. See #36.

## Reading the CSV

- **`date` is the last day of the reference month.** The stocks are counted on
  SECO's *Stichtag*, the last day of the month; the short-time-work figures are
  flows over the month that ends on it. `month` (`YYYY-MM`) is the same
  information without the implied day.
- **The short-time-work series are revised, the others effectively are not.**
  Settled short-time work is published with a three-month delay because it
  depends on employers filing claims, and keeps moving afterwards; the report
  warns that for its last three months the expected revision still exceeds 5
  per cent. `short_time_work_*` therefore ends about three months before the
  other series, and its recent values should be treated as provisional.
  `source.csv` records the `Datenstand` those tables are settled to.
- `benefit_exhaustions` is genuinely 0 or near 0 in spring 2020: exhaustions
  were suspended during the lockdown. It is not a parsing artefact — those
  months reconcile with the annual mean the report prints.
- A month the report has not reached is absent, not zero.

## Why scraping a PDF, and what is fragile about it

There is no API. `amstat.ch` is a MicroStrategy dossier with no CSV, XLSX or
SDMX endpoint, and its login returns HTTP 401 from outside; arbeit.swiss offers
these numbers as PDF only; BFS STAT-TAB does not carry SECO's registered
unemployment. The SNB data portal mirrors the series (cube `amarbma`) but lands
about three weeks after month end against SECO's own five days — and the five
days are the point. Details in #36.

Three things about the scrape are worth knowing before trusting a future run:

- **The filenames are opaque UUIDs** under
  `/api/media/fileservice/.../<uuid>.pdf` with no constructable pattern, so the
  current report has to be found by scraping the index page every month. The
  script takes the newest *Die Lage auf dem Arbeitsmarkt* link by the month in
  its title.
- **arbeit.swiss needs a desktop User-Agent.** A bare client gets a challenge
  page rather than HTML. Same finding as #32.
- **The report carries no `/ToUnicode` map.** It is produced with LaTeX and its
  text is glyph indices, not characters; they sit at a constant offset from
  ASCII. A wrong offset would produce plausible wrong digits rather than an
  error, so the script derives the offset at run time by scoring candidates
  against the report's own boilerplate, and then checks the numbers it read:
  - every full year's twelve monthly values must average to the annual mean the
    report prints beside them (22 years per series for six of the eight series;
    tables 26 and 27 print no mean column);
  - the newest `unemployed` value must equal the one in table 1 on the front
    page, which is laid out completely differently.

  Both checks fail the run rather than writing a number nobody verified.

When the layout moves, print what the scraper actually reconstructed:

```
SECO_DEBUG='Tabelle16|^Total' node seco_amstat/scrape_seco_amstat.mjs
```

One printed page is split across several content streams, and the embedded
charts are content streams too, so a row's title and its numbers are not
necessarily in the same one.
