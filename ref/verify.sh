#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-life-dashboard-agent.

set -euo pipefail

PLOW_BUNDLE_ID="${PLOW_BUNDLE_ID:-co.plow.app}"
APP_SUPPORT="$HOME/Library/Application Support/$PLOW_BUNDLE_ID"
SECRETS_DIR="$APP_SUPPORT/agent-runtime/secrets"
CONTAINERS_DIR="$APP_SUPPORT/containers"
LD_CONFIG="$APP_SUPPORT/agent-runtime/runtime/ld/config.json"
SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# v1: dashboard-endpoint-url and dashboard-token present, mode 600, non-empty.
for s in dashboard-endpoint-url dashboard-token; do
  f="$SECRETS_DIR/$s"
  [ -s "$f" ] || { echo "FAIL v-secrets: $f missing or empty" >&2; exit 1; }
  [ "$(stat -f '%Lp' "$f")" = "600" ] \
    || { echo "FAIL v-secrets: $f not mode 600" >&2; exit 1; }
done
echo "OK   v-secrets"

# v-endpoint-shape / v-token-shape: the secret files are whitespace-FREE by
# contract (SEED.md; the installer rejects the same bytes before mutation, and
# writes verbatim with no trailing newline). Verify certifies that written
# contract — no edge-trim leniency — and never prints either value. The check
# is BYTE-level (grep is line-oriented and cannot see \n, the most likely
# corruption): whitespace-free ⇔ raw size equals the [:space:]-stripped size.
# v-secrets above already guarantees both files are non-empty.
ws_free() { [ "$(wc -c < "$1")" -eq "$(tr -d '[:space:]' < "$1" | wc -c)" ]; }
_ep_file="$SECRETS_DIR/dashboard-endpoint-url"
if ! ws_free "$_ep_file" \
  || ! grep -qE '^https?://[^[:space:]]+/api/message$' "$_ep_file"; then
  echo "FAIL v-endpoint-shape: dashboard-endpoint-url must be a whitespace-free http(s)://…/api/message URL" >&2
  exit 1
fi
unset _ep_file
echo "OK   v-endpoint-shape"

if ! ws_free "$SECRETS_DIR/dashboard-token"; then
  echo "FAIL v-token-shape: dashboard-token must be whitespace-free (RFC 6750 bearer)" >&2
  exit 1
fi
echo "OK   v-token-shape"

# v1b: ld-config present + parses as JSON + passes the minimal
# structural gate. This delegates to the EXACT SAME gate install-bundles.sh
# enforces pre-mutation: the universal core is the shared ld-shared gate
# (plow-pbc/life-dashboard-skills :: scripts/ld_config_gate.py, materialized
# under ref/team-skills/ld-shared/ by sync-ld-shared.sh), plus the one Plow-
# specific local check (family.owner.imessage non-blank). Routing both
# install and verify through the same shared gate + same local check means
# they can never drift on the contract. The gate is deliberately MINIMAL
# — it does NOT mirror run.js's per-field runtime requirements (those
# are the bundles' single source of truth) — it asserts only the
# invariants that separate a USABLE filled config from an unedited
# template or a blank-filled one:
#   - family.owner.name present and non-blank        (shared core)
#   - calendar.sources a non-empty array, each source's account non-blank (shared core)
#   - no string value left as a bare [UPPER_SNAKE] placeholder (shared core)
#   - family.owner.imessage present and non-blank     (Plow-specific local check)
# The autodetected timezone is NOT re-checked: a preserved / operator-
# edited config may legitimately carry a non-host zone (laptop moved,
# remote household), so enforcing it here would falsely reject a valid
# config. PII never prints — only the failing invariant's name.
LD_SHARED_GATE="$SEED_ROOT/ref/team-skills/ld-shared/scripts/ld_config_gate.py"
[ -f "$LD_SHARED_GATE" ] || {
  echo "FAIL v-ld-config: shared ld-config gate not found at $LD_SHARED_GATE — ld-shared not synced; run install first" >&2
  exit 1
}
[ -f "$LD_CONFIG" ] || { echo "FAIL v-ld-config: $LD_CONFIG missing" >&2; exit 1; }
jq -e . "$LD_CONFIG" >/dev/null || { echo "FAIL v-ld-config: $LD_CONFIG is not valid JSON" >&2; exit 1; }
# Universal core (shared gate) + Plow-specific imessage check, joined the
# same way install-bundles.sh's ld_config_gate() joins them.
GATE=$(python3 "$LD_SHARED_GATE" "$LD_CONFIG")
if [ "$GATE" != "not valid JSON" ] \
   && [ "$(jq -r '(.family.owner.imessage // "") | test("\\S")' "$LD_CONFIG" 2>/dev/null)" != "true" ]; then
  GATE="${GATE:+$GATE; }family.owner.imessage is blank"
fi
if [ -n "$GATE" ]; then
  echo "FAIL v-ld-config: $LD_CONFIG does not pass the install gate: $GATE" >&2
  echo "Fix the config (or re-run install with the LD_OWNER_* / LD_CALENDAR_ACCOUNT inputs set) before verifying." >&2
  exit 1
fi
echo "OK   v-ld-config"

# Each ld-* bundle's distinctive file. ld-shared is a helper module (no
# SKILL.md) carrying BOTH shared helpers the producers load: the Python
# post_to_kiosk (wrapper POST path) and the JS ld-runtime (scheduled runners
# require it at module load) — probe both so a stale/partial ld-shared fails
# the gate here instead of crashing the runners at their first tick.
declare -a probes=(
  "ld-shared/scripts/post_to_kiosk.py"
  "ld-shared/scripts/ld-runtime.js"
  "ld-calendar-nudge/SKILL.md"
  "ld-morning-triage/SKILL.md"
  "ld-morning-updates/SKILL.md"
  "ld-weekly-digest/SKILL.md"
  "ld-weather/SKILL.md"
  "ld-sports/SKILL.md"
  "ld-photo/SKILL.md"
)

# Bundle install location varies by plowd build:
#   - current builds install to ~/Plow/skills/
#   - v2 container builds use containers/<agent-UUID>/workspace[/host]/skills/
# Resolve by probing candidate roots for ld-shared's marker file. The list is
# built directly — current host root first, then any container workspace via
# glob — with no index.json/UUID resolver: that resolver's `ls … | grep … |
# head` could exit non-zero under `set -euo pipefail` on a current build with no
# containers/ dir and abort BEFORE ~/Plow/skills is ever checked. An unmatched
# glob stays literal and simply fails the `-f` test, falling through.
MARKER="${probes[0]}"   # single source of truth for the bundle marker file
WORKSPACE_SKILLS=""
for cand in "$HOME/Plow/skills" \
            "$CONTAINERS_DIR"/*/workspace/skills \
            "$CONTAINERS_DIR"/*/workspace/host/skills; do
  [ -f "$cand/$MARKER" ] && { WORKSPACE_SKILLS="$cand"; break; }
done
[ -n "$WORKSPACE_SKILLS" ] \
  || { echo "FAIL v-bundles: ld-* bundles not found (checked ~/Plow/skills and container workspaces)" >&2; exit 1; }

for p in "${probes[@]}"; do
  [ -f "$WORKSPACE_SKILLS/$p" ] \
    || { echo "FAIL v-bundles: $WORKSPACE_SKILLS/$p missing" >&2; exit 1; }
done
echo "OK   v-bundles ($WORKSPACE_SKILLS)"

# v3: dry-run a wrapper. We use the host-side repo-local copy here — same
# wrapper code that's installed inside the VM, just executed from the
# host with rebound module-level constants. This proves the secrets
# resolve and the wrapper executes; it does NOT post over the network.
DRY_OUT=$(mktemp -t agent-verify-out)
trap 'rm -f "$DRY_OUT"' EXIT
# Capture the dry-run's exit status explicitly (no `|| true`): a hard
# failure (e.g. a Python import error in the wrapper) must fail verify,
# not be silently masked so the grep becomes the only signal. The
# output goes to a private mktemp file (not a fixed world-readable
# /tmp path) to avoid symlink/TOCTOU + concurrent-run collisions.
DRY_RC=0
WRAPPER="$SEED_ROOT/ref/team-skills/ld-morning-updates/scripts/post_message.py" \
ENDPOINT_FILE="$SECRETS_DIR/dashboard-endpoint-url" \
TOKEN_FILE="$SECRETS_DIR/dashboard-token" \
python3 - >"$DRY_OUT" 2>&1 <<'PY' || DRY_RC=$?
import os, sys, io, importlib.util
# Load a REAL wrapper so its CARD/BODY_TYPE assignments are load-bearing:
# a wrapper missing the CARD contract must fail this check, not be masked
# by verify assigning the constants itself.
spec = importlib.util.spec_from_file_location("post_message", os.environ["WRAPPER"])
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)
ptk = wrapper.post_to_kiosk
# Rebind ONLY the host-side secret-file paths (the wrapper hardcodes the
# VM /config/secrets/... paths). The message text is fed on stdin, as in
# prod — the helper reads stdin, never a file the agent must create.
ptk.ENDPOINT_FILE = os.environ["ENDPOINT_FILE"]
ptk.TOKEN_FILE = os.environ["TOKEN_FILE"]
sys.stdin = io.StringIO("hello from verify")
sys.argv = ["post_message.py", "--dry-run"]
try:
    ptk.main()
except SystemExit as e:
    # main() may exit normally; a clean exit is fine for --dry-run
    if e.code not in (None, 0):
        raise
PY
if [ "$DRY_RC" != "0" ]; then
  echo "FAIL v-dry-run: wrapper exited non-zero ($DRY_RC)" >&2
  head -20 "$DRY_OUT" >&2
  exit 1
fi
grep -qE '<redacted, [0-9]+ chars>' "$DRY_OUT" \
  || { echo "FAIL v-dry-run: no redacted-body output line in $DRY_OUT" >&2; head -20 "$DRY_OUT" >&2; exit 1; }
echo "OK   v-dry-run"

echo "tree conforms"
