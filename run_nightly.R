# Run from the repository root:  Rscript run_nightly.R

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# The nightly run: newest source data to newest WAI on the website (#72)
#
#   1. BUILD    run_all.R: pipelines, assemble, prepare
#   2. CHECK    compare the prepared dataset with the last published one, series
#               by series; if nothing changed, stop here: no fit, no commit
#   3. PUBLISH  publish/update_wai_web.R: fit, export, checks, commit + push of
#               the web files
#
# The check compares `dat`, the series the model reads, not the downloads: a
# source that re-downloads identical data does not trigger a fit.
#
# A failing pipeline is reported and the run goes on with its last output. A
# failure in assemble, prepare, fit, export or the checks publishes nothing,
# leaves the record of the last publication as it was, and exits non-zero.
#
# Logs: dataset/out/logs/. One line per night in nightly_summary.log.
#
# Usage
#   Rscript run_nightly.R                everything, publishes
#   Rscript run_nightly.R --dry-run      everything except commit and push
#   Rscript run_nightly.R --force        fit and publish even if nothing changed
#   Rscript run_nightly.R --skip=a,b     passed on to run_all.R
#   Rscript run_nightly.R --no-pipelines passed on to run_all.R
#
# See publish/README.md.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

args    <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args
force   <- "--force" %in% args
build_args <- grep("^--(skip=|no-pipelines|gdp-vintage=)", args, value = TRUE)

if (!file.exists("run_all.R")) stop("run this from the wai-webapp repository root", call. = FALSE)
rscript <- file.path(R.home("bin"), "Rscript")
out_dir <- file.path("dataset", "out")
log_dir <- file.path(out_dir, "logs")
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)

# A dry run keeps its own record, so that it can neither stand in for a real
# publication nor be stopped by one.
state_path  <- file.path(out_dir, if (dry_run) "last_dry_run.json" else "last_published.json")
result_path <- file.path(out_dir, "publish_result.json")

say <- function(...) message(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), ...)
started <- Sys.time()
failed_pipelines <- character()
n_changed <- NA

# The night's one line, then the exit.
finish <- function(status, published, nowcast = "-", note = "") {
  line <- sprintf("%s | %s | series changed: %s | failed pipelines: %s | published: %s | nowcast: %s%s",
                  format(started, "%Y-%m-%d %H:%M"), if (dry_run) "dry run" else "nightly",
                  if (is.na(n_changed)) "-" else n_changed,
                  if (length(failed_pipelines)) paste(failed_pipelines, collapse = ",") else "none",
                  published, nowcast, if (nzchar(note)) paste0(" | ", note) else "")
  cat(line, "\n", sep = "", file = file.path(log_dir, "nightly_summary.log"), append = TRUE)
  say(line)
  quit(save = "no", status = status)
}

# 1. BUILD ---------------------------------------------------------------------
say("1. Build: pipelines, assemble, prepare")
build_log <- file.path(log_dir, "nightly_build.log")
st <- system2(rscript, c(shQuote("run_all.R"), build_args), stdout = build_log, stderr = build_log)
if (st != 0) finish(1L, "no", note = paste0("the build failed; see ", build_log))
status <- utils::read.csv(file.path(log_dir, "run_all_status.csv"), stringsAsFactors = FALSE)
failed_pipelines <- status$step[!status$ok]
if (length(failed_pipelines)) say("failed, last output used: ", paste(failed_pipelines, collapse = ", "))

# 2. CHECK ---------------------------------------------------------------------
# One checksum per series, over its dates and its values. Rounded, so that the
# last bits of a numerical routine do not count as new data.
#
# Google Trends draws a new sample on every download, so the values of
# `Arbeitsmarkt` differ each time without anything new having happened (measured
# 2026-10-30: two downloads an hour apart). For it, only the dates count. Its
# resampled values still enter any fit that runs.
dates_only <- "Arbeitsmarkt"
series_digests <- function(dat) {
  series <- c(dat$flows, dat$stocks)
  vapply(names(series), function(nm) {
    x <- series[[nm]]
    values <- if (!nm %in% dates_only) round(as.numeric(x), 10)
    unname(tools::md5sum(bytes = serialize(list(round(as.numeric(stats::time(x)), 6), values),
                                           NULL, version = 2)))
  }, character(1))
}
e <- new.env()
load(file.path(out_dir, "Rda", "data_ch_dataset_new.Rda"), envir = e)
digests <- series_digests(e$dat)

prior <- if (file.exists(state_path)) unlist(jsonlite::read_json(state_path)$series)
old <- if (is.null(prior)) rep(NA_character_, length(digests)) else prior[names(digests)]
same <- !is.na(old) & digests == old
changed <- union(names(digests)[!same], setdiff(names(prior), names(digests)))
n_changed <- length(changed)

say("2. Check: ", n_changed, " of ", length(digests), " series differ from ",
    if (is.null(prior)) "nothing (no earlier record)" else basename(state_path))
if (!n_changed && !force) {
  say("no new data; nothing published")
  finish(0L, "no", note = "no new data")
}
if (n_changed) say("changed: ", paste(changed, collapse = ", "))

# 3. PUBLISH -------------------------------------------------------------------
say("3. Fit, export, check", if (dry_run) " (dry run, no commit)" else ", publish")
publish_log <- file.path(log_dir, "publish.log")
st <- system2(rscript, c(shQuote(file.path("publish", "update_wai_web.R")), if (dry_run) "--dry-run"),
              stdout = publish_log, stderr = publish_log)
if (st != 0 || !file.exists(result_path)) {
  finish(1L, "no", note = paste0("publishing failed, nothing pushed; see ", publish_log))
}
result <- jsonlite::read_json(result_path)

jsonlite::write_json(list(recorded = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
                          outcome = result$outcome, last_date = result$last_date,
                          series = as.list(digests)),
                     state_path, auto_unbox = TRUE, pretty = TRUE)

finish(0L, result$outcome, sprintf("%s %.2f", result$nowcast_quarter, result$nowcast), result$message)
