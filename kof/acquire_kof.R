# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the KOF series of the `mfbdfm` collection (wai-webapp, "KOF Data
# pipeline")
#
# Downloads every time series in the KOF Time Series Database collection
# `mfbdfm` (owner `kphilipp`), curated on the KOF TS Explorer:
#   https://ts-explorer.kof.ethz.ch/collections?collection=mfbdfm
# and writes them out as tidy CSVs: the observations, the metadata, and the
# vintage/release information of what was downloaded.
#
# Source
#   KOF Time Series Database API, via the tsdbapi R package
#   https://tsdb-api.kof.ethz.ch/v2/docs
#   https://github.com/KOF-ch/tsdbapi-R  (not on CRAN; see below)
#   Publisher   KOF Swiss Economic Institute, ETH Zurich
#
# Authentication -- the one thing that differs from the other pipelines
#   The collection belongs to a KOF user, so reading it needs that user's
#   credentials. Interactively, tsdbapi opens KOF's login page. A scheduled or
#   otherwise non-interactive run cannot log in, and needs an API key in the
#   environment variable TSDBAPI_API_KEY (tsdbapi reads it automatically):
#
#     api_key <- tsdbapi::create_user_api_key()   # once, interactively;
#                                                 # invalidates any older key
#
#   NEVER commit the key. Put it in ~/.Renviron (TSDBAPI_API_KEY=...) or, for a
#   GitHub Actions run, in a repository secret. Without a key, a
#   non-interactive run stops here with that instruction rather than hanging
#   on a login prompt nobody can answer.
#
# Redistribution -- read before committing the output
#   The other pipelines in this repository commit their CSVs, because their
#   sources are open data. A KOF collection may hold non-public series, which
#   KOF does not license for redistribution, and this repository is PUBLIC.
#   kof/.gitignore therefore keeps the three CSVs out of git until it has been
#   confirmed which series may be published (see the issue).
#
# Usage
#   Rscript kof/acquire_kof.R
#   Rscript kof/acquire_kof.R <output_dir>
#   Rscript kof/acquire_kof.R <output_dir> <valid_on YYYY-MM-DD>
#
# The third form reads the vintage valid on a past date instead of the latest,
# which is how to rebuild what was known at that date.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

collection <- "mfbdfm"
owner      <- "kphilipp"
locale     <- "en"

# The CSVs land next to this script; see kof/.gitignore before committing them.
# Resolved from the script's own path, not the working directory: the first
# real run (2026-10-25) was started from inside kof/, and a relative "kof"
# then wrote to kof/kof/.
script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "kof"
})
default_out_dir <- script_dir


# HELPERS -----------------------------------------------------------------

#' Dates of a ts object's observations, as the first day of each period
#'
#' tsdbapi returns a regular series as `ts` with its frequency, so the period a
#' value belongs to is implied by the frequency: monthly 2024.25 is April, not
#' "a quarter of the way through the year". The period index is recovered by
#' rounding (time is floating point, so 2024.25 may arrive as 2024.2499999) and
#' the first day of that period built from it; a plain decimal-to-date
#' conversion would land mid-month.
ts_dates <- function(x) {
  f <- stats::frequency(x)
  tt <- as.numeric(stats::time(x))
  if (f %in% c(1, 4, 12)) {
    period <- round(tt * f)                 # periods since year 0
    year <- period %/% f
    month <- (period %% f) * (12 / f) + 1
    return(as.Date(sprintf("%d-%02d-01", as.integer(year), as.integer(month))))
  }
  # Anything else (e.g. 52) has no calendar meaning tsdbapi encodes; keep the
  # closest day and say so, rather than pretend to a precision it does not have.
  warning("frequency ", f, " has no exact calendar mapping; dates are approximate",
          call. = FALSE)
  as.Date(lubridate::date_decimal(tt))
}

#' One series (ts or xts) as a long data frame
series_to_long <- function(x, key) {
  if (inherits(x, "xts") || inherits(x, "zoo")) {
    d <- as.Date(zoo::index(x))
    v <- as.numeric(zoo::coredata(x))
    freq <- NA_real_
  } else if (stats::is.ts(x)) {
    d <- ts_dates(x)
    v <- as.numeric(x)
    freq <- stats::frequency(x)
  } else {
    stop("series '", key, "' is a ", class(x)[1], ", expected ts or xts",
         call. = FALSE)
  }
  out <- data.frame(key = key, date = d, value = v, frequency = freq,
                    stringsAsFactors = FALSE)
  # A missing value inside the API's range is a gap, not a zero; keep it out
  # of the file rather than writing an empty value that reads as zero.
  out[!is.na(out$value), , drop = FALSE]
}

#' Flatten the metadata into one row per series
#'
#' read_collection_ts_metadata() returns whatever shape jsonlite makes of the
#' API's JSON: a data frame, or a list keyed by series. Either way, nested
#' fields become `parent.child` columns and multi-valued ones are joined with
#' "; ", so the result is a plain table that writes cleanly to CSV.
flatten_metadata <- function(md) {
  # Recursive rather than unlist(): unlist() names the elements of a vector
  # field "unit1", "unit2", ..., which would split one field over columns.
  flatten <- function(x, prefix) {
    if (is.list(x)) {
      nm <- names(x)
      if (is.null(nm)) nm <- rep("", length(x))
      out <- list()
      for (i in seq_along(x)) {
        p <- if (!nzchar(nm[i])) prefix else if (nzchar(prefix)) paste0(prefix, ".", nm[i]) else nm[i]
        out <- c(out, flatten(x[[i]], p))
      }
      return(out)
    }
    v <- unique(as.character(x[!is.na(x)]))
    stats::setNames(list(if (length(v)) paste(v, collapse = "; ") else NA_character_), prefix)
  }
  as_row <- function(entry, key) {
    flat <- flatten(as.list(entry), "")
    flat <- flat[nzchar(names(flat))]
    # the same field reached twice (e.g. via an unnamed list) is joined, not duplicated
    vals <- lapply(split(unlist(flat, use.names = FALSE), names(flat))[unique(names(flat))],
                   function(v) { v <- unique(v[!is.na(v)]); if (length(v)) paste(v, collapse = "; ") else NA_character_ })
    as.data.frame(c(list(key = key), vals), stringsAsFactors = FALSE, check.names = FALSE)
  }
  if (is.data.frame(md)) {
    keys <- if ("ts_key" %in% names(md)) md$ts_key else rownames(md)
    rows <- lapply(seq_len(nrow(md)), function(i) as_row(md[i, , drop = FALSE], keys[i]))
  } else if (is.list(md) && length(md)) {
    keys <- if (!is.null(names(md)) && all(nzchar(names(md)))) names(md)
            else vapply(md, function(e) as.character(e$ts_key %||% NA), character(1))
    rows <- Map(as_row, md, keys)
  } else {
    return(data.frame(key = character(0), stringsAsFactors = FALSE))
  }
  all_cols <- unique(unlist(lapply(rows, names)))
  rows <- lapply(rows, function(r) { r[setdiff(all_cols, names(r))] <- NA; r[all_cols] })
  out <- do.call(rbind, rows)
  out <- out[, unique(c("key", setdiff(names(out), c("key", "ts_key")))), drop = FALSE]
  rownames(out) <- NULL
  out
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Download the collection and return the three tables
acquire_kof <- function(valid_on = Sys.Date()) {
  message("Reading collection '", collection, "' (owner ", owner, "), valid on ",
          format(valid_on))
  tsl <- tsdbapi::read_collection_ts(collection, owner = owner, valid_on = valid_on)
  if (!length(tsl)) stop("the collection returned no series", call. = FALSE)

  obs <- do.call(rbind, Map(series_to_long, tsl, names(tsl)))
  rownames(obs) <- NULL

  md <- tsdbapi::read_collection_ts_metadata(collection, owner = owner, locale = locale)
  meta <- flatten_metadata(md)
  missing_meta <- setdiff(names(tsl), meta$key)
  if (length(missing_meta)) {
    warning(length(missing_meta), " series without metadata: ",
            paste(utils::head(missing_meta, 5), collapse = ", "), call. = FALSE)
  }

  # Which vintage each series is, and when it was released. Not essential to
  # the data, so a failure here is reported and skipped, not fatal.
  rel <- tryCatch(
    flatten_metadata(tsdbapi::read_collection_ts_release(collection, owner = owner,
                                                         valid_on = valid_on)),
    error = function(e) {
      warning("release information not read: ", conditionMessage(e), call. = FALSE)
      NULL
    })

  list(observations = obs, metadata = meta, release = rel)
}


# RUN ---------------------------------------------------------------------

if (sys.nframe() == 0L) {
  for (p in c("tsdbapi", "zoo", "lubridate")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      stop("package '", p, "' is required", if (p == "tsdbapi")
        ': remotes::install_github("KOF-ch/tsdbapi-R") -- it is not on CRAN'
        else paste0(': install.packages("', p, '")'), call. = FALSE)
    }
  }
  if (!interactive() && !nzchar(Sys.getenv("TSDBAPI_API_KEY"))) {
    stop("TSDBAPI_API_KEY is not set. A non-interactive run cannot log in to KOF; ",
         "create a key once with tsdbapi::create_user_api_key() in an interactive ",
         "session and put TSDBAPI_API_KEY=<key> in ~/.Renviron. Never commit it.",
         call. = FALSE)
  }

  args <- commandArgs(trailingOnly = TRUE)
  out_dir  <- if (length(args) >= 1L) args[[1L]] else default_out_dir
  valid_on <- if (length(args) >= 2L) as.Date(args[[2L]]) else Sys.Date()

  res <- acquire_kof(valid_on = valid_on)

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(res$observations, file.path(out_dir, "kof_series.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(res$metadata, file.path(out_dir, "kof_metadata.csv"),
                   row.names = FALSE, na = "")
  if (!is.null(res$release)) {
    utils::write.csv(res$release, file.path(out_dir, "kof_release.csv"),
                     row.names = FALSE, na = "")
  }

  obs <- res$observations
  span <- tapply(obs$date, obs$key, function(d) paste(format(min(d)), "to", format(max(d))))
  message("Wrote ", nrow(obs), " observations of ", length(span), " series to ",
          file.path(out_dir, "kof_series.csv"))
  message(paste0("  ", names(span), ": ", span, collapse = "\n"))
}
