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
# The WAI's trade inputs (#50): bazg_trade_wai.csv
#   The WAI inputs ch.ozd.e.wa.index.re.d11 / ch.ozd.i.wa.index.re.d11 (OZD
#   real indices from KOF's database) are not available openly. They are
#   replaced by the SEASONALLY ADJUSTED NOMINAL total of exports and imports
#   from 1995, from dataset BAZG_SA_LAND (seasonally adjusted data by country):
#   https://www.i14y.admin.ch/de/catalog/datasets/BAZG_SA_LAND/description
#   https://ocean.bazg.admin.ch/open-data-reports/SA_COUNTRY_{EXP,IMP}_en_v1/...csv
#   That file has 49 large countries plus regional aggregates, not every
#   country. The total is the sum of the six continents (Europe, Africa, Asia,
#   North America, Central and South America, Oceania), which partition it:
#   their UNADJUSTED sum equals the CPA total exactly (checked on every run).
#   Middle East (part of Asia), EU and Eurozone (part of Europe) are left out.
#   BAZG adjusts each continent separately, so the adjusted sum differs from
#   the CPA file's adjusted total by a few percent at most.
#   Chosen 2026-10-25: without the COVID quarters it correlates better with
#   quarterly GDP growth (exports 0.52, imports 0.52) than the old series
#   (0.24, 0.43), BAZG's real series (0.19, 0.31) or the nominal series
#   deflated by BFS export/import prices (0.44, 0.35).
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
wai_out <- file.path(script_dir, "bazg_trade_wai.csv")
country_files <- c(export = "SA_COUNTRY_EXP_en_v1", import = "SA_COUNTRY_IMP_en_v1")
continents <- c("100800", "100810", "100820", "100844", "100857", "100870")

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

#' The WAI's trade inputs: seasonally adjusted nominal totals from 1995
#'
#' Sums the six continents of BAZG_SA_LAND per month and direction, and
#' checks against the CPA file's unadjusted total that they cover all of it.
acquire_wai_trade <- function(cpa) {
  cols <- c("Nominal_Value", "wdAdjusted_Nominal_Value", "seasonalAdjusted_Nominal_Value",
            "trend_Nominal_Value")
  parts <- lapply(names(country_files), function(dir) {
    url <- sprintf("%s/%s/%s.csv", base_url, country_files[[dir]], country_files[[dir]])
    tmp <- tempfile(fileext = ".csv")
    on.exit(unlink(tmp), add = TRUE)
    message("Downloading ", url)
    utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
    raw <- utils::read.csv(tmp, sep = ";", stringsAsFactors = FALSE, colClasses = "character")
    miss <- setdiff(c("country", "year", "period", cols, "status", "Update"), names(raw))
    if (length(miss)) stop(dir, ": columns missing from the country file: ", paste(miss, collapse = ", "),
                           call. = FALSE)
    if (!all(continents %in% raw$country)) stop(dir, ": continent codes missing from the country file",
                                                call. = FALSE)
    raw <- raw[raw$country %in% continents & as.integer(raw$period) %in% 1:12, ]
    raw$date <- sprintf("%s-%02d-01", raw$year, as.integer(raw$period))
    for (v in cols) raw[[v]] <- as.numeric(raw[[v]])
    n <- tapply(raw$country, raw$date, length)
    if (any(n != length(continents))) stop(dir, ": months without all six continents", call. = FALSE)
    out <- stats::aggregate(raw[cols], by = list(date = raw$date), FUN = sum)
    st <- tapply(raw$status, raw$date, function(s) if (all(s == "def")) "def" else "prov")
    out$status <- st[out$date]
    out$updated <- max(substr(raw$Update, 1, 10))
    out$direction <- dir
    # Coverage: the unadjusted continents equal the unadjusted CPA total, to
    # rounding (5e-6), except for a few months whose later corrections reached
    # only one of the two files (2026-10: six import months in 2013-14, up to
    # 0.4%). Those are reported; more than 1% would mean a missing region.
    tot <- cpa[cpa$direction == dir & cpa$cpa == "0", c("date", "Nominal_Value")]
    m <- merge(out, transform(tot, date = format(date)), by = "date", suffixes = c("", ".cpa"))
    rel <- abs(m$Nominal_Value / m$Nominal_Value.cpa - 1)
    if (!nrow(m) || max(rel) > 0.01) stop(dir, ": the six continents do not add up to the total (max ",
                                         signif(max(rel), 3), ")", call. = FALSE)
    off <- m$date[rel > 1e-5]
    message(sprintf("  %s: continents = CPA total on %d of %d months (max rel diff %.1e)%s", dir,
                    nrow(m) - length(off), nrow(m), max(rel),
                    if (length(off)) paste0("; differing: ", paste(off, collapse = ", ")) else ""))
    out
  })
  w <- do.call(rbind, parts)
  w$date <- as.Date(w$date)
  w[order(w$direction, w$date), c("date", "direction", cols, "status", "updated")]
}


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  out_file <- if (length(args) >= 1L) args[[1L]] else default_out

  dat <- acquire_bazg_trade()
  dir.create(dirname(out_file), showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(dat, out_file, row.names = FALSE, na = "")

  wai <- acquire_wai_trade(dat)
  utils::write.csv(wai, wai_out, row.names = FALSE, na = "")
  for (d in names(country_files)) {
    x <- wai[wai$direction == d, ]
    message(sprintf("Wrote %s %s: %s to %s (%d months)", basename(wai_out), d, format(min(x$date)),
                    format(max(x$date)), nrow(x)))
  }

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
