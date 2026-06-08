# seed-life-dashboard-agent

## Purpose

A SEED that installs the five `ld-*` "life-dashboard" agent skill bundles into a local Plow:

- `ld-shared` — the shared `post_to_kiosk.py` helper required by every `ld-*` bundle.
- `ld-calendar-nudge` — cron-driven calendar nudges.
- `ld-morning-triage` — daily morning email triage cards.
- `ld-morning-updates` — daily good-morning summary cards.
- `ld-weekly-digest` — weekly digest cards.

Each bundle is vendored into this repo at `ref/team-skills/` so a fresh install does not require cloning the entire plow4 repo. The install POSTs each bundle to plowd's `/marketplace/api/install-local-bundles` endpoint (same path `just sync-team-skills` uses); plowd does atomic-swap-with-rollback into each agent container's workspace.

The bundles need a `dashboard-endpoint-url` + `dashboard-token` to POST their cards to. This SEED reads those from [`seed-life-dashboard-relay`](https://github.com/plow-pbc/seed-life-dashboard-relay)'s state file (`~/Library/Application Support/seed-life-dashboard-relay/state.json`) and writes them to `~/Library/Application Support/co.plow.app/agent-runtime/secrets/` (mode 600) for the bundles to consume.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-agent`

The umbrella [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) installs this SEED + its dependencies (`seed-plow-app`, `seed-life-dashboard-relay`) in one shot.

## Household config (`ld-config`)

On first install the SEED lands a household config at `~/Library/Application Support/co.plow.app/agent-runtime/runtime/ld/config.json` (mode 600). Re-runs preserve operator edits.

You can supply a complete config via the **`LD_CONFIG_SRC`** environment variable, set to:

- a **file path** — `LD_CONFIG_SRC=/path/to/config.json`
- `-` to read from **stdin** — `cat config.json | LD_CONFIG_SRC=- ref/install-bundles.sh`
- an **`https://` URL** — `LD_CONFIG_SRC=https://example.com/config.json`

The supplied bytes are validated as JSON and written atomically. Invalid JSON or a non-200 URL fails loud with a non-zero exit (no partial config is ever written). When `LD_CONFIG_SRC` is unset, the SEED copies the vendored example for you to edit by hand.

### Required vs optional fields

The install/verify gate blocks **only** on the fields the bundles cannot run without:

- **Required** — `family.owner.name`, `family.owner.imessage`, and at least one `calendar.sources` row, where **every** present row has a real (non-empty, non-placeholder) `account` (each source is fetched at runtime, so an empty/placeholder account would be a bogus fetch target).
- **Optional** — partner (`[PARTNER_*]`), additional people (`[FAMILY_PERSON_*]`), extra calendars (`[FAMILY_CALENDAR_ID]`), and long-lead type (`[LONG_LEAD_TYPE]`) may be left as placeholders or empty. `family.timezone` ships a real default.

This lets single-parent / single-calendar households complete an unattended install — only the required fields need real values.

## License

MIT
