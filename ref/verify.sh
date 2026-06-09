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

# v1b: ld-config present + parses as JSON + no remaining placeholders.
# Presence + JSON-parse is the floor; the placeholder check (any
# string value matching the `[OWNER_*]` / `[FAMILY_*]` / `[YOUR_*]`
# pattern the example ships with) catches the silent partial-install
# class where a fresh `cp config.example.json -> config.json` leaves
# the bundles wired against fictional household data.
[ -f "$LD_CONFIG" ] || { echo "FAIL v-ld-config: $LD_CONFIG missing" >&2; exit 1; }
jq -e . "$LD_CONFIG" >/dev/null || { echo "FAIL v-ld-config: $LD_CONFIG is not valid JSON" >&2; exit 1; }
# Generic `[UPPER_SNAKE]` placeholder detector — matches the same
# pattern install-bundles.sh's pre-mutation gate uses. Catches
# [OWNER_NAME], [PARTNER_*], [CALENDAR_ACCOUNT_1], [LONG_LEAD_TYPE],
# [FAMILY_TIMEZONE], [YOUR_*], etc. — anything that survives the
# bot-flagged "specific-token list" shape.
PLACEHOLDERS=$(jq -r '[.. | strings | select(test("\\[[A-Z][A-Z0-9_]*\\]"))] | length' "$LD_CONFIG")
if [ "$PLACEHOLDERS" != "0" ]; then
  echo "FAIL v-ld-config: $LD_CONFIG still contains $PLACEHOLDERS placeholder value(s) — edit the file with your household's real values and re-run the install before verifying." >&2
  exit 1
fi
echo "OK   v-ld-config"

# Each ld-* bundle's distinctive file. ld-shared is a helper module (no
# SKILL.md); the other four are full skills with SKILL.md.
declare -a probes=(
  "ld-shared/scripts/post_to_kiosk.py"
  "ld-calendar-nudge/SKILL.md"
  "ld-morning-triage/SKILL.md"
  "ld-morning-updates/SKILL.md"
  "ld-weekly-digest/SKILL.md"
)

# Bundle install location varies by plowd build:
#   - current builds install to ~/Plow/skills/
#   - v2 container builds use containers/<agent-UUID>/workspace[/host]/skills/
# Resolve by probing candidate roots for ld-shared's marker file. The agent
# container in index.json v2 is the entry with role "agent" (the on-disk dir is
# its lowercased id); `.main` is honored if a build emits it; else first UUID dir.
MARKER="${probes[0]}"   # single source of truth for the bundle marker file
AGENT_UUID=""
if [ -f "$CONTAINERS_DIR/index.json" ]; then
  AGENT_UUID=$(jq -r '(.main // (.containers[]? | select(.role=="agent") | .id) // empty)' \
               "$CONTAINERS_DIR/index.json" 2>/dev/null | head -1 | tr 'A-Z' 'a-z')
fi
[ -n "$AGENT_UUID" ] || AGENT_UUID=$(ls "$CONTAINERS_DIR" 2>/dev/null | grep -E '^[0-9a-f-]{36}$' | head -1)

candidates=( "$HOME/Plow/skills" )
[ -n "$AGENT_UUID" ] && candidates+=( \
  "$CONTAINERS_DIR/$AGENT_UUID/workspace/skills" \
  "$CONTAINERS_DIR/$AGENT_UUID/workspace/host/skills" )
WORKSPACE_SKILLS=""
for cand in "${candidates[@]}"; do
  [ -f "$cand/$MARKER" ] && { WORKSPACE_SKILLS="$cand"; break; }
done
[ -n "$WORKSPACE_SKILLS" ] \
  || { echo "FAIL v-bundles: ld-* bundles not found (checked ~/Plow/skills and container workspaces)" >&2; exit 1; }

for p in "${probes[@]}"; do
  [ -f "$WORKSPACE_SKILLS/$p" ] \
    || { echo "FAIL v-bundles: $WORKSPACE_SKILLS/$p missing" >&2; exit 1; }
done
echo "OK   v-bundles ($WORKSPACE_SKILLS)"

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
