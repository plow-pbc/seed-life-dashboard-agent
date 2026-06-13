# seed-life-dashboard-agent

## Purpose

A SEED that installs the seven `ld-*` "life-dashboard" agent skill bundles into a local Plow:

- `ld-shared` — the shared `post_to_kiosk.py` POST helper used by the **wrapper-based** post scripts (`post_alert.py` / `post_message.py` / `post_digest.py` / `post_nudge.py`), plus `scheduled/kiosk.js` — the shared logger / read / kiosk-POST idioms the Pattern-B scheduled runners (`ld-calendar-nudge`, `ld-weather`, `ld-sports`) import.
- `ld-calendar-nudge` — cron-driven calendar nudges.
- `ld-morning-triage` — daily morning email triage cards.
- `ld-morning-updates` — daily good-morning summary cards.
- `ld-weekly-digest` — weekly digest cards.
- `ld-weather` — hourly weather card (current temp + forecast high/low + condition) from the National Weather Service.
- `ld-sports` — the current/next game for each followed team (away/home logos, scores, live/Final) from ESPN's public scoreboard, refreshed every scheduled tick.

This repo is the source-of-truth for the seven `ld-*` bundles — they live at `ref/team-skills/` and are authored and fixed here. The install POSTs each bundle to plowd's `/marketplace/api/install-local-bundles` endpoint (the same path `just sync-team-skills` uses); plowd does atomic-swap-with-rollback into the agent's skills root — `~/Plow/skills/` on current builds, or a container workspace (`containers/<UUID>/workspace[/host]/skills/`) on v2 builds.

The bundles need a `dashboard-endpoint-url` + `dashboard-token` to POST their cards to. This SEED reads `DASHBOARD_ENDPOINT_URL` (the full `/api/message` URL of the household's Pi message API) and `DASHBOARD_TOKEN` (its bearer) from the environment and writes them to `~/Library/Application Support/co.plow.app/agent-runtime/secrets/` (mode 600) for the bundles to consume. On an umbrella install these are derived and exported by `seed-life-dashboard` before this SEED runs; on a standalone install the operator supplies them directly.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-agent`

The umbrella [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) installs this SEED + its dependencies (`seed-plow-app`) in one shot, minting `DASHBOARD_TOKEN` and deriving `DASHBOARD_ENDPOINT_URL` before recursing into this SEED.

## License

MIT
