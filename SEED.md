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

- Read-only consumed: `~/Library/Application Support/seed-life-dashboard-relay/state.json` (Plan B's `^obj-state`). This SEED does NOT write to it; only reads `endpoint_url` and `dashboard_token` and projects them into `^obj-dashboard-secrets`.

## Actions

### Bundles are installed ^act-install-bundles

- The install action MUST tar+POST each of the five bundles to plowd's `http://127.0.0.1:<port>/marketplace/api/install-local-bundles`. The port is discovered the same way `plow4/justfile`'s `sync-team-skills` does it: `dev-plowd-port` file when present, otherwise `lsof` against the plowd PID (matched by `pgrep` on `/Applications/Plow.app/Contents/Resources/runtime/python/bin/python3 -m uvicorn plowd\.main`).
- The install action MUST authenticate with `plow-local-token` (from `<app_support>/agent-runtime/secrets/plow-local-token`) — NOT `plow-api-token`. `plow-local-token` gates the marketplace mutation routes (`local_auth.py`); `plow-api-token` is the api.plow.co bearer, a different scope.
- The bearer MUST flow through Python stdin, not argv — same shape as `sync-team-skills` (a `curl -H "Authorization: …"` would expose the bearer in `ps` while the upload is live).
- plowd's bundle install endpoint does atomic-swap-with-rollback per bundle and refreshes AGENTS.md; no Plow.app restart required.

### Dashboard secrets are landed ^act-land-secrets

- The install action MUST read `^obj-relay-state` (failing fast if absent — without it the bundles have no endpoint to post to) and atomically write `dashboard-endpoint-url` and `dashboard-token` to `<app_support>/agent-runtime/secrets/` at mode 600 via mktemp+rename. Values pass through `jq` and a tempfile — never echoed, never on argv.

## Verify

1. **Dashboard secrets present.** ^v-secrets Do `<app_support>/agent-runtime/secrets/dashboard-endpoint-url` and `dashboard-token` exist with mode `600` and non-zero size? Expected: yes.
2. **Bundles installed.** ^v-bundles Do all five `SKILL.md` files (or, for `ld-shared`, the `scripts/post_to_kiosk.py` file) exist inside the main agent container's bind-mounted workspace at `<app_support>/containers/<container-UUID>/workspace/skills/ld-*`? Expected: yes.
3. **Endpoint+token are syntactically usable.** ^v-dry-run Does one of the vendored `post_*.py` wrappers invoked with `--dry-run` produce a redacted-body output line (proving the secrets resolve and the wrapper executes)? Expected: yes.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open

- **Bundle drift.** The vendored copies under `ref/team-skills/` diverge from `plow4/team-skills/ld-*` unless a `just vendor-ld-skills` recipe (TBD location) keeps them in lock-step. v1 known issue. ^o-drift
- **plowd port discovery.** Today we replicate `plow4/justfile`'s pattern. A pinned, plowd-published port file would make this SEED's install simpler. ^o-port-discovery
- **Cron auto-registration.** plowd's bundle-install endpoint is expected to auto-register cron entries from each bundle's metadata. If it does not, this SEED's `^act-install-bundles` needs to drive cron registration itself. ^o-cron
- **Vendored vs registry-pulled.** Eventually a Plow marketplace registry serving signed bundles would obsolete vendoring. v1 is vendored; v2 candidate. ^o-vendor-vs-registry

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from Plow.app.
- Not a marketplace registry pull. Vendored copies are the v1 delivery mechanism.
- Not source for the `ld-*` bundles. Source-of-truth lives in `plow4/team-skills/`; this repo holds vendored snapshots.
- Not Plow itself — that's [`seed-plow-app`](https://github.com/plow-pbc/seed-plow-app).
