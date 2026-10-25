# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Acquire the trendEcon indicator (the WAI input `trendecon`) (#50)
#
# trendEcon publishes its daily, seasonally adjusted Google Trends indicator
# of the perceived economic situation in Switzerland as a CSV on GitHub. This
# script downloads it, checks it, and writes trendecon_sa.csv (time,value),
# the file wai_ind and mfbdfm's prep read.
#
# Source
#   https://github.com/trendecon/data  (data/ch/trendecon_sa.csv), updated daily
#
# Usage
#   Rscript trendecon/acquire_trendecon.R
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

url <- "https://raw.githubusercontent.com/trendecon/data/master/data/ch/trendecon_sa.csv"

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "trendecon"
})
out_file <- file.path(script_dir, "trendecon_sa.csv")

tmp <- tempfile(fileext = ".csv")
utils::download.file(url, tmp, quiet = TRUE, mode = "wb")
x <- utils::read.csv(tmp, stringsAsFactors = FALSE)
if (!identical(names(x), c("time", "value"))) stop("unexpected columns: ", paste(names(x), collapse = ", "))
d <- as.Date(x$time)
if (anyNA(d) || anyDuplicated(d)) stop("missing or duplicate dates")
if (Sys.Date() - max(d) > 14) stop("newest day ", max(d), " is more than 14 days old")
invisible(file.copy(tmp, out_file, overwrite = TRUE))
message(sprintf("wrote %s: %s to %s (%d days)", out_file, min(d), max(d), nrow(x)))
