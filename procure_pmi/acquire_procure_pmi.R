# Run from anywhere; paths are resolved from this script's location.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the procure.ch PMI series the WAI uses, from the monthly reports (#50)
#
# Finds procure.ch's monthly PMI reports, reads the three seasonally adjusted
# series the WAI uses out of them, and appends them to the existing (fixed)
# Datastream history:
#
#   WAI input   Datastream column                                       report
#   SWPURCHSQ   SW PURCHASING MANAGERS INDEX SADJ                       "PMI Industrie (saisonbereinigt)", PMI (s)
#   SWPMIPROQ   SW PURCHASING MANAGERS INDEX - OUTPUT SADJ             subcomponent "Produktion", Index (s)
#   SWPMIORDQ   SW PURCHASING MANAGERS INDEX - BACKLOG OF ORDERS SADJ  subcomponent "Auftragsbestand", Index (s)
#
# Finding the reports
#   procure.ch publishes one magazine article per release
#   (https://www.procure.ch/magazin -> /magazin/artikel/pmi-...), and each
#   article links the report PDF under
#   /fileadmin/user_upload/Dokumente/PROCURE_SWISS_MAGAZIN/PMI/<YYYY>/<MM>_PMI_....pdf
#   The file names are irregular (..._September_2026-DE.pdf,
#   ..._August_2026_Deutsch.pdf), so links are followed, never constructed.
#   The script pages back through the magazine until it has every month from
#   the end of the history on. The report month is read from the path (YYYY/MM).
#
# Reading a report
#   The tables are IMAGES in the PDF. The table page (the one captioned
#   "(s): saisonbereinigt") is rendered at 300 dpi, its LEFT half (the
#   industry tables) is OCR'd with tesseract, and parsed:
#     - "Produktion" / "Auftragsbestand": the 6th number = Index (s), the 7th
#       = its change on the previous month (+/- (s));
#     - "PMI Industrie (saisonbereinigt)": 13 months of PMI and PMI (s).
#   Every value in these tables has exactly one decimal; OCR sometimes drops
#   the point ("560" for 56.0), which is restored by that rule.
#
# Checks (a failed check stops the run; nothing is written)
#   1. the latest PMI (s) equals the headline in the report's text
#      ("... auf 55,3 ..."), and Produktion (s) equals the text where stated;
#   2. each component's "previous month" (Index (s) minus its change) agrees
#      with the previous report's own value, within revision tolerance;
#   3. against the fixed history, overlapping months are reported (PMI (s)
#      from the 13-month table vs Datastream) - seasonally adjusted values are
#      revised, so this is reported, and only gross gaps (> 1.5) stop the run.
#
# Revisions
#   Seasonally adjusted PMIs are revised each month. Each appended month takes
#   the NEWEST estimate: the headline from the newest report's 13-month table,
#   and the components from the next report (Index (s) minus change) where one
#   exists, else from the month's own report.
#
# Output
#   procure_pmi/pmi_from_reports.csv   values read from the public reports
#                                       (committed)
#   procure_pmi/pmi_extended.csv        the fixed Datastream history with the
#                                       report months appended, in the
#                                       Datastream layout (gitignored: the
#                                       history is licensed Datastream data)
#   procure_pmi/pdf/                    report cache (gitignored)
#
# Usage
#   Rscript procure_pmi/acquire_procure_pmi.R [<history.csv>]
#   default history: ../wai_ind/data/DATASTREAM/datastream_econ.csv
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

site <- "https://www.procure.ch"
magazine <- paste0(site, "/magazin")
max_pages <- 15                       # magazine pages to walk back at most
ua <- c("User-Agent" = "Mozilla/5.0 wai-webapp data pipeline")

cols <- c(pmi    = "SW PURCHASING MANAGERS INDEX SADJ",
          backlog = "SW PURCHASING MANAGERS INDEX - BACKLOG OF ORDERS SADJ",
          output = "SW PURCHASING MANAGERS INDEX - OUTPUT SADJ")

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "procure_pmi"
})
repo_root <- dirname(script_dir)
default_history <- file.path(dirname(repo_root), "wai_ind", "data", "DATASTREAM", "datastream_econ.csv")
pdf_dir <- file.path(script_dir, "pdf")

months_de <- c(Jan = 1, Feb = 2, "Mär" = 3, Mar = 3, Mrz = 3, Apr = 4, Mai = 5, Jun = 6,
               Jul = 7, Aug = 8, Sep = 9, Okt = 10, Nov = 11, Dez = 12)


# HELPERS -----------------------------------------------------------------

get_html <- function(url) {
  con <- url(url, headers = ua)
  on.exit(close(con))
  paste(readLines(con, warn = FALSE), collapse = "\n")
}
hrefs <- function(html, pattern) {
  h <- regmatches(html, gregexpr('href="[^"]+"', html))[[1]]
  h <- gsub("&amp;", "&", sub('^href="', "", sub('"$', "", h)))
  unique(h[grepl(pattern, h)])
}
abs_url <- function(u) ifelse(grepl("^https?://", u), u, paste0(site, u))

month_names <- c(januar = 1, februar = 2, maerz = 3, "märz" = 3, april = 4, mai = 5,
                 juni = 6, juli = 7, august = 8, september = 9, oktober = 10,
                 november = 11, dezember = 12)

#' A GUESS of the report month from its link, only to decide how far back to
#' page. The names are irregular - "09_PMI_September_2026-DE.pdf",
#' "04-PMI_April_2026_DE.pdf", "PMI_Februar_2026_Deutsch.pdf" (no number at
#' all) - so the month name + year in the file name or the article slug is
#' tried first, then a leading MM with the year folder. The month actually
#' used is read from the report itself (read_report()).
guess_month <- function(pdf_url, slug) {
  for (s in c(tolower(basename(pdf_url)), tolower(slug))) {
    for (n in names(month_names)) {
      m <- regmatches(s, regexec(paste0(n, "[-_ ]?(20[0-9]{2})"), s))[[1]]
      if (length(m) == 2) return(sprintf("%s-%02d", m[2], month_names[[n]]))
    }
  }
  m <- regmatches(pdf_url, regexec("/PMI/([0-9]{4})/([0-9]{2})[-_]", pdf_url))[[1]]
  if (length(m) == 3) return(sprintf("%s-%s", m[2], m[3]))
  NA_character_
}

#' Report PDFs found on the magazine, newest pages first, until `need_from`
find_reports <- function(need_from) {
  found <- data.frame(guess = character(0), url = character(0), stringsAsFactors = FALSE)
  page_url <- magazine
  for (p in seq_len(max_pages)) {
    html <- get_html(page_url)
    for (a in hrefs(html, "^/magazin/artikel/pmi")) {
      pdfs <- hrefs(get_html(abs_url(a)), "/PMI/[0-9]{4}/[^/]+\\.pdf$")
      for (u in pdfs) {
        found <- rbind(found, data.frame(guess = guess_month(u, a), url = abs_url(u)))
      }
    }
    found <- found[!duplicated(found$url), ]
    g <- found$guess[!is.na(found$guess)]
    if (length(g) && min(g) < need_from) break     # one report before the gap, for check 2
    nxt <- hrefs(html, sprintf("currentPage%%5D=%d&", p + 1L))
    if (!length(nxt)) break
    page_url <- abs_url(nxt[1])
  }
  found[order(found$guess), ]
}

#' "560" -> 56.0, "-07" -> -0.7, "55.9" -> 55.9 (all table values have one decimal)
one_decimal <- function(tok) {
  tok <- gsub(",", ".", tok)
  ifelse(grepl("\\.", tok), as.numeric(tok),
         as.numeric(sub("^(-?[0-9]*)([0-9])$", "\\1.\\2", tok)))
}
numbers_after <- function(line, label) {
  rest <- sub(paste0("^.*?", label), "", line)
  tok <- regmatches(rest, gregexpr("-?[0-9]+(\\.[0-9])?", rest))[[1]]
  one_decimal(tok)
}

#' Read one report
read_report <- function(path) {
  txt <- pdftools::pdf_text(path)
  pg <- which(grepl("saisonbereinigt", txt))[1]
  if (is.na(pg)) stop(basename(path), ": no table page", call. = FALSE)
  bm <- pdftools::pdf_render_page(path, page = pg, dpi = 300, numeric = TRUE)
  png_file <- tempfile(fileext = ".png")
  png::writePNG(bm[, seq_len(floor(dim(bm)[2] * 0.5)), , drop = FALSE], png_file)
  lines <- strsplit(tesseract::ocr(png_file, engine = tesseract::tesseract("eng")), "\n")[[1]]

  comp <- function(label) {
    l <- grep(paste0("^\\s*", label), lines, value = TRUE)[1]
    if (is.na(l)) stop(basename(path), ": row '", label, "' not found", call. = FALSE)
    v <- numbers_after(l, label)
    if (length(v) < 7) stop(basename(path), ": row '", label, "' unreadable", call. = FALSE)
    c(value = v[6], change = v[7])
  }
  prod <- comp("Produktion"); back <- comp("Auftragsbestand")

  # 13-month table: "2025 Sep 46.4 46.1" / "Okt 47.7 48.1"
  start <- grep("PMI Industrie \\(saisonbereinigt\\)", lines)[1]
  tab <- list(); year <- NA
  for (l in lines[(start + 1):length(lines)]) {
    tok <- strsplit(trimws(l), "\\s+")[[1]]
    if (length(tok) && grepl("^20[0-9]{2}$", tok[1])) { year <- as.integer(tok[1]); tok <- tok[-1] }
    if (length(tok) >= 3 && tok[1] %in% names(months_de) && !is.na(year)) {
      tab[[length(tab) + 1]] <- data.frame(month = sprintf("%d-%02d", year, months_de[[tok[1]]]),
                                           pmi_sa = one_decimal(tok[3]))
    } else if (length(tab) && grepl("^Quellen", l)) break
  }
  tab <- do.call(rbind, tab)
  if (is.null(tab) || nrow(tab) < 6) stop(basename(path), ": 13-month table unreadable", call. = FALSE)

  # check 1: the latest PMI (s) and Produktion (s) as stated in the prose
  prose <- paste(txt, collapse = " ")
  head_val <- regmatches(prose, regexec("Einkaufsmanagerindex \\(PMI\\)[^.]{0,80}?auf ([0-9]{2},[0-9])", prose))[[1]]
  if (length(head_val) == 2 && abs(as.numeric(sub(",", ".", head_val[2])) - utils::tail(tab$pmi_sa, 1)) > 0.05) {
    stop(basename(path), ": PMI (s) ", utils::tail(tab$pmi_sa, 1), " from the table, ",
         head_val[2], " in the text", call. = FALSE)
  }
  prod_txt <- regmatches(prose, regexec("Produktionskomponente[^.]{0,60}?auf ([0-9]{2},[0-9])", prose))[[1]]
  if (length(prod_txt) == 2 && abs(as.numeric(sub(",", ".", prod_txt[2])) - prod[["value"]]) > 0.05) {
    stop(basename(path), ": Produktion (s) ", prod[["value"]], " from the table, ",
         prod_txt[2], " in the text", call. = FALSE)
  }
  list(table = tab, output = prod, backlog = back)
}

read_history <- function(path) {
  h <- utils::read.csv2(path, dec = ".", check.names = FALSE, fileEncoding = "UTF-8-BOM",
                        stringsAsFactors = FALSE)
  names(h)[1] <- "Name"
  if (!all(cols %in% names(h))) stop("history lacks the PMI columns: ", path, call. = FALSE)
  h$month <- format(as.Date(h$Name, "%d.%m.%Y"), "%Y-%m")
  h
}


# MAIN --------------------------------------------------------------------

acquire_procure_pmi <- function(history_path = default_history) {
  hist <- read_history(history_path)
  last_hist <- max(hist$month[!is.na(hist[[cols[["pmi"]]]])])
  need_from <- format(seq(as.Date(paste0(last_hist, "-01")), by = "month", length.out = 2)[2], "%Y-%m")
  message("History ends ", last_hist, "; reports needed from ", need_from)

  rep_list <- find_reports(need_from)
  prior <- max(c("", rep_list$guess[!is.na(rep_list$guess) & rep_list$guess < need_from]))
  rep_list <- rep_list[is.na(rep_list$guess) | rep_list$guess >= need_from | rep_list$guess == prior, ]
  if (!nrow(rep_list)) stop("no PMI report found on ", magazine, call. = FALSE)
  dir.create(pdf_dir, showWarnings = FALSE)
  reports <- list()
  for (i in seq_len(nrow(rep_list))) {
    f <- file.path(pdf_dir, basename(rep_list$url[i]))
    if (!file.exists(f)) utils::download.file(rep_list$url[i], f, mode = "wb", quiet = TRUE, headers = ua)
    r <- read_report(f)
    m <- utils::tail(r$table$month, 1)          # the month the report is about
    if (!is.na(rep_list$guess[i]) && rep_list$guess[i] != m) {
      warning(basename(f), ": link suggests ", rep_list$guess[i], ", report is for ", m, call. = FALSE)
    }
    reports[[m]] <- r
    message("  read ", m, ": ", basename(f))
  }
  reports <- reports[order(names(reports))]
  months <- names(reports)
  gaps <- setdiff(format(seq(as.Date(paste0(min(months), "-01")), as.Date(paste0(max(months), "-01")),
                             by = "month"), "%Y-%m"), months)
  if (length(gaps)) stop("no report found for ", paste(gaps, collapse = ", "), call. = FALSE)
  newest <- reports[[utils::tail(months, 1)]]

  # long table of everything read (committed: public report values)
  long <- do.call(rbind, lapply(months, function(m) {
    r <- reports[[m]]
    rbind(data.frame(report = m, month = r$table$month, series = "pmi_sa", value = r$table$pmi_sa),
          data.frame(report = m, month = m, series = c("output_sa", "backlog_sa"),
                     value = c(r$output[["value"]], r$backlog[["value"]])))
  }))

  # check 2: previous month implied by each report vs the previous report
  for (k in seq_along(months)[-1]) {
    prev <- reports[[months[k - 1]]]; cur <- reports[[months[k]]]
    for (s in c("output", "backlog")) {
      implied <- cur[[s]][["value"]] - cur[[s]][["change"]]
      if (abs(implied - prev[[s]][["value"]]) > 1.5) {
        stop(sprintf("%s %s: implied previous month %.1f vs %.1f in the %s report",
                     months[k], s, implied, prev[[s]][["value"]], months[k - 1]), call. = FALSE)
      }
    }
  }

  # newest estimate per appended month
  new_months <- months[months >= need_from]
  est <- data.frame(month = new_months, stringsAsFactors = FALSE)
  est$pmi <- newest$table$pmi_sa[match(new_months, newest$table$month)]
  for (s in c("output", "backlog")) {
    est[[s]] <- vapply(new_months, function(m) {
      nxt <- months[which(months == m) + 1L]
      if (length(nxt) && !is.na(nxt)) reports[[nxt]][[s]][["value"]] - reports[[nxt]][[s]][["change"]]
      else reports[[m]][[s]][["value"]]
    }, numeric(1))
  }
  # a month older than the newest 13-month table falls back to its own report's table
  miss <- is.na(est$pmi)
  est$pmi[miss] <- vapply(est$month[miss], function(m) {
    t <- reports[[m]]$table; t$pmi_sa[t$month == m] }, numeric(1))

  # check 3: overlap of the newest 13-month table with the fixed history
  ov <- merge(newest$table, data.frame(month = hist$month, ds = hist[[cols[["pmi"]]]]), by = "month")
  ov <- ov[!is.na(ov$ds), ]
  if (nrow(ov)) {
    d <- ov$pmi_sa - ov$ds
    message(sprintf("  overlap with history (PMI s): %d months, max |diff| %.2f", nrow(ov), max(abs(d))))
    if (max(abs(d)) > 1.5) stop("PMI (s) disagrees with the history by more than 1.5 on the overlap", call. = FALSE)
  }

  list(long = long, appended = est, history = hist, overlap = ov, last_hist = last_hist)
}

write_extended <- function(res, path) {
  h <- res$history
  keep <- h[, c("Name", unname(cols))]
  keep <- keep[rowSums(!is.na(keep[, -1, drop = FALSE])) > 0 & h$month <= res$last_hist, ]
  app <- res$appended
  add <- data.frame(Name = format(as.Date(paste0(app$month, "-15")), "%d.%m.%Y"),
                    a = app$pmi, b = app$backlog, c = app$output)
  names(add) <- c("Name", unname(cols))
  out <- rbind(keep, add)
  f <- function(v) ifelse(is.na(v), "", format(v, trim = TRUE))
  lines <- c(paste(names(out), collapse = ";"),
             apply(out, 1, function(r) paste(c(r[1], f(as.numeric(r[-1]))), collapse = ";")))
  con <- file(path, open = "wb", encoding = "UTF-8")
  writeLines(lines, con, sep = "\n")
  close(con)
}


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  for (p in c("pdftools", "tesseract", "png")) {
    if (!requireNamespace(p, quietly = TRUE)) stop("package '", p, "' is required", call. = FALSE)
  }
  args <- commandArgs(trailingOnly = TRUE)
  history <- if (length(args) >= 1L) args[[1L]] else default_history
  res <- acquire_procure_pmi(history)

  utils::write.csv(res$long, file.path(script_dir, "pmi_from_reports.csv"), row.names = FALSE)
  write_extended(res, file.path(script_dir, "pmi_extended.csv"))
  message("Appended ", nrow(res$appended), " month(s) to the history (", res$last_hist, "):")
  print(res$appended, row.names = FALSE)
}
