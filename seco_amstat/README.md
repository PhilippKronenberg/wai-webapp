# SECO monthly labour-market figures

National monthly registered-unemployment statistics, scraped out of SECO's
monthly "Leporello" PDF because SECO publishes no machine-readable route to
them. Adopted in #36. Not used by the dashboard (`index.html` reads only
`wai_data.csv`); wiring a series into the WAI happens in
[`mfbdfm`](https://github.com/PhilippKronenberg/mfbdfm)'s data prep, not here.

- **Source:** Staatssekretariat für Wirtschaft (SECO), Direktion für Arbeit,
  monthly fold-out "Leporello", linked from
  <https://www.arbeit.swiss/de/informationszentrum/arbeitsmarktstatistik-schweiz>.
- **Coverage:** monthly; reference date is the **last day of the month**, so
  these are end-of-month stocks, not monthly averages. Full census
  (*Vollerhebung*) of RAV person dossiers, not a sample.
- **Release:** in the first days of the following month (~5 days).
- **Licence:** **not** CC BY 4.0 — see [Licence](#licence) below.

## Why a PDF scraper

The owner chose this route in #36 over the SNB's `amarbma` mirror of the same
SECO numbers, which is clean and machine-readable but lands ~3 weeks after
month end against SECO's ~5 days. The alternatives all failed:

- **AMSTAT** (`amstat.ch`) is a MicroStrategy dossier. There is no CSV, XLSX
  or SDMX endpoint; export happens inside the BI widget, its unauthenticated
  login returns `401 ERR003` from outside, and the dossier object ids change
  when the dossier is rebuilt.
- **BFS STAT-TAB**'s PxWeb API is clean but does not carry SECO registered
  unemployment. What BFS publishes is the ILO *Erwerbslose* series from SAKE
  — a quarterly sample survey and a different concept.
- The arbeit.swiss page itself offers **PDF only**, under opaque UUID
  filenames with no constructable pattern. Hence: scrape the page each month
  for the current links.

Of the two PDFs published each month, the **Leporello** is the one with
tables. "Die Lage auf dem Arbeitsmarkt" is a chart deck whose numbers live
inside the plots, and it is not read.

## Files

| file | |
| --- | --- |
| `scrape_seco_amstat.mjs` | scrapes the page, downloads the Leporellos, extracts the figures (Node, no dependencies) |
| `seco_amstat_monthly.csv` | `date, series, value, unit, reported_in` |
| `seco_amstat_sources.json` | one entry per Leporello: URL, SHA-256, size, parse status |

Refresh from the repository root:

```
node seco_amstat/scrape_seco_amstat.mjs
```

The PDFs themselves are **not** committed: arbeit.swiss's legal notice does
not allow redistributing them. They go to a temporary directory unless a
directory is given as the second argument, which also makes the script reuse
PDFs already there instead of downloading them again:

```
node seco_amstat/scrape_seco_amstat.mjs seco_amstat/seco_amstat_monthly.csv /tmp/leporellos
```

## Series

| `series` | unit | |
| --- | --- | --- |
| `unemployed` | persons | registered unemployed, *registrierte Arbeitslose* |
| `unemployment_rate` | percent | *Arbeitslosenquote* |
| `youth_unemployed` | persons | 15–24, *Jugendarbeitslose* |
| `youth_unemployment_rate` | percent | |
| `long_term_unemployed` | persons | *Langzeitarbeitslose* |
| `job_seekers` | persons | *Stellensuchende*, a superset of the unemployed |
| `vacancies_registered` | vacancies | *gemeldete offene Stellen* |
| `benefit_exhaustions` | persons | *Aussteuerungen* |
| `stw_establishments` | establishments | settled short-time work: firms |
| `stw_workers` | persons | settled short-time work: workers affected |
| `stw_hours_lost` | hours | settled short-time work: hours lost |
| `stw_compensation_chf` | CHF | settled short-time work: compensation paid |

## Reading the CSV

- `date` is the first day of the month the figure is **about**;
  `reported_in` is the month of the Leporello it was read from. They differ
  for the series the fold-out reports with a lag, and the pair is what makes
  a figure reproducible against a specific published document in
  `seco_amstat_sources.json`.
- **These are the raw counts.** SECO's seasonally adjusted series are
  recomputed with X-13-ARIMA-SEATS at every new observation and are therefore
  rewritten every month; seasonal adjustment belongs in `mfbdfm`, on these
  raw inputs.
- **Short-time work runs three months behind and keeps being revised.** The
  fold-out's own note says the last three months can still move by more than
  5%, because settlement depends on employers filing claims. `benefit_exhaustions`
  lags by two months.
- **Approved / pre-notified short-time work (*Voranmeldungen*) is not here.**
  The monthly PDFs report only settled short-time work (*abgerechnete
  Kurzarbeit*); #36 asked for both. It is also absent from the SNB's
  `amarbma` mirror, and no machine-readable route to it was found. It is the
  more forward-looking of the two, so if it is wanted it needs a route of its
  own.
- **The page carries only the current year's Leporellos**, so a single run
  sees at most ~12 months. History is accumulated by keeping this CSV and
  rerunning monthly: rows for months no longer on the page are preserved, and
  rows this run re-read replace their own `(date, series, reported_in)`.
  The first run, on 2026-10-22, got 2026-01 → 2026-09 (and, through the
  lagged series, back to 2025-10).
- Values are written exactly as SECO prints them, so a rate is `3.0` and not
  `3`.

## The PDF parsing, and how much to trust it

`scrape_seco_amstat.mjs` inflates the PDF content streams and reads the
text-positioning operators with Node's `zlib` — this repository has no
dependencies and CI must not be the thing that introduces one. That works
because the Leporello's text is literal strings in a standard encoding. It is
not a general PDF reader, and it will not survive SECO changing the tool that
produces the fold-out.

So every figure is checked before it is written: each against a plausible
range, `job_seekers` against `unemployed`, `youth_unemployed` against
`unemployed`, and the vacancies total against the same total at the head of
the by-canton table. A month that fails any check is **reported and left
out** rather than written, its entry in `seco_amstat_sources.json` says why,
and the script exits 1. A silent empty column is the failure mode worth
preventing here.

## Licence

**The repository's `LICENSE-DATA` (CC BY 4.0) does not cover this folder,**
and `LICENSE-DATA`'s SCOPE paragraph names it as excluded.

arbeit.swiss's legal notice
(<https://www.arbeit.swiss/de/rechtliche-hinweise>) states that downloading or
copying content transfers no rights, and that reproducing any element
requires the prior **written consent** of the rights holders. Attribute as:

> Source: Staatssekretariat für Wirtschaft (SECO) – Arbeitsmarktstatistik.

If you want these figures for anything beyond non-commercial research use,
ask SECO rather than taking them from here.
