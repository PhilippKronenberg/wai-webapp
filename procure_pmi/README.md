# procure.ch PMI: the three series the WAI uses

Reads the monthly procure.ch PMI reports and **appends** the three seasonally
adjusted series the WAI uses to their existing, fixed history (Datastream).
Not used by the dashboard. These are inputs to
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

| WAI input | Datastream column | read from the report |
| --- | --- | --- |
| `SWPURCHSQ` | `SW PURCHASING MANAGERS INDEX SADJ` | "PMI Industrie (saisonbereinigt)", **PMI (s)** |
| `SWPMIPROQ` | `SW PURCHASING MANAGERS INDEX - OUTPUT SADJ` | subcomponent "Produktion", **Index (s)** |
| `SWPMIORDQ` | `SW PURCHASING MANAGERS INDEX - BACKLOG OF ORDERS SADJ` | subcomponent "Auftragsbestand", **Index (s)** |

- **Source:** procure.ch / UBS, monthly PMI report (PDF). Each release has a
  magazine article on <https://www.procure.ch/magazin> that links the report
  under `/fileadmin/user_upload/Dokumente/PROCURE_SWISS_MAGAZIN/PMI/<YYYY>/…pdf`.
- **History:** the existing Datastream series, treated as **fixed**. Read
  from `../wai_ind/data/DATASTREAM/datastream_econ.csv` by default, or from a
  path given as argument. Only months after its last observation are appended.

## Files

| file | committed | |
| --- | --- | --- |
| `acquire_procure_pmi.R` | yes | the pipeline (R; needs `pdftools`, `tesseract`, `png`) |
| `pmi_from_reports.csv` | yes | every value read from the public reports: `report, month, series, value` |
| `pmi_extended.csv` | **no** | the fixed history plus the appended months, in the Datastream layout (`Name;…`, `DD.MM.YYYY` on the 15th). Gitignored because the history is **licensed Datastream data** and this repository is public |
| `pdf/` | no | report cache |

```
Rscript procure_pmi/acquire_procure_pmi.R [<history.csv>]
```

## Finding a new report automatically

The script walks the magazine's pages, newest first, follows every
`/magazin/artikel/pmi…` article to its PDF, and stops once it has reached the
month before the gap. **The report file names are not regular:**
`09_PMI_September_2026-DE.pdf`, `08_PMI_August_2026_Deutsch.pdf`,
`04-PMI_April_2026_DE.pdf`, `03_Maerz_2026_DE.pdf`, and
`PMI_Februar_2026_Deutsch.pdf` with no month number at all. So nothing is
constructed. The month in a link is only a guess used for paging. **The month
a report is about is read from the report itself:** the last row of its
13-month table. A month missing between the history and the newest report
stops the run.

## Reading a report

The tables are **images** in the PDF. The table page (captioned "(s):
saisonbereinigt") is rendered at 300 dpi, its left half (the industry tables)
is read by OCR (tesseract), and parsed:

- "Produktion" and "Auftragsbestand": Index (s) and its change on the previous
  month;
- "PMI Industrie (saisonbereinigt)": 13 months of PMI (s).

Every value in these tables has one decimal. When OCR drops the point
(`560` for 56.0), it is restored by that rule.

## Checks (a failed check stops the run)

1. The latest PMI (s) and Produktion (s) must equal the values stated in the
   report's prose ("… auf 55,3 …").
2. For consecutive reports, each component's previous month (Index (s) minus
   its change) must agree with the previous report.
3. The 13-month PMI (s) table must agree with the fixed history where they
   overlap (more than 1.5 apart stops the run; the gap is reported).

Each appended month uses the **newest** estimate. The headline comes from the
newest report's 13-month table. The components come from the next report
(value minus change) if there is one, else from the month's own report.

## First run (2026-10-25)

History to 2026-02. Reports 2026-02 to 2026-09 read; 2026-03 to 2026-09
appended:

| month | PMI (s) | output (s) | backlog (s) |
| --- | --- | --- | --- |
| 2026-03 | 53.3 | 50.6 | 54.2 |
| 2026-04 | 54.5 | 52.3 | 56.1 |
| 2026-05 | 57.3 | 57.3 | 59.4 |
| 2026-06 | 54.3 | 57.0 | 53.5 |
| 2026-07 | 53.2 | 54.2 | 53.3 |
| 2026-08 | 57.1 | 59.8 | 57.4 |
| 2026-09 | 55.3 | 55.9 | 57.0 |

**Consistency with the history:** the PMI (s) table matches Datastream on all
6 overlapping months to at most 0.04. Output and backlog in the February
report match Datastream to 0.02. Those differences are the reports'
one-decimal rounding against Datastream's two decimals. The SA history in
the reports was not revised between releases: January and February are
identical in all 8 reports.
