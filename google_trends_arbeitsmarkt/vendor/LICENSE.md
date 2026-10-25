# Licence of the files in this folder

These files are **not** covered by the repository's MIT licence. They are
copies, some patched, of functions from two GPL-licensed R packages:

- **trendecon** (<https://github.com/trendecon/trendecon>), GPL-3: the
  `ts_gtrends*`, `proc_*`, `aggregate_windows`, `path_utils`, `gtrends_with_backoff`,
  `irregular`, `keyword_plot`, `ModeOfSeries` and `utils` files.
- **tempdisagg** (<https://CRAN.R-project.org/package=tempdisagg>),
  GPL-2 | GPL-3: `td.R`, `td.calc.R`, `td.output.R`, `td.sub.R`, `ta.R`,
  `td_alt.R`, `tempdisagg-package.R`.

They are distributed under the GNU General Public License, version 3
(<https://www.gnu.org/licenses/gpl-3.0.html>). The copies were frozen in
`wai_ind` for stability and patched there and here. `proc_keyword_latest.R`
carries the changes made for wai-webapp #50, each marked in a comment.
