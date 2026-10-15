# BFE energy series

Swiss electricity production, consumption and cross-border flows, plus the
degree-day series that controls for weather. Not used by the dashboard
(`index.html` reads only `wai_data.csv`); kept here, next to `rhine_cargo` and
`zurich_air`, as candidate high-frequency indicators — electricity consumption
tracks activity at daily and weekly frequency, and `ogd51` is the **only true
weekly national series** in the whole opendata.swiss catalogue (#32).

- **Publisher:** Bundesamt für Energie (BFE) / Swiss Federal Office of Energy.
  `ogd103` and `ogd107` originate with **Swissgrid**, `ogd105` with
  **MeteoSchweiz**.
- **Licence:** opendata.swiss terms of use, **per dataset — they are not all
  the same**, see the table below. Credited here as required:
  **Bundesamt für Energie (BFE)**.

## Series

| key | dataset | obs. freq | span (checked 2026-10-15) | lag then | terms |
| --- | --- | --- | --- | --- | --- |
| `electricity_balance_weekly` | [ENSTAT Wochenstatistik Elektrizitätsbilanz](https://opendata.swiss/de/dataset/enstat-wochenstatistik-elektrizitatsbilanz-erzeugung-und-abgabe-elektrischer-energie-in-der-sch) (`ogd51`) | weekly | 2003-01-01 → 2026-06-24, 1222 obs | **~16 weeks** | `terms_by` |
| `electricity_consumption_daily` | [energiedashboard.ch: Landesverbrauch und Endverbrauch](https://opendata.swiss/de/dataset/energiedashboard-ch-landesverbrauch-und-endverbrauch) (`ogd103`) | daily | 2017-01-01 → 2026-08-31, 3530 obs | ~6 weeks | **`terms_by_ask`** |
| `electricity_flows_daily` | [energiedashboard.ch: Tägliche Flüsse in die und aus der Schweiz, Strom](https://opendata.swiss/de/dataset/energiedashboard-ch-tagliche-flusse-in-die-und-aus-der-schweiz-strom) (`ogd107`) | daily | 2017-01-01 → 2026-10-14, 3574 obs | **1 day** | `terms_by` |
| `degree_days_monthly` | [Monatliche Heizgradtage und Kühlgradtage (gewichtet)](https://opendata.swiss/de/dataset/monatliche-heizgradtage-und-kuhlgradtage-in-der-schweiz-gewichtet) (`ogd105`) | monthly | 1980-01 → 2026-09, 561 obs | ~2 weeks | `terms_by` |

The two terms differ in one way that matters downstream:

- **`terms_by`** — "Open use. Must provide the source."
- **`terms_by_ask`** — "Open use. Must provide the source. **Use for commercial
  purposes requires permission of the data owner.**"

Only `electricity_consumption_daily` (`ogd103`) carries the second. Redistributing
it here with attribution is within the terms; using it commercially is not,
without asking BFE first. Note that `LICENSE-DATA` (CC BY 4.0) covers
`wai_data.csv` and `wai_meta.json` **only** and does not extend to anything in
this folder, so nothing here is relicensed by being committed.

The timeliness ranking is worth reading off that table before picking a series:
`ogd107` is a day behind, `ogd51` — the only weekly one — is four months behind.

## Files

| file | |
| --- | --- |
| `acquire_bfe_energy.mjs` | downloads all four and writes the CSVs (Node built-ins only, no dependencies) |
| `bfe_electricity_balance_weekly.csv` | `date, measure, value, unit` |
| `bfe_electricity_consumption_daily.csv` | `date, measure, value, unit` |
| `bfe_electricity_flows_daily.csv` | `date, measure, counterparty, value, unit` |
| `bfe_degree_days_monthly.csv` | `date, year, month, measure, value, unit` |

Refresh from the repository root:

```sh
node bfe_energy/acquire_bfe_energy.mjs
node bfe_energy/acquire_bfe_energy.mjs --series electricity_flows_daily
node bfe_energy/acquire_bfe_energy.mjs --cache /tmp/bfe
```

With `--cache` the downloads are kept and reused, which is how to re-parse
without fetching again. All four files together are about 1.7 MB.

## Reading the CSVs

- One row per **period and measure**, long format, sorted, LF line endings, no
  BOM, dates `YYYY-MM-DD`. Monthly periods are dated to the **first of the
  month**, as in `rhine_cargo`.
- `value` is passed through as the publisher's own text, never reparsed and
  reformatted, so no float round-trip can move a digit. That is why `-0.00`
  appears verbatim in the flows file.
- **An absent row means no reported value.** Nothing is zero-filled and nothing
  is reindexed onto a regular grid.

### `electricity_balance_weekly` (`ogd51`)

- **Wednesday data**, in the publisher's words: the week is identified by its
  Wednesday. The grid is *not* a clean 7-day sequence — one observation falls on
  a **Tuesday** (2009-10-27), one week is missing in October 2004, and four are
  missing in December 2007. Resampling code that assumes 7-day steps will be
  quietly wrong.
- **Definitional break at 2025-01-01.** Before it, thermal, wind and
  photovoltaic generation are reported together as `erzeugung_andere`
  (2003-01-01 → 2024-12-25); from it they are reported separately as
  `erzeugung_thermisch`, `erzeugung_windkraftwerk` and `erzeugung_photovoltaik`
  (2025-01-01 →), and `erzeugung_andere` stops. The script does **not** splice
  them into one continuous series: summing the three to extend `erzeugung_andere`
  backwards is a modelling choice and belongs in `mfbdfm`. The unaffected
  measures — `landesverbrauch`, `erzeugung_netto`, `einfuhr`, `ausfuhr`, hydro
  and nuclear — run the full span and are the ones to reach for first.
- `landesverbrauch` includes the storage-pump consumption that
  `verbrauch_speicherpumpen` reports separately.
- The catalogue's own download URL for this dataset **is broken** (it points one
  directory above the file and answers `NoSuchKey`), and the old
  `uvek-gis.admin.ch` copy is **frozen** — it opens with a notice line saying so,
  which a parser reads as a header. The script uses the live `/ogd51/` path and
  rejects any response that starts with markup.

### `electricity_consumption_daily` (`ogd103`)

- **These numbers get revised.** They are built from what distribution network
  operators report to Swissgrid, which the publisher says "can be incomplete or
  erroneous and are corrected afterwards". A refresh rewrites recent history, so
  for real-time work the vintage matters.
- `landesverbrauch` includes storage pumps; `endverbrauch` is consumption by
  households, trade, agriculture, services, industry and transport.

### `electricity_flows_daily` (`ogd107`)

- Physical cross-border flows, summed over the day. `measure` is `import`
  (into Switzerland) or `export` (out of it), with `counterparty` one of `AT`,
  `DE`, `FR`, `IT`.
- `nettoimport` is the balance over all four borders and has **no counterparty**,
  so that cell is empty — as `rhine_cargo` leaves `commodity` empty on its
  headline rows. A **negative** `nettoimport` means Switzerland was a net
  exporter that day.

### `degree_days_monthly` (`ogd105`)

- Not activity: this is the weather control the electricity series need (#32,
  A13). Both measures are computed by MeteoSchweiz for every postcode area and
  **weighted by current population**.
- `heizgradtage` (HGT) sums the daily gaps between mean outdoor temperature and
  a 20 °C room temperature, over days whose mean outdoor temperature is **12 °C
  or below**. `kuehlgradtage` (CDD) sums the gaps against 18.3 °C over days at
  **18.3 °C or above**.
- The publisher implemented the current method in **2025** and says the revised
  series runs from 1980, so this is a recomputed history rather than a
  contemporaneous one. It is a control, not an indicator, which makes that
  acceptable — but it is not a real-time vintage. Method documented in
  *Energie-Indikatoren an Postleitzahlen und für verschiedene institutionelle
  Ebenen*, on the
  [MeteoSchweiz site](https://www.meteoschweiz.admin.ch/klima/klima-der-schweiz/raeumliche-klimaanalysen.html).
