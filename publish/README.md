# The nightly run

One unattended run from the newest source data to the newest WAI on the
dashboard (#72). It runs on the owner's Windows machine, not on a GitHub runner:
it needs inputs that exist only there (Datastream PMI history, SMI, VSMI, the
KOF account, `../wai_ind` read-only).

```
Rscript run_nightly.R                 # everything, publishes
Rscript run_nightly.R --dry-run       # everything except commit and push
Rscript run_nightly.R --force         # fit and publish even if nothing changed
Rscript run_nightly.R --skip=swissgrid --no-pipelines   # passed on to run_all.R
```

| step | script | what happens |
| --- | --- | --- |
| 1. build | `run_all.R` | pipelines, assemble, prepare (`dataset/README.md`). A failing pipeline is reported and its last output is used. A failing assemble or prepare stops the run |
| 2. change check | `run_nightly.R` | one checksum per series of the prepared dataset `dat`, against those of the last publication (`dataset/out/last_published.json`). Nothing changed: stop, exit 0, no fit, no commit |
| 3. fit and publish | `publish/update_wai_web.R` | fit at the current vintage (5000 draws after 1000 burn-in), export, contract checks, CI's validator, commit + push of the web files if they changed |

Measured 2026-10-30: 30 min for the build (20 of them Google Trends), 47 min for
the fit.

**What counts as new data.** Two builds an hour apart differed in 3 of 46 series:
`Arbeitsmarkt`, `SWISSMI` and `VIX`. Google Trends draws a new sample on every
download, so for `Arbeitsmarkt` only new dates count. The market series change
when a trading day is added, so expect a fit on most nights after a trading day
and the stop at the change check mainly on weekends and holidays.

**Only the web files are committed:** `wai_data.csv`, `wai_meta.json`,
`wai_contributions.csv`, `wai_series.csv`, `wai_news.csv`,
`wai_measures_meta.json`. They are checked and committed in a temporary worktree
of `origin/main`, so the checkout the job runs in can be on any branch and hold
other changes. After a publication, `git pull` brings the files into it.

The pipelines rewrite their tracked CSVs (`bazg_trade/`, `astra_traffic/`, …) in
the checkout, as they do under `run_all.R`. **The nightly run does not commit
them**, so they show as modified. Commit them when you want the repository's copy
refreshed, or `git restore` them; the next night downloads them again.

A failure in the fit, export or checks publishes nothing and leaves
`last_published.json` as it was, so the next night tries again.

## Logs

In `dataset/out/logs/`:

| file | |
| --- | --- |
| `nightly_summary.log` | one line per run: date, series changed, failed pipelines, published or not, nowcast |
| `nightly_task.log` | the scheduled job's own output |
| `nightly_build.log`, `publish.log` | the build and the fit and publish step |
| `<pipeline>.log`, `run_all_status.csv` | each pipeline |

## The schedule

Registering is a separate step, done by the owner (asks for the Windows password,
so that the task runs whether or not you are logged on):

```
powershell -ExecutionPolicy Bypass -File publish\register_nightly_task.ps1             # daily at 02:30
powershell -ExecutionPolicy Bypass -File publish\register_nightly_task.ps1 -At 03:15
```

To stop it:

```
schtasks /Change /TN "WAI nightly update" /Disable                  # pause
powershell -ExecutionPolicy Bypass -File publish\remove_nightly_task.ps1   # remove
```

The task stores the full path of `Rscript.exe`. After an R upgrade, register it
again and reinstall the packages (`mfbdfm`, the pipelines').

## What the machine needs

- **Git** on the `PATH` with push access to this repository, also for a job
  without a logged-on user. Check with a by-hand run of the task:
  `schtasks /Run /TN "WAI nightly update"`.
- **Node.js** on the `PATH` (`winget install OpenJS.NodeJS.LTS`). Without it
  `bfs_keu` fails every night, so retail turnover stops updating, and CI's
  validator does not run before the push.
- **`TSDBAPI_API_KEY`** in `~/.Renviron`, for all nine KOF series. Create it once
  in an interactive session with `tsdbapi::create_user_api_key()` and never commit
  it. Without it the public five stay current, and the four manufacturing
  sub-sector series stay at the last private read; the log says so.
- **R 4.5 or newer** (`tools::md5sum(bytes = )`), with `mfbdfm` and `jsonlite`.

## KOF: released data only

The published files never hold KOF data from an unreleased vintage: the dataset
reads only `kof_series_released.csv` (`kof/README.md`). The test changes the raw
downloads and requires the model's KOF input not to move:

```
Rscript publish/check_kof_released.R
```

## `update_wai_web.R`

A copy of mfbdfm's `analysis/update_wai_web.R`; mfbdfm's original is not changed.
Its header lists the differences. `WAI_LENGTH_SAMPLE` and `WAI_BURN_IN` shorten
the chain for smoke tests only; a real run must not set them.
