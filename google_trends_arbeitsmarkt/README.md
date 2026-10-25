# Google Trends labour-market indicator (`Arbeitsmarkt`)

The WAI input `Arbeitsmarkt` ("Google Search Index, Perceived Labour Market
Situation"): the first principal component of four seasonally adjusted daily
Google Trends series for Switzerland. Not used by the dashboard. It is an
input to [mfbdfm](https://github.com/PhilippKronenberg/mfbdfm) via `wai_ind`,
which reads it as `data/dataset/google_trends_Arbeitsmarkt_sa.csv`.

Keywords (geo `CH`):

- `Arbeitslosigkeit + chômage + disoccupazione`
- `arbeitslos + au chômage + disoccupato`
- `Arbeitsamt + agence pour l'emploi + ufficio del lavoro`
- `Kurzarbeit + chômage partiel + lavoro a orario ridotto`

## Files

| file | |
| --- | --- |
| `acquire_arbeitsmarkt.R` | the pipeline (needs `gtrendsR`, `prophet`, `tsbox`, `tempdisagg`, `dplyr`, `readr`, `tidyr`, …) |
| `google_trends_Arbeitsmarkt_sa.csv` | output, `time,value`, daily; drop-in for `wai_ind`'s file of the same name |
| `raw/ch/` | the keyword cache: `<keyword>_{h,d,w,m}.csv` downloads, `_mwd` combined, `_sa` adjusted, and `Arbeitsmarkt_sa.csv`. **Committed on purpose**: each update builds on it |
| `vendor/` | trendecon and tempdisagg functions, frozen and patched (GPL, see `vendor/LICENSE.md`) |

```
Rscript google_trends_arbeitsmarkt/acquire_arbeitsmarkt.R
WAI_OFFLINE=TRUE Rscript google_trends_arbeitsmarkt/acquire_arbeitsmarkt.R   # rebuild from the cache only
```

Options (environment variables) are those of the original script:
`WAI_WAIT` (90), `WAI_RETRY` (8), `WAI_KEYWORD_PAUSE` (45), `WAI_WINDOWS` (2),
`WAI_STOP_AFTER_RATE_LIMIT` (TRUE), `WAI_PROXY`. When Google rate-limits
(HTTP 429), the run stops downloading, keeps the cache and rebuilds the
indicator from what is there. Re-run later.

## Origin

This is `wai_ind`'s newest version of the procedure:
`data/google_trends_indicators/hfi_googletrends_Arbeitsmarkt_DOWNLOAD.R`
(2026-03-31, `wai_ind` commit `18472df`, on ETH GitLab), with its functions
and cache. Only the paths changed. Offline, it reproduces the 2026-03-31
indicator exactly (7395 days).

## Fixed here (2026-10-25)

The first live run failed in `proc_combine_freq()` with
`left hand side contains NAs`. The cause was in `proc_keyword_latest()`, which
chooses the download windows. Google picks the resolution from the length of
the requested range: under 7 days hourly, under about 9 months daily, under 5
years weekly, monthly beyond that.

1. **Weekly:** the window started at the *later* of the last cached date and
   one year ago. After a 7-month gap that is April to today, so Google
   returned daily data, which went into the weekly cache. It now starts at
   the *earlier* of the two.
2. **Daily:** the same `max`/`min` mix-up. A run a few days after the last
   one would have asked for a few days and got hourly data.
3. **Monthly:** 15-year windows starting in 2006 end around 2021 and never
   reach today, so monthly data had stopped updating. The windows now run
   from 2006 to today, as in trendecon.
4. **Guard:** downloaded data at the wrong resolution is no longer written to
   the cache; the run stops with a message instead.

The monthly files keep weekly rows from 2021 on, left from the earlier runs.
`proc_combine_freq()` averages them to months, as it did for the March
release.

Not changed: in `prepare_windows_tbl()`, the guard against windows shrinking
at today takes `[1]` of `seq(start, by = "-<window>")`, which is the start
itself, so the guard does nothing. With the fixes above no window shrinks
enough to change resolution, so it is left as it was.

## First live run (2026-10-25)

All four keywords updated, 2026-04-01 to 2026-10-25, with no rate limit.
Against the 2026-03-31 release on its 7395 days: correlation 0.984 for
levels, 0.994 for weekly changes. The history moves because the seasonal
adjustment (prophet) and the principal component are re-estimated each run.
