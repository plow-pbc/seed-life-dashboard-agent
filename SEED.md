# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

API / per-machine state:

- A Mac running macOS with `Plow.app` installed AND activated. Authored on macOS 26.4.1 / arm64. plowd MUST be running (the install POSTs to its local HTTP API).
- A deployed life-dashboard relay (see `seed-life-dashboard-relay`'s [state file](https://github.com/plow-pbc/seed-life-dashboard-relay/blob/main/SEED.md#state-file)). This SEED reads the relay's state file to wire the bundles to the right endpoint+token.

Software:

- `https://github.com/plow-pbc/seed-plow-app` — installs Plow.app and activates it. Provides its [activation verify check](https://github.com/plow-pbc/seed-plow-app/blob/main/SEED.md#verify) (the `plow-api-token` post-condition); also lands the `plow-local-token` this SEED uses to authenticate to plowd's marketplace endpoint.
- `https://github.com/plow-pbc/seed-life-dashboard-relay` — deploys the Vercel relay and writes the state file consumed below.
- System tools at `/usr/bin/*`: `curl`, `tar`, `jq`, `lsof`, `pgrep`, `python3`, `awk`. No install needed.

Run the following block to install the bundles + land the secrets. The block is idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-with-rollback) and rewrites the two secret files.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install-bundles.sh"
```

## Objects

### `ld-*` bundles

- The five installed bundle directories at `<app_support>/containers/<container-UUID>/workspace/skills/ld-{calendar-nudge,morning-triage,morning-updates,shared,weekly-digest}/`. plowd bind-mounts each container's `workspace/` into the agent VM at `/workspace/`, so the agent reads each bundle at `/workspace/skills/ld-<name>/`.

### Dashboard secrets

- Two operator-supplied secret files under `~/Library/Application Support/co.plow.app/agent-runtime/secrets/`:
  - `dashboard-endpoint-url` — the relay's HTTPS URL.
  - `dashboard-token` — the bearer the relay validates.
- Both mode 600, owner-only. plowd bind-mounts `agent-runtime/` into the agent VM at `/config/`, so the bundles read these at `/config/secrets/dashboard-{endpoint-url,token}` — the paths `ld-shared/scripts/post_to_kiosk.py` already hardcodes.

### Relay state

- Read-only consumed: `~/Library/Application Support/seed-life-dashboard-relay/state.json` ([`seed-life-dashboard-relay`](https://github.com/plow-pbc/seed-life-dashboard-relay)'s [state file](https://github.com/plow-pbc/seed-life-dashboard-relay/blob/main/SEED.md#state-file)). This SEED does NOT write to it; only reads `endpoint_url` and `dashboard_token` and projects them into the [dashboard secrets](#dashboard-secrets).

### ld-config

- The household-state file at `<app_support>/agent-runtime/runtime/ld/config.json`, mode 600. Holds family facts, calendar accounts, per-skill prefs that every `ld-*` bundle reads at its first invocation. plowd bind-mounts the VM-side path `/config/runtime/ld/config.json` from here.
- On first install ONLY (subsequent runs preserve operator edits), the SEED lands this file from one of two sources:
  - **`LD_CONFIG_SRC`** (when set) — a complete household config supplied as a **file path** or `-` (read from **stdin**). The supplied bytes are validated as well-formed JSON, run through the required-field gate, and written atomically (tempfile + `mv`, mode 600). Invalid JSON or an incomplete config FAILS LOUD with a non-zero exit — the SEED never lands a partial config and never silently no-ops.
  - **the vendored example** (`ref/team-skills/ld-shared/references/config.example.json`) — when `LD_CONFIG_SRC` is unset. The example contains `[UPPER_SNAKE]` placeholders the operator MUST replace. The SEED MUST NOT invent these values (per the seed-convention's secret-redaction rule — household data is personal-context-secret).
- **Required vs optional fields.** The install/verify gate blocks on EXACTLY the fields the scheduled bundles throw-on-missing at their first tick (derived from `ld-calendar-nudge/scheduled/run.js`) — no more (single-parent/single-calendar homes still pass), no less (no install passes the gate then dies on the first tick):
  - `family.owner.name`, `family.owner.imessage`; `family.timezone` (run.js:135); `calendar.sources` with at least ONE row (run.js:146) where EVERY present row has a real `account` AND `calendar_id` (run.js:150 — non-empty, not an `[UPPER_SNAKE]` placeholder; every source is fetched at the first tick, so an empty/placeholder value is a bogus fetch target); and `calendar_nudge.lookahead_virtual_minutes` + `calendar_nudge.lookahead_in_person_minutes` as finite numbers (run.js:157).
  - OPTIONAL (never block; may stay empty/placeholder): `[PARTNER_*]`, `[FAMILY_PERSON_*]`, extra calendars beyond the first source's id, `[LONG_LEAD_TYPE]`, and the `morning_*`/`weekly_digest` blocks the skeleton bundles don't yet read. `family.timezone` and the lookaheads ship real defaults in the vendored example, so a hand-edited install satisfies them for free. This lets single-parent / single-calendar households complete an unattended install.

## Actions

### Bundles are installed

- The install action MUST tar **all five bundles** in a single archive and POST that archive to plowd's `http://127.0.0.1:<port>/marketplace/api/install-local-bundles` as one transaction — same shape as `plow4/justfile`'s `sync-team-skills`. A single multi-bundle POST keeps plowd's rollback boundary atomic: if any bundle fails to install, none land. Per-bundle POSTs would lose this property (a failure on bundle 3 would leave bundles 1–2 active against potentially-mismatched shared code in `ld-shared`).
- The port is discovered the same way `plow4/justfile`'s `sync-team-skills` does it: `dev-plowd-port` file when present, otherwise `lsof` against the plowd PID (matched by `pgrep` on `/Applications/Plow.app/Contents/Resources/runtime/python/bin/python3 -m uvicorn plowd\.main`).
- The install action MUST authenticate with `plow-local-token` (from `<app_support>/agent-runtime/secrets/plow-local-token`) — NOT `plow-api-token`. `plow-local-token` gates the marketplace mutation routes (`local_auth.py`); `plow-api-token` is the api.plow.co bearer, a different scope.
- The bearer MUST flow through Python stdin, not argv — same shape as `sync-team-skills` (a `curl -H "Authorization: …"` would expose the bearer in `ps` while the upload is live). The Python opener MUST be a `_NoRedirect` shape (same as `ld-shared/scripts/post_to_kiosk.py`'s opener) so an upstream 30x cannot forward the Authorization header to a different target.
- plowd's bundle install endpoint does atomic-swap-with-rollback for the whole multi-bundle archive and refreshes AGENTS.md; no Plow.app restart required.
- **Order matters:** [dashboard secrets are landed](#dashboard-secrets-are-landed) and [ld-config is landed](#ld-config-is-landed) MUST run BEFORE [bundles are installed](#bundles-are-installed). Activating scheduled code in the bundles before the runtime config + credentials they read are present produces a quiet partial install — the bundles run but fail at their first scheduled tick.

### Dashboard secrets are landed

- The install action MUST read the [relay state](#relay-state) (failing fast if absent — without it the bundles have no endpoint to post to) and atomically write `dashboard-endpoint-url` and `dashboard-token` to `<app_support>/agent-runtime/secrets/` at mode 600 via mktemp+rename. Values pass through `jq` and a tempfile — never echoed, never on argv. The mktemp lives inside `SECRETS_DIR` (not `$TMPDIR`) so the final `mv` is a same-filesystem atomic rename.
- The install action MUST validate `endpoint_url` (HTTPS) and `dashboard_token` (non-empty) BEFORE any plowd mutation. A malformed relay state must fail fast — never land a partial install where bundles run against unknown credentials.

### ld-config is landed

- On first install ONLY (re-runs MUST NOT overwrite the file — the operator's edits are canonical), the install action lands `<app_support>/agent-runtime/runtime/ld/config.json` at mode 600 from `LD_CONFIG_SRC` when set, otherwise from `ref/team-skills/ld-shared/references/config.example.json`.
- When `LD_CONFIG_SRC` is set, the install action MUST read the source (file path / `-` for stdin), validate the bytes parse as JSON, and write atomically (tempfile + `mv`, mode 600). On invalid JSON the install action MUST FAIL LOUD with a NON-ZERO exit — never a partial write, never a silent no-op.
- The supplied-config path (when `LD_CONFIG_SRC` is set) MUST run this required-field gate against the supplied bytes BEFORE the atomic `mv` — a valid-JSON-but-incomplete supplied config MUST NOT land, or a re-run would short-circuit on the bad file and silently ignore a corrected `LD_CONFIG_SRC` retry. The vendored-example path still lands placeholders for manual editing.
- After landing (or detecting an existing) `ld-config`, the install action MUST gate the bundle POST on the EXACT required set the scheduled bundles throw-on-missing: `family.owner.name`, `family.owner.imessage`, `family.timezone`, `calendar.sources` with at least one row where every present row carries a real (non-empty, non-placeholder) `account` AND `calendar_id`, and `calendar_nudge.lookahead_virtual_minutes` + `calendar_nudge.lookahead_in_person_minutes` (finite numbers). If any REQUIRED field is unfilled (placeholder, empty, or — for the lookaheads — non-numeric), the install action MUST exit NON-ZERO with a loud "missing required values / NOT installed" message (distinct from a successful install) BEFORE the bundle POST. OPTIONAL fields (`[PARTNER_*]`, `[FAMILY_PERSON_*]`, extra calendars, `[LONG_LEAD_TYPE]`) MUST NOT block. The [`ld-config` verify check](#verify) cross-checks the same required-only gate at verify time. Field NAMES (never the PII values) appear in the message.
- Single source of truth for "installed": `ld-config` has no REQUIRED-field placeholders. Install, verify, and the operator instructions all agree on this definition.

## Verify

1. **Dashboard secrets present.** Do `<app_support>/agent-runtime/secrets/dashboard-endpoint-url` and `dashboard-token` exist with mode `600` and non-zero size? Expected: yes.
2. **ld-config present, well-formed, and required fields resolved.** Does `<app_support>/agent-runtime/runtime/ld/config.json` exist, parse as JSON, AND have its REQUIRED fields filled (`family.owner.name`, `family.owner.imessage`, `family.timezone`, `calendar.sources` with at least one row where every present row has a real `account` AND `calendar_id` — none empty or still an `[UPPER_SNAKE]` placeholder — and `calendar_nudge.lookahead_virtual_minutes` + `calendar_nudge.lookahead_in_person_minutes` as finite numbers)? Optional fields (partner, additional people, extra calendars, long-lead type) may remain placeholders. Expected: yes — resolved required fields are the SEED's single source of truth for "install complete." [ld-config is landed](#ld-config-is-landed) enforces the same required-only gate at install time (refuses to POST bundles while a required placeholder remains); this verify step is the cross-check that the gate held.
3. **Bundles installed.** Do all five `SKILL.md` files (or, for `ld-shared`, the `scripts/post_to_kiosk.py` file) exist inside the main agent container's bind-mounted workspace at `<app_support>/containers/<container-UUID>/workspace/skills/ld-*`? Expected: yes.
4. **Endpoint+token are syntactically usable.** Does one of the vendored `post_*.py` wrappers invoked with `--dry-run` produce a redacted-body output line (proving the secrets resolve and the wrapper executes)? Expected: yes.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open

- **Bundle drift.** The vendored copies under `ref/team-skills/` diverge from `plow4/team-skills/ld-*` unless a `just vendor-ld-skills` recipe (TBD location) keeps them in lock-step. v1 known issue.
- **plowd port discovery.** Today we replicate `plow4/justfile`'s pattern. A pinned, plowd-published port file would make this SEED's install simpler.
- **Cron registration for three of the five bundles.** `ld-calendar-nudge` uses plowd's `scheduled/` auto-activated entrypoint and recurs immediately on install. The other three (`ld-morning-updates`, `ld-morning-triage`, `ld-weekly-digest`) require Plow's **agent-side** `cron action=add` verb to register their daily/weekly recurrences — that's a runtime action only the agent can perform, not a host-side install step this SEED can drive. Operators MUST message Plow after install with "set up the morning-updates / morning-triage / weekly-digest crons" (the agent reads each bundle's `SKILL.md § Scheduling` and runs the right `cron action=add`). The install script surfaces this as a loud post-install note. v2 destination: restructure the three bundles to use plowd's `scheduled/` entrypoint (a plow4-side bundle change, out of scope for this SEED).
- **Vendored vs registry-pulled.** Eventually a Plow marketplace registry serving signed bundles would obsolete vendoring. v1 is vendored; v2 candidate.

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from Plow.app.
- Not a marketplace registry pull. Vendored copies are the v1 delivery mechanism.
- Not source for the `ld-*` bundles. Source-of-truth lives in `plow4/team-skills/`; this repo holds vendored snapshots.
- Not Plow itself — that's [`seed-plow-app`](https://github.com/plow-pbc/seed-plow-app).
