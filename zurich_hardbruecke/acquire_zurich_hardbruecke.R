# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the passenger counts at Zurich Hardbrücke (oev_freq_hardbruecke) (#50)
#
# Downloads the City of Zurich's yearly files of the VBZ passenger counters
# at Hardbrücke station (frequenzen_hardbruecke_<year>.csv, 2020 to the
# current year) and builds the daily totals wai_ind reads as
# data/dataset/ktzh_daily_frequency_hardbruecke.csv:
#
#   date, total_in, total_out   persons entering and leaving, all counting lines
#
# The aggregation is that of wai_ind's
# data/oev_frequency_SBB_hard/create_daily_frequency_hardbruecke.R (sum per
# timestamp and line, then per day, days cut in UTC), itself based on the
# Canton of Zurich's Mobility_VBZ_Hardbruecke.R (statistikZH/covid19monitoring_
# mobility_VBZHardbruecke, archived 2022). The WAI input is total_in + total_out.
#
# Source
#   Stadt Zürich Open Data, dataset vbz_frequenzen_hardbruecke:
#   https://data.stadt-zuerich.ch/dataset/vbz_frequenzen_hardbruecke
#   Updated daily. The past years' files are cached in raw/; the current
#   year's file is downloaded on every run.
#
# Checks (a failed check stops the run)
#   1. Every year from 2020 to the current one downloads and has the columns.
#   2. The newest day is at most 7 days old.
#   3. With an old file given, complete past days are compared; more than 1%
#      median difference stops the run.
#
# Usage
#   Rscript zurich_hardbruecke/acquire_zurich_hardbruecke.R [<old csv to compare with>]
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

api_url <- "https://data.stadt-zuerich.ch/api/3/action/package_show?id=vbz_frequenzen_hardbruecke"
first_year <- 2020
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "zurich_hardbruecke"
})
raw_dir <- file.path(script_dir, "raw")
out_file <- file.path(script_dir, "daily_frequency_hardbruecke.csv")


# HELPERS -----------------------------------------------------------------

#' Download URLs of the yearly CSVs, from the CKAN API. The short links
#' ".../dataset/<name>/download/<file>" forward to a broken address for some
#' years (2026-10), the form with package and resource ids works for all.
resource_urls <- function() {
  f <- tempfile(fileext = ".json")
  utils::download.file(api_url, f, quiet = TRUE, method = "libcurl", headers = c(`User-Agent` = user_agent))
  p <- jsonlite::fromJSON(f)$result
  r <- p$resources
  r <- r[grepl("^frequenzen_hardbruecke_[0-9]{4}\\.csv$", r$name), ]
  stats::setNames(sprintf("https://data.stadt-zuerich.ch/dataset/%s/resource/%s/download/%s", p$id, r$id, r$name),
                  sub("^frequenzen_hardbruecke_([0-9]{4})\\.csv$", "\\1", r$name))
}

get_year <- function(year, urls) {
  dest <- file.path(raw_dir, sprintf("frequenzen_hardbruecke_%d.csv", year))
  if (is.na(urls[as.character(year)])) stop("no file for ", year, " in the dataset")
  current <- year == as.integer(format(Sys.Date(), "%Y"))
  if (!file.exists(dest) || current) {
    message("downloading ", basename(dest))
    utils::download.file(urls[[as.character(year)]], dest, mode = "wb", quiet = TRUE, method = "libcurl",
                         headers = c(`User-Agent` = user_agent))
  }
  dest
}

# As in create_daily_frequency_hardbruecke.R
read_one <- function(path) {
  x <- utils::read.csv(path, stringsAsFactors = FALSE, encoding = "UTF-8")
  need <- c("In", "Out", "Timestamp", "Name")
  if (!all(need %in% names(x))) stop(basename(path), ": missing columns ", paste(setdiff(need, names(x)), collapse = ", "))
  x <- x[, need]
  x$In <- as.numeric(x$In)
  x$Out <- as.numeric(x$Out)
  x$Timestamp <- as.POSIXct(x$Timestamp, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  x
}


# RUN ---------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
dir.create(raw_dir, showWarnings = FALSE, recursive = TRUE)

years <- first_year:as.integer(format(Sys.Date(), "%Y"))
urls <- resource_urls()
raw <- do.call(rbind, lapply(vapply(years, get_year, "", urls = urls), read_one))

ts_name <- stats::aggregate(cbind(In, Out) ~ Timestamp + Name, data = raw, FUN = sum, na.rm = TRUE)
ts_name$Date <- as.Date(ts_name$Timestamp, tz = "UTC")
daily <- stats::aggregate(cbind(In, Out) ~ Date, data = ts_name, FUN = sum, na.rm = TRUE)
names(daily) <- c("date", "total_in", "total_out")
daily <- daily[order(daily$date), ]
# The current day is still being counted (the canton's script drops it too).
daily <- daily[daily$date < Sys.Date(), ]
if (Sys.Date() - max(daily$date) > 7) stop("newest day ", max(daily$date), " is more than 7 days old")

utils::write.csv(daily, out_file, row.names = FALSE, quote = FALSE)
message(sprintf("wrote %s: %s to %s (%d days)", out_file, min(daily$date), max(daily$date), nrow(daily)))

if (length(args)) {
  old <- utils::read.csv(args[1])
  old$date <- as.Date(old$date)
  m <- merge(old, daily, by = "date", suffixes = c(".old", ".new"))
  m <- m[m$date < max(old$date), ]                    # the old file's last day may be partial
  tot_old <- m$total_in.old + m$total_out.old
  tot_new <- m$total_in.new + m$total_out.new
  rel <- abs(tot_new / tot_old - 1)
  by_year <- tapply(rel < 1e-9, format(m$date, "%Y"), mean)
  message(sprintf("  vs old (%s..%s): %d days, identical %.1f%%, median |rel diff| %.2e, max %.2e",
                  min(m$date), max(m$date), nrow(m), 100 * mean(rel < 1e-9), stats::median(rel), max(rel)))
  message("  identical share by year: ", paste(sprintf("%s %.0f%%", names(by_year), 100 * by_year), collapse = ", "))
  if (stats::median(rel) > 0.01) stop("differs from the old file by more than 1% (median)")
}
