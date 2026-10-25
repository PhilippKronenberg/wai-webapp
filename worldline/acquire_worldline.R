# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the Worldline card-payment series (Monitoring Consumption Switzerland) (#50)
#
# Downloads Worldline's acquiring data, ACQ_Transaction_Type.csv, from the
# public Switch Drive share of Monitoring Consumption Switzerland, and builds
# the daily series that wai_ind reads:
#
#   ktzh_non_online_retail.csv            -> stat_einkauf
#     "Non-Online Retail Sales, Swiss-Wide Volume in CHF": Channel == POS,
#     summed over every payment method and cardholder origin.
#   ktzh_credit_card_transactions_swiss.csv
#     "Credit Card Transactions, Swiss-Wide Scaled Value": Payment method ==
#     Credit, Channel in {E-comm, POS}, summed over cardholder origins.
#
# Both rules are the ones of create_swiss_consumption_time_series.js in
# wai_ind (data/Swiss Consumption Monitoring/), which built the files used so
# far, and they are written in the same layout ("Date;<name>", DD.MM.YYYY), so
# the output replaces wai_ind's data/dataset files directly. The full daily
# table of that script (domestic/foreign x credit/debit) is written as well.
#
# Source
#   Monitoring Consumption Switzerland (University of St. Gallen, UNIL-E4S,
#   Novalytica; data from Worldline), https://monitoringconsumption.com
#   Share:  https://drive.switch.ch/index.php/s/yLISs3KVE7ASE68
#   WebDAV: https://drive.switch.ch/public.php/webdav/2_ACQUIRING%20DATA/
#           (share token as user name, empty password; no login)
#   Daily from 2019-01-01, updated weekly. "Scaled Value" is turnover divided
#   by the average daily turnover of January 2020, i.e. an index, not CHF.
#
# Checks (a failed check stops the run)
#   1. The file has the expected columns and the dimensions the rules filter
#      on (Credit, POS, E-comm), and no overall "All" rows that the sums
#      would count twice.
#   2. The newest date is at most 21 days old (the share is updated weekly).
#   3. If old files are given, the new series is compared with them on their
#      overlap and the differences are reported; more than 1% median absolute
#      difference stops the run (it means the rules or the source changed).
#
# Usage
#   Rscript worldline/acquire_worldline.R
#   Rscript worldline/acquire_worldline.R <dir with old ktzh_*.csv files>
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

webdav <- "https://drive.switch.ch/public.php/webdav/2_ACQUIRING%20DATA/"
source_file <- "ACQ_Transaction_Type.csv"
# Basic auth for the public share: base64("yLISs3KVE7ASE68:"), the share
# token with an empty password.
share_auth <- "Basic eUxJU3MzS1ZFN0FTRTY4Og=="

# Resolved from the script's location, so it can be run from anywhere.
script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "worldline"
})
raw_dir <- file.path(script_dir, "raw")

series <- list(
  ktzh_non_online_retail = list(
    name = "Non-Online Retail Sales, Swiss-Wide Volume in CHF",
    keep = function(x) x$Channel == "POS"
  ),
  ktzh_credit_card_transactions_swiss = list(
    name = "Credit Card Transactions, Swiss-Wide Scaled Value",
    keep = function(x) x$method == "Credit" & x$Channel %in% c("E-comm", "POS")
  ),
  # The WAI input anz_kktrans_ch counts credit-card transactions (SPA, 2020
  # only). The Worldline count matches it: weekly log changes correlate 0.977
  # over the 52 weeks of 2020, against 0.905 for turnover.
  anz_kktrans_ch = list(
    name = "Credit Card Transactions, Swiss-Wide Scaled Number of Transactions",
    keep = function(x) x$method == "Credit" & x$Channel %in% c("E-comm", "POS"),
    measure = "count"
  )
)


# HELPERS -----------------------------------------------------------------

#' Download one file from the share's WebDAV endpoint
download_share_file <- function(file, dest) {
  dir.create(dirname(dest), showWarnings = FALSE, recursive = TRUE)
  utils::download.file(paste0(webdav, file), dest, mode = "wb", quiet = TRUE,
                       method = "libcurl", headers = c(Authorization = share_auth))
  dest
}

#' Read ACQ_Transaction_Type.csv and check it is what the rules expect
read_acquiring <- function(path) {
  x <- utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
  need <- c("Date", "Payment method", "Cardholder origin", "Channel", "Scaled Value",
            "Scaled Number of Transactions")
  miss <- setdiff(need, names(x))
  if (length(miss)) stop("missing columns in ", source_file, ": ", paste(miss, collapse = ", "))
  x$method <- x[["Payment method"]]
  x$origin <- x[["Cardholder origin"]]
  x$value <- suppressWarnings(as.numeric(x[["Scaled Value"]]))
  x$value[is.na(x$value)] <- 0           # as the JS builder: missing counts as 0
  x$count <- suppressWarnings(as.numeric(x[["Scaled Number of Transactions"]]))
  x$count[is.na(x$count)] <- 0
  x$Date <- as.Date(x$Date)
  if (anyNA(x$Date)) stop("unparseable dates in ", source_file)

  if (!all(c("Credit", "Debit") %in% x$method) || !all(c("POS", "E-comm") %in% x$Channel))
    stop("expected payment methods Credit/Debit and channels POS/E-comm")
  # A row that is a total over methods or origins would be summed together
  # with its own components. The file has none (only Debit's channel "All" on
  # a few early days and Mobile's "all/all", both outside the filters).
  if (any(x$method %in% c("All", "all")) || any(x$origin %in% c("All", "all") & x$Channel == "POS"))
    stop("the file now has total rows the sums would double count; revisit the rules")
  x
}

#' Daily sum of the rows a rule keeps, over every date in the file
daily_sum <- function(x, keep, measure = "value") {
  dates <- sort(unique(x$Date))
  s <- tapply(x[[measure]][keep(x)], x$Date[keep(x)], sum)
  out <- stats::setNames(rep(0, length(dates)), as.character(dates))
  out[names(s)] <- s
  data.frame(date = dates, value = unname(out))
}

#' Write one series in wai_ind's layout: "Date;<name>", DD.MM.YYYY
write_ktzh <- function(d, name, path) {
  lines <- c(paste0("Date;", name),
             paste0(format(d$date, "%d.%m.%Y"), ";", as.character(round(d$value, 8))))
  writeLines(lines, path, useBytes = TRUE)
}

read_ktzh <- function(path) {
  x <- utils::read.csv(path, sep = ";", check.names = FALSE, stringsAsFactors = FALSE)
  data.frame(date = as.Date(x[[1]], "%d.%m.%Y"), value = as.numeric(x[[2]]))
}

#' Compare a new series with an old file on their overlap
compare_old <- function(new, old_path) {
  old <- read_ktzh(old_path)
  m <- merge(new, old, by = "date", suffixes = c(".new", ".old"))
  m <- m[m$value.old != 0, ]
  rel <- abs(m$value.new / m$value.old - 1)
  list(days = nrow(m), from = min(m$date), to = max(m$date),
       old_end = max(old$date), median_rel = stats::median(rel),
       max_rel = max(rel), share_exact = mean(abs(m$value.new - m$value.old) < 1e-7))
}


# RUN ---------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
old_dir <- if (length(args)) args[1] else NA

raw <- download_share_file(source_file, file.path(raw_dir, source_file))
x <- read_acquiring(raw)
last <- max(x$Date)
message(source_file, ": ", nrow(x), " rows, ", min(x$Date), " to ", last)
if (Sys.Date() - last > 21) stop("newest date ", last, " is more than 21 days old")

for (id in names(series)) {
  d <- daily_sum(x, series[[id]]$keep, if (is.null(series[[id]]$measure)) "value" else series[[id]]$measure)
  out <- file.path(script_dir, paste0(id, ".csv"))
  write_ktzh(d, series[[id]]$name, out)
  message("wrote ", out, " (", nrow(d), " days)")
  if (!is.na(old_dir)) {
    old <- file.path(old_dir, paste0(id, ".csv"))
    if (file.exists(old)) {
      cmp <- compare_old(read_ktzh(out), old)
      message(sprintf("  vs old file (to %s): %d common days %s..%s, %.1f%% identical, median |rel diff| %.2e, max %.2e",
                      cmp$old_end, cmp$days, cmp$from, cmp$to, 100 * cmp$share_exact,
                      cmp$median_rel, cmp$max_rel))
      if (cmp$median_rel > 0.01) stop("new ", id, " differs from the old file by more than 1% (median)")
    }
  }
}

# The full daily table of the JS builder, for reference.
groups <- list(
  credit = function(x) x$method == "Credit" & x$Channel %in% c("E-comm", "POS"),
  pos_all_methods = function(x) x$Channel == "POS",
  domestic_credit = function(x) x$origin == "Domestic" & x$method == "Credit" & x$Channel %in% c("E-comm", "POS"),
  domestic_debit = function(x) x$origin == "Domestic" & x$method == "Debit" & x$Channel %in% c("E-comm", "POS"),
  foreign_credit = function(x) x$origin == "Foreign" & x$method == "Credit" & x$Channel %in% c("E-comm", "POS"),
  foreign_debit = function(x) x$origin == "Foreign" & x$method == "Debit" & x$Channel %in% c("E-comm", "POS")
)
tab <- data.frame(date = sort(unique(x$Date)))
for (g in names(groups)) tab[[g]] <- round(daily_sum(x, groups[[g]])$value, 8)
utils::write.csv(tab, file.path(script_dir, "worldline_daily.csv"), row.names = FALSE, quote = FALSE)
message("wrote ", file.path(script_dir, "worldline_daily.csv"))
