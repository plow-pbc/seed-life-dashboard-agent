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

# v1b: ld-config present + parses as JSON + passes the minimal
# structural gate. This is the SAME gate install-bundles.sh enforces
# pre-mutation (SEED.md ## Actions > minimal structural gate), so
# install and verify can never drift. The gate is deliberately MINIMAL
# — it does NOT mirror run.js's per-field runtime requirements (those
# are the bundles' single source of truth) — it asserts only the
# invariants that separate a USABLE filled config from an unedited
# template or a blank-filled one:
#   - family.owner.{name,imessage} present and non-blank
#   - calendar.sources a non-empty array, each source's account non-blank
#   - no string value left as a bare [UPPER_SNAKE] placeholder
# The autodetected timezone is NOT re-checked: a preserved / operator-
# edited config may legitimately carry a non-host zone (laptop moved,
# remote household), so enforcing it here would falsely reject a valid
# config. PII never prints — only the failing invariant's name.
[ -f "$LD_CONFIG" ] || { echo "FAIL v-ld-config: $LD_CONFIG missing" >&2; exit 1; }
jq -e . "$LD_CONFIG" >/dev/null || { echo "FAIL v-ld-config: $LD_CONFIG is not valid JSON" >&2; exit 1; }
GATE=$(jq -r '
  [ if ((.family.owner.name    // "") | test("\\S")) then empty else "family.owner.name is blank" end,
    if ((.family.owner.imessage // "") | test("\\S")) then empty else "family.owner.imessage is blank" end,
    if ((.calendar.sources | type) == "array" and (.calendar.sources | length) >= 1)
      then empty else "calendar.sources is not a non-empty array" end,
    if ([.calendar.sources[]? | select(((.account // "") | test("\\S")) | not)] | length) == 0
      then empty else "a calendar.sources[].account is blank" end,
    if ([.. | strings | select(test("^\\[[A-Z][A-Z0-9_]*\\]$"))] | length) == 0
      then empty else "an unfilled [UPPER_SNAKE] placeholder remains" end
  ] | join("; ")
' "$LD_CONFIG")
if [ -n "$GATE" ]; then
  echo "FAIL v-ld-config: $LD_CONFIG does not pass the install gate: $GATE" >&2
  echo "Fix the config (or re-run install with the LD_OWNER_* / LD_CALENDAR_ACCOUNT inputs set) before verifying." >&2
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
