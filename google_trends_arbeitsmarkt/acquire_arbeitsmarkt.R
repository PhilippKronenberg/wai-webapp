# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the Google Trends labour-market indicator "Arbeitsmarkt" (#50)
#
# Updates four Google Trends keyword series for Switzerland incrementally,
# combines their frequencies, adjusts them seasonally and writes the first
# principal component as the daily indicator wai_ind reads
# (data/dataset/google_trends_Arbeitsmarkt_sa.csv).
#
# This is wai_ind's newest version of the procedure,
# data/google_trends_indicators/hfi_googletrends_Arbeitsmarkt_DOWNLOAD.R
# (2026-03-31, wai_ind commit 18472df), with its patched trendecon and
# tempdisagg functions in vendor/. Only the paths are changed: everything is
# resolved from this script's folder instead of a hard-coded setwd().
#
# Procedure, per keyword (vendor/proc_keyword_latest.R and following)
#   1. Download hourly (last 7 days), daily, weekly and monthly Google Trends
#      data from the newest date in the cache on, and average them into the
#      cached raw/ch/<keyword>_{h,d,w,m}.csv.
#   2. proc_combine_freq(): extend daily data with hourly data, then bend the
#      daily series to the weekly and the monthly series (Chow-Lin, td_alt).
#   3. proc_seas_adj(): prophet seasonal adjustment; the indicator uses the
#      "detrended_seas_adj" component.
# Then the four keyword series are cut to their common span and their first
# principal component, scaled, is written as raw/ch/Arbeitsmarkt_sa.csv and
# as google_trends_Arbeitsmarkt_sa.csv.
#
# Google rate-limits these requests (HTTP 429) without warning. A rate limit
# stops the downloads, keeps the cached data and still rebuilds the
# indicator from what is there; re-run later. A rebuilt indicator whose
# common span did not move is reported as "not updated".
#
# Source
#   Google Trends via gtrendsR (unofficial; no API key; rate-limited)
#   Keywords (geo CH): see `keywords` below.
#
# Usage
#   Rscript google_trends_arbeitsmarkt/acquire_arbeitsmarkt.R
#   WAI_OFFLINE=TRUE Rscript google_trends_arbeitsmarkt/acquire_arbeitsmarkt.R
#       (no downloads; rebuild the indicator from the cache)
#   Options as in the original: WAI_WAIT (90), WAI_RETRY (8),
#   WAI_KEYWORD_PAUSE (45), WAI_WINDOWS (2), WAI_STOP_AFTER_RATE_LIMIT (TRUE),
#   WAI_PROXY (none).
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

keywords <- c(
  "Arbeitslosigkeit + chômage + disoccupazione",
  "arbeitslos + au chômage + disoccupato",
  "Arbeitsamt + agence pour l'emploi + ufficio del lavoro",
  "Kurzarbeit + chômage partiel + lavoro a orario ridotto"
)

# Resolved from the script's location, so it can be run from anywhere.
script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "google_trends_arbeitsmarkt"
})
script_dir <- normalizePath(script_dir)
out_file <- file.path(script_dir, "google_trends_Arbeitsmarkt_sa.csv")

env_true <- function(name, default) {
  tolower(Sys.getenv(name, unset = default)) %in% c("1", "true", "t", "yes", "y")
}
offline <- env_true("WAI_OFFLINE", "FALSE")
use_cache <- env_true("WAI_USE_CACHE", "TRUE")
stop_after_rl <- env_true("WAI_STOP_AFTER_RATE_LIMIT", "TRUE")
pause_val <- as.integer(Sys.getenv("WAI_KEYWORD_PAUSE", unset = "45"))
n_windows <- as.integer(Sys.getenv("WAI_WINDOWS", unset = "2"))
# proc_keyword_latest() reads these itself; set the original script's defaults.
if (!nzchar(Sys.getenv("WAI_WAIT"))) Sys.setenv(WAI_WAIT = "90")
if (!nzchar(Sys.getenv("WAI_RETRY"))) Sys.setenv(WAI_RETRY = "8")


# FUNCTIONS AND PACKAGES ----------------------------------------------------

# The vendored functions read and write under getOption("path_trendecon"),
# i.e. raw/ch/ in this folder.
options(path_trendecon = script_dir)
invisible(lapply(list.files(file.path(script_dir, "vendor"), pattern = "[.]R$", full.names = TRUE),
                 source))
suppressPackageStartupMessages({
  library(zoo)
  library(tempdisagg)
  library(forecast)
  library(seasonal)
  library(tis)
  library(prophet)
  library(tsbox)
  library(dplyr)
  library(tibble)
  library(TTR)
  library(gtrendsR)
  library(readr)
  library(tidyr)
})

is_rate_limit_error <- function(msg) {
  grepl("429|too many requests|rate limit|too soon|quota", msg, ignore.case = TRUE)
}

read_latest_time <- function(keyword, geo = "CH", suffix = "sa") {
  existing <- tryCatch(suppressWarnings(read_keyword(keyword, geo, suffix)),
                       error = function(e) NULL)
  if (is.null(existing) || nrow(existing) == 0 || !"time" %in% names(existing)) return(as.Date(NA))
  max(as.Date(existing$time), na.rm = TRUE)
}

update_keyword <- function(keyword, geo = "CH") {
  before <- read_latest_time(keyword, geo, "sa")
  status <- tryCatch(
    proc_keyword_latest(keyword = keyword, geo = geo, n_windows = n_windows),
    error = function(e) {
      if (is_rate_limit_error(conditionMessage(e)) && use_cache) {
        message("  RATE LIMITED while updating ", keyword)
        return(structure(FALSE, rate_limited = TRUE))
      }
      stop(e)
    }
  )
  if (isFALSE(status)) {
    return(list(keyword = keyword, before = before, after = before, updated = FALSE,
                rate_limited = isTRUE(attr(status, "rate_limited"))))
  }
  proc_combine_freq(keyword = keyword, geo = geo)
  proc_seas_adj(keyword = keyword, geo = geo)
  after <- read_latest_time(keyword, geo, "sa")
  list(keyword = keyword, before = before, after = after,
       updated = !is.na(after) && !identical(before, after),
       rate_limited = any(!unlist(status)))
}


# STEP 1: DOWNLOAD ------------------------------------------------------------

previous <- if (file.exists(out_file)) read.csv(out_file) else NULL

if (offline) {
  message("WAI_OFFLINE=TRUE: no downloads, rebuilding the indicator from the cache")
} else {
  results <- list()
  for (kw in keywords) {
    r <- update_keyword(kw, geo = "CH")
    results[[kw]] <- r
    if (isTRUE(r$rate_limited) && stop_after_rl) {
      message("Stopping after the first rate limit to avoid extending the block.")
      break
    }
    if (!identical(kw, tail(keywords, 1)) && pause_val > 0) Sys.sleep(pause_val)
  }
  message("\nKeyword update summary:")
  for (r in results) {
    message(sprintf("  %s | before=%s | after=%s | updated=%s | rate_limited=%s",
                    r$keyword, r$before, r$after, r$updated, r$rate_limited))
  }
}


# STEP 2: INDICATOR -----------------------------------------------------------

data <- read_keywords(keywords, suffix = "sa", id = "detrended_seas_adj")
smry <- ts_summary(data)
if (nrow(dplyr::distinct(smry, start, end)) != 1) {
  message("Trimming keyword series to their common span")
  data <- tsbox::ts_span(data, start = max(as.Date(smry$start)), end = min(as.Date(smry$end)))
  smry <- ts_summary(data)
  if (nrow(dplyr::distinct(smry, start, end)) != 1) stop("could not align the keyword spans")
}
message(sprintf("Span: %s to %s", smry$start[1], smry$end[1]))

x_prcomp <- filter(ts_prcomp(data), id == "PC1") %>%
  select(-id) %>%
  ts_scale()

write_keyword(x_prcomp, "Arbeitsmarkt", "ch", "sa")
invisible(file.copy(path_keyword("Arbeitsmarkt", "ch", "sa"), out_file, overwrite = TRUE))
message("wrote ", out_file)

# Check against the previous release: PC1's sign and scale are re-estimated on
# every run, so the comparison is a correlation on the common days.
if (!is.null(previous)) {
  new <- read.csv(out_file)
  m <- merge(previous, new, by = "time", suffixes = c(".old", ".new"))
  r <- stats::cor(m$value.old, m$value.new)
  message(sprintf("vs previous release (to %s): %d common days, correlation %.5f; new end %s",
                  max(previous$time), nrow(m), r, max(new$time)))
  if (abs(r) < 0.9) stop("the rebuilt indicator correlates only ", round(r, 3), " with the previous one")
  if (r < 0) warning("PC1 changed sign against the previous release")
  if (max(new$time) <= max(previous$time)) message("NOT UPDATED: the common span did not move")
}
