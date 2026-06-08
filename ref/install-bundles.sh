#!/usr/bin/env bash
#
# seed-life-dashboard-agent — POST the vendored ld-* bundles to local
# plowd's install endpoint; land the relay's endpoint+token + the
# household ld-config in the agent-runtime dir so the bundles can run.
#
# Idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-
# with-rollback over the SINGLE multi-bundle transaction) and rewrites
# the two secret files. The ld-config is landed ONLY on first install
# (subsequent runs preserve operator edits); it comes from LD_CONFIG_SRC
# (a file path, `-` for stdin, or an `https://` URL) when set, otherwise
# from the vendored example.
#
# The bundle POST is GATED on REQUIRED ld-config fields only — owner
# name + imessage + at least one real calendar account. Optional fields
# (partner, extra people/calendars, long-lead type) may stay as
# placeholders so single-parent / single-calendar homes install
# unattended. A remaining required placeholder is a hard NON-ZERO stop.
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
# shellcheck source=ref/lib/ld_config.sh
. "$SEED_ROOT/ref/lib/ld_config.sh"
BUNDLES_DIR="$SEED_ROOT/ref/team-skills"
[ -d "$BUNDLES_DIR" ] || { echo "no $BUNDLES_DIR — vendor the bundles first" >&2; exit 1; }
LD_CONFIG_EXAMPLE="$BUNDLES_DIR/ld-shared/references/config.example.json"
[ -f "$LD_CONFIG_EXAMPLE" ] || { echo "no ld-config example at $LD_CONFIG_EXAMPLE" >&2; exit 1; }

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

# 6. Land ld-config (resolution + landing contract lives in
#    ref/lib/ld_config.sh so `just test` covers it). Three ways the file
#    gets populated, in priority: (a) already present -> preserve; (b)
#    LD_CONFIG_SRC -> consume a supplied config (file / `-` stdin /
#    https:// URL), JSON-validated AND required-field-gated BEFORE the
#    atomic mv so nothing bad lands; (c) neither -> copy the vendored
#    example. Config values are PII — never echoed.
ld_config_resolve_and_land "$LD_CONFIG" "$LD_CONFIG_EXAMPLE"

# REQUIRED-field placeholder gate (contract defined in ref/lib/ld_config.sh,
# shared with verify.sh). Emits the NAMES of unfilled required fields only —
# never the PII values — for an actionable message.
MISSING=$(ld_config_missing_required "$LD_CONFIG")
if [ -n "$MISSING" ]; then
  echo "" >&2
  echo "ld-config at $LD_CONFIG is missing REQUIRED household values:" >&2
  echo "$MISSING" | sed 's/^/  - /' >&2
  echo "" >&2
  echo "Fill these in (or supply a complete config via LD_CONFIG_SRC) and" >&2
  echo "re-run this install. Optional fields (partner, additional people," >&2
  echo "extra calendars, long-lead type) may be left as placeholders." >&2
  echo "The bundle install is GATED on the required fields — the bundles" >&2
  echo "would fail at their first scheduled tick otherwise." >&2
  echo "NOT installed." >&2
  exit 1
fi

# 7. POST ALL bundles in a single tarball + single Python call so
#    plowd's marketplace endpoint sees one transaction (atomic
#    rollback boundary). Matches plow4/justfile sync-team-skills shape.
#    Token + body via Python stdlib so neither lands in argv. The
#    no-redirect opener prevents plowd from forwarding Authorization
#    to another target on an upstream 30x — same pattern as
#    ld-shared/scripts/post_to_kiosk.py:_NoRedirect.
BUNDLE_NAMES=(ld-shared ld-calendar-nudge ld-morning-triage ld-morning-updates ld-weekly-digest)
for bundle in "${BUNDLE_NAMES[@]}"; do
  [ -d "$BUNDLES_DIR/$bundle" ] || {
    echo "missing vendored bundle: $bundle" >&2
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
echo "  5 bundles (ld-shared, ld-calendar-nudge, ld-morning-triage," >&2
echo "             ld-morning-updates, ld-weekly-digest) posted in one" >&2
echo "             transaction to plowd at $PLOWD_URL" >&2
echo "  dashboard-endpoint-url, dashboard-token landed in $SECRETS_DIR" >&2
echo "  ld-config resolved at $LD_CONFIG" >&2
echo "" >&2
echo "NOTE: three of the bundles (ld-morning-updates, ld-morning-triage," >&2
echo "ld-weekly-digest) need cron jobs registered via Plow's agent-side" >&2
echo "'cron action=add' verb after install — message your Plow agent to" >&2
echo "set up the morning-updates / morning-triage / weekly-digest crons" >&2
echo "per each bundle's SKILL.md § Scheduling. ld-calendar-nudge uses" >&2
echo "plowd's auto-activated scheduled/ entrypoint and needs no manual" >&2
echo "setup." >&2
