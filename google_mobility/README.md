# Google COVID-19 Community Mobility Reports, Switzerland

**Discontinued: no download pipeline needed.** Google stopped publishing the
COVID-19 Community Mobility Reports in October 2022
(<https://www.google.com/covid19/mobility/>). The data cannot update, so this
folder holds the final national file as a static copy, not a script.

Not used by the dashboard. These six series are WAI inputs in
[mfbdfm](https://github.com/PhilippKronenberg/mfbdfm) (`mobility_*` in
`data-raw/data_meta.csv`), and this is the file its data prep reads
(`Google_Switzerland_Mobility_Report_total.csv`).

- **Source:** Google LLC, "Google COVID-19 Community Mobility Reports",
  <https://www.google.com/covid19/mobility/>. The full archive,
  `https://www.gstatic.com/covid19/mobility/Region_Mobility_Report_CSVs.zip`,
  is still served; checked 2026-10-25: 98 MB, last modified 2022-10-18.
- **Coverage:** Switzerland, national level, daily, **2020-02-15 to
  2022-10-15**.
- **Copied** unchanged from the private `wai_ind` repository
  (`data/google_mobility/Switzerland_Mobility_Report_total.csv`) on
  2026-10-25.

## File

| file | |
| --- | --- |
| `Switzerland_Mobility_Report_total.csv` | `;`-separated, dates `DD.MM.YYYY`; one row per day; six columns `<category>_percent_change_from_baseline` (retail and recreation, grocery and pharmacy, parks, transit stations, workplaces, residential) |

The values are percentage changes from Google's baseline, the median for the
same weekday from 3 Jan to 6 Feb 2020. mfbdfm adds 100 to keep its legacy
baseline convention.

## For the WAI

Because the series end in October 2022, they contribute nothing to a current
nowcast. In mfbdfm's real-time evaluation they still matter for the
2020–2022 vintages. Whether to keep them as inputs is tracked in #50.
