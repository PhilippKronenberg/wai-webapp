# Run from the repository root:  Rscript publish/check_kof_released.R

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Test: no KOF observation from an unreleased vintage reaches the model (#72)
#
# Changes kof_series.csv, the raw download that can hold pre-release data, in
# both KOF folders: every value moved and a future month added. Then reassembles
# and requires the model's KOF input to be unchanged and equal to a released
# file. Equal input means an equal `dat`, so the published series cannot depend
# on the raw download either. The raw files are always restored.
#
# Exit 0 if the test holds.
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

rscript <- file.path(R.home("bin"), "Rscript")
assemble <- function() {
  log <- tempfile()
  if (system2(rscript, shQuote("dataset/assemble_dataset.R"), stdout = log, stderr = log) != 0) {
    stop("assembling failed:\n", paste(readLines(log), collapse = "\n"), call. = FALSE)
  }
}
kof_input <- function() {
  e <- new.env()
  load(list.files(file.path("dataset", "out", "data"), pattern = "^postgres_data_new[.]rda$",
                  ignore.case = TRUE, full.names = TRUE), envir = e)
  e$ts_pg[grep("^ch[.]kof[.]", names(e$ts_pg))]
}

raws <- Filter(file.exists, file.path("kof", c("private", "public"), "kof_series.csv"))
if (!length(raws)) stop("no KOF download to test with; run kof/acquire_kof.R", call. = FALSE)
backup <- vapply(raws, function(f) tempfile(fileext = ".csv"), "")
invisible(file.copy(raws, backup))

assemble()
before <- kof_input()

ok <- tryCatch({
  for (f in raws) {
    x <- utils::read.csv(f, stringsAsFactors = FALSE)
    fut <- x[!duplicated(x$key, fromLast = TRUE), ]
    fut$date <- format(as.Date(fut$date) + 62)
    x <- rbind(x, fut)
    x$value <- x$value + 1000
    utils::write.csv(x, f, row.names = FALSE, na = "")
  }
  assemble()
  identical(before, kof_input())
}, finally = {
  file.copy(backup, raws, overwrite = TRUE)
  assemble()
})
if (!ok) stop("the model's KOF input moved with the raw download: pre-release data can reach it", call. = FALSE)

# The inputs are the values of a released file, unless a series has none at all
# and comes from the old bundle.
released <- lapply(Filter(file.exists, file.path("kof", c("private", "public"), "kof_series_released.csv")),
                   utils::read.csv, stringsAsFactors = FALSE)
for (k in names(before)) {
  v <- as.numeric(before[[k]])
  v <- v[!is.na(v)]
  candidates <- Filter(length, lapply(released, function(r) r$value[r$key == k]))
  if (!length(candidates)) {
    message("  ", k, ": no released file holds it (old-bundle fallback)")
  } else if (!any(vapply(candidates, function(w) isTRUE(all.equal(w, v)), logical(1)))) {
    stop(k, ": the model's input is not the values of a released file", call. = FALSE)
  }
}
message("OK: moving every value of ", paste(raws, collapse = " and "), " leaves the ",
        length(before), " KOF inputs unchanged, and they are released values.")
