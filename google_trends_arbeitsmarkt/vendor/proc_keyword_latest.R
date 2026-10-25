#' Download latest data
#'
#' Downloads latest daily, weekly, and monthly data.
#'
#' @inheritParams ts_gtrends_windows
#' @param keyword A single keyword for which to process the data.
#' @param geo A character vector denoting the geographic region.
#'     Default is "CH".
#' @seealso [ts_gtrends_windows]
#'
#' @section Daily data:
#'     Downloads data for the last 90 days in two windows, with the same end
#'    date (today) but start date shifted by one day. File saved as
#'    `{keyword}_d_{today}.csv` in folder `data-raw/indicator_raw`.
#'
#' @section Weekly data:
#'     Downloads weekly data for two windows, first window starts 1 year ago,
#'     second window offset by one week, both windows end today. File saved
#'     as `{keyword}_w_{today}.csv` in folder `data-raw/indicator_raw`.
#'
#' @section Monthly data:
#'     Downloads monthly data for two windows, first window starts at
#'     2006-01-01, second window offset by  1 month, both windows end today.
#'     File saved as `{keyword}_m_{today}.csv` in folder
#'     `data-raw/indicator_raw`.
#'
proc_keyword_latest <- function(keyword = "Insolvenz",
                                geo = "CH",
                                n_windows = 2,
                                from = NULL) {
  today <- Sys.Date()
  is_rate_limit_error <- function(msg) {
    grepl("429|too many requests|rate limit|too soon|quota", msg, ignore.case = TRUE)
  }
  
  # Read environment variables for rate-limiting
  wait_val <- as.integer(Sys.getenv("WAI_WAIT", unset = "60"))
  retry_val <- as.integer(Sys.getenv("WAI_RETRY", unset = "8"))
  
  # If from is not specified, start from the latest existing data
  if (is.null(from)) {
    existing_sa <- tryCatch(
      {suppressWarnings(read_keyword(keyword, geo, "sa"))},
      error = function(e) NULL
    )
    if (!is.null(existing_sa) && nrow(existing_sa) > 0) {
      from <- max(existing_sa$time, na.rm = TRUE) + 1
      message("Auto-detecting start date from existing data: ", from)
    } else {
      from <- seq(today, length.out = 2, by = "-90 days")[2]
      message("No existing data found; using default 90-day window")
    }
  }
  from_date <- as.Date(from)
  stale_gap_days <- as.numeric(today - from_date)
  if (is.na(stale_gap_days)) {
    stale_gap_days <- 0
  }
  restart_from_raw <- function(suffix, step_days) {
    tryCatch(
      {
        x <- read_keyword(keyword, geo, suffix) %>%
          mutate(time = as.Date(time)) %>%
          filter(!is.na(time)) %>%
          distinct(time, .keep_all = TRUE) %>%
          arrange(time)

        if (nrow(x) == 0) {
          return(list(start = from_date, has_internal_gap = FALSE))
        }

        gaps <- as.integer(diff(x$time))
        gap_idx <- which(gaps > step_days)
        if (length(gap_idx) > 0) {
          list(
            start = x$time[min(gap_idx)] + step_days,
            has_internal_gap = TRUE
          )
        } else {
          list(
            start = max(x$time, na.rm = TRUE) + step_days,
            has_internal_gap = FALSE
          )
        }
      },
      error = function(e) list(start = as.Date(NA), has_internal_gap = FALSE)
    )
  }
  daily_restart <- restart_from_raw("d", 1)
  weekly_restart <- restart_from_raw("w", 7)
  daily_restart_from <- daily_restart$start
  weekly_restart_from <- weekly_restart$start

  enhance_keyword <- function(data, keyword, geo, suffix){
    old <- tryCatch(
      read_keyword(keyword, geo, suffix) %>%
        mutate(n = as.integer(n)),
      error = function(e) NULL
    )
    new <- aggregate_windows(data)
    # Google picks the resolution from the length of the requested range
    # (hourly < 7 days, daily < ~9 months, weekly < 5 years, then monthly). A
    # window of the wrong length returns the wrong frequency, and merging it
    # into the cache corrupts the file for every later run. (wai-webapp #50)
    steps <- as.numeric(diff(sort(unique(as.Date(new$time)))))
    expected <- switch(suffix, d = c(1, 1), w = c(7, 7), m = c(28, 31))
    if (length(steps) && (min(steps) < expected[1] || max(steps) > expected[2])) {
      stop(sprintf("downloaded '%s' data for %s has steps of %s days; not writing it to the cache",
                   suffix, keyword, paste(range(steps), collapse = "-")))
    }
    if (is.null(old) || nrow(old) == 0) {
      write_keyword(new, keyword, geo, suffix)
    } else {
      write_keyword(aggregate_averages(old, new), keyword, geo, suffix)
    }
  }

  safe_download <- function(label, code) {
    tryCatch(
      {
        code
        TRUE
      },
      error = function(e) {
        err_msg <- conditionMessage(e)
        if (is_rate_limit_error(err_msg)) {
          message("  RATE LIMITED during ", label, ": ", err_msg)
          return(FALSE)
        }
        stop(e)
      }
    )
  }

  message("Downloading keyword: ", keyword)
  status <- c(hourly = FALSE, daily = FALSE, weekly = FALSE, monthly = FALSE)

  message("Downloading hourly data")
  status["hourly"] <- safe_download("hourly", {
    h <- ts_gtrends(
      keyword = keyword,
      geo = geo,
      time = "now 7-d",
      wait = wait_val,
      retry = retry_val
    )
    h <- h %>%
      group_by(time) %>%
      summarize(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      mutate(n = 1L)
    # NOTE: this data is intentionally not re-written on every update, not aggregated with the rest
    write_keyword(h, keyword, geo, "h")
  })

  message("Downloading daily data")
  if (stale_gap_days > 120) {
    daily_from <- if (!is.na(daily_restart_from)) daily_restart_from else from_date
    daily_stepsize <- "15 days"
    daily_windowsize <- "6 months"
    daily_n_windows <- max(n_windows, ceiling(as.numeric(today - daily_from) / 15))
  } else {
    # min, not max: the window must be at least 90 days long to come back as
    # daily data (a few days would come back hourly). (wai-webapp #50)
    daily_from <- min(
      if (!is.na(daily_restart_from)) daily_restart_from else from_date,
      seq(today, length.out = 2, by = "-90 days")[2]
    )
    daily_stepsize <- "1 day"
    daily_windowsize <- "3 months"
    daily_n_windows <- n_windows
  }
  message(sprintf(
    "  Daily: downloading from %s to %s using stepsize=%s windowsize=%s (%s windows)",
    daily_from, today, daily_stepsize, daily_windowsize, daily_n_windows
  ))
  if (daily_from >= today) {
    message("  Daily archive already covers today; skipping download")
    status["daily"] <- TRUE
  } else {
    status["daily"] <- safe_download("daily", {
      d <- ts_gtrends_windows(
        keyword = keyword,
        geo = geo,
        from = daily_from,
        stepsize = daily_stepsize, windowsize = daily_windowsize,
        n_windows = daily_n_windows, wait = wait_val, retry = retry_val,
        prevent_window_shrinkage = stale_gap_days > 120
      )
      enhance_keyword(d, keyword, geo, "d")
    })
  }

  message("Downloading weekly data")
  if (stale_gap_days > 370) {
    weekly_from <- if (!is.na(weekly_restart_from)) weekly_restart_from else from_date
    weekly_stepsize <- "11 weeks"
    weekly_windowsize <- "5 years"
    weekly_n_windows <- max(n_windows, ceiling(as.numeric(today - weekly_from) / (11 * 7)))
  } else {
    # min, not max: under ~9 months Google returns daily data. (wai-webapp #50)
    weekly_from <- min(
      if (!is.na(weekly_restart_from)) weekly_restart_from else from_date,
      seq(today, length.out = 2, by = "-1 year")[2]
    )
    weekly_stepsize <- "1 week"
    weekly_windowsize <- "1 year"
    weekly_n_windows <- n_windows
  }
  message(sprintf(
    "  Weekly: downloading from %s to %s using stepsize=%s windowsize=%s",
    weekly_from, today, weekly_stepsize, weekly_windowsize
  ))
  if (weekly_from >= today) {
    message("  Weekly archive already covers today; skipping download")
    status["weekly"] <- TRUE
  } else {
    status["weekly"] <- safe_download("weekly", {
      w <- ts_gtrends_windows(
        keyword = keyword,
        geo = geo,
        from = weekly_from,
        stepsize = weekly_stepsize, windowsize = weekly_windowsize,
        n_windows = weekly_n_windows, wait = wait_val, retry = retry_val,
        prevent_window_shrinkage = stale_gap_days > 370
      )
      enhance_keyword(w, keyword, geo, "w")
    })
  }

  message("Downloading monthly data")
  # Keep the full-history monthly anchor so Google returns a lower-frequency series.
  # Windows from 2006 that run to today, as in trendecon: a 15-year window
  # from 2006 ends around 2021 and never reaches the present, so the monthly
  # data stopped updating; "30 years" is cut at today. (wai-webapp #50)
  monthly_from <- "2006-01-01"
  monthly_n_windows <- n_windows
  message(sprintf("  Monthly: downloading from %s to %s", monthly_from, today))
  status["monthly"] <- safe_download("monthly", {
    m <- ts_gtrends_windows(
      keyword = keyword,
      geo = geo,
      from = monthly_from,
      stepsize = "1 month", windowsize = "30 years",
      n_windows = monthly_n_windows, wait = wait_val, retry = retry_val,
      prevent_window_shrinkage = FALSE
    )
    enhance_keyword(m, keyword, geo, "m")
  })

  invisible(status)
}
