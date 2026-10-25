# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the market series SMI and VIX (#50)
#
#   smi_daily.csv   SMI price index, daily close    -> SWISSMI
#                   Yahoo Finance chart endpoint, symbol ^SSMI, from 1990-11-09.
#                   NOT committed (see README): SIX licenses index data and
#                   Yahoo's terms do not allow redistribution.
#   vix_daily.csv   CBOE Volatility Index (VIX), daily close
#                   CBOE's own history file; FRED (VIXCLS, the same CBOE close)
#                   as fallback. From 1990-01-02.
#
# Note: the series wai_ind calls "VIX" (data/VIX/VIX.csv) is SIX's VSMI
# (ISIN CH0019900841), not the CBOE VIX; see README.
#
# Usage
#   Rscript markets/acquire_markets.R
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
smi_url <- paste0("https://query1.finance.yahoo.com/v8/finance/chart/%5ESSMI?period1=0&period2=",
                  as.integer(Sys.time()), "&interval=1d")
vix_urls <- c(cboe = "https://cdn.cboe.com/api/global/us_indices/daily_prices/VIX_History.csv",
              fred = "https://fred.stlouisfed.org/graph/fredgraph.csv?id=VIXCLS")

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "markets"
})


# HELPERS -----------------------------------------------------------------

fetch <- function(url) {
  dest <- tempfile()
  utils::download.file(url, dest, mode = "wb", quiet = TRUE, method = "libcurl",
                       headers = c(`User-Agent` = user_agent))
  dest
}

check_series <- function(d, name, max_age = 7) {
  if (anyNA(d$date) || anyDuplicated(d$date)) stop(name, ": missing or duplicate dates")
  if (any(d$close <= 0)) stop(name, ": non-positive values")
  if (Sys.Date() - max(d$date) > max_age) stop(name, ": newest date ", max(d$date), " is too old")
  message(sprintf("%s: %d days, %s to %s", name, nrow(d), min(d$date), max(d$date)))
}


# SMI ---------------------------------------------------------------------

j <- jsonlite::fromJSON(fetch(smi_url))
r <- j$chart$result
if (is.null(r) || r$meta$symbol != "^SSMI") stop("SMI: unexpected reply from Yahoo")
# Trading dates in Zurich time; Yahoo stamps the session open.
smi <- data.frame(date = as.Date(as.POSIXct(r$timestamp[[1]], origin = "1970-01-01", tz = "Europe/Zurich")),
                  close = r$indicators$quote[[1]]$close[[1]])
smi <- smi[!is.na(smi$close), ]
smi <- smi[!duplicated(smi$date, fromLast = TRUE), ]
check_series(smi, "SMI")
write.csv(smi, file.path(script_dir, "smi_daily.csv"), row.names = FALSE, quote = FALSE)


# VIX ---------------------------------------------------------------------

vix <- NULL
for (src in names(vix_urls)) {
  vix <- tryCatch({
    x <- utils::read.csv(fetch(vix_urls[[src]]))
    if (src == "cboe") data.frame(date = as.Date(x$DATE, "%m/%d/%Y"), close = as.numeric(x$CLOSE))
    else data.frame(date = as.Date(x[[1]]), close = suppressWarnings(as.numeric(x[[2]])))
  }, error = function(e) { message("VIX: ", src, " failed: ", conditionMessage(e)); NULL })
  if (!is.null(vix)) { message("VIX: from ", src); break }
}
if (is.null(vix)) stop("VIX: no source reachable")
vix <- vix[!is.na(vix$close), ]
check_series(vix, "VIX")
write.csv(vix, file.path(script_dir, "vix_daily.csv"), row.names = FALSE, quote = FALSE)
