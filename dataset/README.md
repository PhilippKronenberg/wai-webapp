# The WAI's model dataset, built from this repository's pipelines

One command builds the dataset the WAI model (`mfbdfm::ind_dfm()`) reads,
from the source downloads to the transformed series:

```
Rscript run_all.R                                    # everything
Rscript run_all.R --skip=swissgrid,zurich_car_traffic # skip slow downloads (last output used)
Rscript run_all.R --no-pipelines                     # rebuild from the pipelines' current outputs
```

| step | script | output |
| --- | --- | --- |
| 1. pipelines | every `<source>/acquire_*.R` (and `bfs_keu`'s `.mjs`) | each source's folder |
| 2. assemble | `dataset/assemble_dataset.R` | `dataset/out/data/`: the 24 raw input files in the names and layouts of `wai_ind`'s `data/dataset`, and `dataset/out/manifest.csv` (source, span and kind of every file) |
| 3. prepare | `dataset/data_prep_dataset.R` | `dataset/out/Rda/data_ch_dataset_new.Rda` (`dat$flows`, `dat$stocks`), the raw stage, csv exports and plots |

`run_all.R` logs every step to `dataset/out/logs/`. A failing pipeline is
reported, and the run goes on with that source's last output. Everything in
`dataset/out/` is **gitignored**: it holds licensed (Datastream PMI history,
SIX, Yahoo) and possibly pre-release (KOF) data.

Needs: R with the pipelines' packages, Node.js, the `mfbdfm` package
installed (its GDP vintages are used), and `wai_ind` next to this repository.
`wai_ind` is read only, for the fixed histories.

## `data_prep_dataset.R`

A copy of mfbdfm's `analysis/1_data_prep_dataset.R`. mfbdfm's original is not
changed. The copy differs only where the inputs now arrive differently (see
its header): input, metadata and output paths, an output tag and the GDP
vintage date as environment variables, X-13 for BFS's unadjusted CPI and PPI,
and stat_einkauf's daily treatment for Worldline's daily credit-card count.
`dataset/data_meta.csv` is a copy of mfbdfm's `data-raw/data_meta.csv`.

**Check that the copy is faithful:** run on `wai_ind`'s `data/dataset`, it
reproduces the dataset the model used, mfbdfm's
`analysis/Rda/data_ch_dataset_test.Rda`. 44 of 46 series are identical, and
the two electricity series differ by at most 3e-7 (MSTL numerics):

```
MFBDFM_DATASET_DIR=../wai_ind/data/dataset MFBDFM_PREP_TAG=old MFBDFM_GDP_VINTAGE_DATE=2026-03-07 \
  Rscript dataset/data_prep_dataset.R
```

## Comparing with the model's old input

```
Rscript dataset/compare_datasets.R      # writes dataset/out/comparison.csv
```

Each series is compared on its common period with the old input (the
transformed series the model reads) and classified as **same** (correlation
≥ 0.99, standard deviations within 10%), **similar** (≥ 0.90), **different**,
**missing** or **new**.

Build of 2026-10-30 (public KOF only): **37 same, 6 similar, 3 different,
0 missing.**

- **different** (by design, the series changed): `anz_kktrans_ch` (Worldline
  count instead of SPA, 2020 only before), exports and imports (BAZG nominal
  SA instead of the OZD real index).
- **similar:** CPI, PPI and core inflation (BFS data adjusted with X-13
  here, Datastream's adjustment before), and 3 KOF series (newer vintages
  revise the seasonal adjustment).

**KOF: released vintages only.** The dataset never contains pre-release KOF
data. The assembler reads `kof_series_released.csv` (see `kof/README.md`), from
`kof/private/` when that file exists, and from `kof/public/` for any series
still missing. A private download without the released-only file is not used.
The four manufacturing sub-sector series are not public. Until
`kof/acquire_kof_loggedin.R` has been rerun, they come from the old bundle and
end in 2026-03 (the manifest marks them `FALLBACK`).

## Test run

```
Rscript dataset/test_run.R [<tag>] [<length_sample>] [<burn_in>]   # default: new 2000 500
```

Fits `ind_dfm()` (one factor, stochastic volatility, serial correlation) on
`data_ch_dataset_<tag>.Rda` and saves the fit to `dataset/out/fits/`.
