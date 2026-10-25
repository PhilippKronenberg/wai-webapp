# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the ASTRA motorway traffic aggregate (traffic_PW, traffic_LW) (#50)
#
# Reads ASTRA's "Wöchentliche Verkehrsentwicklung" page, finds the newest
# workbook ("Wöchentliche Verkehrsentwicklung - Stand DD.MM.YYYY.xlsx"),
# downloads it, and appends its new days to the fixed history of wai_ind's
# aggregate (data/dataset/ASTRA_traffic_extended.csv):
#
#   PW+.Busse/Car   cars, buses and coaches (< 3.5 t)  -> traffic_PW
#   LW              heavy vehicles (> 3.5 t)            -> traffic_LW
#   Gesamtergebnis  all vehicles
#
# vehicles per day, both directions, summed over three counting stations.
# The aggregate is built as in wai_ind's data/ASTRA/traffic scripts:
#   - stations MENDRISIO S (AS) (successor of CHIASSO), SIMPLON, JOSEFGALERIE S
#     and GOTTHARDTUNNEL, read from each station sheet (name in C4, daily rows
#     from row 123: date, total, < 3.5 t, > 3.5 t);
#   - each scaled by the multiplicative stitch factor wai_ind estimated
#     (traffic_extended_stitch_log.csv; copied into `stitch` below);
#   - summed per day.
# wai_ind fills missing station days with a state-space model (KFAS). Here a
# missing station day is filled from the other two stations: their sum that
# day times the station's median share ratio over the previous 28 complete
# days. Filled days are listed in the run log and in the `filled` column.
#
# Checks (a failed check stops the run)
#   1. The page links a "Stand" workbook, and its three stations are found.
#   2. On the overlap with the history, the rebuilt aggregate must match it
#      (median absolute relative difference below 0.5% per series).
#
# Usage
#   Rscript astra_traffic/acquire_astra_traffic.R [<history csv>]
#   default history: ../wai_ind/data/dataset/ASTRA_traffic_extended.csv
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

page_url <- "https://www.astra.admin.ch/de/woechentliche-verkehrsentwicklung"
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
series <- c("PW+.Busse/Car", "LW", "Gesamtergebnis")

# Stitch factors from wai_ind's traffic_extended_stitch_log.csv. Each was
# estimated against the already stitched predecessor, so it is cumulative as
# logged: MENDRISIO S is NOT also multiplied by CHIASSO-BROGEDA's factor.
# With these, the rebuild equals the history to 1e-15 on 2024-04..2026-02.
stitch <- list(
  "MENDRISIO S (AS)"        = c("PW+.Busse/Car" = 0.864924498851633, LW = 0.877466654053543,
                                Gesamtergebnis = 0.865165284767732),
  "SIMPLON, JOSEFGALERIE S" = c("PW+.Busse/Car" = 1.01171193620733, LW = 0.916666666666667,
                                Gesamtergebnis = 1),
  "GOTTHARDTUNNEL"          = c("PW+.Busse/Car" = 1.00483558994197, LW = 0.962809917355372,
                                Gesamtergebnis = 1)
)

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "astra_traffic"
})
raw_dir <- file.path(script_dir, "raw")
out_file <- file.path(script_dir, "astra_traffic.csv")

args <- commandArgs(trailingOnly = TRUE)
history_file <- if (length(args)) args[1] else
  file.path(script_dir, "..", "..", "wai_ind", "data", "dataset", "ASTRA_traffic_extended.csv")

suppressPackageStartupMessages(library(readxl))


# HELPERS -----------------------------------------------------------------

fetch <- function(url, dest) {
  utils::download.file(url, dest, mode = "wb", quiet = TRUE, method = "libcurl",
                       headers = c(`User-Agent` = user_agent))
  dest
}

#' The newest "Stand DD.MM.YYYY" workbook linked on the page
find_newest <- function() {
  html <- paste(readLines(fetch(page_url, tempfile(fileext = ".html")), warn = FALSE,
                          encoding = "UTF-8"), collapse = "\n")
  links <- unique(regmatches(html, gregexpr("https://www\\.astra\\.admin\\.ch/dam/[^\"' ]+\\.xlsx", html))[[1]])
  dec <- vapply(links, utils::URLdecode, "")
  hit <- grepl("Verkehrsentwicklung.*Stand.*[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}\\.xlsx$", dec, ignore.case = TRUE)
  if (!any(hit)) stop("no 'Verkehrsentwicklung ... Stand DD.MM.YYYY' workbook on ", page_url)
  stand <- as.Date(sub("^.*([0-9]{2}\\.[0-9]{2}\\.[0-9]{4})\\.xlsx$", "\\1", dec[hit]), "%d.%m.%Y")
  i <- which.max(stand)
  list(url = links[hit][i], stand = stand[i])
}

#' One station sheet, as in wai_ind's traffic_data_merge_until_2025.R
read_station <- function(path, sheet) {
  # As text: from row 123 on, readxl would guess dates and return seconds.
  raw <- read_excel(path, sheet = sheet, range = "A123:D5000", col_names = FALSE, col_types = "text",
                    na = c("", "NA"), .name_repair = "minimal")
  names(raw) <- c("date", "Gesamtergebnis", "PW+.Busse/Car", "LW")
  raw$date <- suppressWarnings(as.Date(as.numeric(raw$date), origin = "1899-12-30"))
  raw <- raw[!is.na(raw$date) & raw$date >= as.Date("2000-01-01") & raw$date <= Sys.Date(), ]
  for (s in series) raw[[s]] <- suppressWarnings(as.numeric(raw[[s]]))
  raw <- raw[order(raw$date), ]
  as.data.frame(raw[!duplicated(raw$date), c("date", series)], check.names = FALSE)
}

read_stations <- function(path) {
  sheets <- setdiff(excel_sheets(path), "Zählstellen-Liste")
  names_c4 <- vapply(sheets, function(s) {
    x <- read_excel(path, sheet = s, range = "C4:C4", col_names = FALSE, .name_repair = "minimal")
    if (nrow(x) && ncol(x)) trimws(as.character(x[[1, 1]])) else NA_character_
  }, "")
  out <- list()
  for (st in names(stitch)) {
    s <- sheets[which(names_c4 == st)]
    if (length(s) != 1) stop("station '", st, "' found on ", length(s), " sheets")
    out[[st]] <- read_station(path, s)
  }
  out
}

#' Fill a station's missing days from the other two stations' sum
fill_station <- function(st, all) {
  x <- all[[st]]
  others <- Reduce(`+`, lapply(setdiff(names(all), st), function(o) all[[o]][, series]))
  filled <- rep(FALSE, nrow(x))
  for (s in series) {
    miss <- which(is.na(x[[s]]))
    for (i in miss) {
      win <- max(1, i - 60):(i - 1)
      ok <- win[!is.na(x[[s]][win]) & !is.na(others[[s]][win]) & others[[s]][win] > 0]
      ok <- utils::tail(ok, 28)
      if (length(ok) < 14 || is.na(others[[s]][i])) next
      x[[s]][i] <- others[[s]][i] * stats::median(x[[s]][ok] / others[[s]][ok])
      filled[i] <- TRUE
    }
  }
  x$filled <- filled
  x
}


# RUN ---------------------------------------------------------------------

dir.create(raw_dir, showWarnings = FALSE, recursive = TRUE)
newest <- find_newest()
wb <- file.path(raw_dir, utils::URLdecode(basename(newest$url)))
if (!file.exists(wb)) { message("downloading ", basename(wb)); fetch(newest$url, wb) }
message("newest workbook: Stand ", newest$stand)

st <- read_stations(wb)
# Align the three stations on one daily calendar
all_dates <- do.call(c, lapply(st, `[[`, "date"))
cal <- data.frame(date = seq(min(all_dates), max(all_dates), by = "day"))
st <- lapply(st, function(d) merge(cal, d, by = "date", all.x = TRUE))
st_filled <- lapply(stats::setNames(names(st), names(st)), fill_station, all = st)

agg <- data.frame(date = cal$date)
for (s in series) {
  agg[[s]] <- Reduce(`+`, lapply(names(st_filled), function(n) st_filled[[n]][[s]] * stitch[[n]][[s]]))
}
agg$filled <- Reduce(`|`, lapply(st_filled, `[[`, "filled"))
agg <- agg[stats::complete.cases(agg[, series]), ]

hist <- utils::read.csv(history_file, check.names = FALSE)
names(hist)[1] <- "date"
hist$date <- as.Date(hist$date)
# Compare from 2024-04 on: before that the history uses CHIASSO-BROGEDA, not
# MENDRISIO S, and wai_ind filled single missing station days with KFAS.
m <- merge(hist, agg[!agg$filled, ], by = "date", suffixes = c(".hist", ".new"))
m <- m[m$date >= as.Date("2024-04-01"), ]
for (s in series) {
  rel <- abs(m[[paste0(s, ".new")]] / m[[paste0(s, ".hist")]] - 1)
  message(sprintf("  %-15s vs history on %d days (%s..%s): median |rel diff| %.2e, within 1%% on %.1f%%",
                  s, nrow(m), min(m$date), max(m$date), stats::median(rel), 100 * mean(rel < 0.01)))
  if (stats::median(rel) > 1e-6) stop(s, ": rebuilt aggregate does not match the history")
}

new <- agg[agg$date > max(hist$date), ]
out <- rbind(data.frame(hist[, c("date", series)], filled = FALSE, check.names = FALSE),
             new[, c("date", series, "filled")])
names(out)[1] <- "Fahrzeuge.pro.Tag.(beide.Richtungen)"
utils::write.csv(out, out_file, row.names = FALSE)
message(sprintf("wrote %s: history to %s + %d new days to %s (%d filled)", out_file, max(hist$date),
                nrow(new), max(out[[1]]), sum(new$filled)))
if (any(new$filled)) message("  filled days: ", paste(new$date[new$filled], collapse = ", "))
