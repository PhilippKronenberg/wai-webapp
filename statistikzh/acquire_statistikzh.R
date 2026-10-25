# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Download the WAI inputs only available from the Canton of Zurich's
# covid19monitoring repositories (statistikZH) (#50)
#
# These series cannot be rebuilt from a current source: their publishers
# stopped (SBB's daily train counts per station, intervista's tracking panel,
# SIX's card data on the cantonal feed). Their final data are in the
# statistikZH repositories, which this script downloads and writes in the
# layout of wai_ind's data/dataset files:
#
#   ktzh_Mobility_SBBHauptbahnhof.csv    oev_freq_hb            trains in/out, Zurich HB
#   ktzh_intervista_median_distance.csv  tages_distanz_median   median daily distance, CH
#   ktzh_debit_ausland_SIX.csv           debiteinsatz_ausland   debit cards abroad, CHF m
#
# The script also reports, per repository, whether it is archived and when
# it was last pushed, so a revived repository would be noticed.
#
# Source
#   https://github.com/statistikZH/covid19monitoring_mobility_SBBHauptbahnhof
#   https://github.com/statistikZH/covid19monitoring_mobility_intervista
#   https://github.com/statistikZH/covid19monitoring_economy_SIX
#
# Usage
#   Rscript statistikzh/acquire_statistikzh.R
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

raw_base <- "https://raw.githubusercontent.com/statistikZH"
api_base <- "https://api.github.com/repos/statistikZH"
user_agent <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

# One entry per output: repository, file, which series, and wai_ind's layout.
series <- list(
  ktzh_Mobility_SBBHauptbahnhof = list(
    repo = "covid19monitoring_mobility_SBBHauptbahnhof", file = "Mobility_SBBHauptbahnhof.csv",
    variable = "oev_freq_hb", location = NULL, sep = ",", date_format = "%Y-%m-%d"),
  ktzh_intervista_median_distance = list(
    repo = "covid19monitoring_mobility_intervista", file = "Mobility_Intervista.csv",
    variable = "tages_distanz_median", location = "CH", sep = ";", date_format = "%d.%m.%Y"),
  ktzh_debit_ausland_SIX = list(
    repo = "covid19monitoring_economy_SIX", file = "Economy_SIX.csv",
    variable = "debiteinsatz_ausland", location = NULL, sep = ";", date_format = "%d.%m.%Y")
)

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "statistikzh"
})


# RUN ---------------------------------------------------------------------

fetch <- function(url) {
  dest <- tempfile()
  utils::download.file(url, dest, mode = "wb", quiet = TRUE, method = "libcurl",
                       headers = c(`User-Agent` = user_agent))
  dest
}

for (id in names(series)) {
  s <- series[[id]]
  meta <- tryCatch(jsonlite::fromJSON(fetch(file.path(api_base, s$repo))), error = function(e) NULL)
  branch <- if (is.null(meta)) "master" else meta$default_branch
  x <- utils::read.csv(fetch(paste(raw_base, s$repo, branch, s$file, sep = "/")),
                       stringsAsFactors = FALSE, encoding = "UTF-8")
  x <- x[x$variable_short == s$variable, ]
  if (!is.null(s$location)) x <- x[x$location == s$location, ]
  if (!nrow(x)) stop(id, ": no rows for ", s$variable)
  d <- as.Date(substr(x$date, 1, 10))
  x <- x[order(d), ]
  x$date <- format(sort(d), s$date_format)
  utils::write.table(x, file.path(script_dir, paste0(id, ".csv")), sep = s$sep, row.names = FALSE,
                     quote = if (s$sep == ",") which(names(x) != "date" & vapply(x, is.character, TRUE)) else FALSE,
                     fileEncoding = "UTF-8")
  message(sprintf("%-34s %s..%s (%d days) | repo %s, last push %s", paste0(id, ".csv"), min(d), max(d),
                  nrow(x), if (is.null(meta)) "?" else if (isTRUE(meta$archived)) "archived" else "active",
                  if (is.null(meta)) "?" else substr(meta$pushed_at, 1, 10)))
}
