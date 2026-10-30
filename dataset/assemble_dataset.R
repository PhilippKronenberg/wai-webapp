# Run from the repository root.

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#
# Assemble the WAI's model input folder from this repository's pipelines (#50)
#
# mfbdfm builds the model dataset with analysis/1_data_prep_dataset.R, which
# reads 24 raw files from a folder (wai_ind's data/dataset). This script
# writes that folder, with the same file names and layouts, from the outputs
# of the pipelines in this repository, so the prep script runs unchanged on
# current data:
#
#   MFBDFM_DATASET_DIR=<this folder> MFBDFM_PREP_TAG=new Rscript analysis/1_data_prep_dataset.R
#
# Fixed history from wai_ind is read (never written) where a series has no
# current source or its pipeline appends to it: FINANSW/INDUSSW, the SIX cash
# withdrawals, the Swiss bond yield (not a model input), the Zurich Airport
# daily file (continued from the monthly bulletins), and KOF series the
# account cannot read.
#
# Output: dataset/out/data/ (gitignored: it holds licensed and pre-release
# data) and dataset/out/manifest.csv (file, source, span, how it was made).
#
# Usage
#   Rscript dataset/assemble_dataset.R [<wai_ind dir>]   (run_all.R runs the pipelines first)
#   default wai_ind dir: ../wai_ind
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


# SETTINGS ----------------------------------------------------------------

script_dir <- local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else "dataset"
})
root <- normalizePath(file.path(script_dir, ".."))
args <- commandArgs(trailingOnly = TRUE)

args <- args[!grepl("^--", args)]
wai_ind <- normalizePath(if (length(args)) args[1] else file.path(root, "..", "wai_ind"), mustWork = TRUE)
old <- file.path(wai_ind, "data", "dataset")                     # read-only
out <- file.path(script_dir, "out", "data")
dir.create(out, recursive = TRUE, showWarnings = FALSE)

p <- function(...) file.path(root, ...)


# HELPERS -----------------------------------------------------------------

manifest <- list()
note <- function(file, source, kind, dates, comment = "") {
  dates <- as.Date(dates[!is.na(dates)])
  manifest[[length(manifest) + 1]] <<- data.frame(
    file = file, source = source, kind = kind,
    first = if (length(dates)) format(min(dates)) else NA, last = if (length(dates)) format(max(dates)) else NA,
    comment = comment, stringsAsFactors = FALSE)
  message(sprintf("  %-46s %-9s %s..%s  %s", file, kind, if (length(dates)) min(dates) else "-",
                  if (length(dates)) max(dates) else "-", comment))
}
need <- function(path) {
  if (!file.exists(path)) stop("missing pipeline output: ", path, " (run its acquire script, or --refresh)", call. = FALSE)
  path
}
copy_as <- function(src, name, source, kind, date_col = 1, date_format = NULL, sep = NULL, comment = "") {
  file.copy(need(src), file.path(out, name), overwrite = TRUE)
  x <- if (is.null(sep)) utils::read.csv(src, check.names = FALSE, stringsAsFactors = FALSE)
       else utils::read.table(src, sep = sep, header = TRUE, check.names = FALSE, quote = "\"",
                              stringsAsFactors = FALSE, fileEncoding = "UTF-8-BOM")
  d <- x[[date_col]]
  d <- if (is.null(date_format)) as.Date(substr(d, 1, 10)) else as.Date(d, date_format)
  note(name, source, kind, d, comment)
}
monthly_ts <- function(dates, values) {
  dates <- as.Date(dates); ok <- !is.na(dates) & !is.na(values)
  dates <- dates[ok]; values <- values[ok]; o <- order(dates)
  dates <- dates[o]; values <- values[o]
  ym <- as.integer(format(dates, "%Y")) * 12 + as.integer(format(dates, "%m")) - 1
  full <- seq(min(ym), max(ym))
  v <- rep(NA_real_, length(full)); v[match(ym, full)] <- values
  stats::ts(v, start = c(min(ym) %/% 12, min(ym) %% 12 + 1), frequency = 12)
}
ddmmyyyy <- function(d) format(as.Date(d), "%d.%m.%Y")


# ASSEMBLE ----------------------------------------------------------------

message("Assembling ", out)

# 1. postgres_data_new.rda: KOF (9) and trade (2), monthly ts in `ts_pg`
e <- new.env(); load(file.path(old, "postgres_data_new.Rda"), envir = e)
ts_pg <- list()
# Released vintages only: kof_series_released.csv, never kof_series.csv, which
# can hold pre-release data. Only series whose vintage is recorded as released
# in kof_release_used.csv, with a release time that has passed, are taken. A
# private download without these files is not used at all.
read_released_kof <- function(mode) {
  f <- p("kof", mode, "kof_series_released.csv"); u <- p("kof", mode, "kof_release_used.csv")
  if (!file.exists(f) || !file.exists(u)) return(NULL)
  used <- utils::read.csv(u, stringsAsFactors = FALSE)
  rt <- as.POSIXct(sub("Z$", "", sub("T", " ", used$release_time)), tz = "UTC")
  ok <- used$key[used$released %in% TRUE & !is.na(rt) & rt <= Sys.time()]
  if (length(setdiff(used$key, ok))) {
    message("  KOF ", mode, ": not verified as released, not used: ", paste(setdiff(used$key, ok), collapse = ", "))
  }
  x <- utils::read.csv(f, stringsAsFactors = FALSE)
  x <- x[x$key %in% ok, ]
  x$source <- paste0("kof/", mode)
  x$vintage <- used$vintage_date[match(x$key, used$key)]
  x
}
kof <- read_released_kof("private")
if (is.null(kof) && file.exists(p("kof", "private", "kof_series.csv"))) {
  message("  KOF private: no released-only file; rerun kof/acquire_kof_loggedin.R. Not using the private download.")
}
kof_pub <- read_released_kof("public")
if (is.null(kof) && is.null(kof_pub)) stop("no released KOF data; run kof/acquire_kof.R", call. = FALSE)
# Per series the newest released vintage, private on a tie: a private download
# that has not been refreshed must not hold back the public one.
kof <- do.call(rbind, lapply(split(rbind(kof, kof_pub), rbind(kof, kof_pub)$key), function(x) {
  x[x$source == x$source[order(x$vintage, x$source == "kof/private", decreasing = TRUE)[1]], ]
}))
kof_keys <- grep("^ch\\.kof\\.", names(e$ts_pg), value = TRUE)
for (k in kof_keys) {
  x <- kof[kof$key == k, ]
  if (nrow(x)) {
    ts_pg[[k]] <- monthly_ts(x$date, x$value)
    note(paste0("postgres_data_new.rda:", k), x$source[1], "pipeline", x$date, "released vintage")
  } else {
    ts_pg[[k]] <- e$ts_pg[[k]]
    tt <- stats::time(e$ts_pg[[k]])
    note(paste0("postgres_data_new.rda:", k), "wai_ind postgres_data_new.Rda", "FALLBACK",
         as.Date(sprintf("%d-%02d-01", floor(tt + 1e-6), round((tt - floor(tt + 1e-6)) * 12) + 1)),
         "no released vintage available; old values (run kof/acquire_kof_loggedin.R)")
  }
}
tr <- utils::read.csv(need(p("bazg_trade", "bazg_trade_wai.csv")), stringsAsFactors = FALSE)
for (d in c("export", "import")) {
  k <- if (d == "export") "ch.ozd.e.wa.index.re.d11" else "ch.ozd.i.wa.index.re.d11"
  x <- tr[tr$direction == d, ]
  ts_pg[[k]] <- monthly_ts(x$date, x$seasonalAdjusted_Nominal_Value / 1e9)
  note(paste0("postgres_data_new.rda:", k), "bazg_trade", "pipeline", x$date,
       "SWITCHED: nominal SA total (CHF bn), not the OZD real index")
}
save(ts_pg, file = file.path(out, "postgres_data_new.rda"))

# 2. fso_series.csv: retail, NOGA 47, calendar and seasonally adjusted, real
keu <- utils::read.csv(need(p("bfs_keu", "bfs_keu_turnover_monthly.csv")), stringsAsFactors = FALSE)
r <- keu[keu$noga == "47" & keu$adjustment == "Y" & keu$indicator == "PTOT" & keu$measure == "IX", ]
r <- r[order(r$date), ]
utils::write.csv(data.frame(date = substr(r$date, 1, 7), ch.fso.rtt.ind.r.noga0801.sa = r$value, check.names = FALSE),
                 file.path(out, "fso_series.csv"), row.names = FALSE)
note("fso_series.csv", "bfs_keu", "pipeline", r$date)

# 3. datastream_econ.csv: BFS CPI/PPI (unadjusted; the prep adjusts them), core, PMI
pr <- utils::read.csv2(need(p("bfs_prices", "bfs_prices.csv")), dec = ".", check.names = FALSE, stringsAsFactors = FALSE)
pmi <- utils::read.csv2(need(p("procure_pmi", "pmi_extended.csv")), dec = ".", check.names = FALSE, stringsAsFactors = FALSE)
econ <- merge(pr, pmi, by = "Name", all = TRUE)
econ <- econ[order(as.Date(econ$Name, "%d.%m.%Y")), ]
utils::write.table(econ, file.path(out, "datastream_econ.csv"), sep = ";", row.names = FALSE, quote = FALSE, na = "")
note("datastream_econ.csv", "bfs_prices + procure_pmi", "pipeline", as.Date(econ$Name, "%d.%m.%Y"),
     "CPI/PPI unadjusted (X-13 in the prep); PMI = fixed Datastream history + reports")

# 4. datastream_swiss_bonds.csv (not a model input; the prep reads it)
copy_as(file.path(old, "datastream_swiss_bonds.csv"), "datastream_swiss_bonds.csv", "wai_ind", "static",
        date_format = "%d.%m.%Y", sep = ";", comment = "not a model input")

# 5. datastream_SMI.csv: FINANSW, INDUSSW fixed (Datastream ended); SMI from Yahoo, Datastream before 1990-11-09
ds <- utils::read.csv2(file.path(old, "datastream_SMI.csv"), dec = ".", check.names = FALSE, stringsAsFactors = FALSE,
                       fileEncoding = "UTF-8-BOM")
names(ds)[1] <- "Name"
ds$date <- as.Date(ds$Name, "%d.%m.%Y")
smi <- utils::read.csv(need(p("markets", "smi_daily.csv")))
smi$date <- as.Date(smi$date)
m <- merge(ds, smi, by = "date", all = TRUE)
col_smi <- "SWISS MARKET (SMI) - PRICE INDEX"
m[[col_smi]] <- ifelse(!is.na(m$close), m$close, ifelse(m$date < min(smi$date), m[[col_smi]], NA))
m$Name <- ddmmyyyy(m$date)
smi_out <- m[, c("Name", "SWITZ-DS Financials - PRICE INDEX", "SWITZ-DS Industrials - PRICE INDEX", col_smi)]
utils::write.table(smi_out, file.path(out, "datastream_SMI.csv"), sep = ";", row.names = FALSE, quote = FALSE, na = "")
note("datastream_SMI.csv", "markets (SMI) + wai_ind (FINANSW, INDUSSW)", "pipeline", m$date[!is.na(m[[col_smi]])],
     sprintf("FINANSW/INDUSSW fixed to %s", max(ds$date[!is.na(ds[["SWITZ-DS Financials - PRICE INDEX"]])])))

# 6. VIX.csv: VSMI, history + SIX
copy_as(p("vsmi", "VIX.csv"), "VIX.csv", "vsmi", "pipeline", date_format = "%d.%m.%Y", sep = ";", comment = "VSMI")

# 7. trendecon_sa.csv: trendEcon's published series
copy_as(p("trendecon", "trendecon_sa.csv"), "trendecon_sa.csv", "trendecon", "pipeline")

# 8. google_trends_Arbeitsmarkt_sa.csv
copy_as(p("google_trends_arbeitsmarkt", "google_trends_Arbeitsmarkt_sa.csv"), "google_trends_Arbeitsmarkt_sa.csv",
        "google_trends_arbeitsmarkt", "pipeline")

# 9. ktzh_ATM_Cash_Withdrawals_Swiss_Wide_Daily.csv: discontinued (2023-01-01)
copy_as(file.path(old, "ktzh_ATM_Cash_Withdrawals_Swiss_Wide_Daily.csv"), "ktzh_ATM_Cash_Withdrawals_Swiss_Wide_Daily.csv",
        "wai_ind", "static", comment = "discontinued")

# 10. Swiss_Consumption_anz_kktrans_ch.csv: Worldline credit-card count (daily)
copy_as(p("worldline", "anz_kktrans_ch.csv"), "Swiss_Consumption_anz_kktrans_ch.csv", "worldline", "pipeline",
        date_format = "%d.%m.%Y", sep = ";", comment = "SWITCHED: Worldline daily count, not SPA weekly")

# 11-14. Zurich mobility and the statistikZH files
copy_as(p("zurich_hardbruecke", "daily_frequency_hardbruecke.csv"), "ktzh_daily_frequency_hardbruecke.csv",
        "zurich_hardbruecke", "pipeline")
copy_as(p("statistikzh", "ktzh_debit_ausland_SIX.csv"), "ktzh_debit_ausland_SIX.csv", "statistikzh", "static",
        date_format = "%d.%m.%Y", sep = ";", comment = "discontinued")
copy_as(p("statistikzh", "ktzh_intervista_median_distance.csv"), "ktzh_intervista_median_distance.csv", "statistikzh",
        "static", date_format = "%d.%m.%Y", sep = ";", comment = "discontinued")
copy_as(p("statistikzh", "ktzh_Mobility_SBBHauptbahnhof.csv"), "ktzh_Mobility_SBBHauptbahnhof.csv", "statistikzh",
        "static", comment = "discontinued")
copy_as(p("zurich_car_traffic", "Mobility_CarTraffic_indexed.csv"), "ktzh_Mobility_CarTraffic_indexed.csv",
        "zurich_car_traffic", "pipeline", date_format = "%d.%m.%Y", sep = ";")
copy_as(p("worldline", "ktzh_non_online_retail.csv"), "ktzh_non_online_retail.csv", "worldline", "pipeline",
        date_format = "%d.%m.%Y", sep = ";")

# 15-17. ASTRA, Destatis, Swissgrid
copy_as(p("astra_traffic", "astra_traffic.csv"), "ASTRA_traffic_extended.csv", "astra_traffic", "pipeline")
copy_as(p("destatis_maut", "Destatis_Truck_toll_mileage.csv"), "Destatis_Truck_toll_mileage.csv", "destatis_maut",
        "pipeline", date_format = "%d.%m.%Y", sep = ";")
copy_as(p("swissgrid", "swissgrid_daily.csv"), "swissgrid_2009_2025.csv", "swissgrid", "pipeline")

# 18. Flughafen_ZH_daily_anfluege_abfluege.csv: daily departures and arrivals,
# summed over the runway tables of the noise bulletins (zurich_airport/
# zrh_flights_daily.csv, from 2021-01, checked against the bulletins' monthly
# IFR totals). The bulletins start in 2021, so 2019-2020 come from wai_ind's
# daily file, which equals the bulletins on 99.6% of the days 2021-2025 (the
# rest are errors in that file).
zd <- utils::read.csv(need(p("zurich_airport", "zrh_flights_daily.csv")))
zd$date <- as.Date(zd$date)
ad <- utils::read.csv(file.path(old, "Flughafen_ZH_daily_anfluege_abfluege.csv"))
ad$date <- as.Date(ad$date)
ad <- ad[ad$date < min(zd$date), ]
air <- rbind(ad[, c("date", "total_anfluege", "total_abfluege")],
             data.frame(date = zd$date, total_anfluege = zd$arrivals, total_abfluege = zd$departures))
air <- air[order(air$date), ]
utils::write.csv(air, file.path(out, "Flughafen_ZH_daily_anfluege_abfluege.csv"), row.names = FALSE)
note("Flughafen_ZH_daily_anfluege_abfluege.csv", "zurich_airport (+ wai_ind daily before 2021)", "pipeline", air$date,
     sprintf("daily runway sums from the bulletins from %s; before from wai_ind's daily file", min(zd$date)))

# 19. Google mobility: final file
copy_as(p("google_mobility", "Switzerland_Mobility_Report_total.csv"), "Google_Switzerland_Mobility_Report_total.csv",
        "google_mobility", "static", date_col = "date", date_format = "%d.%m.%Y", sep = ";", comment = "discontinued")

man <- do.call(rbind, manifest)
utils::write.csv(man, file.path(script_dir, "out", "manifest.csv"), row.names = FALSE)
message("Wrote ", length(list.files(out)), " files to ", out, "; manifest: ", file.path(script_dir, "out", "manifest.csv"))
