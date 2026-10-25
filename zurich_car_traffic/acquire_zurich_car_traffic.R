# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the Zurich car-traffic index (aufkommen_miv) (#50)
#
# Downloads the City of Zurich's hourly motor-traffic counts
# (sid_dav_verkehrszaehlung_miv_OD2031_<year>.csv) and builds the daily index
# wai_ind reads as data/dataset/ktzh_Mobility_CarTraffic_indexed.csv: cars at
# selected counting stations, relative to the mean 2019 level of the same
# type of day (weekday / weekend), x 100.
#
# The method is wai_ind's data/verkehrszählung_StatistikZH/
# Mobility_CarTraffic_updated.R (see its README), a replication of the
# Canton of Zurich's covid19monitoring Mobility_CarTraffic.R:
#   - rows with a valid timestamp (Europe/Zurich) and a count;
#   - the two inherited lists of problematic stations dropped;
#   - directions summed per station and hour;
#   - station-days kept with at least 21 observed hours;
#   - summed over stations per day;
#   - indexed on the 2019 mean of weekdays and of weekends separately.
#
# The yearly files are large (about 0.4-0.5 GB each). Only the years needed
# are downloaded: 2019 for the benchmark, and the years after the fixed
# history. WAI_FULL=TRUE rebuilds 2012 to today instead.
#
# Source
#   Stadt Zürich Open Data, dataset sid_dav_verkehrszaehlung_miv_od2031
#   https://data.stadt-zuerich.ch/dataset/sid_dav_verkehrszaehlung_miv_od2031
#   Hourly, updated daily (2-day latency). URLs from the CKAN API.
#
# Checks (a failed check stops the run)
#   1. On the overlap with the history, the rebuilt index must match it
#      (median absolute relative difference below 0.1%).
#   2. The newest day is at most 10 days old.
#
# Usage
#   Rscript zurich_car_traffic/acquire_zurich_car_traffic.R [<history csv>]
#   default history: ../wai_ind/data/dataset/ktzh_Mobility_CarTraffic_indexed.csv
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

api_url <- "https://data.stadt-zuerich.ch/api/3/action/package_show?id=sid_dav_verkehrszaehlung_miv_od2031"
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
benchmark_year <- 2019
min_dayhours <- 21
drop_stations_initial <- c("Z006", "Z024", "Z050", "Z092", "Z096", "Z019", "Z087", "Z046", "Z045")
drop_stations_secondary <- c("Z007", "Z037", "Z051", "Z088", "Z086", "Z060", "Z077", "Z022")

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "zurich_car_traffic"
})
raw_dir <- file.path(script_dir, "raw")
out_file <- file.path(script_dir, "Mobility_CarTraffic_indexed.csv")

args <- commandArgs(trailingOnly = TRUE)
history_file <- if (length(args)) args[1] else
  file.path(script_dir, "..", "..", "wai_ind", "data", "dataset", "ktzh_Mobility_CarTraffic_indexed.csv")
full <- tolower(Sys.getenv("WAI_FULL", "FALSE")) %in% c("1", "true", "yes")

suppressPackageStartupMessages(library(data.table))


# HELPERS -----------------------------------------------------------------

resource_urls <- function() {
  f <- tempfile(fileext = ".json")
  utils::download.file(api_url, f, quiet = TRUE, method = "libcurl", headers = c(`User-Agent` = user_agent))
  p <- jsonlite::fromJSON(f)$result
  r <- p$resources
  r <- r[grepl("^sid_dav_verkehrszaehlung_miv_OD2031_[0-9]{4}\\.csv$", r$name, ignore.case = TRUE), ]
  # Two address forms, and on data.stadt-zuerich.ch either can be broken for
  # a given file (2026-10: the id form 404s for this dataset's 2026 file, the
  # short form for some Hardbrücke years). Both are tried, the API's first.
  urls <- Map(c, r$url, sprintf("https://data.stadt-zuerich.ch/dataset/%s/resource/%s/download/%s",
                                p$id, r$id, r$name))
  stats::setNames(urls, sub("^.*_([0-9]{4})\\.csv$", "\\1", r$name))
}

get_year <- function(year, urls) {
  dest <- file.path(raw_dir, sprintf("sid_dav_verkehrszaehlung_miv_OD2031_%d.csv", year))
  if (is.null(urls[[as.character(year)]])) stop("no file for ", year, " in the dataset")
  current <- year >= as.integer(format(Sys.Date() - 7, "%Y"))   # still being updated
  if (!file.exists(dest) || current) {
    message("downloading ", basename(dest))
    ok <- FALSE
    for (u in urls[[as.character(year)]]) {
      ok <- tryCatch({
        utils::download.file(u, dest, mode = "wb", quiet = TRUE, method = "libcurl",
                             headers = c(`User-Agent` = user_agent))
        TRUE
      }, error = function(e) FALSE, warning = function(w) FALSE)
      if (ok) break
    }
    if (!ok) stop("could not download ", basename(dest))
  }
  dest
}

# As process_one_file() in Mobility_CarTraffic_updated.R
daily_of_year <- function(path) {
  message("processing ", basename(path))
  dt <- fread(path, select = c("MessungDatZeit", "ZSID", "AnzFahrzeuge"), showProgress = FALSE)
  dt[, datetime := as.POSIXct(MessungDatZeit, format = "%Y-%m-%dT%H:%M:%S", tz = "Europe/Zurich")]
  dt <- dt[!is.na(datetime) & !is.na(AnzFahrzeuge) & !(ZSID %in% drop_stations_initial)]
  h <- dt[, .(value = sum(AnzFahrzeuge)), by = .(StationID = ZSID, datetime)]
  rm(dt); gc(verbose = FALSE)
  h[, date := format(datetime, "%Y-%m-%d", tz = "Europe/Zurich")]
  h[, typeofday := ifelse(format(datetime, "%u", tz = "Europe/Zurich") <= "5", "Weekday", "Weekend")]
  h <- h[!(StationID %in% drop_stations_secondary)]
  sd <- h[, .(value = sum(value), n_hours = .N), by = .(StationID, date, typeofday)][n_hours >= min_dayhours]
  out <- sd[, .(value = sum(value)), by = .(date, typeofday)]
  out[, date := as.Date(date)]
  as.data.frame(out[order(date)])
}

write_layout <- function(d, path) {
  out <- data.frame(date = format(d$date, "%d.%m.%Y"), value = round(d$value_relative, 8),
                    topic = "Mobilität", variable_short = "aufkommen_miv_indexiert",
                    variable_long = "Aufkommen MIV an ausgewählten Zählstellen, relativ zu mittlerem Aufkommen 2019",
                    location = "Stadt Zürich", unit = "Anteil",
                    source = "Dienstabteilung Verkehr, Sicherheitsdepartement", update = "täglich", public = "ja",
                    description = "wai-webapp zurich_car_traffic (method of wai_ind Mobility_CarTraffic_updated.R)")
  utils::write.table(out, path, sep = ";", row.names = FALSE, quote = FALSE, fileEncoding = "UTF-8")
}


# RUN ---------------------------------------------------------------------

dir.create(raw_dir, showWarnings = FALSE, recursive = TRUE)
hist <- utils::read.csv(history_file, sep = ";", stringsAsFactors = FALSE, encoding = "UTF-8")
hist <- data.frame(date = as.Date(hist$date, "%d.%m.%Y"), value_relative = as.numeric(hist$value))
hist_end <- max(hist$date)

this_year <- as.integer(format(Sys.Date(), "%Y"))
years <- if (full) 2012:this_year else sort(unique(c(benchmark_year, as.integer(format(hist_end, "%Y")):this_year)))
urls <- resource_urls()
daily <- do.call(rbind, lapply(years, function(y) daily_of_year(get_year(y, urls))))

bench <- stats::aggregate(value ~ typeofday, data = daily[format(daily$date, "%Y") == benchmark_year, ], FUN = mean)
daily$value_relative <- daily$value / bench$value[match(daily$typeofday, bench$typeofday)] * 100
message(sprintf("2019 benchmark: weekday %.0f, weekend %.0f vehicles/day", bench$value[bench$typeofday == "Weekday"],
                bench$value[bench$typeofday == "Weekend"]))

# Check against the history: the benchmark year and the overlap after it.
m <- merge(hist, daily, by = "date", suffixes = c(".hist", ".new"))
m <- m[m$date < hist_end, ]                              # the history's last day may be partial
rel <- abs(m$value_relative.new / m$value_relative.hist - 1)
by_year <- tapply(rel, format(m$date, "%Y"), stats::median)
message(sprintf("  vs history on %d days: median |rel diff| %.2e; by year: %s", nrow(m), stats::median(rel),
                paste(sprintf("%s %.1e", names(by_year), by_year), collapse = ", ")))
if (stats::median(rel) > 0.001) stop("rebuilt index does not match the history")

new <- daily[daily$date > hist_end & daily$date < Sys.Date() - 1, ]   # 2-day publication latency
if (!nrow(new) || Sys.Date() - max(new$date) > 10) stop("no recent days in the data")
out <- rbind(hist, new[, c("date", "value_relative")])
write_layout(out, out_file)
message(sprintf("wrote %s: history to %s + %d new days to %s", out_file, hist_end, nrow(new), max(out$date)))
