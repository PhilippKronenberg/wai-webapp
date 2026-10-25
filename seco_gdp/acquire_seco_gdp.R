# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Build seco_gdp/realtime_gdp.csv and realtime_gdp_cssa.csv from SECO's
# real-time database (the WAI target, ch.seco.gdp.real.gdp.ssa) (#50)
#
# wai-webapp copy of mfbdfm's data-raw/realtime_gdp.R (mfbdfm #164, commit
# ac9c2a6); only the output folder differs: this folder instead of mfbdfm's
# inst/extdata. dataset/data_prep_dataset.R reads the files from here through
# mfbdfm::get_real_time_gdp_vintages(gdp_file_path =, gdp_cssa_file_path =).
#
# Downloads SECO's real-time GDP database and writes the two files that
# get_real_time_gdp_vintages() reads, in exactly the format it expects, so a
# rerun of this script is the whole update - no code changes.
#
# Source
#   SECO, real-time database: updated version of Indergand, R. and S. Leist
#   (2014), "A Real-Time Data Set for Switzerland", Swiss Journal of Economics
#   and Statistics 150(4), 331-352.
#   https://www.seco.admin.ch/dam/de/sd-web/MPCPHCXIDH6N/realtime-database.xlsx
#
# Sheets used
#   gdp       real GDP, seasonally adjusted          -> realtime_gdp.csv
#   gdp_cssa  real GDP, seasonally and sport-event   -> realtime_gdp_cssa.csv
#             adjusted (the WAI target)
#   get_real_time_gdp_vintages() takes vintages before 2018q3 from the first and
#   from 2018q3 on from the second.
#
# Layout of each sheet (located by content below, not trusted blindly)
#   a row of vintage RELEASE DATES as Excel serials, directly above
#   a row starting "time" with the vintage QUARTERS (2000q2, 2000q3, ...),
#   then one row per reference quarter (Excel serial date) with GDP levels.
#
# Output format (what read_sheet_info() parses)
#   realtime_gdp.csv       row 1: "", dd.mm.yyyy release dates
#                          row 2: "time", vintage quarters
#                          then:  YYYY-MM-DD, levels ("" for missing)
#   realtime_gdp_cssa.csv  row 1: "time", vintage quarters
#                          then:  YYYY-MM-DD, levels
#
# Guards: the script stops - writing nothing - if the vintage quarters are not
# consecutive, the release dates are not increasing, the two sheets disagree on
# their vintages, or the database has FEWER vintages than the files it would
# replace (a published vintage never disappears; fewer means a broken download).
#
# Usage
#   Rscript seco_gdp/acquire_seco_gdp.R                 # download and write
#   Rscript seco_gdp/acquire_seco_gdp.R <workbook.xlsx> # re-parse a local copy
#
# If SECO moves the file, update `source_url`: the asset id in the path
# (MPCPHCXIDH6N) is SECO's, not ours.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


source_url <- "https://www.seco.admin.ch/dam/de/sd-web/MPCPHCXIDH6N/realtime-database.xlsx"
# Resolved from the script's location, so it can be run from anywhere.
out_dir    <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "seco_gdp"
})
targets    <- c(gdp = "realtime_gdp.csv", gdp_cssa = "realtime_gdp_cssa.csv")


#' Read one sheet into release dates, vintage quarters and the level matrix
#'
#' `need_dates`: the gdp sheet's release dates head realtime_gdp.csv and must
#' all be there. gdp_cssa carries them only from ~2018 (the sport-event
#' adjusted series is younger), and its file does not use them.
read_vintage_sheet <- function(path, sheet, need_dates = TRUE) {
  raw <- as.data.frame(readxl::read_excel(path, sheet = sheet, col_names = FALSE,
                                          col_types = "text", .name_repair = "minimal",
                                          progress = FALSE), stringsAsFactors = FALSE)
  label_row <- which(raw[[1]] %in% "time")
  if (length(label_row) != 1L || label_row < 2L) {
    stop("sheet '", sheet, "': no single 'time' row found; the layout has changed",
         call. = FALSE)
  }
  vint_cols <- which(!is.na(unlist(raw[label_row, -1]))) + 1L
  quarters  <- unlist(raw[label_row, vint_cols], use.names = FALSE)
  released  <- as.Date(as.numeric(unlist(raw[label_row - 1L, vint_cols], use.names = FALSE)),
                       origin = "1899-12-30")

  body <- raw[(label_row + 1L):nrow(raw), , drop = FALSE]
  body <- body[!is.na(body[[1]]) & grepl("^[0-9.]+$", body[[1]]), , drop = FALSE]
  time <- as.Date(as.numeric(body[[1]]), origin = "1899-12-30")
  levels <- lapply(vint_cols, function(j) as.numeric(body[[j]]))
  names(levels) <- quarters

  if (!grepl("^[0-9]{4}q[1-4]$", quarters[1]) || (need_dates && anyNA(released)) ||
      is.unsorted(released[!is.na(released)], strictly = TRUE)) {
    stop("sheet '", sheet, "': vintage labels or release dates are malformed", call. = FALSE)
  }
  qn <- as.integer(substr(quarters, 1, 4)) * 4L + as.integer(substr(quarters, 6, 6))
  if (any(diff(qn) != 1L)) {
    stop("sheet '", sheet, "': vintage quarters are not consecutive", call. = FALSE)
  }
  if (anyNA(time) || is.unsorted(time, strictly = TRUE)) {
    stop("sheet '", sheet, "': reference quarters are malformed", call. = FALSE)
  }
  list(quarters = quarters, released = released, time = time, levels = levels)
}

#' Render the sheet in the shipped file format, as text lines
format_vintage_csv <- function(v, with_dates) {
  num <- function(x) ifelse(is.na(x), "", as.character(x))
  body <- vapply(seq_along(v$time), function(i) {
    paste(c(format(v$time[i], "%Y-%m-%d"),
            vapply(v$levels, function(col) num(col[i]), character(1))), collapse = ",")
  }, character(1))
  head <- paste(c("time", v$quarters), collapse = ",")
  if (with_dates) {
    head <- c(paste(c("", format(v$released, "%d.%m.%Y")), collapse = ","), head)
  }
  c(head, body)
}

#' Vintages in a shipped file (its "time,..." row)
shipped_quarters <- function(path) {
  if (!file.exists(path)) return(character(0))
  lines <- readLines(path, n = 2L, warn = FALSE)
  row <- lines[grepl("^time,", lines)][1]
  if (is.na(row)) character(0) else strsplit(row, ",", fixed = TRUE)[[1]][-1]
}

# The newest release, when the real-time database lags behind it ----------
#
# SECO adds a release to realtime-database.xlsx only some time after
# publishing it (2026-10: the database ended with the 2026-06-01 release
# while the 2026-09-03 release with 2026q2 was out). SECO publishes the
# current release machine-readably (feed on scheduler.swissdatas.ch, with
# SECO's own R example): one CSV with every series (structure, type, seas_adj,
# date, value) and a JSON with metadata. Real GDP is structure "gdp", type
# "real", in CHF million, the database's unit: seas_adj "csa" (seasonally and
# calendar adjusted) -> sheet gdp, "cssa" (also sport-event adjusted) ->
# sheet gdp_cssa, the WAI target. Its values equal the release's workbooks on
# SECO's GDP page (qna_e_csa.xlsx, qna_e_cssa.xlsx) to 1e-14.
#
# Release date: the date SECO's GDP page prints next to the release's files
# (3 September 2026 for 2026q2), which is how the database dates its
# vintages (05.09.2022, 04.09.2023, 03.09.2024). The feed's `updated_utc`
# (2026-08-28 for the same release) is earlier and used only if the page
# cannot be read. If the feed fails, KOF's public time-series database
# carries the same release (identical to 1e-14 on 2026-10-26).

seco_csv  <- "https://scheduler.swissdatas.ch/scheduled/ch-seco-gdp.csv"
seco_json <- "https://scheduler.swissdatas.ch/scheduled/ch-seco-gdp.json"
seco_page <- "https://www.seco.admin.ch/de/bruttoinlandprodukt"
seco_adj  <- c(gdp = "csa", gdp_cssa = "cssa")
months_de <- c(Januar = 1, Februar = 2, "März" = 3, April = 4, Mai = 5, Juni = 6, Juli = 7,
               August = 8, September = 9, Oktober = 10, November = 11, Dezember = 12)

#' Release date printed on SECO's GDP page next to the sport-adjusted file
seco_page_date <- function() {
  page <- tempfile(fileext = ".html")
  utils::download.file(seco_page, page, quiet = TRUE,
                       headers = c(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"))
  html <- paste(readLines(page, warn = FALSE, encoding = "UTF-8"), collapse = " ")
  hit <- regexpr("qna_e_cssa[.]xlsx", html)
  if (hit < 0) stop("qna_e_cssa.xlsx not linked on ", seco_page, call. = FALSE)
  after <- gsub("<[^>]+>", " ", substr(html, hit, hit + 3000))     # the link's label and date follow it
  d <- regmatches(after, regexpr(paste0("[0-9]{1,2}[.] (", paste(names(months_de), collapse = "|"), ") [0-9]{4}"), after))
  if (!length(d)) stop("no release date next to qna_e_cssa.xlsx", call. = FALSE)
  p <- strsplit(sub(".", "", d, fixed = TRUE), " ")[[1]]
  as.Date(sprintf("%s-%02d-%02d", p[3], months_de[[p[2]]], as.integer(p[1])))
}

#' SECO's current release: list(released, source, series = list(gdp =, gdp_cssa =) of data.frame(date, v))
seco_release <- function() {
  x <- utils::read.csv(seco_csv, stringsAsFactors = FALSE)
  if (!all(c("structure", "type", "seas_adj", "date", "value") %in% names(x))) {
    stop("unexpected columns in ", seco_csv, call. = FALSE)
  }
  series <- lapply(seco_adj, function(a) {
    g <- x[x$structure == "gdp" & x$type == "real" & x$seas_adj == a, ]
    if (!nrow(g)) stop("no real GDP (", a, ") in ", seco_csv, call. = FALSE)
    data.frame(date = as.Date(g$date), v = as.numeric(g$value))
  })
  released <- tryCatch(seco_page_date(), error = function(e) {
    meta <- jsonlite::fromJSON(seco_json, simplifyVector = FALSE)
    message("release date not readable on SECO's page (", conditionMessage(e), "); using the feed's updated_utc")
    as.Date(substr(meta$updated_utc, 1, 10))
  })
  list(released = released, source = "SECO (machine-readable feed)", series = series)
}

#' Fallback: the same release from KOF's public time-series database (in CHF)
kof_release <- function() {
  if (!requireNamespace("tsdbapi", quietly = TRUE)) stop("tsdbapi not installed", call. = FALSE)
  keys <- c(gdp = "ch.seco.gdp.real.gdp.sa", gdp_cssa = "ch.seco.gdp.real.gdp.ssa")
  tsdbapi::set_config(access_type = "public")
  ts <- tsdbapi::read_ts(unname(keys)); rel <- tsdbapi::read_ts_release(unname(keys))
  series <- lapply(keys, function(k) {
    tt <- as.numeric(stats::time(ts[[k]]))
    data.frame(date = as.Date(sprintf("%d-%02d-01", floor(tt + 1e-6), round((tt - floor(tt + 1e-6)) * 4) * 3 + 1)),
               v = as.numeric(ts[[k]]) / 1e6)              # CHF -> CHF million, as the database
  })
  list(released = max(as.Date(rel$vintage_date)), source = "KOF (ch.seco.gdp.real.gdp.sa/ssa)", series = series)
}

#' Append a release as the next vintage if it is newer than the database's last
append_release <- function(sheets, rel) {
  last_rel <- max(sheets$gdp$released, na.rm = TRUE)
  if (is.na(rel$released) || rel$released <= last_rel) {
    message(sprintf("  %s release of %s is not newer than the database's (%s); nothing appended",
                    rel$source, format(rel$released), format(last_rel)))
    return(sheets)
  }
  label <- sprintf("%sq%d", format(rel$released, "%Y"), (as.integer(format(rel$released, "%m")) - 1) %/% 3 + 1)
  qn <- function(q) as.integer(substr(q, 1, 4)) * 4L + as.integer(substr(q, 6, 6))
  for (s in names(seco_adj)) {
    v <- sheets[[s]]; x <- rel$series[[s]]
    if (qn(label) != qn(utils::tail(v$quarters, 1)) + 1L) {
      stop(s, ": the release of ", rel$released, " would be vintage ", label, ", not the one after ",
           utils::tail(v$quarters, 1), call. = FALSE)
    }
    new_time <- sort(union(v$time, x$date))
    v$levels <- lapply(v$levels, function(col) col[match(new_time, v$time)])
    v$levels[[label]] <- x$v[match(new_time, x$date)]
    v$time <- new_time
    v$quarters <- c(v$quarters, label)
    v$released <- c(v$released, rel$released)
    sheets[[s]] <- v
    message(sprintf("  %s: appended the release of %s from %s as vintage %s, to %s",
                    s, rel$released, rel$source, label, format(max(x$date))))
  }
  sheets
}

#' The newest release: SECO first, KOF if SECO's page cannot be read
append_latest_release <- function(sheets) {
  rel <- tryCatch(seco_release(), error = function(e) {
    message("SECO's GDP page not readable (", conditionMessage(e), "); trying KOF")
    tryCatch(kof_release(), error = function(e2) {
      message("KOF not reachable either (", conditionMessage(e2), "); database only"); NULL })
  })
  if (is.null(rel)) sheets else append_release(sheets, rel)
}

build_realtime_gdp <- function(workbook = NULL, url = source_url, dir = out_dir) {
  if (is.null(workbook)) {
    workbook <- tempfile(fileext = ".xlsx")
    on.exit(unlink(workbook), add = TRUE)
    message("Downloading ", url)
    utils::download.file(url, workbook, mode = "wb", quiet = TRUE)
  }
  sheets <- lapply(stats::setNames(names(targets), names(targets)),
                   function(s) read_vintage_sheet(workbook, s, need_dates = s == "gdp"))
  if (!identical(sheets$gdp$quarters, sheets$gdp_cssa$quarters)) {
    stop("the 'gdp' and 'gdp_cssa' sheets disagree on their vintages", call. = FALSE)
  }
  sheets <- append_latest_release(sheets)
  if (!identical(sheets$gdp$quarters, sheets$gdp_cssa$quarters)) {
    stop("after appending the latest release, the two files disagree on their vintages", call. = FALSE)
  }

  # Check everything before writing anything.
  out <- list()
  for (s in names(targets)) {
    path <- file.path(dir, targets[[s]])
    old <- shipped_quarters(path)
    new <- sheets[[s]]$quarters
    if (length(new) < length(old) || !identical(new[seq_along(old)], old)) {
      stop(targets[[s]], ": the database has vintages ", new[1], "..", utils::tail(new, 1),
           " but the shipped file has ", old[1], "..", utils::tail(old, 1),
           "; refusing to replace it with fewer or different vintages", call. = FALSE)
    }
    out[[s]] <- list(path = path, lines = format_vintage_csv(sheets[[s]], with_dates = s == "gdp"),
                     added = setdiff(new, old))
  }
  for (s in names(out)) {
    con <- file(out[[s]]$path, open = "wb")         # LF line endings, as committed
    writeLines(out[[s]]$lines, con, sep = "\n")
    close(con)
    v <- sheets[[s]]
    message(sprintf("Wrote %s: %d vintages (%s to %s, latest released %s), quarters %s to %s%s",
                    out[[s]]$path, length(v$quarters), v$quarters[1], utils::tail(v$quarters, 1),
                    format(utils::tail(v$released, 1)), format(v$time[1]),
                    format(utils::tail(v$time, 1)),
                    if (length(out[[s]]$added)) paste0("; new: ", paste(out[[s]]$added, collapse = ", "))
                    else "; no new vintage"))
  }
  invisible(out)
}

if (sys.nframe() == 0L) {
  if (!requireNamespace("readxl", quietly = TRUE)) {
    stop("package 'readxl' is required: install.packages(\"readxl\")", call. = FALSE)
  }
  args <- commandArgs(trailingOnly = TRUE)
  build_realtime_gdp(workbook = if (length(args)) args[[1]] else NULL)
}
