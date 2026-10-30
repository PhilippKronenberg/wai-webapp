# Run from the repository root, in an INTERACTIVE R session (RStudio):
#   source("kof/acquire_kof_loggedin.R")

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the KOF `mfbdfm` collection with your own KOF login
#
# Does what `Rscript kof/acquire_kof.R --private` does: reads the collection
# kept by `kphilipp`, with all series and the latest vintages. It
# authenticates differently: instead of an API key it signs in with your
# KOF/ETH account. tsdbapi's access_type "auth" without an API key opens the
# KOF login page in the browser (OAuth) and uses the token it gets back.
#
# Everything else is acquire_kof.R itself: this file sources it and calls the
# same acquire_kof(mode = "private"), so the two cannot drift apart.
#
# Output: kof/private/ (gitignored). kof_series.csv can hold PRE-RELEASE
# vintages; never publish it. The run warns when it does. The dataset build
# reads only kof_series_released.csv, which holds released vintages.
#
# Needs an interactive session: the OAuth sign-in cannot run under Rscript.
# For unattended runs use `Rscript kof/acquire_kof.R --private` with
# TSDBAPI_API_KEY in ~/.Renviron instead.
#
# Optional, set before sourcing:
#   kof_valid_on <- as.Date("2026-10-01")   # read the vintage valid on a past date
#   kof_out_dir  <- "some/other/dir"        # default kof/private/
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


if (!interactive()) {
  stop("acquire_kof_loggedin.R signs in through the browser and must be run in an ",
       "interactive session: source(\"kof/acquire_kof_loggedin.R\"). For an unattended ",
       "run use `Rscript kof/acquire_kof.R --private` with TSDBAPI_API_KEY set.", call. = FALSE)
}
for (p in c("tsdbapi", "zoo", "lubridate")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("package '", p, "' is required", if (p == "tsdbapi")
      ': remotes::install_github("KOF-ch/tsdbapi-R") -- it is not on CRAN'
      else paste0(': install.packages("', p, '")'), call. = FALSE)
  }
}

# Found from this file's location when sourced, else from the working
# directory (the repository root).
kof_dir <- local({
  f <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) NULL)
  if (!is.null(f)) dirname(f) else normalizePath("kof", mustWork = TRUE)
})

# The functions of acquire_kof.R; its own RUN block does not run when sourced.
source(file.path(kof_dir, "acquire_kof.R"), local = TRUE)

# Log in as yourself: access_type "auth" and no API key, so tsdbapi takes
# the OAuth route. An API key in the environment would take precedence, so
# it is switched off for this session only.
tsdbapi::set_config(access_type = "auth", api_key = "")

valid_on <- if (exists("kof_valid_on")) as.Date(kof_valid_on) else Sys.Date()
out_dir  <- if (exists("kof_out_dir")) kof_out_dir else file.path(kof_dir, "private")

res <- acquire_kof(mode = "private", valid_on = valid_on)

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
utils::write.csv(res$observations, file.path(out_dir, "kof_series.csv"), row.names = FALSE, na = "")
utils::write.csv(res$metadata, file.path(out_dir, "kof_metadata.csv"), row.names = FALSE, na = "")
if (!is.null(res$release)) {
  utils::write.csv(res$release, file.path(out_dir, "kof_release.csv"), row.names = FALSE, na = "")
}
# What the model dataset may use: released vintages only (see released_vintages()).
utils::write.csv(res$observations_released, file.path(out_dir, "kof_series_released.csv"), row.names = FALSE, na = "")
utils::write.csv(res$release_used, file.path(out_dir, "kof_release_used.csv"), row.names = FALSE, na = "")

obs <- res$observations
span <- tapply(obs$date, obs$key, function(d) paste(format(min(d)), "to", format(max(d))))
message("Wrote ", nrow(obs), " observations of ", length(span), " series to ",
        file.path(out_dir, "kof_series.csv"))
message(paste0("  ", names(span), ": ", span, collapse = "\n"))

rel <- res$release
if (!is.null(rel) && "released" %in% names(rel) && any(!rel$released)) {
  warning(sum(!rel$released), " series hold PRE-RELEASE data (first release ",
          min(rel$release_time[!rel$released]), "). Do not publish this output before then.",
          call. = FALSE)
}
