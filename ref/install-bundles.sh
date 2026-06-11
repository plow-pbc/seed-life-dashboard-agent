#!/usr/bin/env bash
#
# seed-life-dashboard-agent — POST this repo's ld-* bundles to local
# plowd's install endpoint; land the relay's endpoint+token + the
# household ld-config in the agent-runtime dir so the bundles can run.
#
# Idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-
# with-rollback over the SINGLE multi-bundle transaction) and rewrites
# the two secret files. The ld-config is ASSEMBLED from the three
# operator inputs (LD_OWNER_NAME / LD_OWNER_IMESSAGE /
# LD_CALENDAR_ACCOUNT) on first install ONLY; subsequent runs preserve
# a gate-passing operator-edited config.
#
# Relay-state validation + ld-config write happen BEFORE the bundle
# POST so that no scheduled code is activated until the runtime
# config + credentials it depends on are known-good.

set -euo pipefail

PLOW_BUNDLE_ID="${PLOW_BUNDLE_ID:-co.plow.app}"
APP_SUPPORT="$HOME/Library/Application Support/$PLOW_BUNDLE_ID"
LOCAL_TOKEN="$APP_SUPPORT/agent-runtime/secrets/plow-local-token"
RELAY_STATE="$HOME/Library/Application Support/seed-life-dashboard-relay/state.json"
SECRETS_DIR="$APP_SUPPORT/agent-runtime/secrets"
LD_CONFIG_DIR="$APP_SUPPORT/agent-runtime/runtime/ld"
LD_CONFIG="$LD_CONFIG_DIR/config.json"

# 1. Required state.
[ -f "$LOCAL_TOKEN" ] || {
  echo "no plow-local-token at $LOCAL_TOKEN — is seed-plow-app installed and activated?" >&2
  exit 1
}
[ -f "$RELAY_STATE" ] || {
  echo "no relay state at $RELAY_STATE — install seed-life-dashboard-relay first" >&2
  exit 1
}
[ "$(stat -f '%Lp' "$RELAY_STATE")" = "600" ] || {
  echo "$RELAY_STATE is not mode 600 — refusing to read" >&2
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

# 4. Validate + extract relay state UPFRONT so a malformed/missing
#    field aborts the install before plowd is mutated. Both must be
#    non-empty (whitespace-only fails too); endpoint_url must be
#    HTTPS. `jq -re` rejects null/missing; the explicit `test("\\S")`
#    rejects empty-string and whitespace-only values that the seed's
#    "validate non-empty before mutation" contract requires.
ENDPOINT_URL=$(jq -re '.endpoint_url | strings | select(test("\\S"))' "$RELAY_STATE") \
  || { echo "$RELAY_STATE: .endpoint_url missing/empty/whitespace" >&2; exit 1; }
DASHBOARD_TOKEN=$(jq -re '.dashboard_token | strings | select(test("\\S"))' "$RELAY_STATE") \
  || { echo "$RELAY_STATE: .dashboard_token missing/empty/whitespace" >&2; exit 1; }
case "$ENDPOINT_URL" in
  https://*) ;;
  *) echo "$RELAY_STATE: endpoint_url is not HTTPS: $ENDPOINT_URL" >&2; exit 1 ;;
esac

# 5. Land dashboard secrets BEFORE bundle install — every ld-* bundle's
#    runtime reads /config/secrets/dashboard-* on first invocation, so
#    a bundle-install before secrets land would activate scheduled code
#    against unknown credentials. Atomic write at mode 600 via mktemp
#    + rename, inside SECRETS_DIR for same-fs atomicity.
#
# Per seed-life-dashboard-relay's SEED.md#state-file contract, state.json's
# `endpoint_url` is the Vercel deployment BASE URL only — this SEED is
# responsible for appending `/api/message` so the runtime
# `dashboard-endpoint-url` is the full URL `post_to_kiosk.py` POSTs to.
# Use already-validated $ENDPOINT_URL / $DASHBOARD_TOKEN from step 4
# (not a re-jq) so the values that hit the secret files are the same
# ones the validation passed.
mkdir -p "$SECRETS_DIR"
TMP=$(mktemp "$SECRETS_DIR/.dashboard-endpoint-url.XXXXXX")
printf '%s/api/message' "${ENDPOINT_URL%/}" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$SECRETS_DIR/dashboard-endpoint-url"
TMP=$(mktemp "$SECRETS_DIR/.dashboard-token.XXXXXX")
printf '%s' "$DASHBOARD_TOKEN" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$SECRETS_DIR/dashboard-token"

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
# Register the three agent-driven crons by driving the agent itself — the
# supported "tell Plow" inbound seam (POST /channels/linq/inbound, Bearer
# plow-api-token via stdin so it never lands in argv). The agent reads each
# bundle's SKILL.md § Scheduling + AGENTS.md § Self-managed crons and runs
# cron action=add. Hand-writing cron/jobs.json does NOT register (the live
# scheduler doesn't watch the file) — the agent turn is the only correct path.
# Best-effort + verified; never fails the install (bundles/config/secrets are
# the install contract).
API_TOKEN_FILE="$SECRETS_DIR/plow-api-token"   # same secrets dir as plow-local-token / the VM's /config/secrets
CRON_JOBS="$APP_SUPPORT/agent-runtime/gateway/cron/jobs.json"
CRON_MSG='Please set up the three life-dashboard recurring cron jobs now: ld-morning-updates, ld-morning-triage, and ld-weekly-digest. For each, read /workspace/skills/<name>/SKILL.md and follow its Scheduling section plus /workspace/AGENTS.md § Self-managed crons, then create the job with cron action=add (schedule, delivery announce/plow-imessage, contextMessages, payload as specified there; tz = family.timezone from /config/runtime/ld/config.json). ld-calendar-nudge and ld-weather are already scheduled and need no cron. Reply with cron action=list when done.'
cron_ok=""
if [ -r "$API_TOKEN_FILE" ] && \
   MSG="$CRON_MSG" TOKEN_FILE="$API_TOKEN_FILE" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Same posture as the bundle POST above: a 30x from the inbound
    endpoint must NOT replay the bearer to the redirect target."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code,
            f"unexpected redirect to {newurl} — refusing to forward Authorization",
            headers, fp,
        )

tok = open(os.environ["TOKEN_FILE"]).read().strip()
body = json.dumps({"text": os.environ["MSG"]}).encode()
opener = urllib.request.build_opener(_NoRedirect())
req = urllib.request.Request("https://api.plow.co/channels/linq/inbound", data=body,
    method="POST", headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
try:
    with opener.open(req, timeout=30) as r:
        ok = json.load(r).get("delivered") is True
except Exception as e:
    sys.exit(f"cron-setup inbound POST failed: {e}")
sys.exit(0 if ok else "cron-setup: agent runtime offline (delivered != true)")
PY
then
  echo "cron-setup message delivered — waiting for the agent to register the three crons..." >&2
  # Each job must be present, ENABLED, and on its expected schedule expr — so a
  # missing, disabled, or wrong-cadence job does not pass. tz/contextMessages/
  # delivery/payload are confirmed by the authoritative agent-side
  # `cron action=list` (SEED.md § Verification step 5); the host can't check
  # payloads without duplicating each bundle's SKILL.md here.
  CRON_EXPECT='{"ld-morning-updates":"0 7 * * *","ld-morning-triage":"5 7 * * *","ld-weekly-digest":"0 7 * * 4"}'
  for _ in $(seq 1 18); do          # ~3 min: registration rides an async agent turn
    if [ -f "$CRON_JOBS" ] && jq -e --argjson want "$CRON_EXPECT" '
        .jobs as $jobs
        | all(($want | to_entries)[]; . as $w
              | any($jobs[]; .name == $w.key and .enabled == true and .schedule.expr == $w.value))
      ' "$CRON_JOBS" >/dev/null 2>&1; then
      cron_ok=1; break
    fi
    sleep 10
  done
fi
if [ -n "$cron_ok" ]; then
  echo "  crons registered + enabled on the expected schedules: ld-morning-updates, ld-morning-triage, ld-weekly-digest (full payload/delivery/contextMessages check: cron action=list)" >&2
else
  echo "" >&2
  echo "NOTE: could not confirm the three agent crons registered (runtime offline or slow)." >&2
  echo "Finish by messaging your Plow agent: \"set up the ld-morning-updates," >&2
  echo "ld-morning-triage, and ld-weekly-digest crons per each bundle's SKILL.md § Scheduling.\"" >&2
  echo "(ld-calendar-nudge and ld-weather auto-recur via scheduled/ and need no cron.)" >&2
fi
