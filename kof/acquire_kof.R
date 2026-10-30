# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the KOF series of the `mfbdfm` collection (wai-webapp, "KOF Data
# pipeline")
#
# Downloads the time series of the KOF Time Series Database collection
# `mfbdfm`, curated on the KOF TS Explorer:
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
# Two modes -- the same collection, kept by two accounts
#
#   public (default)  The copy kept by an open account, read with
#                     access_type = "public": no login, no key, so it runs
#                     unattended anywhere. It sees only series KOF has made
#                     public (5 of the 9 on 2026-10-25; the four manufacturing
#                     sub-sector series are not) and only RELEASED vintages.
#                     Writes to kof/public/.
#
#   private           The copy kept by `kphilipp`, read as that user: every
#   (--private)       series, and vintages that are not yet released (on
#                     2026-10-25 it already held October, due for release on
#                     4 Nov). That output must NEVER be published or feed the
#                     model: it is written to kof/private/, which git ignores,
#                     and the run warns when it holds pre-release data. Each
#                     run also writes kof_series_released.csv, with every such
#                     vintage replaced by the latest released one
#                     (released_vintages()); the dataset build uses only that.
#                     Needs a login (interactive) or TSDBAPI_API_KEY (created
#                     once with tsdbapi::create_user_api_key(); keep it in
#                     ~/.Renviron, never commit it).
#
#   Verified 2026-10-25: on the series both can read, the public values differ
#   from the private ones only by the newer month and the seasonal-adjustment
#   revision it brings (<= 2.2 points), as they should.
#
# Redistribution
#   kof/public/ is gitignored too, until KOF's terms for republishing public
#   series in this public repository are confirmed (see the issue).
#
# Usage
#   Rscript kof/acquire_kof.R [--private] [<output_dir>] [<valid_on YYYY-MM-DD>]
#
# valid_on reads the vintage valid on a past date instead of the latest, which
# is how to rebuild what was known at that date.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

collection <- "mfbdfm"
locale     <- "en"
owners <- c(public  = "0945fec6-0e5a-4490-9e8c-ed38d1d73040",   # open account
            private = "kphilipp")

# Output lands next to this script, in public/ or private/. Resolved from the
# script's own path, not the working directory: the first real run
# (2026-10-25) was started from inside kof/, and a relative "kof" then wrote to
# kof/kof/.
script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "kof"
})


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

#' Download the collection and return the tables
#'
#' Series the account may not read are skipped (ignore_missing) rather than
#' failing the run, but never silently: a strict read first counts them from
#' the API's own refusal ("not allowed to access 4 of 9"), the collection's
#' key list names them, and both are reported. In public mode these are the
#' series KOF has not made public; in private mode, series in an access set
#' the user does not have (2026-10-25: the two BAZG trade series).
acquire_kof <- function(mode = c("public", "private"), valid_on = Sys.Date()) {
  mode <- match.arg(mode)
  owner <- owners[[mode]]
  if (mode == "public") tsdbapi::set_config(access_type = "public")
  message("Reading collection '", collection, "' (", mode, ", owner ", owner,
          "), valid on ", format(valid_on))

  skipped <- c(n = 0L, of = NA_integer_)
  lenient <- TRUE
  tsl <- tryCatch(
    tsdbapi::read_collection_ts(collection, owner = owner, valid_on = valid_on),
    error = function(e) {
      hit <- regmatches(conditionMessage(e),
                        regexec("not allowed to access ([0-9]+) of ([0-9]+)", conditionMessage(e)))[[1]]
      if (length(hit) < 3) stop(e)
      skipped[] <<- as.integer(hit[2:3])
      tsdbapi::read_collection_ts(collection, owner = owner, valid_on = valid_on,
                                  ignore_missing = TRUE)
    })
  if (!length(tsl)) stop("the collection returned no series", call. = FALSE)
  if (skipped[["n"]] > 0) {
    keys <- tryCatch(tsdbapi::read_collection_keys(collection, owner = owner), error = function(e) NULL)
    denied <- setdiff(keys, names(tsl))
    which <- if (length(denied)) paste0(": ", paste(denied, collapse = ", ")) else ""
    if (mode == "public") {
      message("  ", skipped[["n"]], " of ", skipped[["of"]], " series are not public ",
              "and were skipped", which, "; run with --private for all of them")
    } else {
      warning(skipped[["n"]], " of ", skipped[["of"]], " series could not be read with this ",
              "account and were skipped", which, ". Their access set is not granted to the user; ",
              "see tsdbapi::list_user_access_sets() and ask KOF for access.", call. = FALSE)
    }
  }

  message("  the API returned ", length(tsl), " series: ", paste(names(tsl), collapse = ", "))
  obs <- do.call(rbind, Map(series_to_long, tsl, names(tsl)))
  rownames(obs) <- NULL
  # A series whose values are all missing in this vintage leaves no row in
  # obs; say so instead of letting it vanish.
  empty <- setdiff(names(tsl), unique(obs$key))
  if (length(empty)) {
    warning(length(empty), " series returned with no values (all missing in the vintage valid on ",
            format(valid_on), "): ", paste(empty, collapse = ", "), call. = FALSE)
  }

  md <- tsdbapi::read_collection_ts_metadata(collection, owner = owner, locale = locale,
                                             ignore_missing = lenient)
  meta <- flatten_metadata(md)
  # Series the collection lists (metadata) but the data call did not return.
  not_returned <- setdiff(meta$key, names(tsl))
  if (length(not_returned)) {
    warning(length(not_returned), " series are in the collection's metadata but were not returned ",
            "as data: ", paste(not_returned, collapse = ", "), call. = FALSE)
  }
  missing_meta <- setdiff(names(tsl), meta$key)
  if (length(missing_meta)) {
    warning(length(missing_meta), " series without metadata: ",
            paste(utils::head(missing_meta, 5), collapse = ", "), call. = FALSE)
  }

  # Which vintage each series is, and when it is (or was) released. Not
  # essential to the data, so a failure here is reported and skipped.
  rel <- tryCatch(
    flatten_metadata(tsdbapi::read_collection_ts_release(collection, owner = owner,
                                                         valid_on = valid_on,
                                                         ignore_missing = lenient)),
    error = function(e) {
      warning("release information not read: ", conditionMessage(e), call. = FALSE)
      NULL
    })
  if (!is.null(rel) && "release_time" %in% names(rel)) {
    rel$released <- is_released(rel$release_time)
  }

  rv <- released_vintages(obs, rel, valid_on)
  list(observations = obs, metadata = meta, release = rel, mode = mode,
       skipped = skipped, observations_released = rv$observations, release_used = rv$used)
}

#' Has a release time passed? (ISO time from the API; missing = no release time)
is_released <- function(release_time, now = Sys.time()) {
  rt <- as.POSIXct(sub("Z$", "", sub("T", " ", release_time)), tz = "UTC")
  !is.na(rt) & rt <= now
}

#' Replace every pre-release vintage with the latest RELEASED one
#'
#' The private account can read vintages KOF has not released yet (2026-10:
#' October's survey results, released on 2026-11-04). Such a vintage may
#' revise past months as well as add the new one (the seasonal adjustment is
#' re-estimated), so cutting off its last month is not enough: the whole
#' vintage is replaced. For every series whose current vintage is not
#' released, the vintage valid on the day before that vintage's date is read;
#' if it is not released either, the step is repeated (at most `max_steps`).
#' A series with no release information is kept as it is and reported.
#' Returns the observations to use and, per series, the vintage used.
released_vintages <- function(obs, rel, valid_on = Sys.Date(), max_steps = 12L) {
  keys <- unique(obs$key)
  used <- data.frame(key = keys, vintage_date = NA_character_, release_time = NA_character_,
                     released = NA, replaced = FALSE, stringsAsFactors = FALSE)
  if (is.null(rel) || !"release_time" %in% names(rel)) {
    warning("no release information: cannot check for pre-release data", call. = FALSE)
    return(list(observations = obs, used = used))
  }
  out <- obs
  for (k in keys) {
    r <- rel[rel$key == k, , drop = FALSE]
    i <- match(k, used$key)
    if (!nrow(r) || is.na(r$release_time[1])) {
      warning(k, ": no release time; kept as read", call. = FALSE)
      next
    }
    used[i, c("vintage_date", "release_time")] <- c(r$vintage_date[1], r$release_time[1])
    used$released[i] <- is_released(r$release_time[1])
    if (used$released[i]) next
    day <- as.Date(r$vintage_date[1]) - 1
    for (step in seq_len(max_steps)) {
      r2 <- tsdbapi::read_ts_release(k, valid_on = day)
      if (is_released(r2$release_time[1])) {
        x <- tsdbapi::read_ts(k, valid_on = day)[[k]]
        out <- rbind(out[out$key != k, , drop = FALSE], series_to_long(x, k))
        used[i, c("vintage_date", "release_time")] <- c(r2$vintage_date[1], r2$release_time[1])
        used$released[i] <- TRUE
        used$replaced[i] <- TRUE
        break
      }
      day <- as.Date(r2$vintage_date[1]) - 1
    }
    if (!isTRUE(used$released[i])) {
      stop(k, ": no released vintage found within ", max_steps, " steps back", call. = FALSE)
    }
  }
  out <- out[order(out$key, out$date), , drop = FALSE]
  rownames(out) <- NULL
  if (any(used$replaced)) {
    message("  pre-release vintages replaced by the latest released one for ", sum(used$replaced),
            " series: ", paste(sprintf("%s (vintage %s, released %s)", used$key[used$replaced],
                                       used$vintage_date[used$replaced],
                                       substr(used$release_time[used$replaced], 1, 10)),
                               collapse = "; "))
  }
  list(observations = out, used = used)
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
  args <- commandArgs(trailingOnly = TRUE)
  mode <- if ("--private" %in% args) "private" else "public"
  args <- args[!grepl("^--", args)]
  out_dir  <- if (length(args) >= 1L) args[[1L]] else file.path(script_dir, mode)
  valid_on <- if (length(args) >= 2L) as.Date(args[[2L]]) else Sys.Date()

  if (mode == "private" && !interactive() && !nzchar(Sys.getenv("TSDBAPI_API_KEY"))) {
    stop("--private needs KOF credentials, and TSDBAPI_API_KEY is not set. A ",
         "non-interactive run cannot log in; create a key once with ",
         "tsdbapi::create_user_api_key() in an interactive session and put ",
         "TSDBAPI_API_KEY=<key> in ~/.Renviron. Never commit it. ",
         "(The default public mode needs no key.)", call. = FALSE)
  }

  res <- acquire_kof(mode = mode, valid_on = valid_on)

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(res$observations, file.path(out_dir, "kof_series.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(res$metadata, file.path(out_dir, "kof_metadata.csv"),
                   row.names = FALSE, na = "")
  if (!is.null(res$release)) {
    utils::write.csv(res$release, file.path(out_dir, "kof_release.csv"),
                     row.names = FALSE, na = "")
  }
  # What the model dataset may use: released vintages only (see released_vintages()).
  utils::write.csv(res$observations_released, file.path(out_dir, "kof_series_released.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(res$release_used, file.path(out_dir, "kof_release_used.csv"),
                   row.names = FALSE, na = "")

  obs <- res$observations
  span <- tapply(obs$date, obs$key, function(d) paste(format(min(d)), "to", format(max(d))))
  message("Wrote ", nrow(obs), " observations of ", length(span), " series to ",
          file.path(out_dir, "kof_series.csv"))
  message(paste0("  ", names(span), ": ", span, collapse = "\n"))

  rel <- res$release
  if (!is.null(rel) && "released" %in% names(rel) && any(!rel$released)) {
    warning(sum(!rel$released), " series hold PRE-RELEASE data (first release ",
            min(rel$release_time[!rel$released]), "). Do not publish this output ",
            "before then.", call. = FALSE)
  }
}
