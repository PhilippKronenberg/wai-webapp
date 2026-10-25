# Run from anywhere; paths are resolved from this script's location.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire Zurich Airport monthly arrivals and departures (#50)
#
# Scans Flughafen Zürich's noise-monitoring page for every monthly
# "Lärmbulletin" PDF, downloads the ones not yet cached, reads the movements
# table on the bulletin's first content page ("Flugbewegungen auf Ab- und
# Anflugrouten"), and writes one monthly series of total arrivals (Total
# Anflüge) and total departures (Total Abflüge).
#
# Source
#   Flughafen Zürich AG, Lärmbulletin (monthly), listed on
#   https://www.flughafen-zuerich.ch/de/unternehmen/verantwortung/laerm-und-schallschutz/laermmonitoring
#   PDFs on media.flughafen-zuerich.ch, e.g. 2609_lrmbulletin_september.pdf.
#   Totals include VFR (Sichtflüge).
#
# How the series is assembled
#   Each bulletin carries a rolling ~13 months (the year to date plus the end
#   of the previous year), so months overlap across bulletins. Each month is
#   taken from the NEWEST bulletin that reports it; `n_bulletins` and
#   `revised` record how many reported it and whether they disagreed.
#
# Things the parser handles rather than assumes
#   - The file names are not regular (laermbulletin / lrmbulletin /
#     24011laermbulletinjanuar / _korr), so the links are read off the page,
#     never constructed. The bulletin month is the leading YYMM.
#   - The table page moves (page 3 or 4); it is found by its content.
#   - Thousands separators vary: ' (U+2019) in most, ',' in 2504.
#   - March appears as "Mär" and as "Mrz".
#   - 2021 bulletins have one more departure-route column. The departure total
#     is always the last value; the arrival total is always the 10th value
#     after the month (9 runway/time/VFR columns precede it).
#   - Every bulletin is checked against its own side table: arrivals +
#     departures must equal "Gesamt" for each month of the bulletin's year.
#     A mismatch stops the run rather than writing a wrong series.
#
# Usage
#   Rscript zurich_airport/acquire_zurich_airport.R
#   Rscript zurich_airport/acquire_zurich_airport.R <output.csv>
#
# The PDFs are cached in zurich_airport/pdf/ (gitignored), so a rerun only
# downloads bulletins it has not seen; delete the folder to re-fetch all.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

page_url <- "https://www.flughafen-zuerich.ch/de/unternehmen/verantwortung/laerm-und-schallschutz/laermmonitoring"

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "zurich_airport"
})
pdf_dir     <- file.path(script_dir, "pdf")
default_out <- file.path(script_dir, "zrh_flights_monthly.csv")

# Month labels as the bulletins actually write them: abbreviated in most,
# spelled out in some ("Juni", "Juli"), and March as both "Mär" and "Mrz".
months_de <- c(Jan = 1, Feb = 2, "Mär" = 3, "März" = 3, Mrz = 3, Mar = 3,
               Apr = 4, Mai = 5, Jun = 6, Juni = 6, Jul = 7, Juli = 7, Aug = 8,
               Sep = 9, Sept = 9, Okt = 10, Nov = 11, Dez = 12)
ua <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64) wai-webapp data pipeline"


# HELPERS -----------------------------------------------------------------

#' Bulletin PDF links on the monitoring page, with their YYMM
find_bulletins <- function(url = page_url) {
  html <- paste(readLines(url(url, headers = c("User-Agent" = ua)), warn = FALSE), collapse = "\n")
  links <- unique(regmatches(html, gregexpr(
    "https?://media\\.flughafen-zuerich\\.ch/[^\"'<> ]*?\\.pdf", html, ignore.case = TRUE))[[1]])
  links <- links[grepl("bulletin", basename(links), ignore.case = TRUE)]
  yymm <- substr(basename(links), 1, 4)
  ok <- grepl("^[0-9]{2}(0[1-9]|1[0-2])$", yymm)
  if (!any(ok)) stop("no Lärmbulletin links found on ", url, "; the page has changed", call. = FALSE)
  out <- data.frame(url = links[ok], file = basename(links[ok]), yymm = yymm[ok],
                    stringsAsFactors = FALSE)
  out[order(out$yymm, out$file), , drop = FALSE]
}

to_num <- function(x) {
  x <- gsub("[’'`´,]", "", x)
  x[x %in% c("-", "–")] <- "0"
  suppressWarnings(as.numeric(x))
}

#' Read the movements table of one bulletin
parse_bulletin <- function(path) {
  pages <- pdftools::pdf_text(path)
  pg <- which(grepl("Flugbewegungen auf", pages) & grepl("Total", pages) &
                grepl("Abfl", pages) & grepl("Anfl", pages))[1]
  if (is.na(pg)) stop(basename(path), ": movements table not found", call. = FALSE)
  lines <- strsplit(pages[pg], "\n", fixed = TRUE)[[1]]
  a0 <- grep("^\\s*Abfl", lines)[1]
  n0 <- grep("^\\s*Anfl", lines)[1]
  if (is.na(a0) || is.na(n0) || n0 < a0) stop(basename(path), ": table sections not found", call. = FALSE)

  rows <- function(idx) {
    out <- list()
    for (l in lines[idx]) {
      tok <- strsplit(trimws(l), "\\s+")[[1]]
      if (length(tok) < 4 || !(tok[1] %in% names(months_de)) || !grepl("^[0-9]{2}$", tok[2])) next
      out[[length(out) + 1L]] <- list(year = 2000L + as.integer(tok[2]),
                                      month = unname(months_de[tok[1]]), vals = tok[-(1:2)])
    }
    out
  }
  dep <- rows(a0:(n0 - 1L))
  arr <- rows(n0:length(lines))
  # VFR ("Sichtflüge") is the column before the departure total and the 9th
  # arrival value; the totals include it.
  d <- data.frame(year = sapply(dep, `[[`, "year"), month = sapply(dep, `[[`, "month"),
                  departures = sapply(dep, function(r) to_num(utils::tail(r$vals, 1))),
                  departures_vfr = sapply(dep, function(r) to_num(r$vals[length(r$vals) - 1L])))
  a <- data.frame(year = sapply(arr, `[[`, "year"), month = sapply(arr, `[[`, "month"),
                  arrivals = sapply(arr, function(r) to_num(r$vals[10])),
                  arrivals_vfr = sapply(arr, function(r) to_num(r$vals[9])))
  out <- merge(d, a, all = TRUE)
  if (!nrow(out) || anyNA(out$arrivals) || anyNA(out$departures) ||
      anyNA(out$arrivals_vfr) || anyNA(out$departures_vfr) ||
      any(out$arrivals_vfr > out$arrivals) || any(out$departures_vfr > out$departures)) {
    stop(basename(path), ": unreadable or missing totals", call. = FALSE)
  }

  # Cross-check against the side table "Gesamt <year> <previous year>": its
  # rows are the 2-3 tokens after the arrival total, month then the two years.
  cur_year <- max(out$year)
  side <- do.call(rbind, lapply(arr, function(r) {
    s <- r$vals[-(1:10)]
    if (length(s) >= 2 && s[1] %in% names(months_de)) {
      data.frame(month = unname(months_de[s[1]]), gesamt = to_num(s[2]))
    }
  }))
  if (!is.null(side)) {
    side <- side[!is.na(side$gesamt) & side$gesamt > 0, , drop = FALSE]
    chk <- merge(out[out$year == cur_year, ], side, by = "month")
    bad <- chk[chk$arrivals + chk$departures != chk$gesamt, , drop = FALSE]
    if (nrow(bad)) {
      stop(basename(path), ": arrivals + departures disagree with the side table for month(s) ",
           paste(bad$month, collapse = ", "), call. = FALSE)
    }
    attr(out, "checked") <- nrow(chk)
  }
  out
}

acquire_zurich_airport <- function() {
  b <- find_bulletins()
  dir.create(pdf_dir, showWarnings = FALSE, recursive = TRUE)
  new <- 0L
  for (i in seq_len(nrow(b))) {
    f <- file.path(pdf_dir, b$file[i])
    if (!file.exists(f)) {
      utils::download.file(b$url[i], f, mode = "wb", quiet = TRUE, headers = c("User-Agent" = ua))
      new <- new + 1L
    }
  }
  message(nrow(b), " bulletins listed (", b$yymm[1], " to ", utils::tail(b$yymm, 1), "), ",
          new, " newly downloaded")

  # A bulletin whose table cannot be read, or fails the side-table check, is
  # skipped with a warning: every month is carried by ~13 bulletins, so the
  # overlap covers it (2405 has a scrambled text layer, for instance). Two
  # things stay fatal: the NEWEST bulletin failing (its latest month would be
  # lost silently), and any month left uncovered (the gap check below).
  skipped <- character(0)
  parsed <- lapply(seq_len(nrow(b)), function(i) {
    x <- tryCatch(parse_bulletin(file.path(pdf_dir, b$file[i])), error = function(e) {
      if (i == nrow(b)) stop("the newest bulletin failed: ", conditionMessage(e), call. = FALSE)
      warning("skipped ", conditionMessage(e), call. = FALSE)
      skipped[length(skipped) + 1L] <<- b$file[i]
      NULL
    })
    if (is.null(x)) return(NULL)
    x$bulletin <- b$file[i]; x$yymm <- b$yymm[i]
    x
  })
  parsed <- parsed[!vapply(parsed, is.null, logical(1))]
  checked <- sum(vapply(parsed, function(x) as.integer(attr(x, "checked") %||% 0L), integer(1)))
  all <- do.call(rbind, parsed)
  all$key <- sprintf("%d-%02d", all$year, all$month)

  # newest bulletin wins; record how many reported each month and whether they agreed
  all <- all[order(all$key, all$yymm, all$bulletin, decreasing = c(FALSE, TRUE, TRUE),
                   method = "radix"), ]
  stats <- do.call(rbind, lapply(split(all, all$key), function(x)
    data.frame(key = x$key[1], n_bulletins = nrow(x),
               revised = length(unique(x$arrivals)) > 1 || length(unique(x$departures)) > 1)))
  latest <- all[!duplicated(all$key), ]
  out <- merge(latest, stats, by = "key")
  out <- data.frame(date = as.Date(paste0(out$key, "-01")),
                    arrivals = out$arrivals, departures = out$departures,
                    total = out$arrivals + out$departures,
                    arrivals_vfr = out$arrivals_vfr, departures_vfr = out$departures_vfr,
                    arrivals_ifr = out$arrivals - out$arrivals_vfr,
                    departures_ifr = out$departures - out$departures_vfr,
                    bulletin = out$bulletin, n_bulletins = out$n_bulletins, revised = out$revised)
  out <- out[order(out$date), ]
  rownames(out) <- NULL

  gaps <- setdiff(format(seq(min(out$date), max(out$date), by = "month"), "%Y-%m"),
                  format(out$date, "%Y-%m"))
  if (length(gaps)) {
    stop("month(s) covered by no readable bulletin: ", paste(gaps, collapse = ", "), call. = FALSE)
  }
  newest <- utils::tail(b$yymm, 1)
  if (!sprintf("20%s-%s", substr(newest, 1, 2), substr(newest, 3, 4)) %in% format(out$date, "%Y-%m")) {
    stop("the newest bulletin (", newest, ") does not report its own month", call. = FALSE)
  }
  attr(out, "checked") <- checked
  attr(out, "skipped") <- skipped
  out
}

`%||%` <- function(a, b) if (is.null(a)) b else a


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  if (!requireNamespace("pdftools", quietly = TRUE)) {
    stop("package 'pdftools' is required: install.packages(\"pdftools\")", call. = FALSE)
  }
  args <- commandArgs(trailingOnly = TRUE)
  out_file <- if (length(args) >= 1L) args[[1L]] else default_out

  dat <- acquire_zurich_airport()
  utils::write.csv(dat, out_file, row.names = FALSE)
  message("Wrote ", nrow(dat), " months (", format(min(dat$date)), " to ", format(max(dat$date)),
          ") to ", out_file, "; ", attr(dat, "checked"),
          " bulletin-months verified against the side-table totals; ",
          sum(dat$revised), " month(s) revised between bulletins; ",
          length(attr(dat, "skipped")), " unreadable bulletin(s) skipped",
          if (length(attr(dat, "skipped"))) paste0(" (", paste(attr(dat, "skipped"), collapse = ", "), ")"))
}
