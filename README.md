# seed-life-dashboard-agent

## Purpose

A SEED that installs the seven `ld-*` "life-dashboard" agent skill bundles into a local Plow:

- `ld-shared` — the shared `post_to_kiosk.py` POST helper used by the **wrapper-based** post scripts (`post_alert.py` / `post_message.py` / `post_digest.py` / `post_nudge.py`). The Pattern-B scheduled runners (`ld-weather`, `ld-sports`, and `ld-calendar-nudge`'s `scheduled/run.js`) post directly instead. **`ld-shared` is the shared contract layer**, pulled from [`plow-pbc/life-dashboard-skills`](https://github.com/plow-pbc/life-dashboard-skills) at install/test time (`ref/sync-ld-shared.sh`) and not vendored here — both life-dashboard agent seeds pull the same copy.
- `ld-calendar-nudge` — scheduled-runner calendar nudges (`scheduled/run.js`; no `cron action=add`).
- `ld-morning-triage` — daily morning email triage cards.
- `ld-morning-updates` — daily good-morning summary cards.
- `ld-weekly-digest` — weekly digest cards.
- `ld-weather` — hourly weather card (current temp + forecast high/low + condition) from the National Weather Service.
- `ld-sports` — quarter-hourly sports card (Apple-Sports-style scoreboard for the household's followed teams) from ESPN's public scoreboard feed.

This repo is the source-of-truth for the **six platform-specific** `ld-*` producer bundles — they live at `ref/team-skills/` and are authored and fixed here. The seventh, `ld-shared`, is the shared contract layer pulled from [`plow-pbc/life-dashboard-skills`](https://github.com/plow-pbc/life-dashboard-skills) (see above). The install POSTs each bundle to plowd's `/marketplace/api/install-local-bundles` endpoint (the same path `just sync-team-skills` uses); plowd does atomic-swap-with-rollback into the agent's skills root — `~/Plow/skills/` on current builds, or a container workspace (`containers/<UUID>/workspace[/host]/skills/`) on v2 builds.

The bundles need a `dashboard-endpoint-url` + `dashboard-token` to POST their cards to. This SEED reads `DASHBOARD_ENDPOINT_URL` (the full `/api/message` URL of the household's Pi message API) and `DASHBOARD_TOKEN` (its bearer) from the environment and writes them to `~/Library/Application Support/co.plow.app/agent-runtime/secrets/` (mode 600) for the bundles to consume.

**Required compatible viewer.** `ld-weather` (card 3) and `ld-sports` (card 5) emit **self-contained HTML tiles** — each ships its own `<style>` — that the viewer renders verbatim; the viewer carries **no** widget-specific CSS, so these bundles depend only on the generic box-renderer ([`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer), PR #40) and its shared theme tokens (`--ink` / `--muted` / fonts / …) that the producer styles reference. (The optional producer `title` field these bundles use to hide the alert/affirmation eyebrows is viewer PR #43.) That viewer is a **required runtime** for this SEED: installed against an older viewer that does not render HTML, cards 3 and 5 show literal markup tags. Install/upgrade the viewer before (or alongside) this SEED. On an umbrella install these are derived and exported by `seed-life-dashboard` before this SEED runs; on a standalone install the operator supplies them directly.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-agent`

The umbrella [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) installs this SEED + its dependencies (`seed-plow-app`) in one shot, minting `DASHBOARD_TOKEN` and deriving `DASHBOARD_ENDPOINT_URL` before recursing into this SEED.

## License

MIT
