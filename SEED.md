# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

API / per-machine state:

- A Mac running macOS with `Plow.app` installed AND activated. Authored on macOS 26.4.1 / arm64. plowd MUST be running (the install POSTs to its local HTTP API).
- A deployed life-dashboard relay (see `seed-life-dashboard-relay`'s `^obj-state`). This SEED reads the relay's state file to wire the bundles to the right endpoint+token.

Software:

- `https://github.com/plow-pbc/seed-plow-app` — installs Plow.app and activates it. Provides `^v-activated` (the `plow-api-token` post-condition); also lands the `plow-local-token` this SEED uses to authenticate to plowd's marketplace endpoint.
- `https://github.com/plow-pbc/seed-life-dashboard-relay` — deploys the Vercel relay and writes the state file consumed below.
- System tools at `/usr/bin/*`: `curl`, `tar`, `jq`, `lsof`, `pgrep`, `python3`, `awk`. No install needed.

Run the following block to install the bundles + land the secrets. The block is idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-with-rollback) and rewrites the two secret files.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install-bundles.sh"
```

## Objects

### `ld-*` bundles ^obj-bundles

- The five installed bundle directories at `<app_support>/containers/<container-UUID>/workspace/skills/ld-{calendar-nudge,morning-triage,morning-updates,shared,weekly-digest}/`. plowd bind-mounts each container's `workspace/` into the agent VM at `/workspace/`, so the agent reads each bundle at `/workspace/skills/ld-<name>/`.

### Dashboard secrets ^obj-dashboard-secrets

- Two operator-supplied secret files under `~/Library/Application Support/co.plow.app/agent-runtime/secrets/`:
  - `dashboard-endpoint-url` — the relay's HTTPS URL.
  - `dashboard-token` — the bearer the relay validates.
- Both mode 600, owner-only. plowd bind-mounts `agent-runtime/` into the agent VM at `/config/`, so the bundles read these at `/config/secrets/dashboard-{endpoint-url,token}` — the paths `ld-shared/scripts/post_to_kiosk.py` already hardcodes.

### Relay state ^obj-relay-state

- Read-only consumed: `~/Library/Application Support/seed-life-dashboard-relay/state.json` ([`seed-life-dashboard-relay`](https://github.com/plow-pbc/seed-life-dashboard-relay)'s `^obj-state`). This SEED does NOT write to it; only reads `endpoint_url` and `dashboard_token` and projects them into `^obj-dashboard-secrets`.

### ld-config ^obj-ld-config

- The household-state file at `<app_support>/agent-runtime/runtime/ld/config.json`, mode 600. Holds family facts, calendar accounts, per-skill prefs that every `ld-*` bundle reads at its first invocation. plowd bind-mounts the VM-side path `/config/runtime/ld/config.json` from here.
- The SEED copies `ref/team-skills/ld-shared/references/config.example.json` into this path on first install ONLY — subsequent runs preserve operator edits. The example contains placeholder values; the operator MUST edit it with their household's real values before the bundles function correctly. The SEED MUST NOT invent these values (per the seed-convention's secret-redaction rule — household data is personal-context-secret).

## Actions

### Bundles are installed ^act-install-bundles

- The install action MUST tar **all five bundles** in a single archive and POST that archive to plowd's `http://127.0.0.1:<port>/marketplace/api/install-local-bundles` as one transaction — same shape as `plow4/justfile`'s `sync-team-skills`. A single multi-bundle POST keeps plowd's rollback boundary atomic: if any bundle fails to install, none land. Per-bundle POSTs would lose this property (a failure on bundle 3 would leave bundles 1–2 active against potentially-mismatched shared code in `ld-shared`).
- The port is discovered the same way `plow4/justfile`'s `sync-team-skills` does it: `dev-plowd-port` file when present, otherwise `lsof` against the plowd PID (matched by `pgrep` on `/Applications/Plow.app/Contents/Resources/runtime/python/bin/python3 -m uvicorn plowd\.main`).
- The install action MUST authenticate with `plow-local-token` (from `<app_support>/agent-runtime/secrets/plow-local-token`) — NOT `plow-api-token`. `plow-local-token` gates the marketplace mutation routes (`local_auth.py`); `plow-api-token` is the api.plow.co bearer, a different scope.
- The bearer MUST flow through Python stdin, not argv — same shape as `sync-team-skills` (a `curl -H "Authorization: …"` would expose the bearer in `ps` while the upload is live). The Python opener MUST be a `_NoRedirect` shape (same as `ld-shared/scripts/post_to_kiosk.py`'s opener) so an upstream 30x cannot forward the Authorization header to a different target.
- plowd's bundle install endpoint does atomic-swap-with-rollback for the whole multi-bundle archive and refreshes AGENTS.md; no Plow.app restart required.
- **Order matters:** `^act-land-secrets` and `^act-land-ld-config` MUST run BEFORE `^act-install-bundles`. Activating scheduled code in the bundles before the runtime config + credentials they read are present produces a quiet partial install — the bundles run but fail at their first scheduled tick.

### Dashboard secrets are landed ^act-land-secrets

- The install action MUST read `^obj-relay-state` (failing fast if absent — without it the bundles have no endpoint to post to) and atomically write `dashboard-endpoint-url` and `dashboard-token` to `<app_support>/agent-runtime/secrets/` at mode 600 via mktemp+rename. Values pass through `jq` and a tempfile — never echoed, never on argv. The mktemp lives inside `SECRETS_DIR` (not `$TMPDIR`) so the final `mv` is a same-filesystem atomic rename.
- The install action MUST validate `endpoint_url` (HTTPS) and `dashboard_token` (non-empty) BEFORE any plowd mutation. A malformed relay state must fail fast — never land a partial install where bundles run against unknown credentials.

### ld-config is landed ^act-land-ld-config

- The install action MUST copy `ref/team-skills/ld-shared/references/config.example.json` to `<app_support>/agent-runtime/runtime/ld/config.json` at mode 600 on first install ONLY. Re-runs MUST NOT overwrite the file — the operator's edits are the canonical state.
- The example ships with placeholder values for family/timezone/calendar accounts; the SEED MUST surface a loud message to the operator that the file needs editing before the bundles function correctly.

## Verify

1. **Dashboard secrets present.** ^v-secrets Do `<app_support>/agent-runtime/secrets/dashboard-endpoint-url` and `dashboard-token` exist with mode `600` and non-zero size? Expected: yes.
2. **ld-config present + well-formed.** ^v-ld-config Does `<app_support>/agent-runtime/runtime/ld/config.json` exist and parse as JSON? Expected: yes. (We do NOT assert "operator filled in real values" — that's outside the SEED's contract; the bundles will fail loudly on placeholder data when their first scheduled invocation reads the file.)
3. **Bundles installed.** ^v-bundles Do all five `SKILL.md` files (or, for `ld-shared`, the `scripts/post_to_kiosk.py` file) exist inside the main agent container's bind-mounted workspace at `<app_support>/containers/<container-UUID>/workspace/skills/ld-*`? Expected: yes.
4. **Endpoint+token are syntactically usable.** ^v-dry-run Does one of the vendored `post_*.py` wrappers invoked with `--dry-run` produce a redacted-body output line (proving the secrets resolve and the wrapper executes)? Expected: yes.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open

- **Bundle drift.** The vendored copies under `ref/team-skills/` diverge from `plow4/team-skills/ld-*` unless a `just vendor-ld-skills` recipe (TBD location) keeps them in lock-step. v1 known issue. ^o-drift
- **plowd port discovery.** Today we replicate `plow4/justfile`'s pattern. A pinned, plowd-published port file would make this SEED's install simpler. ^o-port-discovery
- **Cron registration for three of the five bundles.** `ld-calendar-nudge` uses plowd's `scheduled/` auto-activated entrypoint and recurs immediately on install. The other three (`ld-morning-updates`, `ld-morning-triage`, `ld-weekly-digest`) require Plow's **agent-side** `cron action=add` verb to register their daily/weekly recurrences — that's a runtime action only the agent can perform, not a host-side install step this SEED can drive. Operators MUST message Plow after install with "set up the morning-updates / morning-triage / weekly-digest crons" (the agent reads each bundle's `SKILL.md § Scheduling` and runs the right `cron action=add`). The install script surfaces this as a loud post-install note. v2 destination: restructure the three bundles to use plowd's `scheduled/` entrypoint (a plow4-side bundle change, out of scope for this SEED). ^o-cron-three-bundles
- **Vendored vs registry-pulled.** Eventually a Plow marketplace registry serving signed bundles would obsolete vendoring. v1 is vendored; v2 candidate. ^o-vendor-vs-registry

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from Plow.app.
- Not a marketplace registry pull. Vendored copies are the v1 delivery mechanism.
- Not source for the `ld-*` bundles. Source-of-truth lives in `plow4/team-skills/`; this repo holds vendored snapshots.
- Not Plow itself — that's [`seed-plow-app`](https://github.com/plow-pbc/seed-plow-app).
