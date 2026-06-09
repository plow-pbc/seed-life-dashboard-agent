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

This SEED's three operator-supplied values — the household facts it [assembles `config.json` from](#ld-config). All are `kind: input`, `phase: preflight` (collectible before install); the env-var name lives in `satisfy`. The installer unions all preflight inputs across the dependency tree and asks them ONCE up front — this SEED only DECLARES them, it does not collect them. `family.timezone` is **autodetected** from the host (`readlink /etc/localtime` → IANA, fallback `America/Los_Angeles`) and is therefore NOT an input.

| kind | label | phase | satisfy | bypass |
|---|---|---|---|---|
| input | Household owner's display name (how the dashboard refers to you) | preflight | `LD_OWNER_NAME` | |
| input | Owner's iMessage handle — an E.164 phone (`+15551234567`) or an email address | preflight | `LD_OWNER_IMESSAGE` | |
| input | Account that owns the primary calendar (e.g. `sam@example.com`) | preflight | `LD_CALENDAR_ACCOUNT` | |

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
- On first install ONLY (subsequent runs preserve a gate-PASSING operator-edited file), the SEED populates this file by exactly one of three paths, in priority order:
  - **assembled from the declared [inputs](#requirements)** (the default) — when `LD_OWNER_NAME` / `LD_OWNER_IMESSAGE` / `LD_CALENDAR_ACCOUNT` are present in the env (the installer collects + exports them; see [Requirements](#requirements)), the SEED ASSEMBLES a complete household config from them: `family.owner.{name,imessage}`, one `calendar.sources[0]` with `account` from `LD_CALENDAR_ACCOUNT` (`calendar_id: "primary"`), `family.timezone` **autodetected** (see below), real defaults for the `calendar_nudge` lookaheads, and optional sections (partner, extra calendars, long-lead) empty/omitted — mirroring the vendored example's shape with every `[UPPER_SNAKE]` placeholder filled. Assembly uses `jq` with the PII values (owner name/handle, calendar account) fed as **data over stdin** — never `--arg` argv (which would surface them in `/proc/<pid>/cmdline`); only the non-PII autodetected timezone is passed via `--arg`. The result is run through the minimal gate BEFORE the atomic write (tempfile + `mv`, mode 600), so a blank/incomplete input fails loud, non-zero, with nothing landed. Single-parent / single-calendar is the default.
  - **`LD_CONFIG_SRC=-`** (escape hatch) — a complete household config supplied via stdin, for a caller that has already assembled a full `config.json`. The supplied bytes are validated as well-formed JSON, run through the minimal gate, and written atomically (mode 600). Invalid JSON or a config that fails the gate FAILS LOUD with a non-zero exit — the SEED never lands a partial config. Any non-`-` value is rejected loud, non-zero.
  - **the vendored example** (`ref/team-skills/ld-shared/references/config.example.json`) — when neither the inputs nor `LD_CONFIG_SRC` are set. The example contains `[UPPER_SNAKE]` placeholders the operator MUST replace by hand. The SEED MUST NOT invent these values (per the seed-convention's secret-redaction rule — household data is personal-context-secret).
- **family.timezone is autodetected, not an input.** The IANA zone is everything after the last `/zoneinfo/` in `readlink /etc/localtime` (e.g. `/usr/share/zoneinfo/America/New_York` → `America/New_York`), falling back to `America/Los_Angeles` if detection yields nothing — so a non-Pacific household gets the right local time without a 4th question. The single detection rule lives in [`ref/lib/detect-timezone.sh`](ref/lib/detect-timezone.sh), sourced by BOTH assembly (which writes it) and the gate (which asserts the landed config carries the SAME zone) — so a tz-autodetect regression can't ship a wrong zone that the gate still passes.
- **The minimal install gate.** The install/verify gate is deliberately minimal — rather than mirror `run.js`'s field-by-field requirements (a list that drifted from the runtime contract across multiple review rounds), it checks only the invariants that distinguish a USABLE filled config from an unedited template or a blank-filled one:
  - `calendar.sources` is a **non-empty array** (`run.js` requires `Array.isArray` + `length>=1`; an object-valued or empty sources is unusable), and each source's `account` is **non-blank**.
  - `family.owner.{name,imessage}` are present and **non-blank** (a whitespace-only value is rejected, not just empty/missing).
  - `family.timezone` equals the host-autodetected zone (the gate is passed the detected zone by install/verify; a tz regression can't ship a wrong local time and still pass).
  - **No string value is left as a bare `[UPPER_SNAKE]` placeholder** (a real value that merely contains a bracketed token, e.g. a calendar named "Work [TEAM]", is fine — the match is whole-string anchored). The example ships placeholders ONLY for the fields the operator MUST provide (owner identity — `[OWNER_NAME]`, `[OWNER_IMESSAGE]` — and at least one calendar `[CALENDAR_ACCOUNT]`), so for a hand-edited example "no bare placeholder left" is exactly "every required field was filled."
  - Per-field runtime requirements (a finite lookahead, every source carrying a real `calendar_id`, at least one non-`self:false` owner source) are **enforced at runtime by each bundle** — the single source of truth for them. The install gate intentionally does NOT duplicate that list; this is the structural fix for the gate-vs-runtime drift the earlier mirrored field-list kept reintroducing.

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

- On first install (re-runs MUST NOT overwrite a gate-PASSING file — the operator's edits are canonical), the install action lands `<app_support>/agent-runtime/runtime/ld/config.json` at mode 600 by the three-way resolution in [ld-config](#ld-config): **assemble from the declared [inputs](#requirements)** (the default, when `LD_OWNER_NAME` / `LD_OWNER_IMESSAGE` / `LD_CALENDAR_ACCOUNT` are present), else **consume a supplied config from `LD_CONFIG_SRC=-`** (escape hatch), else **copy the vendored example** for manual editing. The ONE exception to re-run preservation: when the existing landed config still FAILS the minimal gate (e.g. a first run with no inputs landed the placeholder example, or a manually-corrupted file) AND a supply source (inputs or `LD_CONFIG_SRC`) is now present, the install action assembles/consumes the new config and atomically replaces the bad file through the same validation path — otherwise the early "file exists" return would short-circuit a corrected rerun and silently ignore it. The freshly-assembled config is authoritative on a corrected single-shot rerun (new owner / calendar account / host timezone).
- The config is built with `jq`, the PII values (owner name/handle, calendar account) fed as **data over stdin** (never `--arg` argv, which would surface them in `/proc/<pid>/cmdline`) and only the non-PII autodetected `family.timezone` passed via `--arg`. When `LD_CONFIG_SRC` is set it MUST be `-` (read from stdin); any non-`-` value MUST be rejected loud, non-zero. The assembled-or-supplied config is JSON-validated AND run through the minimal gate BEFORE the atomic `mv` — a malformed or incomplete config MUST NOT land (a landed-but-bad file would short-circuit every retry), so the action FAILS LOUD with a NON-ZERO exit and never a partial write.
- After landing (or detecting an existing) `ld-config`, the install action MUST gate the bundle POST on the minimal gate (`calendar.sources` a non-empty array with non-blank `account`s, `family.owner.{name,imessage}` non-blank, `family.timezone` equal to the host-autodetected zone, and no bare `[UPPER_SNAKE]` placeholder remaining). If the gate fails, the install action MUST exit NON-ZERO with a loud "NOT installed" message (distinct from a successful install) BEFORE the bundle POST. The check NAMES the failing invariant (never the PII values). The [`ld-config` verify check](#verify) cross-checks the same minimal gate at verify time. Per-field requirements are enforced at runtime by each bundle, not here.
- Single source of truth for "installed": `ld-config` passes the minimal gate above. Install, verify, and the operator instructions all agree on this definition.
- PII handling: the operator inputs (owner name/handle, calendar account) and the assembled config MUST NOT be echoed to stdout, MUST NOT be written anywhere in the SEED tree, and reach `jq` only as stdin data. The assembly tempfile lives under the destination dir, is mode 600, and is the only on-disk landing.

## Verify

1. **Dashboard secrets present.** Do `<app_support>/agent-runtime/secrets/dashboard-endpoint-url` and `dashboard-token` exist with mode `600` and non-zero size? Expected: yes.
2. **ld-config present, well-formed, and passes the minimal gate.** Does `<app_support>/agent-runtime/runtime/ld/config.json` exist, parse as JSON, AND pass the minimal gate — `calendar.sources` a non-empty array with non-blank `account`s, `family.owner.{name,imessage}` non-blank, `family.timezone` equal to the host-autodetected zone (the same `ref/lib/detect-timezone.sh` rule assembly used), and no string value left as a bare `[UPPER_SNAKE]` placeholder (a real value that merely contains a bracketed token being fine)? Expected: yes — a gate-passing config is the SEED's single source of truth for "install complete." [ld-config is landed](#ld-config-is-landed) enforces the same minimal gate at install time (refuses to POST bundles otherwise); this verify step is the cross-check that the gate held, and the shared detection helper means a tz regression can't ship a wrong local time and still pass. Per-field requirements are enforced at runtime by each bundle. The values are PII so only the check name prints, never the contents.
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
