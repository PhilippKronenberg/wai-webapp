# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the Swiss Rhine ports cargo series (wai-webapp #30; moved from mfbdfm #142)
#
# Downloads web table t11.4.02 "Umschlag nach Warengattung" from the
# Statistisches Amt des Kantons Basel-Stadt and writes it out as one tidy CSV:
# monthly tonnage handled at the Swiss Rhine ports, by transport category
# (Zufuhr / Abfuhr / Gesamtumschlag) and commodity group.
#
# Source
#   https://statistik.bs.ch/files/webtabellen/t11-4-02.xlsx
#   Publisher   Statistisches Amt des Kantons Basel-Stadt
#   Data source Schweizerische Rheinhaefen (full census)
#   Period      month; available since 1926, monthly detail from 2001
#   Updated     monthly ("laufend" per the workbook's Steckbrief sheet)
#
# Two things about the workbook that the parser has to handle rather than
# assume away:
#
# 1. One sheet per year, each with the twelve months in columns, plus
#    aggregate sheets ("Gesamtumschlag seit 2024", "... 1926-2024", and the
#    Steckbrief cover sheet). Only the per-year sheets are read here; the
#    aggregate sheets are annual and carry nothing the monthly sheets do not.
#
# 2. A classification break in 2024. From 2024 the table reports NST-2007
#    groups (codes 1-20, with 11-13, 17-18 and 19-20 collapsed); 2023 and
#    earlier report the ten NSTR groups, unnumbered. The workbook ships both
#    schemes for the overlap years as extra "2024-NSTR" / "2025-NSTR" sheets.
#    Both layouts are read, and which one a row came from is kept in a
#    `classification` column - the two are NOT mapped onto each other, because
#    the group boundaries genuinely differ.
#
# The row with direction "gesamtumschlag" and no commodity is the headline
# monthly series; "zufuhr"/"abfuhr" with no commodity are the two transport
# categories; the remaining rows are the commodity breakdown within each.
#
# Usage
#   Rscript rhine_cargo/acquire_rhine_cargo.R
#   Rscript rhine_cargo/acquire_rhine_cargo.R <output.csv>
#   Rscript rhine_cargo/acquire_rhine_cargo.R <output.csv> <workbook.xlsx>
#
# The second form reuses a workbook already on disk instead of downloading one,
# which is how to re-parse without hitting the server. Nothing is written
# unless the script is run, and only to the path given.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

source_url <- "https://statistik.bs.ch/files/webtabellen/t11-4-02.xlsx"

# The CSV is committed next to this script; rerun the script to refresh it.
default_out <- file.path("rhine_cargo", "rhine_cargo.csv")

# German month abbreviations as the workbook spells them, in order.
months_de <- c("Jan", "Feb", "Mrz", "Apr", "Mai", "Jun",
               "Jul", "Aug", "Sep", "Okt", "Nov", "Dez")

# The three transport-category rows that open each block.
directions <- c("Zufuhr", "Abfuhr", "Gesamtumschlag")


# HELPERS -----------------------------------------------------------------

#' Read one year sheet into a long data frame
#'
#' The sheet is read with no header and no type guessing, so every cell arrives
#' as a character string and the layout can be located by content instead of by
#' hard-coded cell references - the two layouts (NSTR, NST-2007) put the labels
#' and the first month in different columns.
parse_year_sheet <- function(path, sheet) {
  raw <- readxl::read_excel(path, sheet = sheet, col_names = FALSE,
                            col_types = "text", .name_repair = "minimal",
                            progress = FALSE)
  raw <- as.data.frame(raw, stringsAsFactors = FALSE)
  if (nrow(raw) == 0L || ncol(raw) == 0L) return(NULL)

  # Locate the header row by looking for the month labels rather than trusting
  # a fixed row number.
  is_header <- apply(raw, 1L, function(r) all(months_de %in% r))
  if (!any(is_header)) {
    warning("sheet '", sheet, "': no month header row found, skipped",
            call. = FALSE)
    return(NULL)
  }
  head_row <- which(is_header)[1L]
  header <- as.character(unlist(raw[head_row, ], use.names = FALSE))
  month_col <- match(months_de, header)

  # Label columns: everything left of January that holds any text at all. The
  # NST-2007 layout uses two of them (code, then name), NSTR only one (name).
  label_cols <- seq_len(month_col[1L] - 1L)
  label_cols <- label_cols[vapply(label_cols, function(j)
    any(nzchar(trimws(ifelse(is.na(raw[[j]]), "", raw[[j]])))), logical(1))]
  if (length(label_cols) == 0L) {
    warning("sheet '", sheet, "': no label column found, skipped", call. = FALSE)
    return(NULL)
  }

  year <- as.integer(sub("-.*$", "", sheet))
  classification <- if (grepl("NSTR$", sheet) || year <= 2023L) "NSTR" else "NST-2007"

  cell <- function(i, j) {
    x <- raw[[j]][i]
    if (is.na(x)) "" else trimws(x)
  }

  out <- list()
  direction <- NA_character_
  for (i in seq.int(head_row + 1L, nrow(raw))) {
    labels <- vapply(label_cols, function(j) cell(i, j), character(1))
    labels <- labels[nzchar(labels)]
    if (length(labels) == 0L) next
    # Footnote lines ("1In Tonnen, ...") sit below the table and have no values.
    if (all(is.na(suppressWarnings(as.numeric(
      vapply(month_col, function(j) cell(i, j), character(1))))))) {
      # Keep going: a direction row with no reported months is still a header
      # for the commodity rows beneath it.
      if (!labels[1L] %in% directions) next
    }

    if (labels[1L] %in% directions) {
      direction <- labels[1L]
      code <- NA_character_
      commodity <- NA_character_
    } else {
      if (is.na(direction)) next
      # NST-2007: first label is the code ("3", "11-13"), second the name.
      if (length(labels) >= 2L) {
        code <- labels[1L]
        commodity <- labels[2L]
      } else {
        code <- NA_character_
        commodity <- labels[1L]
      }
    }

    values <- vapply(month_col, function(j) cell(i, j), character(1))
    # "…" marks a month not yet reported; anything else non-numeric is a defect
    # worth hearing about rather than silently dropping.
    values[values %in% c("", "…", "...", "-", "–")] <- NA_character_
    tonnes <- suppressWarnings(as.numeric(values))
    if (any(is.na(tonnes) & !is.na(values))) {
      warning("sheet '", sheet, "' row ", i, ": unparseable value(s) ",
              paste(unique(values[is.na(tonnes) & !is.na(values)]),
                    collapse = ", "), call. = FALSE)
    }

    out[[length(out) + 1L]] <- data.frame(
      year           = year,
      month          = seq_along(months_de),
      direction      = tolower(direction),
      classification = classification,
      nst_code       = code,
      commodity      = commodity,
      tonnes         = tonnes,
      stringsAsFactors = FALSE
    )
  }

  if (length(out) == 0L) return(NULL)
  do.call(rbind, out)
}

#' Download and parse t11.4.02 into one tidy data frame
acquire_rhine_cargo <- function(workbook = NULL, url = source_url) {
  if (is.null(workbook)) {
    workbook <- tempfile(fileext = ".xlsx")
    on.exit(unlink(workbook), add = TRUE)
    message("Downloading ", url)
    utils::download.file(url, workbook, mode = "wb", quiet = TRUE)
  }

  sheets <- readxl::excel_sheets(workbook)
  year_sheets <- grep("^[0-9]{4}(-NSTR)?$", sheets, value = TRUE)
  if (length(year_sheets) == 0L) {
    stop("no per-year sheets found in the workbook; the layout has changed")
  }
  message("Parsing ", length(year_sheets), " year sheet(s): ",
          paste(range(as.integer(sub("-.*$", "", year_sheets))), collapse = "-"))

  dat <- do.call(rbind, lapply(year_sheets, parse_year_sheet,
                               path = workbook))
  dat <- dat[!is.na(dat$tonnes), , drop = FALSE]
  dat$date <- as.Date(sprintf("%d-%02d-01", dat$year, dat$month))
  dat <- dat[order(dat$date, dat$classification, dat$direction,
                   !is.na(dat$commodity)), , drop = FALSE]
  rownames(dat) <- NULL
  dat[, c("date", "year", "month", "direction", "classification",
          "nst_code", "commodity", "tonnes")]
}


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  if (!requireNamespace("readxl", quietly = TRUE)) {
    stop("package 'readxl' is required: install.packages(\"readxl\")")
  }

  args <- commandArgs(trailingOnly = TRUE)
  out_file <- if (length(args) >= 1L) args[[1L]] else default_out
  workbook <- if (length(args) >= 2L) args[[2L]] else NULL

  dat <- acquire_rhine_cargo(workbook = workbook)

  dir.create(dirname(out_file), showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(dat, out_file, row.names = FALSE, na = "")

  headline <- dat[dat$direction == "gesamtumschlag" & is.na(dat$commodity), ]
  message("Wrote ", nrow(dat), " rows to ", out_file)
  message("Headline series (gesamtumschlag): ", nrow(headline),
          " months, ", format(min(headline$date)), " to ",
          format(max(headline$date)))
}
