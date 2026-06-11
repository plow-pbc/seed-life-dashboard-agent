# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

API / per-machine state:

- A Mac running macOS with `Plow.app` installed AND activated. Authored on macOS 26.4.1 / arm64. plowd MUST be running (the install POSTs to its local HTTP API).
- The two env inputs `DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` must be set before install (see [Requirements](#requirements)). They point at the household's Pi message API; this SEED does NOT depend on or deploy any relay — the umbrella SEED (`seed-life-dashboard`) derives and exports both values before recursing into this SEED.

Software:

- `https://github.com/plow-pbc/seed-plow-app` — installs Plow.app and activates it. Provides its [activation verify check](https://github.com/plow-pbc/seed-plow-app/blob/main/SEED.md#verify) (the `plow-api-token` post-condition); also lands the `plow-local-token` this SEED uses to authenticate to plowd's marketplace endpoint.
- System tools at `/usr/bin/*`: `curl`, `tar`, `jq`, `lsof`, `pgrep`, `python3`, `awk`. No install needed.

### Requirements

This SEED's five operator-supplied values: two endpoint inputs and three household facts it [assembles `config.json` from](#ld-config). All are `kind: input`, `phase: preflight` (collectible before install); the env-var name lives in `satisfy`. The installer unions all preflight inputs across the dependency tree and asks them ONCE up front — this SEED only DECLARES them, it does not collect them. `family.timezone` is **autodetected** from the host (`readlink /etc/localtime` → IANA, fallback `America/Los_Angeles`) and is therefore NOT an input.

`DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` are normally derived and exported by the umbrella SEED (`seed-life-dashboard`) before recursing into this SEED, so on an umbrella install they are never collected from the operator. On a standalone install (running this SEED directly), they are collected as preflight inputs.

| kind | label | phase | satisfy | bypass |
|---|---|---|---|---|
| input | Full `/api/message` URL of the Pi message API (e.g. `http://rpi5screen:5174/api/message`) | preflight | `DASHBOARD_ENDPOINT_URL` | |
| input | Bearer the Pi message API validates | preflight | `DASHBOARD_TOKEN` | |
| input | Household owner's display name (how the dashboard refers to you) | preflight | `LD_OWNER_NAME` | |
| input | Owner's iMessage handle — an E.164 phone (`+15551234567`) or an email address | preflight | `LD_OWNER_IMESSAGE` | |
| input | Account that owns the primary calendar (e.g. `sam@example.com`) | preflight | `LD_CALENDAR_ACCOUNT` | |

Run the following block to assemble + land the household config, land the secrets, and install the bundles. The three `LD_*` inputs above MUST be in the environment when it runs (the installer exports them from the preflight answers; a hand-run sets them inline as shown) — on first install the script assembles `ld-config` from them and exits non-zero if any is missing. The block is idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-with-rollback), rewrites the two secret files, and preserves a gate-passing `ld-config`.

```bash
set -euo pipefail
export LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT   # set from the Requirements above
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install-bundles.sh"
```

## Objects

### `ld-*` bundles

- This repo is the **source-of-truth** for the six `ld-*` skill bundles — they live under `ref/team-skills/ld-*/` and are authored and fixed here. There is no upstream the copies track; a fix to bundle behavior lands in this repo.
- The six installed bundle directories `ld-{calendar-nudge,morning-triage,morning-updates,shared,weekly-digest,weather}/`. The host-side install root is plowd-build-dependent: current builds install to `~/Plow/skills/ld-*`; v2 container builds use `<app_support>/containers/<container-UUID>/workspace/skills/ld-*` (or `…/workspace/host/skills/ld-*`). Regardless of host layout, plowd presents them to the agent VM at `/workspace/skills/ld-<name>/`, which is the path the agent reads.

### Dashboard secrets

- Two env-derived secret files under `~/Library/Application Support/co.plow.app/agent-runtime/secrets/`:
  - `dashboard-endpoint-url` — the full `/api/message` URL of the Pi message API.
  - `dashboard-token` — the bearer the Pi message API validates.
- Both mode 600, owner-only. plowd bind-mounts `agent-runtime/` into the agent VM at `/config/`, so the bundles read these at `/config/secrets/dashboard-{endpoint-url,token}` — the paths `ld-shared/scripts/post_to_kiosk.py` already hardcodes.

### Endpoint inputs

- `DASHBOARD_ENDPOINT_URL` — the FULL message-API URL (e.g. `http://rpi5screen:5174/api/message`). Written verbatim to `dashboard-endpoint-url` — no `/api/message` append. `http://` is allowed: the Pi endpoint rides the household LAN/tailnet; with a Tailscale hostname the path is encrypted on the wire, and plaintext-LAN otherwise is a documented, accepted trade-off.
- `DASHBOARD_TOKEN` — the bearer the Pi message API validates. Written verbatim to `dashboard-token`.
- Validation (performed BEFORE any plowd mutation): both must be non-blank (rejects whitespace-only), `DASHBOARD_ENDPOINT_URL` must begin with `http://` or `https://` AND end with `/api/message` (fail-fast on old base-URL shape), and both must be single-line (no embedded newlines).

### ld-config

- The household-state file at `<app_support>/agent-runtime/runtime/ld/config.json`, mode 600. Holds the family facts, calendar accounts, and per-skill prefs that every `ld-*` bundle reads at its first invocation. plowd bind-mounts the VM-side path `/config/runtime/ld/config.json` from here.
- On first install, the SEED ASSEMBLES this file from the declared [inputs](#requirements) (the action's prose is in [ld-config is landed](#ld-config-is-landed)). It mirrors the shape of the repo-local example (`ref/team-skills/ld-shared/references/config.example.json`) — `family.owner.{name,imessage}`, an autodetected `family.timezone`, one `calendar.sources[0]` (`calendar_id: "primary"`), and real defaults for the `calendar_nudge` lookaheads — with every `[UPPER_SNAKE]` placeholder filled and optional sections (partner, extra calendars, long-lead) omitted. Single-parent / single-calendar is the default; an operator who wants more edits the landed file directly.
- Re-runs preserve an existing config that passes the structural gate — the operator's edits are canonical. Two narrow exceptions: (1) a landed file that still FAILS the gate (e.g. a corrupted edit) is re-assembled from the inputs through the same validation path, so a corrected rerun is not short-circuited by the early "file exists" return; (2) a gate-passing file that predates `ld-weather` and has no `weather` section gets the Mountain View `weather` defaults appended — never overwriting an existing `weather` block — so the auto-activating weather runner has the `lat`/`lon` it needs instead of fail-looping every tick.

## Actions

### Bundles are installed

- The install action MUST tar **all six bundles** in a single archive and POST that archive to plowd's `http://127.0.0.1:<port>/marketplace/api/install-local-bundles` as one transaction — same shape as `plow4/justfile`'s `sync-team-skills`. A single multi-bundle POST keeps plowd's rollback boundary atomic: if any bundle fails to install, none land. Per-bundle POSTs would lose this property (a failure on bundle 3 would leave bundles 1–2 active against potentially-mismatched shared code in `ld-shared`).
- The port is discovered the same way `plow4/justfile`'s `sync-team-skills` does it: `dev-plowd-port` file when present, otherwise `lsof` against the plowd PID (matched by `pgrep` on `/Applications/Plow.app/Contents/Resources/runtime/python/bin/python3 -m uvicorn plowd\.main`).
- The install action MUST authenticate with `plow-local-token` (from `<app_support>/agent-runtime/secrets/plow-local-token`) — NOT `plow-api-token`. `plow-local-token` gates the marketplace mutation routes (`local_auth.py`); `plow-api-token` is the api.plow.co bearer, a different scope.
- The bearer MUST flow through Python stdin, not argv — same shape as `sync-team-skills` (a `curl -H "Authorization: …"` would expose the bearer in `ps` while the upload is live). The Python opener MUST be a `_NoRedirect` shape (same as `ld-shared/scripts/post_to_kiosk.py`'s opener) so an upstream 30x cannot forward the Authorization header to a different target.
- plowd's bundle install endpoint does atomic-swap-with-rollback for the whole multi-bundle archive and refreshes AGENTS.md; no Plow.app restart required.
- **Order matters:** [dashboard secrets are landed](#dashboard-secrets-are-landed) and [ld-config is landed](#ld-config-is-landed) MUST run BEFORE [bundles are installed](#bundles-are-installed). Activating scheduled code in the bundles before the runtime config + credentials they read are present produces a quiet partial install — the bundles run but fail at their first scheduled tick.

### Dashboard secrets are landed

- The install action MUST read `DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` from the environment (failing fast if either is absent or invalid — without them the bundles have no endpoint to post to) and atomically write `dashboard-endpoint-url` and `dashboard-token` to `<app_support>/agent-runtime/secrets/` at mode 600 via mktemp+rename. Values flow through the environment and a tempfile — never echoed, never on argv. The mktemp lives inside `SECRETS_DIR` (not `$TMPDIR`) so the final `mv` is a same-filesystem atomic rename.
- `DASHBOARD_ENDPOINT_URL` is written VERBATIM — it is already the full `/api/message` URL; no path is appended.
- The install action MUST validate `DASHBOARD_ENDPOINT_URL` (http(s)://, must end with `/api/message`, single-line, non-blank) and `DASHBOARD_TOKEN` (single-line, non-blank — rejects whitespace-only) BEFORE any plowd mutation. A malformed input must fail fast — never land a partial install where bundles run against unknown credentials.

### ld-config is landed

- On first install, the install action ASSEMBLES `<app_support>/agent-runtime/runtime/ld/config.json` (mode 600) from the declared [inputs](#requirements) and lands it via mktemp+rename inside the destination dir. The assembled JSON mirrors the repo-local example's shape: `family.owner.{name,imessage}` from `LD_OWNER_NAME` / `LD_OWNER_IMESSAGE`, one `calendar.sources` entry with `account` from `LD_CALENDAR_ACCOUNT` and `calendar_id: "primary"`, the autodetected `family.timezone`, and the example's real `calendar_nudge` lookahead defaults. The agent MAY express the assembly with a small inline `jq` filter, e.g.:

  ```bash
  jq -n --arg tz "$LD_TIMEZONE" '
    { family: { owner: { name: env.LD_OWNER_NAME, imessage: env.LD_OWNER_IMESSAGE }, timezone: $tz },
      calendar: { sources: [ { account: env.LD_CALENDAR_ACCOUNT, calendar_id: "primary", name: "Personal" } ] } }'
  ```

  but the exact filter is the agent's to adapt to the host — the contract below is what MUST hold, not a specific command.
- **family.timezone is autodetected, not an input.** The IANA zone is everything after the last `/zoneinfo/` in `readlink /etc/localtime` (e.g. `/usr/share/zoneinfo/America/New_York` → `America/New_York`), falling back to `America/Los_Angeles` when detection yields nothing — so a non-Pacific household gets the right local time without a 4th question. This is one inline `readlink` + parse, not a sourced helper.
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

1. **Dashboard secrets present and well-shaped.** Do `<app_support>/agent-runtime/secrets/dashboard-endpoint-url` and `dashboard-token` exist with mode `600` and non-zero size — AND are both files entirely whitespace-free — the endpoint matching `http(s)://…/api/message`, the token a bare RFC 6750 bearer (no trailing newline either: the installer writes verbatim; the same predicates it enforces before any plowd mutation; checked without printing either value)? Expected: yes.
2. **ld-config present, well-formed, and passes the structural gate.** Does `<app_support>/agent-runtime/runtime/ld/config.json` exist, parse as JSON, AND pass the [minimal structural gate](#minimal-structural-gate) — `family.owner.{name,imessage}` non-blank, `calendar.sources` a non-empty array with non-blank `account`s, and no string value left as a bare `[UPPER_SNAKE]` placeholder? Expected: yes — a gate-passing config is the SEED's single source of truth for "install complete." [ld-config is landed](#ld-config-is-landed) enforces the same gate at install time (refuses to POST bundles otherwise); this verify step is the cross-check that the gate held. The timezone is NOT re-checked here (a preserved config may carry a non-host zone). The values are PII, so only the check name prints, never the contents.
3. **Bundles installed.** Do all six `SKILL.md` files (or, for `ld-shared`, the `scripts/post_to_kiosk.py` file) exist under the installed bundle root — resolved across plowd layouts: `~/Plow/skills/ld-*` (current builds), else `<app_support>/containers/<container-UUID>/workspace/skills/ld-*` or `…/workspace/host/skills/ld-*` (v2 container builds), located by the `ld-shared` marker? Expected: yes.
4. **Endpoint+token are syntactically usable.** Does one of the bundled `post_*.py` wrappers invoked with `--dry-run` produce a redacted-body output line (proving the secrets resolve and the wrapper executes)? Expected: yes.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- **plowd port discovery.** Today we replicate `plow4/justfile`'s pattern. A pinned, plowd-published port file would make this SEED's install simpler.
- **Cron registration for three of the six bundles.** `ld-calendar-nudge` and `ld-weather` use plowd's `scheduled/` auto-activated entrypoint and recur immediately on install. The other three (`ld-morning-updates`, `ld-morning-triage`, `ld-weekly-digest`) require Plow's **agent-side** `cron action=add` verb to register their daily/weekly recurrences — that's a runtime action only the agent can perform, not a host-side install step this SEED can drive. Operators MUST message Plow after install with "set up the morning-updates / morning-triage / weekly-digest crons" (the agent reads each bundle's `SKILL.md § Scheduling` and runs the right `cron action=add`). The install script surfaces this as a loud post-install note. v2 destination: restructure the three bundles to use plowd's `scheduled/` entrypoint (a bundle change in this repo, deferred — not part of the install contract).
- **Bundled vs registry-pulled.** The bundles' source lives in this repo; v1 ships them by bundling the copies into the install archive. Eventually a Plow marketplace registry serving signed bundles would replace the bundle-into-archive step (the source would still live here, just be published to the registry rather than POSTed directly). v2 candidate.

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from Plow.app.
- Not a marketplace registry pull. Bundling the `ld-*` copies into the install archive is the v1 delivery mechanism.
- Not Plow itself — that's [`seed-plow-app`](https://github.com/plow-pbc/seed-plow-app).
