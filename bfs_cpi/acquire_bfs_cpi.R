# Run from anywhere; paths are resolved from this script's location.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the Swiss consumer price index (LIK), monthly (#50)
#
# Downloads BFS's CPI indexation table ("Indexierungstabelle", the total CPI
# monthly on every original base since 1921), chains the bases into one
# continuous series on the newest base, and writes it in the layout of the
# Datastream export it replaces (wai_ind data/DATASTREAM/datastream_econ.csv:
# ";"-separated, a "Name" date column as DD.MM.YYYY on the 15th, one column
# per series).
#
# Source
#   Bundesamt für Statistik (BFS), Landesindex der Konsumentenpreise,
#   Indexierungstabelle, asset cc-d-05.02.08:
#   https://www.bfs.admin.ch/asset/de/cc-d-05.02.08
#   downloaded through the stable route
#   https://www.bfs.admin.ch/bfsstatic/dam/assets/orderNr:cc-d-05.02.08/master
#   (the asset/de/... page answers scripts with HTML, not the file).
#   Updated monthly; to 2026-09 on 2026-10-25.
#
# NOT seasonally adjusted
#   BFS publishes the CPI unadjusted. The Datastream series the WAI used is
#   "SW CPI SADJ" (seasonally adjusted by Refinitiv). By the owner's decision
#   (2026-10-25) the pipeline stays a pure download and stores the unadjusted
#   index ("SW CPI NADJ"); seasonal adjustment happens in mfbdfm's data prep
#   with X-13, as it already does for core inflation (SWCPCOREF).
#
# Chaining
#   Each column of the table is the CPI on one base (June 1914 = 100, August
#   1939 = 100, ..., December 2025 = 100), from its base month on. The output
#   uses the newest base wherever it exists. Each older base is rescaled to the
#   newer series by their ratio in the month the newer base starts. The newer
#   base equals 100 there by construction, so the result is exactly the newest
#   base's series, extended backwards with the older bases' month-on-month
#   movements. Values are rounded to one decimal at source, so ratios between
#   adjacent months carry that rounding.
#
# Usage
#   Rscript bfs_cpi/acquire_bfs_cpi.R
#   Rscript bfs_cpi/acquire_bfs_cpi.R <output.csv>
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

source_url <- "https://www.bfs.admin.ch/bfsstatic/dam/assets/orderNr:cc-d-05.02.08/master"
series_name <- "SW CPI NADJ"   # Datastream-style column name; "NADJ" = not adjusted

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "bfs_cpi"
})
default_out <- file.path(script_dir, "bfs_cpi.csv")


# HELPERS -----------------------------------------------------------------

xl_date <- function(x) as.Date(suppressWarnings(as.numeric(x)), origin = "1899-12-30")

#' Read the indexation table: one column per base, located by content
read_index_table <- function(path) {
  x <- as.data.frame(readxl::read_excel(path, sheet = "Index_m", col_names = FALSE,
                                        col_types = "text", .name_repair = "minimal",
                                        progress = FALSE), stringsAsFactors = FALSE)
  hdr_row <- which(grepl("^Datum", x[[1]]))[1]
  if (is.na(hdr_row)) stop("no 'Datum' header row in sheet Index_m; the layout has changed", call. = FALSE)
  bases <- xl_date(unlist(x[hdr_row, -1]))
  base_cols <- which(!is.na(bases)) + 1L
  body <- x[(hdr_row + 1L):nrow(x), , drop = FALSE]
  dates <- xl_date(body[[1]])
  keep <- !is.na(dates)
  vals <- sapply(base_cols, function(j) suppressWarnings(as.numeric(body[[j]][keep])))
  colnames(vals) <- format(bases[base_cols - 1L])
  list(dates = dates[keep], values = vals)
}

#' Chain all bases into one series on the newest base
chain_bases <- function(tab) {
  v <- tab$values
  bases <- as.Date(colnames(v))
  ord <- order(bases, decreasing = TRUE)                    # newest first
  out <- v[, ord[1]]
  for (k in ord[-1]) {
    older <- v[, k]
    # link month: the earliest month where the chain so far is defined
    link <- which(!is.na(out) & !is.na(older))[1]
    if (is.na(link)) stop("base ", colnames(v)[k], " does not overlap the newer bases", call. = FALSE)
    fill <- is.na(out) & !is.na(older)
    out[fill] <- older[fill] * out[link] / older[link]
  }
  # sanity: on the newest base the index is 100 in its base month
  b0 <- which(tab$dates == max(bases))
  if (length(b0) == 1L && abs(out[b0] - 100) > 0.05) {
    stop("chained index is ", out[b0], " in the newest base month, expected 100", call. = FALSE)
  }
  ok <- !is.na(out)
  data.frame(date = tab$dates[ok], value = out[ok])
}

acquire_bfs_cpi <- function(url = source_url) {
  tmp <- tempfile(fileext = ".xlsx")
  on.exit(unlink(tmp), add = TRUE)
  message("Downloading ", url)
  utils::download.file(url, tmp, mode = "wb", quiet = TRUE,
                       headers = c("User-Agent" = "Mozilla/5.0 wai-webapp data pipeline"))
  tab <- read_index_table(tmp)
  cpi <- chain_bases(tab)
  if (anyDuplicated(cpi$date) || is.unsorted(cpi$date)) stop("dates not monthly and increasing", call. = FALSE)
  gaps <- length(seq(min(cpi$date), max(cpi$date), by = "month")) - nrow(cpi)
  if (gaps) stop(gaps, " month(s) missing inside the series", call. = FALSE)
  attr(cpi, "bases") <- colnames(tab$values)
  cpi
}

#' Write in the Datastream export layout
write_datastream_layout <- function(cpi, path) {
  lines <- c(paste("Name", series_name, sep = ";"),
             paste(format(cpi$date, "15.%m.%Y"), formatC(cpi$value, format = "f", digits = 6), sep = ";"))
  con <- file(path, open = "wb", encoding = "UTF-8")
  writeLines(lines, con, sep = "\n")
  close(con)
}


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  if (!requireNamespace("readxl", quietly = TRUE)) {
    stop("package 'readxl' is required: install.packages(\"readxl\")", call. = FALSE)
  }
  args <- commandArgs(trailingOnly = TRUE)
  out_file <- if (length(args) >= 1L) args[[1L]] else default_out

  cpi <- acquire_bfs_cpi()
  write_datastream_layout(cpi, out_file)
  message(sprintf("Wrote %d months (%s to %s) of %s to %s; %d bases chained onto %s = 100; latest %.1f",
                  nrow(cpi), format(min(cpi$date), "%Y-%m"), format(max(cpi$date), "%Y-%m"),
                  series_name, out_file, length(attr(cpi, "bases")),
                  format(max(as.Date(attr(cpi, "bases"))), "%B %Y"), utils::tail(cpi$value, 1)))
}
