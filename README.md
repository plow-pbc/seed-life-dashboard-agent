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

On first install the SEED lands a household config at `~/Library/Application Support/co.plow.app/agent-runtime/runtime/ld/config.json` (mode 600). Re-runs preserve a gate-passing operator-edited file.

The SEED **assembles** this config from three operator inputs it declares as `kind: input` requirements (the installer collects them once up front and exports them; see SEED.md `### Requirements`):

- `LD_OWNER_NAME` — household owner's display name.
- `LD_OWNER_IMESSAGE` — owner's iMessage handle (E.164 phone `+15551234567`, or an email).
- `LD_CALENDAR_ACCOUNT` — account that owns the primary calendar.

`family.timezone` is **autodetected** from the host (`readlink /etc/localtime` → IANA zone, fallback `America/Los_Angeles`), so a non-Pacific household gets the right local time without a fourth question. Assembly uses `jq` with the PII values fed in as stdin data (never argv); the assembled config is gate-checked before the atomic write — a blank/incomplete input fails loud, non-zero, with nothing landed.

Two other supply paths: when the inputs are unset, `LD_CONFIG_SRC=-` consumes a complete config from stdin (`cat config.json | LD_CONFIG_SRC=- ref/install-bundles.sh`) — an escape hatch for a caller that has already assembled a full config; any non-`-` value is rejected loud. With neither set, the SEED copies the vendored example for you to edit by hand.

### The install gate

The install/verify gate is deliberately **minimal**. It checks the invariants that distinguish a usable filled config from an unedited template or a blank-filled one:

- **`calendar.sources` is a non-empty array** with each source's **`account` non-blank** — the bundles iterate it at runtime, so an object-valued, empty, or blank-account sources is unusable.
- **`family.owner.{name,imessage}` are non-blank** (a whitespace-only value is rejected, not just empty/missing).
- **`family.timezone` equals the host-autodetected zone** — checked ONLY when the SEED assembles the config (the regression guard on a config the SEED built), using the single detection rule in `ref/lib/detect-timezone.sh`. The post-install gate and verify check structural invariants only, so a preserved operator-edited or `LD_CONFIG_SRC=-`-supplied config may carry an intentionally non-host zone (after a kiosk move, or for a remote household) without being falsely rejected.
- **No string value is left as a bare `[UPPER_SNAKE]` placeholder** (a real value that merely contains a bracketed token, e.g. a calendar named "Work [TEAM]", is fine) — the vendored example ships placeholders **only** for the fields the operator must provide (owner identity — `[OWNER_NAME]`, `[OWNER_IMESSAGE]` — and at least one calendar `[CALENDAR_ACCOUNT]`), so for a hand-edited example "no bare placeholder left" is exactly "every required field was filled."

Per-field requirements (a finite lookahead, a non-`self:false` owner source, every source carrying a real `calendar_id`) are **enforced at runtime by each bundle**, which is the single source of truth for them — the install gate intentionally does not duplicate that list.

## License

MIT
