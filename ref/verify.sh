#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-life-dashboard-agent.

set -euo pipefail

PLOW_BUNDLE_ID="${PLOW_BUNDLE_ID:-co.plow.app}"
APP_SUPPORT="$HOME/Library/Application Support/$PLOW_BUNDLE_ID"
SECRETS_DIR="$APP_SUPPORT/agent-runtime/secrets"
CONTAINERS_DIR="$APP_SUPPORT/containers"

# v1: dashboard-endpoint-url and dashboard-token present, mode 600, non-empty.
for s in dashboard-endpoint-url dashboard-token; do
  f="$SECRETS_DIR/$s"
  [ -s "$f" ] || { echo "FAIL ^v-secrets: $f missing or empty" >&2; exit 1; }
  [ "$(stat -f '%Lp' "$f")" = "600" ] \
    || { echo "FAIL ^v-secrets: $f not mode 600" >&2; exit 1; }
done
echo "OK   ^v-secrets"

# v2: each bundle present in the main agent's container workspace.
#     "Main agent" container resolution: containers/index.json names
#     it; fallback is first UUID-shaped dir under containers/.
if [ -f "$CONTAINERS_DIR/index.json" ] && jq -e '.main' "$CONTAINERS_DIR/index.json" >/dev/null 2>&1; then
  CONTAINER_UUID=$(jq -r '.main' "$CONTAINERS_DIR/index.json")
else
  CONTAINER_UUID=$(ls "$CONTAINERS_DIR" 2>/dev/null \
                   | grep -E '^[0-9a-f-]{36}$' \
                   | head -1)
fi
[ -n "$CONTAINER_UUID" ] || { echo "FAIL ^v-bundles: no main agent container under $CONTAINERS_DIR" >&2; exit 1; }
WORKSPACE_SKILLS="$CONTAINERS_DIR/$CONTAINER_UUID/workspace/skills"

# Each ld-* bundle's distinctive file. ld-shared is a helper module (no
# SKILL.md); the other four are full skills with SKILL.md.
declare -a probes=(
  "ld-shared/scripts/post_to_kiosk.py"
  "ld-calendar-nudge/SKILL.md"
  "ld-morning-triage/SKILL.md"
  "ld-morning-updates/SKILL.md"
  "ld-weekly-digest/SKILL.md"
)
for p in "${probes[@]}"; do
  [ -f "$WORKSPACE_SKILLS/$p" ] \
    || { echo "FAIL ^v-bundles: $WORKSPACE_SKILLS/$p missing" >&2; exit 1; }
done
echo "OK   ^v-bundles ($CONTAINER_UUID)"

# v3: dry-run a wrapper. We use the host-side vendored copy here — same
# wrapper code that's installed inside the VM, just executed from the
# host with rebound module-level constants. This proves the secrets
# resolve and the wrapper executes; it does NOT post over the network.
SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
DRY_INPUT=$(mktemp -t agent-verify-msg)
echo "hello from verify" > "$DRY_INPUT"
PYTHONPATH="$SEED_ROOT/ref/team-skills/ld-shared/scripts" \
ENDPOINT_FILE="$SECRETS_DIR/dashboard-endpoint-url" \
TOKEN_FILE="$SECRETS_DIR/dashboard-token" \
DRY_INPUT="$DRY_INPUT" \
python3 - <<'PY' >/tmp/agent-verify-out 2>&1 || true
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location(
    "post_to_kiosk",
    os.path.join(os.environ["PYTHONPATH"], "post_to_kiosk.py"),
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# Rebind the module-level constants to point at our host-side secrets
# (the wrapper normally hardcodes the VM paths /config/secrets/...).
mod.ENDPOINT_FILE = os.environ["ENDPOINT_FILE"]
mod.TOKEN_FILE = os.environ["TOKEN_FILE"]
mod.MESSAGE_FILE = os.environ["DRY_INPUT"]
mod.BODY_TYPE = "message"
sys.argv = ["post_to_kiosk.py", "--dry-run"]
try:
    mod.main()
except SystemExit as e:
    # main() may exit normally; a clean exit is fine for --dry-run
    if e.code not in (None, 0):
        raise
PY
rm -f "$DRY_INPUT"
grep -qE '<redacted, [0-9]+ chars>' /tmp/agent-verify-out \
  || { echo "FAIL ^v-dry-run: no redacted-body output line in /tmp/agent-verify-out" >&2; head -20 /tmp/agent-verify-out >&2; exit 1; }
rm -f /tmp/agent-verify-out
echo "OK   ^v-dry-run"

echo "tree conforms"
