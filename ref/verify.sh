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

# Each ld-* bundle's distinctive file. ld-shared is a helper module (no
# SKILL.md); the other five are full skills with SKILL.md.
declare -a probes=(
  "ld-shared/scripts/post_to_kiosk.py"
  "ld-calendar-nudge/SKILL.md"
  "ld-morning-triage/SKILL.md"
  "ld-morning-affirmation/SKILL.md"
  "ld-weekly-digest/SKILL.md"
  "ld-weather/SKILL.md"
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
SHARED_SCRIPTS="$SEED_ROOT/ref/team-skills/ld-shared/scripts" \
WRAPPER_FILE="$SEED_ROOT/ref/team-skills/ld-morning-affirmation/scripts/post_affirmation.py" \
ENDPOINT_FILE="$SECRETS_DIR/dashboard-endpoint-url" \
TOKEN_FILE="$SECRETS_DIR/dashboard-token" \
DRY_INPUT="$DRY_INPUT" \
python3 - >"$DRY_OUT" 2>&1 <<'PY' || DRY_RC=$?
import os, sys, importlib.util, tempfile, pathlib

# 1. Load post_to_kiosk into sys.modules FIRST so the wrapper's
#    `import post_to_kiosk` resolves to this same module object.
shared = os.environ["SHARED_SCRIPTS"]
spec = importlib.util.spec_from_file_location(
    "post_to_kiosk",
    os.path.join(shared, "post_to_kiosk.py"),
)
mod = importlib.util.module_from_spec(spec)
sys.modules["post_to_kiosk"] = mod
spec.loader.exec_module(mod)

# 2. Rebind host-side paths BEFORE the wrapper runs (wrapper overrides
#    MESSAGE_FILE to its own bundle path — that is intentional: we write
#    the fixture there so the wrapper is tested exactly as installed).
mod.ENDPOINT_FILE = os.environ["ENDPOINT_FILE"]
mod.TOKEN_FILE = os.environ["TOKEN_FILE"]
# Point CONFIG_FILE at a nonexistent temp path so host config cannot
# influence card resolution (absent file -> fall through to DEFAULT_CARD).
mod.CONFIG_FILE = os.path.join(tempfile.mkdtemp(), "no-such-config.json")

# 3. Write the fixture text to the wrapper's expected MESSAGE_FILE path
#    so the wrapper finds it when main() reads it.
wrapper_msg = "/tmp/ld-morning-affirmation-text"
pathlib.Path(wrapper_msg).write_text(pathlib.Path(os.environ["DRY_INPUT"]).read_text())

# 4. Exec the wrapper as __main__ — it sets BODY_TYPE / DEFAULT_CARD on
#    the shared module object, then calls post_to_kiosk.main().
wrapper_spec = importlib.util.spec_from_file_location(
    "__main__",
    os.environ["WRAPPER_FILE"],
)
sys.argv = ["post_affirmation.py", "--dry-run"]
try:
    wrapper_mod = importlib.util.module_from_spec(wrapper_spec)
    wrapper_spec.loader.exec_module(wrapper_mod)
except SystemExit as e:
    # main() exits normally on --dry-run; a clean exit is fine
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
