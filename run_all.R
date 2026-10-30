# Run from the repository root:  Rscript run_all.R

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Build the WAI's model dataset from scratch, in one run (#50)
#
#   1. PIPELINES  run every source's acquire script; each writes its own
#                 folder (see the folder's README)
#   2. ASSEMBLE   dataset/assemble_dataset.R writes the model's raw input
#                 folder, dataset/out/data/, in the file names and layouts of
#                 wai_ind's data/dataset
#   3. PREPARE    dataset/data_prep_dataset.R (copy of mfbdfm's
#                 analysis/1_data_prep_dataset.R) harmonises, adjusts and
#                 transforms the series and writes the model dataset,
#                 dataset/out/Rda/data_ch_dataset_new.Rda (`dat`: flows/stocks)
#
# A failing pipeline is reported and the run goes on with that source's last
# output; steps 2 and 3 stop on a missing input. Everything under
# dataset/out/ is gitignored: it holds licensed and pre-release data.
#
# Needs R with the packages of the individual pipelines, Node.js (bfs_keu),
# the mfbdfm package installed, and wai_ind next to this repository (read
# only, for the fixed histories).
#
# Usage
#   Rscript run_all.R                          everything
#   Rscript run_all.R --skip=swissgrid,zurich_car_traffic
#                                              skip slow pipelines (their last output is used)
#   Rscript run_all.R --no-pipelines           steps 2 and 3 only
#   Rscript run_all.R --gdp-vintage=2026-09-01 latest GDP vintage to include (default: today)
#
# KOF: with TSDBAPI_API_KEY set the pipeline reads all series (--private),
# without it the public ones. kof/acquire_kof_loggedin.R does the private read
# interactively. The assembler takes, per series, the newest released vintage.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
skip <- strsplit(arg_value("skip", ""), ",")[[1]]
run_pipelines <- !"--no-pipelines" %in% args
gdp_vintage <- arg_value("gdp-vintage", format(Sys.Date()))

rscript <- file.path(R.home("bin"), "Rscript")
pipelines <- list(            # folder, interpreter, script
  c("seco_gdp", "R", "seco_gdp/acquire_seco_gdp.R"),
  c("trendecon", "R", "trendecon/acquire_trendecon.R"),
  c("kof", "R", "kof/acquire_kof.R"),
  c("bazg_trade", "R", "bazg_trade/acquire_bazg_trade.R"),
  c("bfs_keu", "node", "bfs_keu/acquire_bfs_keu.mjs"),
  c("bfs_prices", "R", "bfs_prices/acquire_bfs_prices.R"),
  c("procure_pmi", "R", "procure_pmi/acquire_procure_pmi.R"),
  c("markets", "R", "markets/acquire_markets.R"),
  c("vsmi", "R", "vsmi/acquire_vsmi.R"),
  c("google_trends_arbeitsmarkt", "R", "google_trends_arbeitsmarkt/acquire_arbeitsmarkt.R"),
  c("worldline", "R", "worldline/acquire_worldline.R"),
  c("zurich_hardbruecke", "R", "zurich_hardbruecke/acquire_zurich_hardbruecke.R"),
  c("statistikzh", "R", "statistikzh/acquire_statistikzh.R"),
  c("zurich_car_traffic", "R", "zurich_car_traffic/acquire_zurich_car_traffic.R"),
  c("astra_traffic", "R", "astra_traffic/acquire_astra_traffic.R"),
  c("destatis_maut", "R", "destatis_maut/acquire_destatis_maut.R"),
  c("swissgrid", "R", "swissgrid/acquire_swissgrid.R"),
  c("zurich_airport", "R", "zurich_airport/acquire_zurich_airport.R")
)

log_dir <- file.path("dataset", "out", "logs")
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
run <- function(interp, script, log, env = character(), script_args = character()) {
  cmd <- if (interp == "node") "node" else rscript
  t0 <- Sys.time()
  # system2(env = ) is not supported on Windows; set the variables for the child instead.
  if (length(env)) {
    kv <- strsplit(env, "=", fixed = TRUE)
    old <- Sys.getenv(vapply(kv, `[`, "", 1), unset = NA)
    do.call(Sys.setenv, stats::setNames(as.list(vapply(kv, function(x) paste(x[-1], collapse = "="), "")),
                                        vapply(kv, `[`, "", 1)))
    on.exit(for (n in names(old)) if (is.na(old[[n]])) Sys.unsetenv(n) else do.call(Sys.setenv, stats::setNames(list(old[[n]]), n)),
            add = TRUE)
  }
  st <- system2(cmd, c(shQuote(script), script_args), stdout = log, stderr = log)
  list(ok = identical(as.integer(st), 0L), secs = round(as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}
status <- data.frame(step = character(), ok = logical(), secs = numeric(), log = character())

# 1. PIPELINES --------------------------------------------------------------
if (run_pipelines) {
  message("1. Pipelines")
  for (pl in pipelines) {
    if (pl[1] %in% skip) { message(sprintf("   %-28s skipped", pl[1])); next }
    log <- file.path(log_dir, paste0(pl[1], ".log"))
    # KOF: all series with an API key; without one, or if that read fails, the
    # public ones. The assembler takes released vintages only, either way.
    if (pl[1] == "kof" && nzchar(Sys.getenv("TSDBAPI_API_KEY"))) {
      r <- run(pl[2], pl[3], log, script_args = "--private")
      if (!r$ok) {
        message(sprintf("   %-28s private read FAILED -> see %s; reading the public series", pl[1], log))
        log <- file.path(log_dir, "kof_public.log")
        r <- run(pl[2], pl[3], log)
      }
    } else {
      if (pl[1] == "kof") message("   kof: TSDBAPI_API_KEY not set; reading the public series only")
      r <- run(pl[2], pl[3], log)
    }
    status[nrow(status) + 1, ] <- list(pl[1], r$ok, r$secs, log)
    message(sprintf("   %-28s %s (%ds)%s", pl[1], if (r$ok) "ok" else "FAILED", r$secs,
                    if (r$ok) "" else paste0(" -> see ", log)))
  }
}

# 2. ASSEMBLE ----------------------------------------------------------------
message("2. Assemble the model's input folder")
log <- file.path(log_dir, "assemble.log")
r <- run("R", "dataset/assemble_dataset.R", log)
status[nrow(status) + 1, ] <- list("assemble", r$ok, r$secs, log)
if (!r$ok) stop("assembling failed; see ", log, call. = FALSE)
message(sprintf("   ok (%ds); manifest: dataset/out/manifest.csv", r$secs))

# 3. PREPARE -------------------------------------------------------------------
message("3. Prepare the model dataset (GDP vintages up to ", gdp_vintage, ")")
log <- file.path(log_dir, "data_prep.log")
r <- run("R", "dataset/data_prep_dataset.R", log,
         env = c(paste0("MFBDFM_DATASET_DIR=", normalizePath(file.path("dataset", "out", "data"))),
                 "MFBDFM_PREP_TAG=new", paste0("MFBDFM_GDP_VINTAGE_DATE=", gdp_vintage)))
status[nrow(status) + 1, ] <- list("data_prep", r$ok, r$secs, log)
if (!r$ok) stop("the data prep failed; see ", log, call. = FALSE)
message(sprintf("   ok (%ds): dataset/out/Rda/data_ch_dataset_new.Rda", r$secs))

utils::write.csv(status, file.path(log_dir, "run_all_status.csv"), row.names = FALSE)
if (any(!status$ok)) {
  warning(sum(!status$ok), " pipeline(s) failed: ", paste(status$step[!status$ok], collapse = ", "),
          "; their last outputs were used", call. = FALSE)
}
