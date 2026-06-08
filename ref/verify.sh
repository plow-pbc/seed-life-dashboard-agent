#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-life-dashboard-agent.

set -euo pipefail

PLOW_BUNDLE_ID="${PLOW_BUNDLE_ID:-co.plow.app}"
APP_SUPPORT="$HOME/Library/Application Support/$PLOW_BUNDLE_ID"
SECRETS_DIR="$APP_SUPPORT/agent-runtime/secrets"
CONTAINERS_DIR="$APP_SUPPORT/containers"
LD_CONFIG="$APP_SUPPORT/agent-runtime/runtime/ld/config.json"

# v1: dashboard-endpoint-url and dashboard-token present, mode 600, non-empty.
for s in dashboard-endpoint-url dashboard-token; do
  f="$SECRETS_DIR/$s"
  [ -s "$f" ] || { echo "FAIL v-secrets: $f missing or empty" >&2; exit 1; }
  [ "$(stat -f '%Lp' "$f")" = "600" ] \
    || { echo "FAIL v-secrets: $f not mode 600" >&2; exit 1; }
done
echo "OK   v-secrets"

# v1b: ld-config present + parses as JSON + REQUIRED fields resolved.
# Presence + JSON-parse is the floor; the required-field check mirrors
# install-bundles.sh's pre-mutation gate EXACTLY — block only on the
# fields the bundles cannot function without:
#   - family.owner.name      ([OWNER_NAME])
#   - family.owner.imessage  ([OWNER_IMESSAGE])
#   - at least ONE real calendar.sources[].account
# Optional fields ([PARTNER_*], [FAMILY_PERSON_*], [FAMILY_CALENDAR_ID],
# [LONG_LEAD_TYPE]) intentionally do NOT block — single-parent /
# single-calendar homes leave them as-is.
[ -f "$LD_CONFIG" ] || { echo "FAIL v-ld-config: $LD_CONFIG missing" >&2; exit 1; }
jq -e . "$LD_CONFIG" >/dev/null || { echo "FAIL v-ld-config: $LD_CONFIG is not valid JSON" >&2; exit 1; }
PH='test("\\[[A-Z][A-Z0-9_]*\\]")'
MISSING=$(jq -r "
  [ (if (.family.owner.name      // \"\" | $PH) then \"family.owner.name\"      else empty end),
    (if (.family.owner.imessage  // \"\" | $PH) then \"family.owner.imessage\"  else empty end),
    (if ([ .calendar.sources[]?.account // \"\" | select($PH | not) ] | length) == 0
       then \"calendar.sources[].account (need at least one real account)\" else empty end)
  ] | .[]" "$LD_CONFIG")
if [ -n "$MISSING" ]; then
  echo "FAIL v-ld-config: $LD_CONFIG is missing required household values:" >&2
  echo "$MISSING" | sed 's/^/  - /' >&2
  echo "Fill these in (or re-run install with LD_CONFIG_SRC) before verifying." >&2
  exit 1
fi
echo "OK   v-ld-config"

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
[ -n "$CONTAINER_UUID" ] || { echo "FAIL v-bundles: no main agent container under $CONTAINERS_DIR" >&2; exit 1; }
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
    || { echo "FAIL v-bundles: $WORKSPACE_SKILLS/$p missing" >&2; exit 1; }
done
echo "OK   v-bundles ($CONTAINER_UUID)"

# v3: dry-run a wrapper. We use the host-side vendored copy here — same
# wrapper code that's installed inside the VM, just executed from the
# host with rebound module-level constants. This proves the secrets
# resolve and the wrapper executes; it does NOT post over the network.
SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
DRY_INPUT=$(mktemp -t agent-verify-msg)
DRY_OUT=$(mktemp -t agent-verify-out)
trap 'rm -f "$DRY_INPUT" "$DRY_OUT"' EXIT
echo "hello from verify" > "$DRY_INPUT"
# Capture the dry-run's exit status explicitly (no `|| true`): a hard
# failure (e.g. a Python import error in the wrapper) must fail verify,
# not be silently masked so the grep becomes the only signal. The
# output goes to a private mktemp file (not a fixed world-readable
# /tmp path) to avoid symlink/TOCTOU + concurrent-run collisions.
DRY_RC=0
PYTHONPATH="$SEED_ROOT/ref/team-skills/ld-shared/scripts" \
ENDPOINT_FILE="$SECRETS_DIR/dashboard-endpoint-url" \
TOKEN_FILE="$SECRETS_DIR/dashboard-token" \
DRY_INPUT="$DRY_INPUT" \
python3 - >"$DRY_OUT" 2>&1 <<'PY' || DRY_RC=$?
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
if [ "$DRY_RC" != "0" ]; then
  echo "FAIL v-dry-run: wrapper exited non-zero ($DRY_RC)" >&2
  head -20 "$DRY_OUT" >&2
  exit 1
fi
grep -qE '<redacted, [0-9]+ chars>' "$DRY_OUT" \
  || { echo "FAIL v-dry-run: no redacted-body output line in $DRY_OUT" >&2; head -20 "$DRY_OUT" >&2; exit 1; }
echo "OK   v-dry-run"

echo "tree conforms"
