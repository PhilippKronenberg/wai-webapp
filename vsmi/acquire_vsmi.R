# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the VSMI volatility index (the WAI input called "VIX") (#50)
#
# The WAI's input "VIX" is SIX's VSMI (ISIN CH0019900841, symbol V3X), the
# 30-day implied volatility of the SMI from Eurex SMI options. This script
# appends the days after the fixed history (wai_ind's data/VIX/VIX.csv,
# read-only) with SIX's daily closes, and writes the result in the same
# layout (Date;ISIN;Indexvalue).
#
# Source
#   SIX, the request behind the chart on
#   https://www.six-group.com/en/market-data/indices/global/strategy/vsmi-volatility.html
#   https://www.six-group.com/fqs/charts.json?select=ValorId,ValorSymbol
#     &where=ValorId=CH0019900841CHF9&columns=Date,Time,Close,Open,High,Low,TotalVolume
#     &netting=1440&fromdate=YYYYMMDD&todate=YYYYMMDD
#   Daily closes since 1999-01-04. The keys are lowercase (fromdate, todate);
#   with camelCase the endpoint ignores them and returns only the last day.
#   "(c) SIX Group Ltd. All rights reserved": the output is not committed.
#
# Checks (a failed check stops the run)
#   1. SIX answers for ISIN CH0019900841.
#   2. On the overlap, SIX's closes equal the history (median absolute
#      relative difference below 1e-4; SIX's chart rounds early years).
#   3. The newest day is at most 7 days old.
#
# Usage
#   Rscript vsmi/acquire_vsmi.R [<history csv>]
#   default history: ../wai_ind/data/VIX/VIX.csv
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

isin <- "CH0019900841"
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
chart_url <- function(from, to) {
  paste0("https://www.six-group.com/fqs/charts.json?select=ValorId,ValorSymbol",
         "&where=ValorId=", isin, "CHF9",
         "&columns=Date,Time,Close,Open,High,Low,TotalVolume&netting=1440",
         "&fromdate=", format(from, "%Y%m%d"), "&todate=", format(to, "%Y%m%d"))
}

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "vsmi"
})
out_file <- file.path(script_dir, "VIX.csv")
args <- commandArgs(trailingOnly = TRUE)
history_file <- if (length(args)) args[1] else
  file.path(script_dir, "..", "..", "wai_ind", "data", "VIX", "VIX.csv")


# RUN ---------------------------------------------------------------------

hist <- utils::read.csv2(history_file, dec = ".", stringsAsFactors = FALSE)
if (!all(c("Date", "ISIN", "Indexvalue") %in% names(hist)) || any(hist$ISIN != isin))
  stop("the history is not the VSMI file (Date;ISIN;Indexvalue, ISIN ", isin, ")")
hist$date <- as.Date(hist$Date, "%d.%m.%Y")

f <- tempfile(fileext = ".json")
utils::download.file(chart_url(as.Date("1999-01-01"), Sys.Date()), f, quiet = TRUE, method = "libcurl",
                     headers = c(`User-Agent` = user_agent))
j <- jsonlite::fromJSON(f)
if (!length(j$valors) || is.null(j$valors$data)) stop("SIX returned no data for ", isin)
d <- j$valors$data
six <- data.frame(date = as.Date(as.character(d$Date[[1]]), "%Y%m%d"), close = as.numeric(d$Close[[1]]))
six <- six[!is.na(six$date) & !is.na(six$close), ]
message(sprintf("SIX: %d days, %s to %s", nrow(six), min(six$date), max(six$date)))
if (Sys.Date() - max(six$date) > 7) stop("newest SIX day ", max(six$date), " is more than 7 days old")

m <- merge(hist, six, by = "date")
rel <- abs(m$close / m$Indexvalue - 1)
message(sprintf("  vs history (to %s): %d common days, median |rel diff| %.1e, identical to 4 decimals %.1f%%",
                max(hist$date), nrow(m), stats::median(rel), 100 * mean(rel < 1e-6)))
if (stats::median(rel) > 1e-4) stop("SIX's closes do not match the history")

new <- six[six$date > max(hist$date), ]
out <- rbind(data.frame(Date = hist$Date, ISIN = isin, Indexvalue = hist$Indexvalue),
             data.frame(Date = format(new$date, "%d.%m.%Y"), ISIN = isin, Indexvalue = new$close))
utils::write.table(out, out_file, sep = ";", row.names = FALSE, quote = FALSE)
message(sprintf("wrote %s: history to %s + %d new days to %s", out_file, max(hist$date), nrow(new),
                max(new$date)))
