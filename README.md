# seed-life-dashboard-agent

## Purpose

A SEED that installs the six `ld-*` "life-dashboard" agent skill bundles into a local Plow:

- `ld-shared` — the shared `post_to_kiosk.py` POST helper used by the **wrapper-based** post scripts (`post_alert.py` / `post_message.py` / `post_digest.py` / `post_nudge.py`). The Pattern-B scheduled runners (`ld-weather`, and `ld-calendar-nudge`'s `scheduled/run.js`) post directly instead.
- `ld-calendar-nudge` — cron-driven calendar nudges.
- `ld-morning-triage` — daily morning email triage cards.
- `ld-morning-updates` — daily good-morning summary cards.
- `ld-weekly-digest` — weekly digest cards.
- `ld-weather` — hourly weather card (current temp + forecast high/low + condition) from the National Weather Service.

This repo is the source-of-truth for the six `ld-*` bundles — they live at `ref/team-skills/` and are authored and fixed here. The install POSTs each bundle to plowd's `/marketplace/api/install-local-bundles` endpoint (the same path `just sync-team-skills` uses); plowd does atomic-swap-with-rollback into the agent's skills root — `~/Plow/skills/` on current builds, or a container workspace (`containers/<UUID>/workspace[/host]/skills/`) on v2 builds.

The bundles need a `dashboard-endpoint-url` + `dashboard-token` to POST their cards to. This SEED reads those from [`seed-life-dashboard-relay`](https://github.com/plow-pbc/seed-life-dashboard-relay)'s state file (`~/Library/Application Support/seed-life-dashboard-relay/state.json`) and writes them to `~/Library/Application Support/co.plow.app/agent-runtime/secrets/` (mode 600) for the bundles to consume.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-agent`

The umbrella [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) installs this SEED + its dependencies (`seed-plow-app`, `seed-life-dashboard-relay`) in one shot.

## License

MIT
