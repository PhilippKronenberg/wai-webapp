# Run from the repository root:  Rscript publish/update_wai_web.R [--dry-run]

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Fit the WAI on the dataset this repository builds and publish the web files
#
# A copy of mfbdfm's analysis/update_wai_web.R (mfbdfm's original is not
# changed). It differs only where the setting differs:
#   - the dataset is dataset/out/Rda/data_ch_dataset_new.Rda, built by
#     run_all.R; mfbdfm's data prep is not run
#   - GDP vintages and the published GDP series come from seco_gdp/, metadata
#     from dataset/data_meta.csv, fits go to dataset/out/fits/
#   - the files are checked and committed in a temporary worktree of
#     origin/main, not in this checkout. This checkout may be on another
#     branch or hold other changes, and neither can reach the commit, which
#     holds the web files and nothing else
#   - --dry-run does everything except commit and push, and leaves the web
#     files in this checkout untouched; the run's files stay in
#     dataset/out/publish_staging/
#   - the validator CI runs (tools/validate-data.mjs) runs on the files first,
#     when Node.js exists
#
# Normally called by run_nightly.R, which decides whether a fit is needed.
#
# WAI_LENGTH_SAMPLE / WAI_BURN_IN are for smoke tests only; a real run must not
# set them.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

target       <- "ch.seco.gdp.real.gdp.ssa"
dataset_path <- file.path("dataset", "out", "Rda", "data_ch_dataset_new.Rda")
fit_root     <- file.path("dataset", "out", "fits")
staging      <- file.path("dataset", "out", "publish_staging")
result_path  <- file.path("dataset", "out", "publish_result.json")
gdp_files    <- list(gdp_file_path = file.path("seco_gdp", "realtime_gdp.csv"),
                     gdp_cssa_file_path = file.path("seco_gdp", "realtime_gdp_cssa.csv"))

length_sample <- as.integer(Sys.getenv("WAI_LENGTH_SAMPLE", unset = "5000"))
burn_in       <- as.integer(Sys.getenv("WAI_BURN_IN",       unset = "1000"))
thinning      <- 1

# Weekly fits kept; the news decomposition needs only the previous one.
keep_fits <- 8

digits <- 4

args    <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args


# HELPERS -----------------------------------------------------------------

say <- function(...) message(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), ...)

# Guard rails are deliberately fatal rather than warning: a scheduled job with
# nobody watching must not publish a half-broken file.
must <- function(condition, ...) {
  if (!isTRUE(condition)) stop(..., call. = FALSE)
  invisible(TRUE)
}

git <- function(..., dir = ".") {
  out <- suppressWarnings(system2("git", c("-C", shQuote(dir), ...),
                                  stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop("git ", paste(..., collapse = " "), " failed:\n",
         paste(out, collapse = "\n"), call. = FALSE)
  }
  out
}

# Re-read what we are about to publish and hold it to the contract the front end
# relies on. Checking the written file rather than the in-memory object is the
# point: it is the file that gets served.
validate_export <- function(dir) {
  csv_path  <- file.path(dir, "wai_data.csv")
  meta_path <- file.path(dir, "wai_meta.json")
  must(file.exists(csv_path),  "export produced no wai_data.csv")
  must(file.exists(meta_path), "export produced no wai_meta.json")

  lines <- readLines(csv_path, warn = FALSE)
  must(length(lines) > 100, "wai_data.csv has only ", length(lines), " lines")

  expected <- c("date", "wai_qoq", "wai_qoq_lo", "wai_qoq_hi", "wai_yoy",
                "wai_index", "wai_qoq_q", "wai_yoy_q",
                "gdp_qoq", "gdp_yoy", "gdp_index")
  header <- strsplit(lines[1], ",", fixed = TRUE)[[1]]
  must(identical(header, expected),
       "wai_data.csv header is\n  ", lines[1],
       "\nbut the front end expects\n  ", paste(expected, collapse = ","))

  must(!any(grepl("\"", lines, fixed = TRUE)), "wai_data.csv contains quotes")
  must(!any(grepl("\\b(NA|NaN|Inf|NULL)\\b", lines)),
       "wai_data.csv encodes missing values as NA/NaN/Inf/NULL; the contract is the empty string")

  d <- utils::read.csv(csv_path, stringsAsFactors = FALSE)
  dates <- as.Date(d$date)
  must(!anyNA(dates), "wai_data.csv has unparseable dates")
  must(!is.unsorted(dates), "wai_data.csv rows are not sorted ascending by date")
  must(anyDuplicated(dates) == 0, "wai_data.csv has duplicate dates")
  must(!anyNA(d$wai_qoq), "wai_qoq has missing values")

  # A column that is present but entirely empty is well-formed, so every check
  # above passes it. Every published column must carry at least one value.
  for (nm in setdiff(names(d), "date")) {
    must(any(!is.na(d[[nm]])),
         "column `", nm, "` is present but entirely empty - it would publish a ",
         "series with nothing in it")
  }
  must(all(d$wai_qoq_lo < d$wai_qoq & d$wai_qoq < d$wai_qoq_hi),
       "the 95% band does not bracket wai_qoq everywhere")

  invisible(list(n = nrow(d), last = max(dates), table = d))
}

# Refuse to replace a published series with one that stops earlier. A fit that
# silently lost its most recent weeks is well-formed, so nothing above sees it.
check_not_going_backwards <- function(new_last, published_csv) {
  if (!file.exists(published_csv)) return(invisible(TRUE))
  old <- utils::read.csv(published_csv, stringsAsFactors = FALSE)
  if (!nrow(old) || is.null(old$date)) return(invisible(TRUE))
  old_last <- max(as.Date(old$date))
  must(new_last >= old_last,
       "the new export ends at ", new_last, " but the published data already ",
       "runs to ", old_last, ". Refusing to publish a shorter series.")
  invisible(TRUE)
}

# The same validator CI runs. CI would catch a failure only after the push, when
# the dashboard already serves the files.
run_ci_validator <- function(dir) {
  node <- Sys.which("node")
  if (!nzchar(node)) {
    say("WARNING: Node.js not found; tools/validate-data.mjs not run here, CI runs it after the push")
    return(invisible(FALSE))
  }
  old <- setwd(dir)
  on.exit(setwd(old), add = TRUE)
  out <- suppressWarnings(system2(node, "tools/validate-data.mjs", stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  must(is.null(status) || status == 0,
       "tools/validate-data.mjs rejected the files:\n", paste(out, collapse = "\n"))
  say("tools/validate-data.mjs passed")
  invisible(TRUE)
}


# RUN ---------------------------------------------------------------------

say("update_wai_web starting", if (dry_run) " (dry run)" else "")
must(file.exists("run_all.R"), "run this from the wai-webapp repository root")
must(nzchar(Sys.which("git")), "git is not on the PATH")
unlink(result_path)

suppressPackageStartupMessages({
  library(mfbdfm)
  library(zoo)
})

# Package internals (mfbdfm #102), bound as mfbdfm's analysis/_internals.R does.
for (.f in c("export_wai_web", "export_wai_measures", "gdp_web_series")) {
  assign(.f, get(.f, envir = asNamespace("mfbdfm")))
}

must(file.exists(dataset_path), "prepared dataset not found: ", dataset_path, "; run run_all.R")
load(dataset_path)                      # provides `dat`
must(exists("dat"), dataset_path, " did not contain an object named `dat`")

# 1. Fit at the most recent vintage ----------------------------------------
GDP_gr_vintages <- do.call(get_real_time_gdp_vintages, c(list("quarterly"), gdp_files))

last_week <- max(vapply(c(dat$flows, dat$stocks),
                        function(x) max(as.numeric(stats::time(x))), numeric(1)))
# The EXACT weekly grid point, not a rounded one (mfbdfm #157). The file name is
# derived with round(eval_date, 3) below, exactly as run_wai_adj() names it.
eval_date <- round(last_week * 48) / 48
say("fitting at ", eval_date, " (", length_sample, " draws after ", burn_in,
    " burn-in)", if (length_sample < 5000) " [SHORT CHAIN - smoke test only]" else
      " - this takes a while")

dat_rt <- cut_data_real_time(dat, eval_date, GDP_gr_vintages)
dat_rt$flows[[target]] <- zoo::na.trim(
  stats::ts(select_most_recent_GDP_vintage(eval_date, GDP_gr_vintages),
            start = c(1990, 1), frequency = 4)
)

fit <- run_wai_adj(flows = dat_rt$flows, stocks = dat_rt$stocks,
                   target = target, date = eval_date,
                   dataset_used = "web",
                   length_sample = length_sample, burn_in = burn_in,
                   thinning = thinning, output_dir = fit_root)

fit_path <- file.path(fit_root, "web", paste0("fit_", round(eval_date, 3), ".Rda"))
must(file.exists(fit_path), "run_wai_adj() did not write ", fit_path)
say("fit written to ", fit_path)

# 2. Export, into a staging directory first --------------------------------
unlink(staging, recursive = TRUE)
dir.create(staging, recursive = TRUE)

# Official GDP on the WAI's three scales, from this repository's vintages.
gdp_latest <- do.call(gdp_web_series, gdp_files)

export_wai_web(fit_path, dir = staging, gdp = gdp_latest, digits = digits,
               vintage_date = as.character(dec2week(eval_date)))

info <- validate_export(staging)
say("export validated: ", info$n, " weeks, ending ", info$last)

# News needs an earlier week's fit as its old vintage. With none there (a first
# run), the news file is skipped and the metadata says so.
meta_csv <- utils::read.csv(file.path("dataset", "data_meta.csv"),
                            stringsAsFactors = FALSE)
series_info <- data.frame(key = meta_csv$keys, name = meta_csv$Name,
                          group = meta_csv$Category, stringsAsFactors = FALSE)
series_info$group[series_info$key == target] <- "GDP (target)"
if (!target %in% series_info$key) {
  series_info <- rbind(series_info, data.frame(key = target, name = "Real GDP",
                                               group = "GDP (target)"))
}

web_fits <- list.files(file.path(fit_root, "web"), pattern = "^fit_.*[.]Rda$",
                       full.names = TRUE)
web_dates <- as.numeric(sub("^fit_(.*)[.]Rda$", "\\1", basename(web_fits)))
earlier <- which(web_dates < round(eval_date, 3))
prev_fit <- if (length(earlier)) web_fits[earlier[which.max(web_dates[earlier])]] else NULL

measures <- export_wai_measures(fit_path, dir = staging, series_info = series_info,
                                news_fit_path = prev_fit,
                                news_new_data = if (!is.null(prev_fit)) dat_rt,
                                digits = digits,
                                vintage_date = as.character(dec2week(eval_date)))
must(file.exists(file.path(staging, "wai_contributions.csv")),
     "export produced no wai_contributions.csv")
must(file.exists(file.path(staging, "wai_series.csv")),
     "export produced no wai_series.csv")
say("measures exported: ", length(unique(measures$contributions$component)),
    " contribution components, ", nrow(measures$series), " series, news ",
    if (is.null(prev_fit)) "skipped (no earlier fit)" else
      paste0("against ", basename(prev_fit)))
published <- c("wai_data.csv", "wai_meta.json", "wai_contributions.csv",
               "wai_series.csv", "wai_measures_meta.json",
               if (!is.null(measures$news)) "wai_news.csv")

# What the commit message and the night's summary name.
last_row <- info$table[nrow(info$table), ]
nowcast_quarter <- paste0(format(info$last, "%Y"), "q",
                          (as.integer(format(info$last, "%m")) - 1L) %/% 3L + 1L)
nowcast <- last_row$wai_qoq_q
msg <- sprintf("Update WAI data to %s (nowcast %s: wai_qoq_q %.2f)",
               info$last, nowcast_quarter, nowcast)

# 3. Check against origin/main in a temporary worktree, and publish ---------
invisible(git("fetch", "origin", "main"))
worktree <- file.path(tempdir(), "wai-publish")
invisible(git("worktree", "prune"))
invisible(git("worktree", "add", "--detach", shQuote(worktree), "origin/main"))

outcome <- tryCatch({
  check_not_going_backwards(info$last, file.path(worktree, "wai_data.csv"))
  invisible(file.copy(file.path(staging, published), worktree, overwrite = TRUE))
  run_ci_validator(worktree)

  changed <- git("status", "--porcelain", "--", published, dir = worktree)
  if (!length(changed)) {
    say("no change in the published files - nothing to commit")
    "unchanged"
  } else if (dry_run) {
    say("dry run: would commit: ", msg)
    say("dry run: the files are in ", staging, ". Against origin/main:\n",
        paste(git("diff", "--stat", "--", published, dir = worktree), collapse = "\n"))
    "dry-run"
  } else {
    git("add", "--", published, dir = worktree)
    git("commit", "-m", shQuote(msg), dir = worktree)
    git("push", "origin", "HEAD:main", dir = worktree)
    say("pushed: ", msg)
    "pushed"
  }
}, finally = git("worktree", "remove", "--force", shQuote(worktree)))

# 4. Keep the most recent fits ------------------------------------------------
if (length(web_fits) > keep_fits) {
  unlink(web_fits[order(web_dates, decreasing = TRUE)][-seq_len(keep_fits)])
}

jsonlite::write_json(list(outcome = outcome, last_date = as.character(info$last),
                          nowcast_quarter = nowcast_quarter, nowcast = nowcast,
                          message = msg),
                     result_path, auto_unbox = TRUE, pretty = TRUE)
say("done")
