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

The supplied bytes are validated as JSON, run through the minimal install gate, and written atomically. Invalid JSON or a config that fails the gate fails loud with a non-zero exit (no partial config is ever written). When `LD_CONFIG_SRC` is unset, the SEED copies the vendored example for you to edit by hand.

### The install gate

The install/verify gate is deliberately **minimal**. It checks two structural invariants that distinguish an unedited template from a filled config:

- **`calendar.sources` is a non-empty array** — the bundles iterate it at runtime, so an object-valued or empty sources is unusable.
- **No string value is left as a bare `[UPPER_SNAKE]` placeholder** (a real value that merely contains a bracketed token, e.g. a calendar named "Work [TEAM]", is fine) — the vendored example ships placeholders **only** for the fields the operator must provide (owner identity — `[OWNER_NAME]`, `[OWNER_IMESSAGE]` — and at least one calendar `[CALENDAR_ACCOUNT]`), with real defaults for `family.timezone` and the `calendar_nudge` lookaheads and empty/omitted optional sections (partner, additional people, extra calendars, long-lead). So "no bare placeholder left" is exactly "every required field was filled" — and single-parent / single-calendar households pass without editing optional fields.

Per-field requirements (a finite lookahead, a non-`self:false` owner source, every source carrying a real `account`/`calendar_id`) are **enforced at runtime by each bundle**, which is the single source of truth for them — the install gate intentionally does not duplicate that list.

## License

MIT
