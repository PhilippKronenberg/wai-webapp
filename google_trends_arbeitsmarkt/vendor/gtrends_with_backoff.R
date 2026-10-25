gtrends_with_backoff <- function(keyword = NA,
                                 geo = "ch",
                                 time = "today+5-y",
                                 gprop = "web",
                                 category = "0",
                                 hl = "en-US",
                                 low_search_volume = FALSE,
                                 cookie_url = "http://trends.google.com/Cookies/NID",
                                 tz = 0,
                                 onlyInterest = FALSE,
                                 retry = 5,
                                 wait = 5,
                                 quiet = FALSE,
                                 attempt = 1,
                                 use_proxy = NULL) {
  is_rate_limit_error <- function(msg) {
    grepl("429|too many requests|rate limit|too soon|quota", msg, ignore.case = TRUE)
  }
  
  # Configure proxy if requested or set via environment variable
  if (attempt == 1) {
    proxy_url <- use_proxy
    if (is.null(proxy_url)) {
      proxy_url <- Sys.getenv("WAI_PROXY", unset = NA)
    }
    if (!is.na(proxy_url) && nzchar(proxy_url)) {
      # Set proxy for both http and https
      Sys.setenv(http_proxy = proxy_url)
      Sys.setenv(https_proxy = proxy_url)
      if (!quiet) {
        message("[PROXY] Using proxy: ", proxy_url)
      }
    }
  }
  msg <- function(...) {
    if (!quiet) {
      message(...)
    }
  }

  if (attempt > retry) {
    stop("Retries exhausted!")
  }

  if (attempt == 1) {
    msg("Downloading data for ", time)
  } else {
    msg("Attempt ", attempt, "/", retry)
  }
  tryCatch(
    gtrends(
      keyword = keyword, geo = geo, time = time, gprop = gprop,
      category = category, hl = hl,
      low_search_volume = low_search_volume, cookie_url = cookie_url,
      tz = tz, onlyInterest = onlyInterest
    ),
    error = function(e) {
      err_msg <- conditionMessage(e)
      if (grepl("No data returned by the query", err_msg, fixed = TRUE)) {
        msg("No data returned for this window; continuing with an empty result.")
        return(list(interest_over_time = NULL))
      }
      if (grepl("== 200", err_msg, fixed = TRUE) || is_rate_limit_error(err_msg)) {
        if (attempt == 1) {
          msg("Google Trends rejected the request, backing off...")
        } else {
          msg("Still blocked by Google Trends...")
        }

        jitter <- stats::runif(1, min = 0, max = max(wait, 1))
        t <- ceiling(wait * (2 ^ (attempt - 1)) + jitter)

        msg("Waiting for ", t, " seconds")
        Sys.sleep(t)
        msg("Retrying...")

        # Error handling by recurshian... xD
        # TODO: Could replace this with a while(attemt < retry && !is.tibble(result)) { result <- tryCatch(call, error = function(e) FALSE)}
        # construct. easier on the stack if retry gets large
        gtrends_with_backoff(
          keyword,
          geo,
          time,
          gprop,
          category,
          hl,
          low_search_volume,
          cookie_url,
          tz,
          onlyInterest,
          retry,
          wait,
          quiet,
          attempt + 1,
          use_proxy
        )
      } else {
        stop(e)
      }
    }
  )
}
