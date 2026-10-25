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
