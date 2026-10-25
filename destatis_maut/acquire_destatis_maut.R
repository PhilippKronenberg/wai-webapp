# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the German truck-toll mileage index (Lkw-Maut-Fahrleistungsindex) (#50)
#
# Reads Destatis' download page for the daily truck-toll mileage index,
# finds the current workbook (statistischer-bericht-lkw-maut-
# fahrleistungsindex-5421901.xlsx, version in the link), downloads it, and
# reads table 42191-b01: daily from 2008-01-01, 2021 = 100, unadjusted,
# calendar and seasonally adjusted (KSB, by the Deutsche Bundesbank), and the
# centred 7-day moving average of KSB.
#
#   Destatis_Truck_toll_mileage.csv   the 7-day average of KSB, the WAI input
#                                     Lkw-Maut-Fahrleistungsindex_DE, in the
#                                     layout of wai_ind's file of that name
#   destatis_maut_daily.csv           the whole table
#
# Checks (a failed check stops the run)
#   1. The page links the workbook, and table 42191-b01 has its seven columns.
#   2. The 7-day average equals the centred 7-day mean of KSB (to rounding),
#      i.e. the column is what its name says.
#   3. The newest date is at most 21 days old (Destatis updates weekly).
#
# Usage
#   Rscript destatis_maut/acquire_destatis_maut.R
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

base <- "https://www.destatis.de"
page_url <- paste0(base, "/DE/Themen/Branchen-Unternehmen/Industrie-Verarbeitendes-Gewerbe/",
                   "Tabellen/Lkw-Maut-Fahrleistungsindex-Daten.html")
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
series_name <- paste("Germany, Truck Toll Mileage Index, Total, Calendar Adjusted (X13 JDemetra+),",
                     "SA (X13 JDemetra+), Index, 7 Day Moving Average")

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "destatis_maut"
})

suppressPackageStartupMessages(library(readxl))


# RUN ---------------------------------------------------------------------

fetch <- function(url, dest) {
  utils::download.file(url, dest, mode = "wb", quiet = TRUE, method = "libcurl",
                       headers = c(`User-Agent` = user_agent))
  dest
}

html <- paste(readLines(fetch(page_url, tempfile(fileext = ".html")), warn = FALSE), collapse = "\n")
link <- regmatches(html, regexpr("/DE/[^\"]*statistischer-bericht-lkw-maut-fahrleistungsindex-[0-9]+\\.xlsx[^\"]*", html))
if (!length(link)) stop("no workbook link on ", page_url)
link <- paste0(base, gsub("&amp;(amp;)?", "&", link))
message("workbook: ", link)
wb <- fetch(link, tempfile(fileext = ".xlsx"))

x <- suppressWarnings(as.data.frame(read_excel(wb, sheet = "42191-b01", skip = 3)))
need <- c("Datum", "unbereinigt", "Kalender- und saisonbereinigt (KSB)", "gleitender 7-Tage-Durchschnitt KSB")
if (!all(need %in% names(x))) stop("table 42191-b01 lacks: ", paste(setdiff(need, names(x)), collapse = ", "))
x <- x[!is.na(suppressWarnings(as.Date(x$Datum))), ]
d <- data.frame(date = as.Date(x$Datum),
                unadjusted = as.numeric(x$unbereinigt),
                ksb = as.numeric(x[["Kalender- und saisonbereinigt (KSB)"]]),
                ksb_ma7 = suppressWarnings(as.numeric(x[["gleitender 7-Tage-Durchschnitt KSB"]])))
d <- d[order(d$date), ]
if (anyDuplicated(d$date)) stop("duplicate dates")
if (Sys.Date() - max(d$date) > 21) stop("newest date ", max(d$date), " is more than 21 days old")

centred <- as.numeric(stats::filter(d$ksb, rep(1 / 7, 7), sides = 2))
dev <- abs(centred - d$ksb_ma7)
if (stats::median(dev, na.rm = TRUE) > 0.06) stop("the 7-day column is not the centred mean of KSB")

utils::write.csv(d, file.path(script_dir, "destatis_maut_daily.csv"), row.names = FALSE, quote = FALSE)
ma <- d[!is.na(d$ksb_ma7), ]
writeLines(c(paste0(";", series_name), paste0(format(ma$date, "%d.%m.%Y"), ";", ma$ksb_ma7)),
           file.path(script_dir, "Destatis_Truck_toll_mileage.csv"), useBytes = TRUE)
message(sprintf("wrote %d days, %s to %s (7-day average to %s)", nrow(d), min(d$date), max(d$date), max(ma$date)))
