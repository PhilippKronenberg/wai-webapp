# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What this is

A public dashboard for the **Weekly Activity Index (WAI)**, a high-frequency
indicator of Swiss GDP growth. Published at
<https://philippkronenberg.github.io/wai-webapp/>.

It is a static page and the data it reads. **No build step, no server, no
framework, no `node_modules`.** `index.html` is opened directly by the browser,
fetches one CSV, and draws it.

```
index.html                     the entire application
wai_data.csv                   the entire data layer
wai_meta.json                  run metadata (drives the "as of" line)
vendor/chart.umd.js            Chart.js 4.4.0 (MIT), vendored
vendor/chartjs-adapter-*.js    its date adapter (MIT), vendored
vendor/SHA256SUMS              checksum pin for both of the above
tools/validate-data.mjs        CI data validator, zero dependencies
.github/workflows/ci.yml       the only CI
.github/scripts/               CI-only helpers, zero dependencies
LICENSE / LICENSE-DATA         MIT for code, CC BY 4.0 for the data
```

The numbers come from the [`mfbdfm`](https://github.com/PhilippKronenberg/mfbdfm)
R package — specifically `export_wai_web()`. **This page performs no estimation
of its own.** If a number looks wrong, the bug is almost certainly upstream in
mfbdfm, not here.

## Constraints to defend, not fix

These look like omissions and are not. Each was chosen.

- **No build step.** Do not introduce npm, a bundler, TypeScript, or a
  framework. The whole point is that the page is deployable as a free static
  site with nothing between the source and what the browser runs.
- **Chart.js is vendored, not loaded from a CDN.** This is a supply-chain
  decision: a CDN can change what it serves. `vendor/SHA256SUMS` pins the exact
  bytes and CI verifies them. Do not "modernise" this into a `<script
  src="https://cdn...">`.
- **`tools/validate-data.mjs` uses Node built-ins only.** CI must not be the
  thing that introduces a dependency into a repository that deliberately has
  none. `html-validate` is fetched by `npx` at run time for the same reason —
  it is never declared as a dependency.
- **`wai_data.csv` is a public interface.** People download it and the page
  links it. Its column names and `YYYY-MM-DD` date format are not free to
  change; changing them breaks other people's scripts silently.

## The data contract

`wai_meta.json` has more fields than the page uses. **`index.html` reads exactly
four**: `vintage_date`, `run_timestamp`, `mfbdfm_version`, `columns`. Removing
one of those breaks the page.

The rest — `n_obs`, `first_obs_date`, `last_obs_date`, `latest_wai_qoq`,
`latest_wai_yoy`, `latest_index` — restate facts derivable from the CSV and are
read by nobody. They can therefore drift out of agreement with the data while
the page still looks entirely correct. `tools/validate-data.mjs` checks them
against the CSV precisely because nothing else would notice.

## CI

`.github/workflows/ci.yml`, three jobs:

- **`check`** gates merges. `node tools/validate-data.mjs`, then
  `sha256sum -c vendor/SHA256SUMS`, then `npx html-validate index.html`. All
  deterministic, all fast (~11s total).
- **`links`** is advisory (`continue-on-error: true`) and deliberately **not** a
  merge gate. External link checking depends on other people's servers being
  reachable and willing, so it fails for reasons unrelated to the change under
  review, and gating merges on it teaches people to ignore red.
- **`a11y`** is advisory for a different reason: it grades the page as it
  stands, not the change under review, so it was already red the day it was
  added. It serves the page and runs axe-core against the `http://` URL —
  never the file, because `fetch()` is blocked over `file://` and an auditor
  pointed at the file grades the error banner and reports almost nothing.
  A step before the audit asserts the dashboard actually rendered (stat tiles
  present, chart canvas sized by Chart.js, error banner still hidden) so a
  silent data failure cannot masquerade as a clean audit. Findings go to the
  run summary via `.github/scripts/a11y-summary.mjs`. Promote it to a gate once
  what it reports is fixed.

**The link job accepts HTTP 403 as alive.** `index.html` cites
`doi:10.1002/jae.3104`, which resolves to `onlinelibrary.wiley.com`, and Wiley
returns 403 to any non-browser client including one sending a full desktop user
agent. That is bot protection, not a dead link. Do not "fix" it by removing the
DOI.

## Traps that have already cost time

- **Line endings vs the checksum pin.** `vendor/**` is marked `-text` in
  `.gitattributes` so git never converts its line endings. Without that, a
  Windows checkout of `chart.umd.js` is 204962 bytes where the stored blob is
  204948 — 14 carriage returns — and `sha256sum -c` fails on a file nobody
  touched. If you regenerate the checksums, do it from a checkout with LF, or
  read them off a CI run. `vendor/SHA256SUMS` is itself pinned to `eol=lf`,
  because `sha256sum -c` splits on exact bytes and a trailing CR joins the
  filename.
- **The palette is defined three times.** `index.html` has a light `:root`, a
  `@media (prefers-color-scheme: dark)` override, and a `:root[data-theme="dark"]`
  block for the theme toggle. A colour written directly into a rule applies to
  one of the three and looks broken in the other two. **Add colours as tokens,
  in all three blocks.** Dark mode needs its own values, not the light ones:
  the brand `#173f47` sinks into a `#121211` page and `#276873` title text
  falls below WCAG AA against it, so dark uses lifted variants of the same hue.
- **The legend is hand-built.** Chart.js's own legend is disabled
  (`legend: { display: false }`); the visible one is
  `<div class="legend" id="legend">` populated by `renderLegend()`. Moving or
  restyling it is a markup/CSS change, never a Chart.js options change.
- **`fetch()` does not work over `file://`.** Opening `index.html` by
  double-clicking shows an error banner, not the dashboard, because the browser
  blocks the CSV and JSON fetches. To preview locally, serve it:
  `python -m http.server 8787 --bind 127.0.0.1` and open
  <http://127.0.0.1:8787/>.

## Deployment

GitHub Pages, built from `main` (not `gh-pages`). A merge to `main` triggers
`pages-build-deployment` automatically; there is no deploy workflow to maintain.

**Toggling the repository private and back to public silently disables Pages,
and it does not come back on its own.** This happened to mfbdfm: its `gh-pages`
branch stayed populated by months of deploys while the site returned 404, and
this dashboard linked to the dead URL. Re-enable under Settings → Pages.

## Cost

Public repository, standard GitHub-hosted runners, so **Actions minutes are
free** — the monthly allowance is drawn down only by private repositories. Any
Claude automation must authenticate with `claude_code_oauth_token` against the
subscription, never `anthropic_api_key`, which bills metered API credit.

Both properties depend on the repository staying public. Larger runners bill
even on public repos, so do not switch a job to one.

## Start here: what is actually outstanding

**Read the issue queue before doing anything else.** `gh issue list --state open`
plus a glance at what closed recently is the fastest way to pick up where the
last session stopped, and it is cheaper than re-deriving the state from the
code.

**An open issue here does not mean outstanding work.** Three of them are open
for reasons that are not "unfinished", and reading the titles alone gets this
wrong every time:

| Issue | Why it is open |
| --- | --- |
| #5 | The **running design list**, open by design. New design points get appended to it rather than opening their own issue. It is a container, not a task. |
| #17 | **Deliberately parked.** `data/dataset/` is a fixed snapshot and re-fitting it weekly would republish identical bytes. The unpark trigger is newer vintages arriving — not a decision anyone needs to revisit meanwhile. |
| #2 | Open only for `claude-code.yml` and `claude-code-review.yml`. **No agent can ever close it:** a GitHub App cannot write under `.github/workflows/` without the `workflows` permission, which this one does not carry. Confirmed twice, including after a full App reinstall. These get applied by hand. |

So the useful question is not "what is open" but "what is open **and** actionable".

**Labels carry the queue state**, and `.github/workflows/claude-agent-queue.yml`
acts on them:

- `agent-ready` — queued. The queue takes **one per run**, on `issues: labeled`
  and a 6-hourly cron.
- `agent-working` — claimed. A run that dies without releasing this leaves the
  claim behind; the next cron fire is what recovers it.
- `agent-done` — the agent finished its part. **Not the same as closed** — #2
  carries this label and is still open.
- `agent-blocked` — a dead end. It is deliberately **not** restored to
  `agent-ready`, because a dead end that retries forever is worse than one that
  waits for a person.

**Check `main`, not just the issue.** Work can be complete on a branch, or
merged but not reflected in `NEWS.md`, and neither shows in the issue state.
That is exactly how the #15/#16 changelog entry went missing: the deferral was
correct, the follow-through had nowhere to live. `git log --oneline -15` and the
top of `NEWS.md` settle it in seconds.

**Read the issue body for ordering before starting one.** Dependencies between
issues are written in the bodies, not expressed by any label — #21 must not be
worked before #20, for instance. The queue picks one issue at a time and has no
notion of a blocked-by edge.

## Conventions

- **Issue-driven, branch per issue.** Every change gets an issue, a short-lived
  branch off an up-to-date `main`, and a PR. Never commit to `main`.
- Commit messages end with `Closes #N` and a `Co-Authored-By:` line.
- **Every PR updates `NEWS.md`, in the same PR.** A merge to `main` deploys, so
  the top of that file is what is live. Add the entry under a `## YYYY-MM-DD`
  heading for the day the change reaches `main`, newest first, and mark it
  *Data* if the published numbers moved or *Presentation* if what the page
  shows changed; leave it unmarked for repository infrastructure. Marking
  matters most for data: `wai_data.csv` is republished in full on every update,
  so a change to the numbers is invisible in the diff and the changelog is the
  only place a reader who cites the index can find it.

  Write the entry against the file it describes rather than from the commit
  message — reviewing #18 that way turned up two wrong figures in an entry that
  read perfectly well. **Do not write an entry for work that is not yet on
  `main`**; it belongs in the file the day its PR merges, which is exactly how
  the #15/#16 entry came to be missing.
- **Design changes go to the running design issue** rather than getting their
  own — see #5, which stays open as the accumulating list.
- After editing any workflow, run `gh workflow list` and confirm it still shows
  the workflow's real name. A workflow file can be valid YAML and still be
  rejected by GitHub's schema, and the failure is silent: no trigger fires, and
  the only signs are a run that fails in 0s and a display name that has quietly
  become a file path.
