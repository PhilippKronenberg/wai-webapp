# Run from the repository root (wai-webapp). Normally started by run_all.R.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Data Input for Swiss Weekly GDP Indicator from data/dataset
# Baseline: code/1_data_prep.R
#
# wai-webapp copy (#50). A copy of mfbdfm's analysis/1_data_prep_dataset.R
# (2026-10-25, mfbdfm commit ac9c2a6), changed only where the inputs now
# arrive differently. mfbdfm's original stays untouched. The changes:
#   - Paths: inputs from MFBDFM_DATASET_DIR (dataset/assemble_dataset.R's
#     folder), metadata from dataset/data_meta.csv, outputs to dataset/out/.
#   - Output name tag (MFBDFM_PREP_TAG) and GDP vintage date
#     (MFBDFM_GDP_VINTAGE_DATE), so old and new inputs can be built side by side.
#   - CPI and PPI: BFS publishes them unadjusted; they get SWCPCOREF's X-13
#     step, from 1985 (X-13's 780-observation limit).
#   - anz_kktrans_ch: Worldline's daily count gets stat_einkauf's daily MSTL
#     treatment; the legacy weekly SPA file keeps its step rule.
#   - GDP vintages from seco_gdp/ (MFBDFM_GDP_DIR), this repository's SECO
#     pipeline, instead of the files inside the installed mfbdfm package.
# With MFBDFM_DATASET_DIR pointing at wai_ind's data/dataset it reproduces
# the original's dataset.
#
# Summary
# 1. Read the variable metadata that defines the target series order and transformation.
# 2. Load each raw source file from data/dataset and harmonize it to the project time-series
#    conventions, mostly weekly frequency with 48 observations per year.
# 3. Apply the series-specific preprocessing choices decided during the dataset review:
#    date alignment fixes, seasonal adjustment, moving-average smoothing, weekly aggregation,
#    and for selected monthly series an index-level X-13 adjustment.
# 4. Export the harmonized pre-transformation series to data_ch_dataset_raw.Rda/csv.
# 5. Apply the metadata-defined transformations, trim to the legacy sample window, and export
#    the final transformed dataset to data_ch_dataset.Rda/csv together with diagnostic plots.
#
# Series-Specific Adjustment Summary
# - postgres.rda block:
#   The legacy postgres bundle is kept as provided, except all KOF balance series are shifted
#   up by 100 so that balance indicators can be logged when metadata requests it.
# - FSO retail block:
#   The matched retail NOGA monthly series are read from fso_series.csv and replace the
#   corresponding legacy postgres versions so the dataset uses the curated external extract.
# - Datastream monthly macro block:
#   SWCONPRCE, SWPROPRCE, SWPURCHSQ, SWPMIORDQ, SWPMIPROQ are read as monthly levels.
#   SWCPCOREF is additionally seasonally adjusted at the monthly index level with X-13.
# - Datastream bond block:
#   SWGBOND. is read as a monthly level with no extra preprocessing here.
# - Datastream daily equity block:
#   FINANSW, INDUSSW, SWISSMI use a 7-day moving average on the daily index and are then
#   aggregated to weekly levels.
# - Trendecon / Google Trends block:
#   trendecon and Arbeitsmarkt use daily MSTL adjustment with weekly and annual seasonality,
#   then a 7-day moving average, then weekly aggregation.
# - KTZH cash / card / mobility / retail block:
#   bezug_bargeld uses daily MSTL adjustment with weekly, monthly-like, and annual seasonality,
#   then weekly aggregation.
#   anz_kktrans_ch is expanded from weekly steps to daily values and then re-aggregated with
#   the legacy daily_to_weekly rule to match historical timing exactly.
#   oev_freq_hardbruecke and oev_freq_hb are aggregated from daily to weekly with no extra
#   adjustment in the active specification.
#   debiteinsatz_ausland uses daily MSTL adjustment with weekly and annual seasonality, then
#   weekly aggregation.
#   tages_distanz_median is aggregated from daily to weekly with no extra adjustment.
#   aufkommen_miv uses daily MSTL adjustment with weekly, monthly-like, and annual seasonality,
#   then weekly aggregation.
#   stat_einkauf cuts off the startup-jump period, applies daily MSTL adjustment with weekly,
#   monthly-like, and annual seasonality, and then aggregates to weekly. The trend-removing
#   alternative is kept directly below the active call in commented form.
# - ASTRA traffic block:
#   traffic_PW and traffic_LW apply daily MSTL adjustment with weekly, monthly-like, and annual
#   seasonality, then a 7-day moving average, then weekly aggregation. The trend-removing
#   alternative is kept directly below the active call in commented form.
# - Destatis truck-toll block:
#   Lkw-Maut-Fahrleistungsindex_DE is aggregated from daily to weekly with no extra adjustment.
# - Swissgrid electricity block:
#   electricity_in and electricity_out use daily MSTL adjustment with weekly and annual
#   seasonality, then a 7-day moving average, then weekly aggregation.
# - Zurich Airport block:
#   zrh_airport_departure and zrh_airport_arrivals are aggregated to weekly first and then
#   seasonally adjusted with the legacy weekly MSTL-style helper.
# - Google mobility block:
#   mobility_retail_and_recreation, mobility_grocery_and_pharmacy, mobility_parks,
#   mobility_transit_stations, mobility_workplaces, and mobility_residential use daily MSTL
#   adjustment with weekly, monthly-like, and annual seasonality, then a 7-day moving average,
#   then weekly aggregation, and finally a +100 baseline shift for legacy comparability.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# Paths are relative to the repository root.
project_dir <- "."

# Settings (environment variables):
#   MFBDFM_DATASET_DIR       folder with the raw source files (default dataset/out/data)
#   MFBDFM_PREP_TAG          output name tag: data_ch_dataset_<tag>.Rda (default "new")
#   MFBDFM_GDP_VINTAGE_DATE  last GDP vintage date to use, YYYY-MM-DD (default 2026-03-07)
metadata_path <- file.path("dataset", "data_meta.csv")
dataset_dir <- Sys.getenv("MFBDFM_DATASET_DIR", file.path(project_dir, "dataset", "out", "data"))
prep_tag <- Sys.getenv("MFBDFM_PREP_TAG", "new")
raw_suffix <- paste0("_", prep_tag)
rda_dir <- file.path("dataset", "out", "Rda")
out_dir <- file.path("dataset", "out", "out")

dir.create(rda_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# HELPERS -----------------------------------------------------------------
# These helper functions do the generic work shared across many source blocks:
# reading files, parsing dates, harmonizing daily data to weekly data, applying
# seasonal adjustment, and exporting diagnostic objects.

# Helper packages used by the prep pipeline. All are declared in the package
# DESCRIPTION (Imports/Suggests); install them once via
# remotes::install_deps(dependencies = TRUE) instead of installing at runtime.
library(zoo)
library(forecast)
library(dplyr)
library(tsbox)
library(tseries)
library(mfbdfm)

# Load variable metadata that controls source ordering, frequency, and transformation.
metadata <- utils::read.csv(metadata_path) |>
  dplyr::mutate(
    Frequency = as.integer(Frequency),
    Flow = as.integer(Flow)
  )

# Parse dates that appear either in ISO format or in day.month.year format.
parse_date_multi <- function(x) {
  x <- trimws(as.character(x))
  x[x %in% c("", "NA")] <- NA_character_
  out <- as.Date(x, format = "%Y-%m-%d")
  miss <- is.na(out)
  out[miss] <- as.Date(x[miss], format = "%d.%m.%Y")
  miss <- is.na(out)
  out[miss] <- as.Date(paste0(x[miss], "-01"), format = "%Y-%m-%d")
  out
}

# Detect the csv delimiter automatically so mixed source files can be read consistently.
read_delim_auto <- function(path) {
  sample_lines <- readLines(path, n = 5, warn = FALSE, encoding = "UTF-8")
  score_sep <- function(sep) {
    counts <- vapply(strsplit(sample_lines, sep, fixed = TRUE), length, integer(1))
    c(valid = sum(counts > 1L), spread = stats::sd(counts), median = stats::median(counts))
  }
  cand <- list(";" = score_sep(";"), "," = score_sep(","))
  choose_semicolon <- (
    cand[[";"]]["valid"] > cand[[","]]["valid"] ||
      (cand[[";"]]["valid"] == cand[[","]]["valid"] && cand[[";"]]["spread"] < cand[[","]]["spread"]) ||
      (cand[[";"]]["valid"] == cand[[","]]["valid"] && cand[[";"]]["spread"] == cand[[","]]["spread"] && cand[[";"]]["median"] >= cand[[","]]["median"])
  )
  sep <- if (choose_semicolon) ";" else ","
  utils::read.table(
    path,
    sep = sep,
    header = TRUE,
    quote = "\"",
    stringsAsFactors = FALSE,
    check.names = FALSE,
    fileEncoding = "UTF-8-BOM"
  )
}

# Convert daily dates into the fractional year scale used by the weekly aggregation.
annual_fraction <- function(dates) {
  as.numeric(format(dates, "%Y")) +
    (as.numeric(format(dates, "%m")) - 1) / 12 +
    as.numeric(format(dates, "%d")) / 365
}

# Aggregate daily observations to the legacy weekly frequency with 48 periods per year.
daily_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !is.na(dates)
  dates <- dates[keep]
  values <- values[keep]
  idx <- floor(annual_fraction(dates) * 48) / 48
  weekly_df <- data.frame(idx = idx, value = values) |>
    dplyr::group_by(idx) |>
    dplyr::summarise(
      value = if (all(is.na(value))) NA_real_ else mean(value, na.rm = TRUE),
      .groups = "drop"
    )
  weekly_vals <- weekly_df$value
  weekly_vals[is.nan(weekly_vals)] <- NA_real_
  stats::ts(weekly_vals, start = weekly_df$idx[1], frequency = 48)
}

# Aggregate a zoo/xts daily series to the legacy weekly frequency used in the project.
daily2weekly <- function(x) {
  dates <- as.Date(time(x))
  values <- as.numeric(x)
  out <- daily_to_weekly(dates, values)
  dimnames(out) <- NULL
  out
}

# Turn date-value pairs into a monthly ts object while preserving their original start date.
date_to_monthly_ts <- function(dates, values) {
  dates <- parse_date_multi(dates)
  values <- as.numeric(values)
  keep <- !is.na(dates)
  dates <- dates[keep]
  values <- values[keep]
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  stats::ts(values, start = c(as.integer(format(dates[1], "%Y")), as.integer(format(dates[1], "%m"))), frequency = 12)
}

# Turn date-value pairs into a quarterly ts object while preserving their original start date.
date_to_quarterly_ts <- function(dates, values) {
  dates <- parse_date_multi(dates)
  values <- as.numeric(values)
  keep <- !is.na(dates)
  dates <- dates[keep]
  values <- values[keep]
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  qtr <- ((as.integer(format(dates[1], "%m")) - 1) %/% 3) + 1
  stats::ts(values, start = c(as.integer(format(dates[1], "%Y")), qtr), frequency = 4)
}

# Turn weekly date-value pairs into the legacy weekly ts object without re-aggregating them.
date_to_weekly_ts <- function(dates, values) {
  dates <- parse_date_multi(dates)
  values <- as.numeric(values)
  keep <- !is.na(dates)
  dates <- dates[keep]
  values <- values[keep]
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  daily_to_weekly(dates, values)
}

# Collapse duplicated dates before converting high-frequency inputs to time series.
aggregate_duplicate_dates <- function(dates, values, fun = c("mean", "sum")) {
  fun <- match.arg(fun)
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !is.na(dates)
  dates <- dates[keep]
  values <- values[keep]
  agg_fun <- if (fun == "sum") function(x) sum(x, na.rm = TRUE) else function(x) mean(x, na.rm = TRUE)
  agg <- aggregate(values, by = list(date = dates), FUN = agg_fun)
  agg[order(agg$date), ]
}

# Remove leading and trailing missing values after seasonal adjustment or transformation.
trim_ts_na <- function(x) {
  stats::as.ts(zoo::na.trim(zoo::as.zoo(x), sides = "both"))
}

# Apply the old-style weekly seasonal adjustment with forecast::mstl when possible.
seasonally_adjust_weekly <- function(x) {
  x <- trim_ts_na(x)
  vals <- as.numeric(x)
  if (length(vals) < 2 * frequency(x) || anyNA(vals)) return(x)
  fit <- forecast::mstl(forecast::msts(vals, seasonal.periods = frequency(x)))
  adjusted <- fit[, "Trend"] + fit[, "Remainder"]
  stats::ts(adjusted, start = stats::start(x), frequency = frequency(x))
}

# Seasonally adjust daily data, smooth it with a 7-day moving average, then aggregate to weekly.
daily_adjust_ma7_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit <- forecast::mstl(forecast::msts(values, seasonal.periods = 365))
    adjusted_vals <- fit[, "Trend"] + fit[, "Remainder"]
  }
  ma7_vals <- stats::filter(adjusted_vals, rep(1 / 7, 7), sides = 1)
  trim_ts_na(daily_to_weekly(dates, ma7_vals))
}

# Apply daily MSTL seasonal adjustment, then a 7-day moving average, then aggregate to weekly.
daily_mstl_ma7_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 365)))
    adjusted_vals <- fit[, "Trend"] + fit[, "Remainder"]
  }
  ma7_vals <- stats::filter(adjusted_vals, rep(1 / 7, 7), sides = 1)
  trim_ts_na(daily_to_weekly(dates, ma7_vals))
}

# Apply daily MSTL seasonal adjustment with weekly, monthly-like, and annual periods,
# then aggregate directly to weekly.
daily_mstl_monthly_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 30.5, 365)))
    seas_cols <- grep("^Season", colnames(fit))
    if (length(seas_cols)) {
      adjusted_vals <- values - rowSums(fit[, seas_cols, drop = FALSE])
    }
  }
  trim_ts_na(daily_to_weekly(dates, adjusted_vals))
}

# Apply daily MSTL seasonal adjustment with weekly, monthly-like, and annual periods,
# smooth with a 7-day moving average, then aggregate directly to weekly.
daily_mstl_monthly_ma7_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 30.5, 365)))
    seas_cols <- grep("^Season", colnames(fit))
    if (length(seas_cols)) {
      adjusted_vals <- values - rowSums(fit[, seas_cols, drop = FALSE])
    }
  }
  ma7_vals <- stats::filter(adjusted_vals, rep(1 / 7, 7), sides = 1)
  trim_ts_na(daily_to_weekly(dates, ma7_vals))
}

# Apply daily MSTL seasonal adjustment with weekly, monthly-like, and annual periods,
# smooth with a 7-day moving average, then aggregate to weekly and keep the level.
daily_mstl_monthly_ma7_weekly <- function(dates, values) {
  daily_mstl_monthly_ma7_to_weekly(dates, values)
}

# Apply daily MSTL seasonal adjustment with weekly, monthly-like, and annual periods,
# smooth with a 7-day moving average, aggregate to weekly, then remove the weekly trend
# component with MSTL.
daily_mstl_monthly_ma7_detrend_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit_daily <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 30.5, 365)))
    seas_cols <- grep("^Season", colnames(fit_daily))
    if (length(seas_cols)) {
      adjusted_vals <- values - rowSums(fit_daily[, seas_cols, drop = FALSE])
    }
  }
  ma7_vals <- stats::filter(adjusted_vals, rep(1 / 7, 7), sides = 1)
  weekly <- trim_ts_na(daily_to_weekly(dates, ma7_vals))
  fit_weekly <- forecast::mstl(forecast::msts(as.numeric(weekly), seasonal.periods = frequency(weekly)))
  cycle <- stats::ts(fit_weekly[, "Remainder"], start = stats::start(weekly), frequency = frequency(weekly))
  trim_ts_na(cycle)
}

# Apply daily MSTL seasonal adjustment with weekly and annual periods,
# then aggregate directly to weekly.
daily_mstl_annual_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 365)))
    seas_cols <- grep("^Season", colnames(fit))
    if (length(seas_cols)) {
      adjusted_vals <- values - rowSums(fit[, seas_cols, drop = FALSE])
    }
  }
  trim_ts_na(daily_to_weekly(dates, adjusted_vals))
}

# Cut off the startup jump, seasonally adjust daily retail data, then aggregate to weekly.
daily_retail_mstl_weekly <- function(dates, values, start_date = as.Date("2019-03-18")) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  keep_start <- dates >= start_date
  dates <- dates[keep_start]
  values <- values[keep_start]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit_daily <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 30.5, 365)))
    seas_cols <- grep("^Season", colnames(fit_daily))
    if (length(seas_cols)) {
      adjusted_vals <- values - rowSums(fit_daily[, seas_cols, drop = FALSE])
    }
  }
  trim_ts_na(daily_to_weekly(dates, adjusted_vals))
}

# Cut off the startup jump, seasonally adjust daily retail data, aggregate to weekly,
# then remove the weekly trend component with MSTL.
daily_retail_mstl_trend_weekly <- function(dates, values, start_date = as.Date("2019-03-18")) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  keep_start <- dates >= start_date
  dates <- dates[keep_start]
  values <- values[keep_start]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  adjusted_vals <- values
  if (length(values) >= 2 * 365) {
    fit_daily <- forecast::mstl(forecast::msts(values, seasonal.periods = c(7, 30.5, 365)))
    seas_cols <- grep("^Season", colnames(fit_daily))
    if (length(seas_cols)) {
      adjusted_vals <- values - rowSums(fit_daily[, seas_cols, drop = FALSE])
    }
  }
  weekly <- trim_ts_na(daily_to_weekly(dates, adjusted_vals))
  fit_weekly <- forecast::mstl(forecast::msts(as.numeric(weekly), seasonal.periods = frequency(weekly)))
  cycle <- stats::ts(fit_weekly[, "Remainder"], start = stats::start(weekly), frequency = frequency(weekly))
  trim_ts_na(cycle)
}

# Smooth daily data with a 7-day moving average, then aggregate to weekly.
daily_ma7_to_weekly <- function(dates, values) {
  dates <- as.Date(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  ma7_vals <- stats::filter(values, rep(1 / 7, 7), sides = 1)
  trim_ts_na(daily_to_weekly(dates, ma7_vals))
}

# Expand step-like weekly observations to daily values, then re-aggregate with the legacy weekly rule.
weekly_step_to_daily_then_weekly <- function(dates, values) {
  dates <- parse_date_multi(dates)
  values <- as.numeric(values)
  keep <- !(is.na(dates) | is.na(values))
  dates <- dates[keep]
  values <- values[keep]
  if (!length(values)) {
    return(stats::ts(numeric(0), start = 0, frequency = 48))
  }
  ord <- order(dates)
  dates <- dates[ord]
  values <- values[ord]
  next_dates <- c(dates[-1] - 1, dates[length(dates)] + 6)
  daily_dates <- do.call(c, lapply(seq_along(dates), function(i) seq(dates[i], next_dates[i], by = "day")))
  daily_values <- rep(values, times = as.integer(next_dates - dates) + 1L)
  daily_to_weekly(daily_dates, daily_values)
}

# Apply X-13 seasonal adjustment to monthly indicator levels when needed.
seasonally_adjust_monthly_x13 <- function(x) {
  x <- trim_ts_na(x)
  vals <- as.numeric(x)
  if (frequency(x) != 12 || length(vals) < 24 || anyNA(vals)) return(x)
  if (!requireNamespace("seasonal", quietly = TRUE)) {
    stop("Package 'seasonal' is required to adjust monthly series such as SWCPCOREF.")
  }
  fit <- seasonal::seas(x, transform.function = "none")
  stats::as.ts(seasonal::final(fit))
}

# Build right-aligned rolling means for the detrending transformations.
roll_mean_right <- function(x, k) {
  zoo::rollmeanr(as.numeric(x), k = k, fill = NA)
}

# Interpolate monthly series to the weekly target grid when only low-frequency data exists.
monthly_to_weekly <- function(x) {
  tx <- as.numeric(time(x))
  tgt <- seq(floor(tx[1] * 48) / 48, ceiling(tx[length(tx)] * 48) / 48, by = 1 / 48)
  y <- stats::approx(tx, as.numeric(x), xout = tgt, method = "linear", rule = 2)$y
  stats::ts(y, start = tgt[1], frequency = 48)
}

# Smooth weekly Google mobility data with the same two-week average used before.
two_week_rollmean <- function(x) {
  if (length(x) < 2) return(x)
  out <- zoo::rollmean(as.numeric(x), 2)
  stats::ts(out, start = time(x)[1], frequency = frequency(x))
}

# Convert ts time indices back to dates for the exported long-format files.
ts_time_to_date <- function(x) {
  t <- as.numeric(time(x))
  f <- frequency(x)
  if (f == 12) {
    year <- floor(t)
    month <- round((t - year) * 12) + 1
    as.Date(sprintf("%04d-%02d-01", year, month))
  } else if (f == 4) {
    year <- floor(t)
    quarter <- round((t - year) * 4) + 1
    month <- 1 + (quarter - 1) * 3
    as.Date(sprintf("%04d-%02d-01", year, month))
  } else if (f == 48) {
    year <- floor(t)
    offset <- round((t - year) * 365)
    as.Date(sprintf("%04d-01-01", year)) + offset
  } else {
    as.Date(NA)
  }
}

# Stack a named list of series into a long data frame for csv export and inspection.
list_to_long_df <- function(x, stage) {
  parts <- lapply(names(x), function(nm) {
    ser <- x[[nm]]
    data.frame(
      stage = stage,
      series = nm,
      frequency = frequency(ser),
      date = ts_time_to_date(ser),
      time_index = as.numeric(time(ser)),
      value = as.numeric(ser),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, parts)
}

# Summarize each series by its observed date span for quick raw-data checks.
series_span_df <- function(x, stage) {
  do.call(rbind, lapply(names(x), function(nm) {
    ser <- x[[nm]]
    dates <- ts_time_to_date(ser)
    keep <- !is.na(as.numeric(ser)) & !is.na(dates)
    data.frame(
      stage = stage,
      Keys = nm,
      frequency = frequency(ser),
      start_date = if (any(keep)) min(dates[keep]) else as.Date(NA),
      end_date = if (any(keep)) max(dates[keep]) else as.Date(NA),
      stringsAsFactors = FALSE
    )
  }))
}

# Standardize each transformed series and plot all of them on a shared date axis.
plot_standardized_series <- function(long_df, path) {
  plot_df <- long_df |>
    dplyr::filter(!is.na(date), !is.na(value)) |>
    dplyr::group_by(series) |>
    dplyr::mutate(
      value_mean = mean(value, na.rm = TRUE),
      value_sd = stats::sd(value, na.rm = TRUE),
      value_std = dplyr::if_else(
        is.na(value_sd) | value_sd == 0,
        NA_real_,
        (value - value_mean) / value_sd
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::filter(!is.na(value_std))

  if (!nrow(plot_df)) {
    return(invisible(NULL))
  }

  series_names <- unique(plot_df$series)
  color_map <- grDevices::hcl.colors(length(series_names), palette = "Dark 3", alpha = 0.35)
  names(color_map) <- series_names

  grDevices::png(path, width = 1800, height = 1000, res = 150)
  on.exit(grDevices::dev.off(), add = TRUE)

  graphics::plot(
    x = range(plot_df$date),
    y = range(plot_df$value_std, na.rm = TRUE),
    type = "n",
    xlab = "Date",
    ylab = "Mean 0, SD 1",
    main = "Standardized Transformed Series",
    xaxt = "n"
  )
  graphics::axis.Date(1, at = seq(min(plot_df$date), max(plot_df$date), by = "5 years"), format = "%Y")
  graphics::abline(h = 0, col = "grey70", lty = 2)

  invisible(lapply(series_names, function(nm) {
    tmp <- plot_df[plot_df$series == nm, ]
    graphics::lines(tmp$date, tmp$value_std, col = color_map[[nm]], lwd = 1)
  }))
}

# Save one simple history plot per transformed series for quick visual inspection.
plot_series_history_pngs <- function(series_list, out_dir) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  invisible(lapply(names(series_list), function(nm) {
    ser <- trim_ts_na(series_list[[nm]])
    vals <- as.numeric(ser)
    if (!length(vals) || all(is.na(vals))) {
      return(invisible(NULL))
    }
    png(
      filename = file.path(out_dir, paste0(gsub("[^A-Za-z0-9._-]", "_", nm), ".png")),
      width = 1800,
      height = 900,
      res = 150
    )
    graphics::plot(
      ser,
      type = "l",
      lwd = 2,
      col = "#1f77b4",
      main = nm,
      xlab = "Time",
      ylab = "Value"
    )
    graphics::abline(h = 0, col = "grey70", lty = 2)
    grDevices::dev.off()
    invisible(NULL)
  }))
}

# IMPORT DATA -------------------------------------------------------------
# Each import chunk below handles one logical source family. The general pattern is:
# read the raw file, convert dates and values, apply the chosen preprocessing recipe,
# and return a named list that already matches the project key names.

# 1. Legacy postgres bundle:
# keep only the keys that still exist in the metadata, drop the curated FSO retail keys
# that now come from a separate dataset file, and shift KOF balances by +100.
#load(file.path(dataset_dir, "postgres.rda"))
load(file.path(dataset_dir, "postgres_data_new.rda"))
ts_pg <- ts_pg[names(ts_pg) %in% metadata$keys]
fso_keys <- grep("^ch\\.fso\\.rtt\\.ind\\.r\\.noga", metadata$keys, value = TRUE)
interpolate_na <- function(x) {
  if (inherits(x, c("xts", "zoo"))) {
    return(zoo::na.approx(x, na.rm = FALSE))
  }
  
  if (is.ts(x)) {
    z <- zoo::as.zoo(x)
    z <- zoo::na.approx(z, na.rm = FALSE)
    return(stats::as.ts(z))
  }
  
  x
}

ts_pg <- ts_pg[!names(ts_pg) %in% fso_keys]

if ("se.macrobond.chrate0006" %in% names(ts_pg)) {
  saron_raw <- ts_pg[["se.macrobond.chrate0006"]]
  
  ts_pg[["se.macrobond.chrate0006"]] <- if (inherits(saron_raw, c("xts", "zoo"))) {
    trim_ts_na(
      interpolate_na(
        daily2weekly(saron_raw)
      )
    )
  } else {
    interpolate_na(stats::as.ts(saron_raw))
  }
  
  ts_pg[["se.macrobond.chrate0006"]] <- ts_pg[["se.macrobond.chrate0006"]] + 100
}

kof_idx <- grep("^ch\\.kof", names(ts_pg))
if (length(kof_idx)) {
  ts_pg[kof_idx] <- lapply(ts_pg[kof_idx], function(x) {
    interpolate_na(x) + 100
  })
}

# 2. FSO matched retail NOGA monthly series:
# read the curated matched monthly series export and keep only the metadata-listed keys.
fso_raw <- read_delim_auto(file.path(dataset_dir, "fso_series.csv"))
fso_cols <- intersect(names(fso_raw)[names(fso_raw) != "date"], fso_keys)
ts_fso <- lapply(fso_cols, function(col) date_to_monthly_ts(fso_raw[["date"]], fso_raw[[col]]))
names(ts_fso) <- fso_cols

# 3. Datastream monthly macro, bond, and daily equity market files:
# convert macro and bond series to monthly ts objects, apply X-13 to SWCPCOREF,
# and convert daily equity indices to weekly smoothed levels.
econ_raw <- read_delim_auto(file.path(dataset_dir, "datastream_econ.csv"))
econ_map <- c(
  "SW CPI SADJ" = "SWCONPRCE",
  "SW PPI (2025M12=100) SADJ" = "SWPROPRCE",
  "SW CORE INFLATION 1 NADJ" = "SWCPCOREF",
  "SW PURCHASING MANAGERS INDEX SADJ" = "SWPURCHSQ",
  "SW PURCHASING MANAGERS INDEX - BACKLOG OF ORDERS SADJ" = "SWPMIORDQ",
  "SW PURCHASING MANAGERS INDEX - OUTPUT SADJ" = "SWPMIPROQ"
)
# BFS publishes CPI and PPI unadjusted (wai-webapp bfs_prices/). When the file
# carries those instead of Datastream's adjusted columns, they are adjusted
# here with the same X-13 step as SWCPCOREF, from 1985 on: X-13 takes at most
# 780 observations, and the BFS CPI starts in 1921.
nadj_cols <- c("SW CPI SADJ" = "SW CPI NADJ", "SW PPI (2025M12=100) SADJ" = "SW PPI (2025M12=100) NADJ")
x13_keys <- "SWCPCOREF"
for (sadj in names(nadj_cols)) {
  if (!sadj %in% names(econ_raw) && nadj_cols[[sadj]] %in% names(econ_raw)) {
    names(econ_map)[names(econ_map) == sadj] <- nadj_cols[[sadj]]
    x13_keys <- c(x13_keys, econ_map[[nadj_cols[[sadj]]]])
  }
}
ts_ds_econ <- lapply(names(econ_map), function(col) date_to_monthly_ts(econ_raw[[1]], econ_raw[[col]]))
names(ts_ds_econ) <- unname(econ_map)
for (k in x13_keys) {
  x <- trim_ts_na(ts_ds_econ[[k]])
  if (stats::start(x)[1] < 1985) x <- stats::window(x, start = c(1985, 1))
  ts_ds_econ[[k]] <- seasonally_adjust_monthly_x13(x)
}

bond_raw <- read_delim_auto(file.path(dataset_dir, "datastream_swiss_bonds.csv"))
ts_ds_bonds <- list(SWGBOND. = date_to_monthly_ts(bond_raw[[1]], bond_raw[[2]]))
ts_ds_bonds[["SWGBOND."]] <- ts_ds_bonds[["SWGBOND."]] + 100

smi_raw <- read_delim_auto(file.path(dataset_dir, "datastream_SMI.csv"))
smi_map <- c(
  "SWITZ-DS Financials - PRICE INDEX" = "FINANSW",
  "SWITZ-DS Industrials - PRICE INDEX" = "INDUSSW",
  "SWISS MARKET (SMI) - PRICE INDEX" = "SWISSMI"
)
ts_ds_smi <- lapply(names(smi_map), function(col) {
  agg <- aggregate_duplicate_dates(parse_date_multi(smi_raw[[1]]), smi_raw[[col]], fun = "mean")
  daily_ma7_to_weekly(agg$date, agg$x)
})
names(ts_ds_smi) <- unname(smi_map)

# 3b. VIX daily market volatility index:
# aggregate the daily VIX observations to the project's weekly frequency.
# dataset_dir, not a separate data/VIX/ folder. This was the only one of the 21
# raw inputs read from somewhere other than dataset_dir, which is the kind of
# lone exception that makes a pipeline fail on a fresh machine for no reason.
vix_raw <- read_delim_auto(file.path(dataset_dir, "VIX.csv"))
vix_daily <- aggregate_duplicate_dates(parse_date_multi(vix_raw[["Date"]]), vix_raw[["Indexvalue"]], fun = "mean")
ts_vix <- list(VIX = daily_to_weekly(vix_daily$date, vix_daily$x))

ts_ds_adj <- c(ts_ds_bonds, ts_ds_econ, ts_ds_smi, ts_vix)

# 4. Trendecon and Google Trends:
# apply the agreed daily MSTL-plus-MA7 preprocessing and aggregate to weekly.
trendecon_raw <- read_delim_auto(file.path(dataset_dir, "trendecon_sa.csv"))
ts_te <- list(trendecon = daily_mstl_ma7_to_weekly(parse_date_multi(trendecon_raw[[1]]), trendecon_raw[[2]]) + 100)

gt_raw <- read_delim_auto(file.path(dataset_dir, "google_trends_Arbeitsmarkt_sa.csv"))
ts_gt <- list(Arbeitsmarkt = daily_mstl_ma7_to_weekly(parse_date_multi(gt_raw[[1]]), gt_raw[[2]]) + 100)

# 5. KTZH mobility, payment, and retail files:
# apply the source-specific timing, seasonal-adjustment, and smoothing decisions
# that were selected during the legacy-versus-dataset comparison review.
cash_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_ATM_Cash_Withdrawals_Swiss_Wide_Daily.csv"))
kk_raw <- read_delim_auto(file.path(dataset_dir, "Swiss_Consumption_anz_kktrans_ch.csv"))
hard_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_daily_frequency_hardbruecke.csv"))
debit_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_debit_ausland_SIX.csv"))
intervista_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_intervista_median_distance.csv"))
miv_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_Mobility_CarTraffic_indexed.csv"))
hb_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_Mobility_SBBHauptbahnhof.csv"))
retail_raw <- read_delim_auto(file.path(dataset_dir, "ktzh_non_online_retail.csv"))

hard_daily <- aggregate_duplicate_dates(parse_date_multi(hard_raw[[1]]), as.numeric(hard_raw[["total_in"]]) + as.numeric(hard_raw[["total_out"]]), fun = "sum")
hb_daily <- aggregate_duplicate_dates(parse_date_multi(hb_raw[[1]]), hb_raw[["value"]], fun = "sum")
retail_daily <- aggregate_duplicate_dates(parse_date_multi(retail_raw[[1]]), retail_raw[[2]], fun = "mean")
retail_weekly <- daily_retail_mstl_weekly(retail_daily$date, retail_daily$x)
# retail_weekly <- daily_retail_mstl_trend_weekly(retail_daily$date, retail_daily$x)

# anz_kktrans_ch: the legacy SPA file is weekly (2020 only) and keeps its step
# rule. Worldline's credit-card transaction count (wai-webapp worldline/) is
# daily, like stat_einkauf, and gets stat_einkauf's daily MSTL treatment.
kk_dates <- parse_date_multi(kk_raw[[1]])
kk_daily <- stats::median(as.numeric(diff(sort(unique(kk_dates[!is.na(kk_dates)])))), na.rm = TRUE) == 1
kk_weekly <- if (kk_daily) {
  kk_agg <- aggregate_duplicate_dates(kk_dates, kk_raw[[2]], fun = "mean")
  daily_retail_mstl_weekly(kk_agg$date, kk_agg$x)
} else {
  weekly_step_to_daily_then_weekly(kk_raw[[1]], kk_raw[[2]])
}

ts_ktzh <- list(
  bezug_bargeld = daily_mstl_monthly_to_weekly(parse_date_multi(cash_raw[[1]]), cash_raw[[2]]),
  anz_kktrans_ch = kk_weekly,
  oev_freq_hardbruecke = daily_to_weekly(hard_daily$date, hard_daily$x),
  debiteinsatz_ausland = daily_mstl_annual_to_weekly(parse_date_multi(debit_raw[["date"]]), debit_raw[["value"]]),
  tages_distanz_median = daily_to_weekly(parse_date_multi(intervista_raw[["date"]]), intervista_raw[["value"]]),
  aufkommen_miv = daily_mstl_monthly_to_weekly(parse_date_multi(miv_raw[["date"]]), miv_raw[["value"]]),
  oev_freq_hb = daily_to_weekly(hb_daily$date, hb_daily$x),
  stat_einkauf = retail_weekly
)

# 6. ASTRA road traffic:
# use the active non-detrended weekly level specification, with the detrended option
# left commented directly below for quick switching.
astra_raw <- read_delim_auto(file.path(dataset_dir, "ASTRA_traffic_extended.csv"))
traffic_dates <- parse_date_multi(astra_raw[[1]])
ts_traffic <- list(
  traffic_PW = daily_mstl_monthly_ma7_weekly(traffic_dates, astra_raw[["PW+.Busse/Car"]]),
  # traffic_PW = daily_mstl_monthly_ma7_detrend_weekly(traffic_dates, astra_raw[["PW+.Busse/Car"]]),
  traffic_LW = daily_mstl_monthly_ma7_weekly(traffic_dates, astra_raw[["LW"]])
  # traffic_LW = daily_mstl_monthly_ma7_detrend_weekly(traffic_dates, astra_raw[["LW"]])
)

# 7. Destatis truck toll:
# aggregate the corrected daily series directly to weekly.
truck_raw <- read_delim_auto(file.path(dataset_dir, "Destatis_Truck_toll_mileage.csv"))
truck_daily <- aggregate_duplicate_dates(parse_date_multi(truck_raw[[1]]), truck_raw[[2]], fun = "mean")
ts_trucktoll_DE <- list("Lkw-Maut-Fahrleistungsindex_DE" = daily_to_weekly(truck_daily$date, truck_daily$x))

# 8. Swissgrid electricity flows:
# seasonally adjust daily data, smooth it, and then aggregate to weekly.
swissgrid_raw <- read_delim_auto(file.path(dataset_dir, "swissgrid_2009_2025.csv"))
swissgrid_dates <- parse_date_multi(swissgrid_raw[[1]])
swissgrid_out <- daily_mstl_ma7_to_weekly(swissgrid_dates, swissgrid_raw[["out.ch"]])
swissgrid_in <- daily_mstl_ma7_to_weekly(swissgrid_dates, swissgrid_raw[["in.ch"]])
ts_swissgrid_data <- list(
  electricity_out = swissgrid_out,
  electricity_in = swissgrid_in
)

# 9. Zurich Airport arrivals and departures:
# aggregate the daily counts to weekly totals and then apply weekly seasonal adjustment.
airport_raw <- read_delim_auto(file.path(dataset_dir, "Flughafen_ZH_daily_anfluege_abfluege.csv"))
arrivals_daily <- aggregate_duplicate_dates(parse_date_multi(airport_raw[["date"]]), airport_raw[["total_anfluege"]], fun = "sum")
departures_daily <- aggregate_duplicate_dates(parse_date_multi(airport_raw[["date"]]), airport_raw[["total_abfluege"]], fun = "sum")
ts_airport_data <- list(
  zrh_airport_departure = seasonally_adjust_weekly(daily_to_weekly(departures_daily$date, departures_daily$x)),
  zrh_airport_arrivals = seasonally_adjust_weekly(daily_to_weekly(arrivals_daily$date, arrivals_daily$x))
)

# 10. Google mobility:
# remove daily weekly/monthly/annual seasonality, smooth with a 7-day moving average,
# aggregate to weekly, and shift by +100 to preserve the legacy baseline convention.
google_raw <- read_delim_auto(file.path(dataset_dir, "Google_Switzerland_Mobility_Report_total.csv"))
keys_g <- c(
  "retail_and_recreation_percent_change_from_baseline",
  "grocery_and_pharmacy_percent_change_from_baseline",
  "parks_percent_change_from_baseline",
  "transit_stations_percent_change_from_baseline",
  "workplaces_percent_change_from_baseline",
  "residential_percent_change_from_baseline"
)
google_dates <- parse_date_multi(google_raw[["date"]])
ts_google_mobility <- lapply(keys_g, function(col) {
  vals <- as.numeric(google_raw[[col]])
  daily_mstl_monthly_ma7_to_weekly(google_dates, vals) + 100
})
names(ts_google_mobility) <- paste0("mobility_", sub("_percent_change_from_baseline", "", keys_g, fixed = TRUE))

# COMBINE RAW DATA --------------------------------------------------------
# Combine all harmonized source blocks, reorder them to the metadata key order,
# and export the pre-transformation dataset in both Rda and csv form.

# Merge all raw source blocks into the metadata-defined series order and export them once.
dat_raw <- c(
  ts_fso,
  ts_ds_adj,
  ts_pg,
  ts_te,
  ts_ktzh,
  ts_gt,
  ts_traffic,
  ts_trucktoll_DE,
  ts_swissgrid_data,
  ts_airport_data,
  ts_google_mobility
)
dat_raw <- dat_raw[intersect(metadata$keys, names(dat_raw))]

raw_long <- list_to_long_df(dat_raw, "raw")
raw_spans <- series_span_df(dat_raw, "raw")
save(dat_raw, raw_long, file = file.path(rda_dir, paste0("data_ch_dataset_raw", raw_suffix, ".Rda")))
utils::write.csv(raw_long, file = file.path(out_dir, paste0("data_ch_dataset_raw", raw_suffix, ".csv")), row.names = FALSE)
utils::write.csv(raw_spans, file = file.path(out_dir, paste0("data_ch_dataset_raw_start_end", raw_suffix, ".csv")), row.names = FALSE)

# TRANSFORMATIONS ---------------------------------------------------------
# Apply the metadata transformation exactly once to each harmonized weekly/monthly/quarterly
# series. The script mirrors the legacy logic so later model code can use the dataset output
# exactly like the old prep file output.

# Apply the metadata-defined transformations exactly once to each harmonized raw series.
dat_adj <- lapply(names(dat_raw), function(ix) {
  x <- dat_raw[[ix]]
  tr <- metadata$Transformation[metadata$keys == ix]
  if (tr == "None") {
    out <- x
  } else if (tr == "Log Difference") {
    out <- diff(log(x))
  } else if (tr == "Year-on-Year, Detr.") {
    freq <- frequency(x)
    x_adj <- diff(log(x), lag = freq)
    out <- x_adj - stats::ts(
      roll_mean_right(x_adj, 3 * freq),
      start = stats::start(x_adj),
      frequency = freq
    )
  } else if (tr == "Detrended") {
    freq <- frequency(x)
    out <- x - stats::ts(
      roll_mean_right(x, 3 * freq),
      start = stats::start(x),
      frequency = freq
    )
  } else {
    stop("Unknown transformation for ", ix, ": ", tr)
  }
  out
})
names(dat_adj) <- names(dat_raw)

# CUT SERIES AND SAVE -----------------------------------------------------
# Trim transformed series to the legacy sample window, split them into flow and stock blocks,
# export the final dataset objects, and create overview plots including one png per series.

# Trim the transformed series to the legacy sample window and export the final outputs.
dat_final <- lapply(dat_adj, function(x) {
  # Only window when it would actually cut something. 46 of the 52 series begin
  # after 1990, and window() warns "'start' value not changed" for each of those
  # - 37 identical warnings in a full run, carrying no information. Same reasoning
  # as trim_to() in R/backcast.R: a step that warns on its ordinary case teaches
  # people to ignore its warnings, and then a real one goes unread.
  if (as.numeric(stats::time(x))[1] < 1990) x <- stats::window(x, start = 1990)
  trim_ts_na(x)
})

# Restore quarterly GDP to the dataset using the same real-time vintage logic as in 0_test.R.
target <- "ch.seco.gdp.real.gdp.ssa"
sample_end_gdp_vintage_date <- as.Date(Sys.getenv("MFBDFM_GDP_VINTAGE_DATE", "2026-03-07"))
sample_end_gdp_vintage_decimal <- round(
  as.numeric(format(sample_end_gdp_vintage_date, "%Y")) +
    (as.numeric(format(sample_end_gdp_vintage_date, "%m")) - 1) / 12 +
    as.numeric(format(sample_end_gdp_vintage_date, "%d")) / 365,
  3
)
# The vintages come from this repository's SECO pipeline (seco_gdp/), not from
# the copy shipped inside the installed mfbdfm package.
gdp_dir <- Sys.getenv("MFBDFM_GDP_DIR", file.path(project_dir, "seco_gdp"))
GDP_gr_vintages_quarterly <- get_real_time_gdp_vintages(
  "quarterly",
  gdp_file_path = file.path(gdp_dir, "realtime_gdp.csv"),
  gdp_cssa_file_path = file.path(gdp_dir, "realtime_gdp_cssa.csv")
)
gdp_vintage_names <- names(GDP_gr_vintages_quarterly)[-1]
gdp_vintage_numbers <- suppressWarnings(as.numeric(gdp_vintage_names))
valid_gdp_idx <- which(
  !is.na(gdp_vintage_numbers) &
    gdp_vintage_numbers >= 2005.438 &
    gdp_vintage_numbers <= sample_end_gdp_vintage_decimal
)
if (!length(valid_gdp_idx)) {
  stop("No valid quarterly GDP vintage found for ch.seco.gdp.real.gdp.ssa.")
}
sample_end_gdp_vintage <- gdp_vintage_numbers[valid_gdp_idx][which.max(gdp_vintage_numbers[valid_gdp_idx])]
x_hist_gr <- ts(
  GDP_gr_vintages_quarterly[[as.character(sample_end_gdp_vintage)]],
  start = c(1990, 1),
  frequency = 4
)
dat_final[[target]] <- trim_ts_na(x_hist_gr)

final_long <- list_to_long_df(dat_final, "transformed")

types <- setNames(metadata$Flow, metadata$keys)
types <- types[names(types) %in% names(dat_final)]
dat <- list(
  flows = dat_final[names(types)[types == 1]],
  stocks = dat_final[names(types)[types == 0]]
)

save(dat, dat_final, final_long, file = file.path(rda_dir, paste0("data_ch_dataset_", prep_tag, ".Rda")))
utils::write.csv(final_long, file = file.path(out_dir, paste0("data_ch_dataset_", prep_tag, ".csv")), row.names = FALSE)
plot_standardized_series(final_long, file.path(out_dir, paste0("data_ch_dataset_", prep_tag, "_standardized.png")))
plot_series_history_pngs(dat_final, file.path(out_dir, paste0("series_history", raw_suffix)))
