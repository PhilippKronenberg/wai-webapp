# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Test run of the WAI model on a built dataset (#50)
#
# Fits mfbdfm::ind_dfm() (one factor, stochastic volatility, serial
# correlation, as analysis/0_test.R) on dataset/out/Rda/data_ch_dataset_<tag>.Rda
# and saves the fit and a small summary. Shorter chains than the production
# run by default (2000 draws after 500 burn-in, as mfbdfm's vignette), which
# is enough to check that the model runs and to compare datasets.
#
# Usage
#   Rscript dataset/test_run.R [<tag>] [<length_sample>] [<burn_in>]
#   defaults: new 2000 500
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

suppressPackageStartupMessages(library(mfbdfm))
args <- commandArgs(trailingOnly = TRUE)
tag <- if (length(args) >= 1) args[1] else "new"
length_sample <- if (length(args) >= 2) as.integer(args[2]) else 2000L
burn_in <- if (length(args) >= 3) as.integer(args[3]) else 500L
target <- "ch.seco.gdp.real.gdp.ssa"

e <- new.env()
load(file.path("dataset", "out", "Rda", paste0("data_ch_dataset_", tag, ".Rda")), envir = e)
dat <- e$dat
if (is.null(dat$flows[[target]])) stop("the dataset has no ", target)

# Nowcast to the end of the quarter of the newest weekly observation.
last_week <- max(vapply(c(dat$flows, dat$stocks), function(x) {
  if (stats::frequency(x) == 48) as.numeric(utils::tail(stats::time(x), 1)) else -Inf
}, numeric(1)))
extend_to <- ceiling(last_week * 4 + 1e-9) / 4 - 1 / 48
message(sprintf("dataset %s: %d flows, %d stocks; newest weekly obs %.3f; GDP to %.2f; extend_to %.3f",
                tag, length(dat$flows), length(dat$stocks), last_week,
                as.numeric(utils::tail(stats::time(dat$flows[[target]]), 1)), extend_to))

set.seed(20261025)
t0 <- Sys.time()
fit <- ind_dfm(flows = dat$flows, stocks = dat$stocks, target = target, p = 1,
               length_sample = length_sample, burn_in = burn_in, thinning = 1,
               extend_to = extend_to, stochastic_volatility = TRUE, serial_correlation = TRUE)
secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")))

dir.create(file.path("dataset", "out", "fits"), recursive = TRUE, showWarnings = FALSE)
saveRDS(fit, file.path("dataset", "out", "fits", paste0("fit_", tag, ".rds")))
nc <- fit$nowcast
message(sprintf("fitted in %ds; nowcast %s .. %s", secs, paste(round(utils::tail(stats::time(nc), 1), 3)),
                paste(round(utils::tail(nc, 1), 4))))
print(fit)
