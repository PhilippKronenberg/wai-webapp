# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire Swiss foreign trade in goods, seasonally adjusted, by CPA (#50)
#
# Downloads BAZG's seasonally adjusted foreign-trade data (dataset
# BAZG_SA_CPA) for exports and imports and writes one tidy monthly CSV: the
# business-cycle total ("konjunkturelles Total", Total 1, CPA code 0) and all
# CPA commodity groups, each as nominal and real value and chain index, raw,
# working-day adjusted, seasonally adjusted and trend.
#
# Source
#   Federal Office for Customs and Border Security (BAZG), foreign trade
#   statistics, dataset BAZG_SA_CPA on I14Y:
#   https://www.i14y.admin.ch/de/catalog/datasets/BAZG_SA_CPA/description
#   Files (one per direction, ";"-separated, "." decimal):
#   https://ocean.bazg.admin.ch/open-data-reports/SA_CPA_EXP_en_v1/SA_CPA_EXP_en_v1.csv
#   https://ocean.bazg.admin.ch/open-data-reports/SA_CPA_IMP_en_v1/SA_CPA_IMP_en_v1.csv
#   Monthly from 2012-01; updated monthly (the 2026-10-13 release ran to
#   2026-09). The latest months are provisional (status "prov").
#
# Two things the parser handles rather than assumes away
#   1. The files mix monthly rows (period 1-12) with quarterly aggregates
#      coded as period 24-27. Only the monthly rows are kept; the quarters are
#      sums of them.
#   2. The values come partly in scientific notation (1.6E10) and partly as
#      plain integers; both are read as numbers.
#
# Usage
#   Rscript bazg_trade/acquire_bazg_trade.R
#   Rscript bazg_trade/acquire_bazg_trade.R <output.csv>
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

base_url <- "https://ocean.bazg.admin.ch/open-data-reports"
files <- c(export = "SA_CPA_EXP_en_v1", import = "SA_CPA_IMP_en_v1")

# Resolved from the script's location, so it can be run from anywhere.
script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "bazg_trade"
})
default_out <- file.path(script_dir, "bazg_trade_sa.csv")

value_cols <- c("Nominal_Value", "Real_Value", "Chain_Index",
                "wdAdjusted_Nominal_Value", "wdAdjusted_Real_Value", "wdAdjusted_Chain_Index",
                "seasonalAdjusted_Nominal_Value", "seasonalAdjusted_Real_Value",
                "seasonalAdjusted_Chain_Index",
                "Trend_Nominal_Value", "Trend_Real_Value", "Trend_Chain_Index")


# HELPERS -----------------------------------------------------------------

#' Read one direction's file into the tidy monthly layout
read_direction <- function(path, direction) {
  raw <- utils::read.csv(path, sep = ";", dec = ".", stringsAsFactors = FALSE,
                         check.names = FALSE, colClasses = "character")
  need <- c("Commodity_Group_CPA", "Commodity_Group_CPA_txt", "year", "period",
            value_cols, "status", "Update")
  missing <- setdiff(need, names(raw))
  if (length(missing)) {
    stop(direction, ": columns missing from the BAZG file: ",
         paste(missing, collapse = ", "), "; the layout has changed", call. = FALSE)
  }
  period <- as.integer(raw$period)
  raw <- raw[!is.na(period) & period >= 1L & period <= 12L, , drop = FALSE]  # drop quarters (24-27)
  out <- data.frame(
    date      = as.Date(sprintf("%s-%02d-01", raw$year, as.integer(raw$period))),
    direction = direction,
    cpa       = raw$Commodity_Group_CPA,
    cpa_txt   = gsub("\\s*,\\s*", " - ", raw$Commodity_Group_CPA_txt),  # CSV-safe
    stringsAsFactors = FALSE
  )
  for (v in value_cols) out[[v]] <- as.numeric(raw[[v]])
  out$status  <- raw$status
  out$updated <- substr(raw$Update, 1, 10)
  if (anyNA(out$date)) stop(direction, ": unparseable year/period", call. = FALSE)
  if (anyDuplicated(out[c("date", "cpa")])) {
    stop(direction, ": duplicate month/CPA rows", call. = FALSE)
  }
  out
}

#' Download both directions and combine
acquire_bazg_trade <- function() {
  parts <- lapply(names(files), function(dir) {
    url <- sprintf("%s/%s/%s.csv", base_url, files[[dir]], files[[dir]])
    tmp <- tempfile(fileext = ".csv")
    on.exit(unlink(tmp), add = TRUE)
    message("Downloading ", url)
    utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
    read_direction(tmp, dir)
  })
  dat <- do.call(rbind, parts)
  dat <- dat[order(dat$direction, dat$cpa != "0", dat$cpa, dat$date), , drop = FALSE]
  rownames(dat) <- NULL
  dat
}


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  out_file <- if (length(args) >= 1L) args[[1L]] else default_out

  dat <- acquire_bazg_trade()
  dir.create(dirname(out_file), showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(dat, out_file, row.names = FALSE, na = "")

  tot <- dat[dat$cpa == "0", ]
  message("Wrote ", nrow(dat), " rows (", length(unique(dat$cpa)), " CPA groups incl. the total) to ",
          out_file)
  for (d in names(files)) {
    x <- tot[tot$direction == d, ]
    message(sprintf("  %s total: %d months, %s to %s, %d provisional, released %s",
                    d, nrow(x), format(min(x$date)), format(max(x$date)),
                    sum(x$status == "prov"), max(x$updated)))
  }
}
