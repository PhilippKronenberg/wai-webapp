# Swiss consumer price index (LIK), monthly

The total Swiss consumer price index, monthly since 1921, as one continuous
series on the newest base (December 2025 = 100). Not used by the dashboard.
It replaces the Datastream CPI behind the WAI input `SWCONPRCE` in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm).

- **Source:** Bundesamt für Statistik (BFS), Landesindex der
  Konsumentenpreise, *Indexierungstabelle* (asset `cc-d-05.02.08`):
  the total CPI on every original base since 1921.
  Download route: `https://www.bfs.admin.ch/bfsstatic/dam/assets/orderNr:cc-d-05.02.08/master`.
  The `bfs.admin.ch/asset/de/...` pages answer scripts with HTML, not the file.
- **Coverage:** monthly, **1921-01 to 2026-09** (on 2026-10-25), updated
  monthly by BFS.

## Files

| file | |
| --- | --- |
| `acquire_bfs_cpi.R` | downloads, chains the bases, writes the CSV (needs R and `readxl`) |
| `bfs_cpi.csv` | output in the **layout of the Datastream export it replaces** (`wai_ind` `data/DATASTREAM/datastream_econ.csv`): `;`-separated, first column `Name` with dates `DD.MM.YYYY` on the 15th, then the series column `SW CPI NADJ` |

```
Rscript bfs_cpi/acquire_bfs_cpi.R
```

## Not seasonally adjusted, deliberately

BFS publishes the CPI unadjusted. The Datastream series the WAI used was
`SW CPI SADJ`, seasonally adjusted by Refinitiv. By the owner's decision
(2026-10-25), this pipeline stays a pure download and writes the unadjusted
index, hence the column name `SW CPI NADJ`. Seasonal adjustment belongs in
mfbdfm's data prep, with X-13, as already done for core inflation.

## Chaining

Each column of the BFS table is the CPI on one base (June 1914, August 1939,
…, December 2025 = 100), from its base month on. The output uses the newest
base wherever it exists. Each older base is rescaled to the newer series at
the month the newer base starts. The result is exactly the December 2025 base
(100.0 in 2025-12), extended backwards with the older bases' movements. BFS
rounds to one decimal, so the earliest decades carry that rounding.

## Checked against the series it replaces (2026-10-25)

Datastream `SW CPI SADJ` against this series, 1953-01 to 2026-02 (878
months):

| | correlation | mean abs. difference |
| --- | --- | --- |
| y/y inflation, since 2000 | 0.998 | 0.05 pp |
| y/y inflation, since 1953 | 0.994 | 0.10 pp |
| m/m change (SA vs unadjusted) | 0.72 | — |

The year-on-year rates agree. The month-on-month changes differ by the
seasonal pattern, as they should. This series is also seven months more
current than the Datastream export (2026-09 against 2026-02).

## Not in this pipeline

Core inflation (`SWCPCOREF`, Datastream `SW CORE INFLATION 1 NADJ`) and the
producer price index (`SWPROPRCE`) are in other BFS files: the current-basket
CPI detail file, and `su-q-05.04.03.01-ppi-ipp` (PPI total, monthly since
1963). The same download route works for both. They are follow-ups (#50).
The I14Y dataset `36506626` (wages and consumer prices) is **annual** and
cannot replace a monthly series.
