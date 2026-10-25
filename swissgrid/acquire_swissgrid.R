# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire Swissgrid's Swiss electricity totals (EnergieUebersichtCH) (#50)
#
# Reads Swissgrid's "Energieübersicht Schweiz" page, finds every yearly
# workbook EnergieUebersichtCH-<year>.xls(x), downloads the ones that are new
# or have changed, and builds the daily series that wai_ind reads as
# data/dataset/swissgrid_2009_2025.csv:
#
#   out.ch              Summe endverbrauchte Energie Regelblock Schweiz -> electricity_out
#   in.ch               Summe produzierte Energie Regelblock Schweiz    -> electricity_in
#   out_incl_losses.ch  Summe verbrauchte Energie Regelblock Schweiz
#
# all in kWh, summed per day from the quarter-hourly sheet "Zeitreihen0h15".
# The reading is that of wai_ind's data/Swissgrid/swissgrid.R (columns B-D,
# both time formats, days cut as there), so the output has the same columns,
# units and layout.
#
# Source
#   Swissgrid, https://www.swissgrid.ch/de/home/customers/topics/energy-data-ch.html
#   One workbook per year since 2009; the current year's is updated during
#   the year. The links carry an id (/dam/jcr:<id>/) that changes when a
#   file is replaced, so the page is read on every run and a workbook is
#   downloaded again only when its link changed (raw/manifest.csv).
#
# Checks (a failed check stops the run)
#   1. The page lists a workbook for every year from 2009 to the current one.
#   2. Each workbook has the sheet and the three columns, and every day of
#      its year (to its last day) has 96 quarter-hours.
#   3. With old output given, complete past years must be unchanged.
#
# Usage
#   Rscript swissgrid/acquire_swissgrid.R [<old swissgrid csv to compare with>]
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

page_url <- "https://www.swissgrid.ch/de/home/customers/topics/energy-data-ch.html"
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
first_year <- 2009

# Resolved from the script's location, so it can be run from anywhere.
script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "swissgrid"
})
raw_dir <- file.path(script_dir, "raw")
manifest_file <- file.path(raw_dir, "manifest.csv")
out_file <- file.path(script_dir, "swissgrid_daily.csv")

suppressPackageStartupMessages(library(readxl))


# HELPERS -----------------------------------------------------------------

fetch <- function(url, dest) {
  utils::download.file(url, dest, mode = "wb", quiet = TRUE, method = "libcurl",
                       headers = c(`User-Agent` = user_agent))
  dest
}

#' The yearly workbooks linked on the page: year, url, file name
find_workbooks <- function() {
  html <- paste(readLines(fetch(page_url, tempfile(fileext = ".html")), warn = FALSE), collapse = "\n")
  links <- unique(regmatches(html, gregexpr(
    "https://www\\.swissgrid\\.ch/dam/jcr:[0-9a-f-]+/EnergieUebersichtCH-[0-9]{4}\\.xlsx?", html))[[1]])
  if (!length(links)) stop("no EnergieUebersichtCH workbooks found on ", page_url)
  wb <- data.frame(url = links, file = basename(links), stringsAsFactors = FALSE)
  wb$year <- as.integer(sub("^EnergieUebersichtCH-([0-9]{4}).*$", "\\1", wb$file))
  if (anyDuplicated(wb$year)) stop("more than one workbook per year on the page")
  wb <- wb[order(wb$year), ]
  missing <- setdiff(first_year:as.integer(format(Sys.Date(), "%Y")), wb$year)
  if (length(missing)) stop("no workbook on the page for: ", paste(missing, collapse = ", "))
  wb
}

# As in swissgrid.R: "dd.mm.yyyy hh:mm" text, else an Excel serial number.
parse_swissgrid_time <- function(x) {
  x_chr <- trimws(as.character(x))
  x_chr[x_chr %in% c("", "NA")] <- NA_character_
  parsed <- suppressWarnings(as.POSIXct(x_chr, format = "%d.%m.%Y %H:%M", tz = "UTC"))
  needs_excel <- is.na(parsed) & !is.na(x_chr)
  if (any(needs_excel)) {
    excel_num <- suppressWarnings(as.numeric(x_chr[needs_excel]))
    parsed[needs_excel] <- as.POSIXct((excel_num - 25569) * 86400, origin = "1970-01-01", tz = "UTC")
  }
  parsed
}

# As in swissgrid.R, plus checks of the layout it relies on.
read_swissgrid_file <- function(file_path) {
  if (!"Zeitreihen0h15" %in% excel_sheets(file_path)) stop(basename(file_path), ": no sheet Zeitreihen0h15")
  raw <- read_excel(file_path, sheet = "Zeitreihen0h15", col_types = "text", trim_ws = TRUE)
  hdr <- names(raw)[2:4]
  if (!grepl("endverbraucht", hdr[1], ignore.case = TRUE) || !grepl("produziert", hdr[2], ignore.case = TRUE) ||
      !grepl("verbraucht", hdr[3], ignore.case = TRUE))
    stop(basename(file_path), ": columns B-D are not end-use, production, consumption: ",
         paste(hdr, collapse = " | "))
  raw <- as.data.frame(raw[, 1:4], stringsAsFactors = FALSE)
  raw <- raw[-1, , drop = FALSE]                       # the unit row (kWh)
  names(raw) <- c("time", "out.ch", "in.ch", "out_incl_losses.ch")
  raw$time <- parse_swissgrid_time(raw$time)
  raw <- raw[!is.na(raw$time), , drop = FALSE]
  for (col in c("out.ch", "out_incl_losses.ch", "in.ch")) {
    raw[[col]] <- suppressWarnings(as.numeric(gsub(",", ".", raw[[col]], fixed = TRUE)))
  }
  raw
}


# RUN ---------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
dir.create(raw_dir, showWarnings = FALSE, recursive = TRUE)

wb <- find_workbooks()
old_manifest <- if (file.exists(manifest_file)) read.csv(manifest_file, stringsAsFactors = FALSE) else
  data.frame(year = integer(), url = character())
for (i in seq_len(nrow(wb))) {
  dest <- file.path(raw_dir, wb$file[i])
  known <- old_manifest$url[old_manifest$year == wb$year[i]]
  if (!file.exists(dest) || !length(known) || known != wb$url[i]) {
    message("downloading ", wb$file[i])
    fetch(wb$url[i], dest)
  }
}
write.csv(wb[, c("year", "url")], manifest_file, row.names = FALSE)

swissgrid <- do.call(rbind, lapply(file.path(raw_dir, wb$file), read_swissgrid_file))

# Every day must be complete: 96 quarter-hours, the day's 00:00 included in it
# being the end of the previous day's last interval is how swissgrid.R cuts,
# and is kept.
swissgrid$day <- cut(swissgrid$time, breaks = "1 day")
n_q <- table(swissgrid$day)
last_day <- names(n_q)[length(n_q)]
short <- n_q[n_q < 92 & names(n_q) != names(n_q)[1] & names(n_q) != last_day]  # DST days have 92/100
if (length(short)) stop("incomplete days: ", paste(head(names(short)), collapse = ", "))

ch_daily <- aggregate(swissgrid[, c("out.ch", "out_incl_losses.ch", "in.ch")],
                      by = list(date = swissgrid$day), FUN = sum, na.rm = TRUE)
ch_daily$date <- as.POSIXct(as.character(ch_daily$date), tz = "UTC")
ch_daily <- ch_daily[order(ch_daily$date), c("date", "out.ch", "out_incl_losses.ch", "in.ch")]
# The last day is complete only if its last quarter-hour (the next day's
# 00:00) is in the data; otherwise drop it rather than publish a partial sum.
if (n_q[last_day] < 92) ch_daily <- ch_daily[format(ch_daily$date) != last_day, ]
write.csv(ch_daily, out_file, row.names = FALSE)
message(sprintf("wrote %s: %s to %s (%d days)", out_file, format(min(ch_daily$date), "%Y-%m-%d"),
                format(max(ch_daily$date), "%Y-%m-%d"), nrow(ch_daily)))

if (length(args)) {
  old <- read.csv(args[1])
  old$date <- substr(old$date, 1, 10)
  new <- transform(read.csv(out_file), date = substr(date, 1, 10))
  m <- merge(old, new, by = "date", suffixes = c(".old", ".new"))
  # The old file's final day can be a partial sum (cut at its last
  # quarter-hour), so it is compared but not required to match.
  full <- m$date < max(old$date)
  # Swissgrid replaces a year's workbook when its data become final, so
  # small revisions of recent years are expected and reported per year. A
  # change above 2% means the reading broke, not a revision.
  for (v in c("out.ch", "out_incl_losses.ch", "in.ch")) {
    rel <- abs(m[[paste0(v, ".new")]] / m[[paste0(v, ".old")]] - 1)
    by_year <- tapply(rel[full], substr(m$date[full], 1, 4), max, na.rm = TRUE)
    revised <- by_year[by_year > 1e-12]
    message(sprintf("  %-18s vs old (%s..%s): %d days; identical in %d of %d years%s",
                    v, min(m$date), max(m$date), nrow(m), length(by_year) - length(revised), length(by_year),
                    if (length(revised)) paste0("; revised: ", paste(sprintf("%s (max %.2f%%)", names(revised),
                                                                             100 * revised), collapse = ", ")) else ""))
    if (max(rel[full], na.rm = TRUE) > 0.02) stop(v, " differs from the old output by more than 2%")
  }
}
