#!/usr/bin/env bash
#
# seed-life-dashboard-agent — POST the vendored ld-* bundles to local
# plowd's install endpoint; land the relay's endpoint+token in the
# agent-runtime secrets dir so the bundles can post cards.
#
# Idempotent: re-running re-POSTs every bundle (plowd does atomic-swap-
# with-rollback) and rewrites the two secret files.

set -euo pipefail

PLOW_BUNDLE_ID="${PLOW_BUNDLE_ID:-co.plow.app}"
APP_SUPPORT="$HOME/Library/Application Support/$PLOW_BUNDLE_ID"
LOCAL_TOKEN="$APP_SUPPORT/agent-runtime/secrets/plow-local-token"
RELAY_STATE="$HOME/Library/Application Support/seed-life-dashboard-relay/state.json"
SECRETS_DIR="$APP_SUPPORT/agent-runtime/secrets"

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

# 4. POST each bundle. Token + body via Python stdlib so neither lands
#    in argv (same shape as plow4/justfile's sync-team-skills).
SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BUNDLES_DIR="$SEED_ROOT/ref/team-skills"
[ -d "$BUNDLES_DIR" ] || { echo "no $BUNDLES_DIR — vendor the bundles first" >&2; exit 1; }

cd "$BUNDLES_DIR"
for bundle in ld-shared ld-calendar-nudge ld-morning-triage ld-morning-updates ld-weekly-digest; do
  [ -d "$bundle" ] || {
    echo "missing vendored bundle: $bundle" >&2
    exit 1
  }
  TARBALL=$(mktemp -t "agent-$bundle")
  tar czf "$TARBALL" "$bundle"
  TOKEN_PATH="$LOCAL_TOKEN" PLOWD_URL="$PLOWD_URL" TARBALL="$TARBALL" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
token = open(os.environ["TOKEN_PATH"]).read().strip()
body = open(os.environ["TARBALL"], "rb").read()
req = urllib.request.Request(
    os.environ["PLOWD_URL"],
    data=body,
    method="POST",
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/gzip"},
)
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        print(json.dumps(json.load(resp), indent=2))
except urllib.error.HTTPError as exc:
    sys.exit(f"install-local-bundles failed (HTTP {exc.code}): {exc.read().decode(errors='replace')[:500]}")
except (urllib.error.URLError, TimeoutError) as exc:
    sys.exit(f"install-local-bundles failed (network/timeout): {exc}")
PY
  rm -f "$TARBALL"
  echo "installed: $bundle" >&2
done

# 5. Land the relay's endpoint+token into agent-runtime/secrets. Atomic
#    write at mode 600. The values pass through jq → file; no echo, no
#    argv.
mkdir -p "$SECRETS_DIR"
for field in endpoint_url:dashboard-endpoint-url dashboard_token:dashboard-token; do
  jq_key="${field%%:*}"
  out_name="${field##*:}"
  TMP=$(mktemp -t "agent-secret")
  jq -re ".${jq_key}" "$RELAY_STATE" > "$TMP"
  chmod 600 "$TMP"
  mv "$TMP" "$SECRETS_DIR/$out_name"
done

echo "" >&2
echo "Agent installed:" >&2
echo "  5 bundles posted to plowd at $PLOWD_URL" >&2
echo "  dashboard-endpoint-url, dashboard-token landed in $SECRETS_DIR" >&2
