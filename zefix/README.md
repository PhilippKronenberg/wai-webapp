# Zefix daily register entries

Bankruptcy openings and new company registrations from the federal commercial
register, daily, **for Switzerland as a whole as well as the canton of Zurich**,
broken down by NOGA section. Not used by the dashboard (`index.html` reads only
`wai_data.csv`); kept here, next to `rhine_cargo`, `zurich_air` and
`bfe_energy`, as a candidate high-frequency indicator — these are national
business dynamics at daily resolution, refreshed weekly, which almost nothing
else in the opendata.swiss catalogue offers (#32, A6).

- **Source:** Statistisches Amt des Kantons Zürich (Amt für Statistik und
  Daten), *Tagesregistereinträge zum Kanton Zürich und der Schweiz aus dem
  zentralen Firmenindex Zefix des EHRA*,
  <https://opendata.swiss/de/dataset/tagesregistereintrage-zum-kanton-zurich-und-der-schweiz-aus-dem-zentralen-firmenindex-zefix-des1>.
  Underlying register: Zefix, Eidgenössisches Amt für das Handelsregister
  (EHRA). The branch classification comes from the Betriebs- und
  Unternehmensregister (BUR).
- **Coverage:** 2017-01-01 → 2026-10-09 as fetched on 2026-10-15, daily dates,
  **refreshed weekly** by the publisher. Lag then: 6 days.
- **Licence:** opendata.swiss `terms_by` — "Open use. Must provide the source."
  Credited as required: **Statistisches Amt des Kantons Zürich**.
  `LICENSE-DATA` (CC BY 4.0) covers `wai_data.csv` and `wai_meta.json` only and
  does not extend to this folder, so nothing here is relicensed by being
  committed.

## Files

| file | |
| --- | --- |
| `acquire_zefix.mjs` | downloads both series and writes the CSVs (Node built-ins only, no dependencies) |
| `zefix_bankruptcies_daily.csv` | `date, location, noga_section, value` — Konkurseröffnungen |
| `zefix_new_registrations_daily.csv` | `date, location, noga_section, value` — Neugründungen |
| `zefix_noga_sections.csv` | `noga_section, section_de, sector_code, sector_de` — the labels, once each |

Refresh from the repository root:

```sh
node zefix/acquire_zefix.mjs
node zefix/acquire_zefix.mjs --series bankruptcies
node zefix/acquire_zefix.mjs --cache /tmp/zefix
```

Each series file is about 2.4 MB, 135,622 rows.

**The labels are normalised out of the data files.** At source each row repeats
a branch label up to 90 characters long, which costs about 7 MB per file and
says nothing a code does not: `br_abschnitt_code` determines the label, the
sector code and the sector label one-to-one. They live in
`zefix_noga_sections.csv` instead, and the script re-checks that the mapping is
still one-to-one on every run. Joining the lookup back on reproduces the
publisher's own rows exactly — that was verified row by row, not assumed.

## Reading the CSVs

- One row per **day, location and NOGA section**, sorted by those three. LF
  line endings, no BOM, dates `YYYY-MM-DD`.
- `location` is `CH` for Switzerland as a whole or `ZH` for the canton. The
  national series is the one to reach for; `ZH` is there because this is a
  cantonal publication that happens to carry both.
- **`noga_section` is empty on the publisher's own total row** ("Alle
  Branchen"), the convention `rhine_cargo` uses for its headline rows. The
  total equals the sum of its sections on every date and location — the script
  checks it and fails rather than committing a file where it does not hold.
- `value` is a **count of register entries that day**, passed through as the
  publisher's own text. Nothing is dropped and nothing is zero-filled: the
  daily grid is complete, and a zero here is a real observation ("no bankruptcy
  in that section that day"), not a missing value. That is why this folder
  keeps zeros where `zurich_air` drops its gaps.
- **Weekends are structurally zero.** In 9.7 years there is not one non-zero
  Saturday or Sunday — the register does not record entries then, so about two
  sevenths of the rows are zero by construction, and public holidays behave the
  same way. Summing to a weekly figure is therefore safe; a daily average over
  calendar days is biased downwards and a day-of-week effect fitted to this
  series is mostly an artefact of the opening hours. Bankruptcies also lean
  early in the week (mean 33.5 on Mondays against 21.4 on Thursdays).
- **NOGA section `O` is absent**, along with `T` and `U`: public
  administration, households as employers, and extraterritorial bodies are not
  commercial-register entities. The 18 sections present are `A`–`N` and `P`–`S`.
- Revisions are not documented by the publisher. A weekly refresh rewrites the
  whole file, so a vintage is only recoverable from this repository's git
  history.
