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

### Requirements

This SEED needs **one** operator-supplied value — the owner's iMessage handle. The display name and calendar account are **derived** (the way `family.timezone` already is), so they cost no question: the installer only has to ask for the handle, which keeps the whole dependency graph within the ≤3-question budget. The one input is `kind: input`, `phase: preflight` (collectible before install); the env-var name lives in `satisfy`. The installer unions all preflight inputs across the dependency tree and asks them ONCE up front — this SEED only DECLARES them, it does not collect them.

| kind | label | phase | satisfy | bypass |
|---|---|---|---|---|
| input | Owner's iMessage handle — an E.164 phone (`+15551234567`) or an email address | preflight | `LD_OWNER_IMESSAGE` | |

**Derived, NOT inputs** (each costs zero questions; set the env var to override the default):

- `family.owner.name` — autodetected from the host's full name (`id -F`, fallback `$USER`); override with `LD_OWNER_NAME`.
- `family.timezone` — autodetected from `readlink /etc/localtime` → IANA, fallback `America/Los_Angeles`.
- `calendar.sources[0].account` — defaults to the owner's iMessage handle when that handle is an email; override with `LD_CALENDAR_ACCOUNT`.

Run the following block to assemble + land the household config, land the secrets, and install the bundles. `LD_OWNER_IMESSAGE` MUST be in the environment when it runs (the installer exports it from the preflight answer; a hand-run sets it inline as shown) — on first install the script assembles `ld-config`, deriving the owner name and calendar account when their override vars are unset, and exits non-zero only if the handle is missing. The block is idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-with-rollback), rewrites the two secret files, and preserves a gate-passing `ld-config`.

```bash
set -euo pipefail
export LD_OWNER_IMESSAGE                       # the one required input (Requirements above)
export LD_OWNER_NAME LD_CALENDAR_ACCOUNT       # optional overrides; derived if unset
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install-bundles.sh"
```

## Objects

### `ld-*` bundles

- The five installed bundle directories `ld-{calendar-nudge,morning-triage,morning-updates,shared,weekly-digest}/`. The host-side install root is plowd-build-dependent: current builds install to `~/Plow/skills/ld-*`; v2 container builds use `<app_support>/containers/<container-UUID>/workspace/skills/ld-*` (or `…/workspace/host/skills/ld-*`). Regardless of host layout, plowd presents them to the agent VM at `/workspace/skills/ld-<name>/`, which is the path the agent reads.

### Dashboard secrets

- Two operator-supplied secret files under `~/Library/Application Support/co.plow.app/agent-runtime/secrets/`:
  - `dashboard-endpoint-url` — the relay's HTTPS URL.
  - `dashboard-token` — the bearer the relay validates.
- Both mode 600, owner-only. plowd bind-mounts `agent-runtime/` into the agent VM at `/config/`, so the bundles read these at `/config/secrets/dashboard-{endpoint-url,token}` — the paths `ld-shared/scripts/post_to_kiosk.py` already hardcodes.

### Relay state

- Read-only consumed: `~/Library/Application Support/seed-life-dashboard-relay/state.json` ([`seed-life-dashboard-relay`](https://github.com/plow-pbc/seed-life-dashboard-relay)'s [state file](https://github.com/plow-pbc/seed-life-dashboard-relay/blob/main/SEED.md#state-file)). This SEED does NOT write to it; only reads `endpoint_url` and `dashboard_token` and projects them into the [dashboard secrets](#dashboard-secrets).

### ld-config

- The household-state file at `<app_support>/agent-runtime/runtime/ld/config.json`, mode 600. Holds the family facts, calendar accounts, and per-skill prefs that every `ld-*` bundle reads at its first invocation. plowd bind-mounts the VM-side path `/config/runtime/ld/config.json` from here.
- On first install, the SEED ASSEMBLES this file from the declared [inputs](#requirements) (the action's prose is in [ld-config is landed](#ld-config-is-landed)). It mirrors the shape of the vendored example (`ref/team-skills/ld-shared/references/config.example.json`) — `family.owner.{name,imessage}`, an autodetected `family.timezone`, one `calendar.sources[0]` (`calendar_id: "primary"`), and real defaults for the `calendar_nudge` lookaheads — with every `[UPPER_SNAKE]` placeholder filled and optional sections (partner, extra calendars, long-lead) omitted. Single-parent / single-calendar is the default; an operator who wants more edits the landed file directly.
- Re-runs preserve an existing config that passes the structural gate — the operator's edits are canonical. The ONE exception: a landed file that still FAILS the gate (e.g. a corrupted edit) is re-assembled from the inputs through the same validation path, so a corrected rerun is not short-circuited by the early "file exists" return.

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

- On first install, the install action ASSEMBLES `<app_support>/agent-runtime/runtime/ld/config.json` (mode 600) from the one declared [input](#requirements) plus the derived values, and lands it via mktemp+rename inside the destination dir. The assembled JSON mirrors the vendored example's shape: `family.owner.{name,imessage}` from the resolved `LD_OWNER_NAME` (autodetected if unset) and `LD_OWNER_IMESSAGE`, one `calendar.sources` entry with `account` from the resolved `LD_CALENDAR_ACCOUNT` (derived from the handle if unset) and `calendar_id: "primary"`, the autodetected `family.timezone`, and the example's real `calendar_nudge` lookahead defaults. The agent MAY express the assembly with a small inline `jq` filter, e.g.:

  ```bash
  jq -n --arg tz "$LD_TIMEZONE" '
    { family: { owner: { name: env.LD_OWNER_NAME, imessage: env.LD_OWNER_IMESSAGE }, timezone: $tz },
      calendar: { sources: [ { account: env.LD_CALENDAR_ACCOUNT, calendar_id: "primary", name: "Personal" } ] } }'
  ```

  but the exact filter is the agent's to adapt to the host — the contract below is what MUST hold, not a specific command.
- **Three values are derived, not asked** — so the only question this SEED contributes to the up-front batch is the iMessage handle. Each is resolved by an inline shell step (not a sourced helper) before the `jq` filter runs:
  - `family.owner.name` — `id -F` (the host's full name), falling back to `id -un` (the username); skipped when `LD_OWNER_NAME` is already set.
  - `family.timezone` — everything after the last `/zoneinfo/` in `readlink /etc/localtime` (e.g. `/usr/share/zoneinfo/America/New_York` → `America/New_York`), fallback `America/Los_Angeles`.
  - `calendar.sources[0].account` — the owner's iMessage handle when it's an email (`*@*`); skipped when `LD_CALENDAR_ACCOUNT` is already set. When the handle is a phone and no override is given, the install fails loud asking for `LD_CALENDAR_ACCOUNT` rather than landing a bad account.
  Name and calendar account are PII (see the next bullet), so they reach `jq` only via the environment; only the non-PII timezone uses `--arg`.
- **PII never leaks.** The operator inputs (owner name/handle, calendar account) are personal-context-secret. They MUST NOT be echoed to stdout, MUST NOT be written anywhere in the SEED tree, and MUST reach `jq` only **through the environment, read inside the filter via jq's `env` builtin — never `--arg`/argv** (which would surface them in `/proc/<pid>/cmdline`). Only the non-PII autodetected `family.timezone` MAY be passed via `--arg`. The assembled config is JSON-validated AND run through the [minimal structural gate](#minimal-structural-gate) BEFORE the atomic `mv`; a blank input or a gate failure FAILS LOUD, non-zero, with nothing landed (a landed-but-bad file would short-circuit every retry).
- Re-runs MUST NOT overwrite an existing config that PASSES the [minimal structural gate](#minimal-structural-gate) — the operator's edits are the canonical state, even if its zone drifted from the current host (a laptop moved, or a hand-set remote zone). The ONE exception: when the existing file FAILS the gate (a first run that landed nothing usable, or a corrupted edit), the action re-assembles from the inputs and atomically replaces it through the same validation path — otherwise the early "file exists" return would silently ignore a corrected rerun.
- After landing (or detecting a gate-passing existing) `ld-config`, the install action MUST gate the bundle POST on the [minimal structural gate](#minimal-structural-gate). If the gate fails, the action MUST exit NON-ZERO with a loud "NOT installed" message (distinct from a successful install) BEFORE the bundle POST, NAMING the failing invariant (never the PII values). The [`ld-config` verify check](#verification) cross-checks the same gate at verify time. Single source of truth for "installed": `ld-config` passes the gate. Install, verify, and the operator instructions all agree on this definition.

### minimal structural gate

- The structural gate is deliberately MINIMAL — rather than mirror `run.js`'s field-by-field runtime requirements (which is the bundles' single source of truth, and whose duplication here only drifts), it checks only the invariants that distinguish a USABLE filled config from an unedited template or a blank-filled one:
  - `family.owner.{name,imessage}` are present and **non-blank** (a whitespace-only value is rejected, not just empty/missing).
  - `calendar.sources` is a **non-empty array**, and each source's `account` is **non-blank**.
  - **No string value is left as a bare `[UPPER_SNAKE]` placeholder** (a real value that merely contains a bracketed token — e.g. a calendar named "Work [TEAM]" — is fine; the match is whole-string anchored).
- The gate lives inline as a few `jq` lines in [`ref/verify.sh`](ref/verify.sh) (the `v-ld-config` check) and the same inline check in the install action. It does NOT re-check the autodetected timezone: a preserved or operator-edited config may legitimately carry a non-host zone, so re-enforcing it would falsely reject a valid config. Per-field runtime requirements (a finite lookahead, every source carrying a real `calendar_id`, at least one non-`self:false` owner source) are enforced at runtime by each bundle — the install gate intentionally does NOT duplicate that list.

## Verification

1. **Dashboard secrets present.** Do `<app_support>/agent-runtime/secrets/dashboard-endpoint-url` and `dashboard-token` exist with mode `600` and non-zero size? Expected: yes.
2. **ld-config present, well-formed, and passes the structural gate.** Does `<app_support>/agent-runtime/runtime/ld/config.json` exist, parse as JSON, AND pass the [minimal structural gate](#minimal-structural-gate) — `family.owner.{name,imessage}` non-blank, `calendar.sources` a non-empty array with non-blank `account`s, and no string value left as a bare `[UPPER_SNAKE]` placeholder? Expected: yes — a gate-passing config is the SEED's single source of truth for "install complete." [ld-config is landed](#ld-config-is-landed) enforces the same gate at install time (refuses to POST bundles otherwise); this verify step is the cross-check that the gate held. The timezone is NOT re-checked here (a preserved config may carry a non-host zone). The values are PII, so only the check name prints, never the contents.
3. **Bundles installed.** Do all five `SKILL.md` files (or, for `ld-shared`, the `scripts/post_to_kiosk.py` file) exist under the installed bundle root — resolved across plowd layouts: `~/Plow/skills/ld-*` (current builds), else `<app_support>/containers/<container-UUID>/workspace/skills/ld-*` or `…/workspace/host/skills/ld-*` (v2 container builds), located by the `ld-shared` marker? Expected: yes.
4. **Endpoint+token are syntactically usable.** Does one of the vendored `post_*.py` wrappers invoked with `--dry-run` produce a redacted-body output line (proving the secrets resolve and the wrapper executes)? Expected: yes.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- **Bundle drift.** The vendored copies under `ref/team-skills/` diverge from `plow4/team-skills/ld-*` unless a `just vendor-ld-skills` recipe (TBD location) keeps them in lock-step. v1 known issue.
- **plowd port discovery.** Today we replicate `plow4/justfile`'s pattern. A pinned, plowd-published port file would make this SEED's install simpler.
- **Cron registration for three of the five bundles.** `ld-calendar-nudge` uses plowd's `scheduled/` auto-activated entrypoint and recurs immediately on install. The other three (`ld-morning-updates`, `ld-morning-triage`, `ld-weekly-digest`) require Plow's **agent-side** `cron action=add` verb to register their daily/weekly recurrences — that's a runtime action only the agent can perform, not a host-side install step this SEED can drive. Operators MUST message Plow after install with "set up the morning-updates / morning-triage / weekly-digest crons" (the agent reads each bundle's `SKILL.md § Scheduling` and runs the right `cron action=add`). The install script surfaces this as a loud post-install note. v2 destination: restructure the three bundles to use plowd's `scheduled/` entrypoint (a plow4-side bundle change, out of scope for this SEED).
- **Vendored vs registry-pulled.** Eventually a Plow marketplace registry serving signed bundles would obsolete vendoring. v1 is vendored; v2 candidate.

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from Plow.app.
- Not a marketplace registry pull. Vendored copies are the v1 delivery mechanism.
- Not source for the `ld-*` bundles. Source-of-truth lives in `plow4/team-skills/`; this repo holds vendored snapshots.
- Not Plow itself — that's [`seed-plow-app`](https://github.com/plow-pbc/seed-plow-app).
