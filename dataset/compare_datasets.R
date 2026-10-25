# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Compare a newly built model dataset with the one the model used (#50)
#
# Compares, series by series, the transformed series the model reads (`dat`
# from data_ch_dataset_<tag>.Rda) on their common period, and classifies:
#   same       identical, or correlation >= 0.99 with standard deviations within 10%
#   similar    correlation >= 0.90
#   different  correlation <  0.90
#   missing    in the old dataset only
#   new        in the new dataset only
# and reports how far each series now runs.
#
# Usage
#   Rscript dataset/compare_datasets.R [<new.Rda>] [<old.Rda>]
#   defaults: dataset/out/Rda/data_ch_dataset_new.Rda, ../mfbdfm/analysis/Rda/data_ch_dataset_test.Rda
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

args <- commandArgs(trailingOnly = TRUE)
new_file <- if (length(args) >= 1) args[1] else file.path("dataset", "out", "Rda", "data_ch_dataset_new.Rda")
old_file <- if (length(args) >= 2) args[2] else
  file.path("..", "mfbdfm", "analysis", "Rda", "data_ch_dataset_test.Rda")
out_file <- file.path(dirname(new_file), "..", "comparison.csv")

load_dat <- function(f) { e <- new.env(); load(f, envir = e); c(e$dat$flows, e$dat$stocks) }
new <- load_dat(new_file)
old <- load_dat(old_file)
meta <- utils::read.csv(file.path("dataset", "data_meta.csv"), stringsAsFactors = FALSE)

tdate <- function(x) {                       # end date of a ts, as a Date
  t <- stats::time(x)[length(x)]; f <- stats::frequency(x)
  y <- floor(t + 1e-9); frac <- t - y
  as.Date(sprintf("%d-01-01", y)) + round(frac * 365.25)
}

rows <- lapply(union(names(old), names(new)), function(k) {
  a <- old[[k]]; b <- new[[k]]
  base <- data.frame(key = k, name = meta$Name[match(k, meta$keys)], status = NA_character_, n_common = NA_integer_,
                     cor = NA_real_, sd_ratio = NA_real_, old_end = if (is.null(a)) NA else format(tdate(a)),
                     new_end = if (is.null(b)) NA else format(tdate(b)), stringsAsFactors = FALSE)
  if (is.null(b)) { base$status <- "missing"; return(base) }
  if (is.null(a)) { base$status <- "new"; return(base) }
  u <- stats::ts.intersect(a, b)
  ok <- stats::complete.cases(u)
  x <- as.numeric(u[ok, 1]); y <- as.numeric(u[ok, 2])
  base$n_common <- length(x)
  if (length(x) < 3) { base$status <- "different"; return(base) }
  base$cor <- stats::cor(x, y)
  base$sd_ratio <- stats::sd(y) / stats::sd(x)
  base$status <- if (max(abs(x - y)) < 1e-6) "same" else
    if (base$cor >= 0.99 && abs(base$sd_ratio - 1) <= 0.1) "same" else
    if (base$cor >= 0.9) "similar" else "different"
  base
})
res <- do.call(rbind, rows)
res$cor <- round(res$cor, 4); res$sd_ratio <- round(res$sd_ratio, 3)
res <- res[order(match(res$status, c("same", "similar", "different", "missing", "new")), res$key), ]
utils::write.csv(res, out_file, row.names = FALSE)
print(res[, c("key", "status", "n_common", "cor", "sd_ratio", "old_end", "new_end")], row.names = FALSE)
cat("\n"); print(table(factor(res$status, c("same", "similar", "different", "missing", "new"))))
message("written: ", normalizePath(out_file))
