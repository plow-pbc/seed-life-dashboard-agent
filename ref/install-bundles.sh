#!/usr/bin/env bash
#
# seed-life-dashboard-agent — POST this repo's ld-* bundles to local
# plowd's install endpoint; land the env-supplied endpoint+token + the
# household ld-config in the agent-runtime dir so the bundles can run.
#
# Idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-
# with-rollback over the SINGLE multi-bundle transaction) and rewrites
# the two secret files. The ld-config is ASSEMBLED from the three
# operator inputs (LD_OWNER_NAME / LD_OWNER_IMESSAGE /
# LD_CALENDAR_ACCOUNT) on first install ONLY; subsequent runs preserve
# a gate-passing operator-edited config.
#
# Input validation + ld-config write happen BEFORE the bundle
# POST so that no scheduled code is activated until the runtime
# config + credentials it depends on are known-good.

set -euo pipefail

PLOW_BUNDLE_ID="${PLOW_BUNDLE_ID:-co.plow.app}"
APP_SUPPORT="$HOME/Library/Application Support/$PLOW_BUNDLE_ID"
LOCAL_TOKEN="$APP_SUPPORT/agent-runtime/secrets/plow-local-token"
SECRETS_DIR="$APP_SUPPORT/agent-runtime/secrets"
LD_CONFIG_DIR="$APP_SUPPORT/agent-runtime/runtime/ld"
LD_CONFIG="$LD_CONFIG_DIR/config.json"

# 1. Required state.
[ -f "$LOCAL_TOKEN" ] || {
  echo "no plow-local-token at $LOCAL_TOKEN — is seed-plow-app installed and activated?" >&2
  exit 1
}

# 2. Required tools.
for tool in jq tar lsof pgrep python3 awk; do
  command -v "$tool" >/dev/null \
    || { echo "missing required tool: $tool" >&2; exit 1; }
done

SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BUNDLES_DIR="$SEED_ROOT/ref/team-skills"
[ -d "$BUNDLES_DIR" ] || { echo "no $BUNDLES_DIR — incomplete checkout?" >&2; exit 1; }

# 3. Discover plowd's HTTP API port. Same pattern as plow4/justfile.
if [ -s "$APP_SUPPORT/dev-plowd-port" ]; then
  PLOWD_PORT=$(cat "$APP_SUPPORT/dev-plowd-port")
else
  PLOWD_PID=$(pgrep -f "/Applications/Plow.app/Contents/Resources/runtime/python/bin/python3 -m uvicorn plowd\.main" | head -1 || true)
  [ -n "$PLOWD_PID" ] || {
    echo "plowd not running for $PLOW_BUNDLE_ID — start Plow.app first" >&2
    exit 1
  }
  PLOWD_PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PLOWD_PID" 2>/dev/null \
               | awk 'NR>1 {split($9, a, ":"); print a[length(a)]; exit}' \
               || true)
  [ -n "$PLOWD_PORT" ] || {
    echo "could not resolve plowd HTTP port from pid $PLOWD_PID" >&2
    exit 1
  }
fi
PLOWD_URL="http://127.0.0.1:$PLOWD_PORT/marketplace/api/install-local-bundles"

# 4. Validate the two umbrella/operator-supplied inputs UPFRONT so a
#    malformed value aborts before plowd is mutated. DASHBOARD_ENDPOINT_URL is
#    the FULL message-API URL (e.g. http://rpi5screen:5174/api/message) —
#    written verbatim, no path append. http:// is allowed: the Pi endpoint
#    rides the household LAN/tailnet, not the public internet.
ENDPOINT_URL="${DASHBOARD_ENDPOINT_URL:?DASHBOARD_ENDPOINT_URL not set — full /api/message URL of the Pi backend}"
: "${DASHBOARD_TOKEN:?DASHBOARD_TOKEN not set — bearer the Pi message API validates}"
case "$DASHBOARD_TOKEN" in
  *[![:space:]]*) ;;  # contains a non-whitespace char
  *) echo "DASHBOARD_TOKEN is blank" >&2; exit 1 ;;
esac
case "$ENDPOINT_URL" in
  http://*|https://*) ;;
  *) echo "DASHBOARD_ENDPOINT_URL is not http(s)://" >&2; exit 1 ;;
esac
case "$ENDPOINT_URL" in
  */api/message) ;;
  *) echo "DASHBOARD_ENDPOINT_URL must be the FULL message-API URL ending in /api/message" >&2; exit 1 ;;
esac
case "$ENDPOINT_URL" in
  *[[:space:]]*) echo "DASHBOARD_ENDPOINT_URL must contain no whitespace" >&2; exit 1 ;;
esac
case "$DASHBOARD_TOKEN" in
  *$'\n'*) echo "DASHBOARD_TOKEN must be single-line" >&2; exit 1 ;;
esac

# 5. Land dashboard secrets BEFORE bundle install — every ld-* bundle's
#    runtime reads /config/secrets/dashboard-* on first invocation, so
#    a bundle-install before secrets land would activate scheduled code
#    against unknown credentials. Atomic write at mode 600 via mktemp
#    + rename, inside SECRETS_DIR for same-fs atomicity.
#
# DASHBOARD_ENDPOINT_URL is the FULL message-API URL (already validated
# in step 4) — written VERBATIM, no path append. The umbrella SEED
# (seed-life-dashboard) derives and exports this value; a standalone
# install supplies it directly as an operator input.
# Use already-validated $ENDPOINT_URL / $DASHBOARD_TOKEN from step 4
# so the values that hit the secret files are the same ones validation passed.
mkdir -p "$SECRETS_DIR"
TMP=$(mktemp "$SECRETS_DIR/.dashboard-endpoint-url.XXXXXX")
printf '%s' "$ENDPOINT_URL" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$SECRETS_DIR/dashboard-endpoint-url"
TMP=$(mktemp "$SECRETS_DIR/.dashboard-token.XXXXXX")
printf '%s' "$DASHBOARD_TOKEN" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$SECRETS_DIR/dashboard-token"
# Clear the secrets from the environment after landing them — same pattern as
# the LD_* operator inputs below. The ld-config assembly + bundle-POST python3
# child have no use for these values; secret files are the canonical handoff.
unset DASHBOARD_ENDPOINT_URL DASHBOARD_TOKEN

# 6. Assemble + land ld-config from the three operator inputs on first
#    install ONLY; preserve a gate-passing operator-edited config on
#    re-runs (the operator's edits are canonical). The ONE exception:
#    a landed file that still FAILS the gate is re-assembled from the
#    inputs, so a corrected rerun is not short-circuited by "file
#    exists." The gate is the SEED's single definition of "installed"
#    (SEED.md ## Actions > minimal structural gate) — install, verify,
#    and the operator instructions all agree on it.
mkdir -p "$LD_CONFIG_DIR"

# The minimal structural gate, inline. Prints the failing invariant(s)
# (never the PII values) to stdout; empty output == PASS. Same checks
# ref/verify.sh's v-ld-config enforces, so install + verify never drift.
ld_config_gate() {  # ld_config_gate FILE -> prints failures (empty == pass)
  jq -r '
    [ if ((.family.owner.name     // "") | test("\\S")) then empty else "family.owner.name is blank" end,
      if ((.family.owner.imessage // "") | test("\\S")) then empty else "family.owner.imessage is blank" end,
      if ((.calendar.sources | type) == "array" and (.calendar.sources | length) >= 1)
        then empty else "calendar.sources is not a non-empty array" end,
      if ([.calendar.sources[]? | select(((.account // "") | test("\\S")) | not)] | length) == 0
        then empty else "a calendar.sources[].account is blank" end,
      if ([.. | strings | select(test("^\\[[A-Z][A-Z0-9_]*\\]$"))] | length) == 0
        then empty else "an unfilled [UPPER_SNAKE] placeholder remains" end
    ] | join("; ")
  ' "$1" 2>/dev/null || echo "not valid JSON"
}

# Assemble only when there is no config yet, OR the existing one fails
# the gate (corrupted / never-completed). A gate-passing existing file
# is the operator's canonical edit — left untouched, even if its zone
# drifted from the host.
NEED_ASSEMBLE=0
if [ ! -f "$LD_CONFIG" ]; then
  NEED_ASSEMBLE=1
elif [ -n "$(ld_config_gate "$LD_CONFIG")" ]; then
  NEED_ASSEMBLE=1
fi

if [ "$NEED_ASSEMBLE" = "1" ]; then
  # All three inputs are REQUIRED to assemble — the installer collects
  # them up front (SEED.md ### Requirements). A missing one fails loud
  # rather than landing a partial config.
  for v in LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT; do
    eval "val=\${$v:-}"
    case "$val" in
      *[![:space:]]*) ;;  # contains a non-whitespace char (matches the jq gate's \S)
      *) echo "$v is unset or blank — the installer must collect the three LD_* inputs before assembling ld-config" >&2; exit 1 ;;
    esac
  done

  # Autodetect IANA timezone: everything after the last /zoneinfo/ in
  # readlink /etc/localtime; fall back to America/Los_Angeles. Non-PII,
  # so it is the ONLY value passed to jq via --arg.
  TZLINK=$(readlink /etc/localtime 2>/dev/null || true)
  case "$TZLINK" in
    */zoneinfo/*) LD_TIMEZONE=${TZLINK##*/zoneinfo/} ;;
    *) LD_TIMEZONE="" ;;
  esac
  [ -n "$LD_TIMEZONE" ] || LD_TIMEZONE="America/Los_Angeles"

  # Assemble. The PII values (owner name/handle, calendar account) reach
  # jq ONLY through the environment, read inside the filter via the `env`
  # builtin — NEVER on argv, so they never surface in /proc/<pid>/cmdline.
  # The per-command env prefix sets them for jq's process; the inputs also
  # arrive EXPORTED in this script's env (the installer sets them), so they
  # are `unset` right after this block — before the bundle-POST python3
  # child below — so that child never inherits owner PII. Only the non-PII
  # autodetected timezone is passed via --arg. Mirrors the example's shape: single owner,
  # one primary calendar, the example's real calendar_nudge lookahead
  # defaults; optional sections (partner, extra calendars, long-lead)
  # omitted.
  TMP=$(mktemp "$LD_CONFIG_DIR/.config.json.XXXXXX")
  LD_OWNER_NAME="$LD_OWNER_NAME" \
  LD_OWNER_IMESSAGE="$LD_OWNER_IMESSAGE" \
  LD_CALENDAR_ACCOUNT="$LD_CALENDAR_ACCOUNT" \
  jq -n --arg tz "$LD_TIMEZONE" '
    {
      family: { owner: { name: env.LD_OWNER_NAME, imessage: env.LD_OWNER_IMESSAGE }, timezone: $tz },
      calendar: { sources: [ { account: env.LD_CALENDAR_ACCOUNT, calendar_id: "primary", name: "Personal" } ] },
      morning_updates: { review_window_hours: 24 },
      morning_triage: { ranking_instructions: "", exclude: { imessage_handles: [], email_addresses: [] } },
      calendar_nudge: { lookahead_virtual_minutes: 30, lookahead_in_person_minutes: 60 },
      weather: { location: "Mountain View", lat: 37.386, lon: -122.083 }
    }
  ' > "$TMP"
  chmod 600 "$TMP"
  FAILS=$(ld_config_gate "$TMP")
  if [ -n "$FAILS" ]; then
    rm -f "$TMP"
    echo "assembled ld-config did NOT pass the structural gate: $FAILS" >&2
    echo "NOT installed — no config landed and no bundles posted." >&2
    exit 1
  fi
  mv "$TMP" "$LD_CONFIG"
  echo "" >&2
  echo "ld-config assembled + landed at $LD_CONFIG (timezone: $LD_TIMEZONE)." >&2
fi

# Preserve-path upgrade: a gate-passing existing config is the operator's
# canonical edit, but one that predates ld-weather lacks the `weather` section
# the now-auto-activating scheduled runner reads — it would fail-loud every
# ~5-min tick. Backfill the Mountain View defaults ONLY when the section is
# absent (never overwrite operator values), so an upgrade activates cleanly.
if [ "$NEED_ASSEMBLE" = "0" ] && [ "$(jq -r 'has("weather")' "$LD_CONFIG" 2>/dev/null)" = "false" ]; then
  TMP=$(mktemp "$LD_CONFIG_DIR/.config.json.XXXXXX")
  jq '. + { weather: { location: "Mountain View", lat: 37.386, lon: -122.083 } }' "$LD_CONFIG" > "$TMP"
  chmod 600 "$TMP"
  mv "$TMP" "$LD_CONFIG"
  echo "backfilled weather defaults into the preserved ld-config (ld-weather upgrade)." >&2
fi

# The three operator inputs arrive EXPORTED in this script's environment (the
# installer sets them to assemble the config). Clear them now — before the
# bundle-POST python3 child below — so owner PII is not inherited into that
# child's environment. Unconditional: harmless on the preserve path (which
# never used them), and bash-3.2-safe.
unset LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT

# Pre-POST gate: refuse to activate scheduled bundles unless the landed
# config passes the structural gate. NAMES the failing invariant, never
# the PII values. ref/verify.sh cross-checks the same gate at verify.
FAILS=$(ld_config_gate "$LD_CONFIG")
if [ -n "$FAILS" ]; then
  echo "" >&2
  echo "ld-config at $LD_CONFIG does NOT pass the structural gate: $FAILS" >&2
  echo "NOT installed — bundles NOT posted. Re-run with the three LD_* inputs set." >&2
  exit 1
fi

# 7. POST ALL bundles in a single tarball + single Python call so
#    plowd's marketplace endpoint sees one transaction (atomic
#    rollback boundary). Matches plow4/justfile sync-team-skills shape.
#    Token + body via Python stdlib so neither lands in argv. The
#    no-redirect opener prevents plowd from forwarding Authorization
#    to another target on an upstream 30x — same pattern as
#    ld-shared/scripts/post_to_kiosk.py:_NoRedirect.
BUNDLE_NAMES=(ld-shared ld-calendar-nudge ld-morning-triage ld-morning-updates ld-weekly-digest ld-weather)
for bundle in "${BUNDLE_NAMES[@]}"; do
  [ -d "$BUNDLES_DIR/$bundle" ] || {
    echo "missing bundle: $bundle" >&2
    exit 1
  }
done
TARBALL=$(mktemp -t agent-bundles)
trap 'rm -f "$TARBALL"' EXIT
( cd "$BUNDLES_DIR" && tar czf "$TARBALL" "${BUNDLE_NAMES[@]}" )
TOKEN_PATH="$LOCAL_TOKEN" PLOWD_URL="$PLOWD_URL" TARBALL="$TARBALL" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """plowd is local; an upstream 30x means something is wrong. Do
    NOT forward the Authorization header to another target."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code,
            f"unexpected redirect to {newurl} — refusing to forward Authorization",
            headers, fp,
        )

token = open(os.environ["TOKEN_PATH"]).read().strip()
body = open(os.environ["TARBALL"], "rb").read()
opener = urllib.request.build_opener(_NoRedirect())
req = urllib.request.Request(
    os.environ["PLOWD_URL"],
    data=body,
    method="POST",
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/gzip"},
)
try:
    with opener.open(req, timeout=60) as resp:
        print(json.dumps(json.load(resp), indent=2))
except urllib.error.HTTPError as exc:
    sys.exit(f"install-local-bundles failed (HTTP {exc.code}): {exc.read().decode(errors='replace')[:500]}")
except (urllib.error.URLError, TimeoutError) as exc:
    sys.exit(f"install-local-bundles failed (network/timeout): {exc}")
PY
rm -f "$TARBALL"
trap - EXIT

echo "" >&2
echo "Agent installed:" >&2
echo "  6 bundles (ld-shared, ld-calendar-nudge, ld-morning-triage," >&2
echo "             ld-morning-updates, ld-weekly-digest, ld-weather) posted" >&2
echo "             in one transaction to plowd at $PLOWD_URL" >&2
echo "  dashboard-endpoint-url, dashboard-token landed in $SECRETS_DIR" >&2
echo "  ld-config resolved at $LD_CONFIG" >&2
echo "" >&2
echo "NOTE: three of the bundles (ld-morning-updates, ld-morning-triage," >&2
echo "ld-weekly-digest) need cron jobs registered via Plow's agent-side" >&2
echo "'cron action=add' verb after install — message your Plow agent to" >&2
echo "set up the morning-updates / morning-triage / weekly-digest crons" >&2
echo "per each bundle's SKILL.md § Scheduling. ld-calendar-nudge and" >&2
echo "ld-weather use plowd's auto-activated scheduled/ entrypoint and need" >&2
echo "no manual setup." >&2
