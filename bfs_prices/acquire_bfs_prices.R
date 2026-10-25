# Run from anywhere; paths are resolved from this script's location.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire Swiss consumer prices, core inflation and producer prices from BFS (#50)
#
# Downloads three BFS files and writes the three WAI price inputs in the layout
# of the Datastream export they replace (wai_ind data/DATASTREAM/
# datastream_econ.csv): ";"-separated, a "Name" date column DD.MM.YYYY on the
# 15th, one column per series, empty for missing.
#
#   column                      WAI input    BFS source (asset orderNr)
#   SW CPI NADJ                 SWCONPRCE    su-d-05.02.10   LIK, Totalindex auf allen Basen
#                                                            seit Einfuehrung (lange Reihen)
#   SW PPI (2025M12=100) NADJ   SWPROPRCE    su-q-05.04.03.01-ppi-ipp
#                                                            Produzentenpreisindex (PPI), Total
#   SW CORE INFLATION 1 NADJ    SWCPCOREF    su-d-05.02.66   LIK (Dez 2025=100), Detailresultate
#                                                            seit 1982, Warenkorbstruktur 2025,
#                                                            inkl. Sondergliederungen [LIK25B25]
#
# Download route: https://www.bfs.admin.ch/bfsstatic/dam/assets/orderNr:<orderNr>/master
# always serves the newest release of an asset. The bfs.admin.ch/asset/de/...
# pages answer scripts with HTML, not the file.
#
# NOT seasonally adjusted (owner's decision, 2026-10-25)
#   BFS publishes all three unadjusted. Datastream's CPI and PPI were
#   seasonally adjusted ("SADJ"); here they are written unadjusted ("NADJ") and
#   adjusted in mfbdfm's data prep with X-13, as core inflation always was.
#
# Series construction
#   CPI   The long-series table holds the total CPI on every original base
#         (June 1914 = 100 ... December 2025 = 100), each from its base month
#         on. The newest base is used wherever it exists, and each older base is
#         rescaled at the month the newer one starts. The result equals the
#         newest base exactly (100.0 in its base month) and extends it back to
#         1921.
#   PPI   BFS back-computes every base to 1963, so the newest base column
#         (located by its "<YYYY>" marker) is used directly.
#   Core  "Kerninflation 1" = total CPI excluding fresh and seasonal products
#         and energy and fuels (BFS code 1170_103). Taken from the current-
#         basket detail file. Every run also REBUILDS it from the subgroups
#         for the months of the current weight year:
#           core = (100 R_total - w_fresh R_fresh - w_energy R_energy)
#                  / (100 - w_fresh - w_energy),  R = index / previous December
#         and stops if that differs from BFS's aggregate by more than 0.001.
#         Verified 2026-10-25 to 0.00014 for 2025 and 2026, i.e. the rounding
#         of the published indices.
#         Why the 2025-basket file and not the 2020-basket one (su-d-05.02.67):
#         the 2025 basket redefined "fresh and seasonal products" (weight 4.8%
#         in 2025, 10.7% in 2026), and this file back-casts the new definition.
#         The Datastream series the WAI used IS that back-cast. Against it,
#         this file matches to 6e-5 in level and y/y correlation 0.99998,
#         whereas the 2020 file chained at December 2025 reaches only 0.94.
#         When BFS moves to a new basket, `core_order_nr` must move with it.
#
# Usage
#   Rscript bfs_prices/acquire_bfs_prices.R
#   Rscript bfs_prices/acquire_bfs_prices.R <output.csv>
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

route <- "https://www.bfs.admin.ch/bfsstatic/dam/assets/orderNr:%s/master"
cpi_order_nr  <- "su-d-05.02.10"
ppi_order_nr  <- "su-q-05.04.03.01-ppi-ipp"
core_order_nr <- "su-d-05.02.66"                 # LIK25B25: current basket

col_cpi  <- "SW CPI NADJ"
col_ppi  <- "SW PPI (2025M12=100) NADJ"
col_core <- "SW CORE INFLATION 1 NADJ"

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "bfs_prices"
})
default_out <- file.path(script_dir, "bfs_prices.csv")


# HELPERS -----------------------------------------------------------------

xl_date <- function(x) as.Date(suppressWarnings(as.numeric(x)), origin = "1899-12-30")
num <- function(x) suppressWarnings(as.numeric(x))

download_asset <- function(order_nr) {
  f <- tempfile(fileext = ".xlsx")
  message("Downloading ", order_nr)
  utils::download.file(sprintf(route, order_nr), f, mode = "wb", quiet = TRUE,
                       headers = c("User-Agent" = "Mozilla/5.0 wai-webapp data pipeline"))
  f
}

read_sheet <- function(path, sheet) {
  as.data.frame(readxl::read_excel(path, sheet = sheet, col_names = FALSE, col_types = "text",
                                   .name_repair = "minimal", progress = FALSE),
                stringsAsFactors = FALSE)
}

#' Total CPI: chain the original bases onto the newest
build_cpi <- function(path) {
  x <- read_sheet(path, readxl::excel_sheets(path)[1])
  hr <- which(grepl("^Datum", x[[1]]))[1]
  if (is.na(hr)) stop("CPI: no 'Datum' header row; the layout has changed", call. = FALSE)
  bases <- xl_date(unlist(x[hr, -1]))
  cols <- which(!is.na(bases)) + 1L
  body <- x[(hr + 1L):nrow(x), , drop = FALSE]
  dates <- xl_date(body[[1]])
  keep <- !is.na(dates)
  v <- sapply(cols, function(j) num(body[[j]][keep]))
  b <- bases[cols - 1L]
  ord <- order(b, decreasing = TRUE)
  out <- v[, ord[1]]
  for (k in ord[-1]) {
    link <- which(!is.na(out) & !is.na(v[, k]))[1]
    if (is.na(link)) stop("CPI: base ", b[k], " does not overlap the newer bases", call. = FALSE)
    fill <- is.na(out) & !is.na(v[, k])
    out[fill] <- v[fill, k] * out[link] / v[link, k]
  }
  d <- dates[keep]
  if (abs(out[d == max(b)] - 100) > 0.05) stop("CPI: newest base month is not 100", call. = FALSE)
  data.frame(date = d, value = out)[!is.na(out), ]
}

#' PPI: the newest base column, by its "<YYYY>" marker
build_ppi <- function(path) {
  x <- read_sheet(path, "INDEX_m")
  mr <- which(apply(x, 1, function(r) any(grepl("^<[0-9]{4}>$", r))))[1]
  if (is.na(mr)) stop("PPI: no base marker row; the layout has changed", call. = FALSE)
  yrs <- num(sub("^<([0-9]{4})>$", "\\1", unlist(x[mr, ])))
  j <- which.max(yrs)
  dates <- xl_date(x[[3]])
  v <- num(x[[j]])
  ok <- !is.na(dates) & !is.na(v)
  out <- data.frame(date = dates[ok], value = v[ok])
  attr(out, "base") <- x[mr + 1L, j]
  out
}

#' Core inflation: BFS's aggregate, verified against its subgroup construction
build_core <- function(path) {
  x <- read_sheet(path, "INDEX_m")
  hr <- which(x[[1]] %in% "Code")[1]
  if (is.na(hr)) stop("core: no 'Code' header row; the layout has changed", call. = FALSE)
  h <- unlist(x[hr, ]); hn <- num(h)
  dc <- which(!is.na(hn) & hn > 20000)
  dates <- xl_date(hn[dc])
  wyear <- as.integer(h[14])                    # the weight year of column 14
  row <- function(code) {
    i <- which(x[[1]] == code)[1]
    if (is.na(i)) stop("core: position ", code, " not found", call. = FALSE)
    list(w = num(x[i, 14]), v = num(unlist(x[i, dc])))
  }
  tot <- row("100_100"); fresh <- row("1170_101"); energy <- row("1170_102"); core <- row("1170_103")

  dec <- which(dates == as.Date(sprintf("%d-12-01", wyear - 1L)))
  mo <- which(format(dates, "%Y") == as.character(wyear) & !is.na(core$v))
  if (length(dec) == 1L && length(mo)) {
    R <- function(s) s$v[mo] / s$v[dec]
    built <- core$v[dec] * (100 * R(tot) - fresh$w * R(fresh) - energy$w * R(energy)) /
      (100 - fresh$w - energy$w)
    err <- max(abs(built - core$v[mo]))
    if (err > 1e-3) {
      stop(sprintf("core: subgroup construction misses BFS's aggregate by %.4g", err), call. = FALSE)
    }
    message(sprintf("  core rebuilt from subgroups for %d month(s) of %d: max |diff| %.2g",
                    length(mo), wyear, err))
  }
  ok <- !is.na(core$v)
  data.frame(date = dates[ok], value = core$v[ok])
}

#' Merge on month and write the Datastream layout
write_datastream_layout <- function(series, path) {
  key <- function(d) format(d, "%Y-%m")
  months <- sort(unique(unlist(lapply(series, function(s) key(s$date)))))
  cols <- lapply(series, function(s) {
    v <- s$value[match(months, key(s$date))]
    ifelse(is.na(v), "", formatC(v, format = "f", digits = 6))
  })
  lines <- c(paste(c("Name", names(series)), collapse = ";"),
             do.call(paste, c(list(format(as.Date(paste0(months, "-15")), "%d.%m.%Y")), cols, sep = ";")))
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

  series <- list()
  series[[col_cpi]]  <- build_cpi(download_asset(cpi_order_nr))
  series[[col_ppi]]  <- build_ppi(download_asset(ppi_order_nr))
  series[[col_core]] <- build_core(download_asset(core_order_nr))
  write_datastream_layout(series, out_file)

  message("Wrote ", out_file)
  for (n in names(series)) {
    s <- series[[n]]
    message(sprintf("  %-27s %s to %s (%d months), latest %.4f", n, format(min(s$date), "%Y-%m"),
                    format(max(s$date), "%Y-%m"), nrow(s), utils::tail(s$value, 1)))
  }
}
