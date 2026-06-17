#!/usr/bin/env bash
#
# Materialize ref/team-skills/ld-shared from the canonical shared repo
# (plow-pbc/life-dashboard-skills). ld-shared is NOT vendored in this seed —
# it is gitignored. It is the shared contract layer BOTH life-dashboard agent
# seeds pull (the kiosk-POST helper + the wire/tile protocol + the ld-config
# template), so a fix lands once upstream instead of being hand-applied to two
# repos. This seed owns only its six platform-specific producers.
#
# Idempotent: re-running refreshes the pinned ref. Overridable for dev/CI:
#   LD_SKILLS_REPO  — clone source (default: the public GitHub repo)
#   LD_SKILLS_REF   — branch or tag to pull (default: main)

set -euo pipefail

REPO="${LD_SKILLS_REPO:-https://github.com/plow-pbc/life-dashboard-skills}"
REF="${LD_SKILLS_REF:-main}"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/team-skills" && pwd)/ld-shared"

command -v git >/dev/null || { echo "sync-ld-shared: git is required" >&2; exit 1; }

# Reject a credential-bearing LD_SKILLS_REPO: userinfo in ANY scheme URL
# (scheme://user:pass@host — http(s), ssh, git, …) would surface in git's argv
# (visible in `ps`) and in the status/error messages below; a query/fragment has
# no place in a clone URL. An scp-style SSH URL (git@host:path — no `://`)
# carries no secret and is left alone. Same posture install-bundles.sh applies to
# DASHBOARD_ENDPOINT_URL.
case "$REPO" in
  *://*)
    _auth="${REPO#*://}"; _auth="${_auth%%/*}"
    case "$_auth" in
      *@*) echo "sync-ld-shared: LD_SKILLS_REPO must not contain userinfo (user:pass@); use a credential-free URL" >&2; exit 1 ;;
    esac ;;
esac
case "$REPO" in
  *\?*|*"#"*) echo "sync-ld-shared: LD_SKILLS_REPO must not contain a query or fragment" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 --branch "$REF" "$REPO" "$TMP" >/dev/null 2>&1 \
  || { echo "sync-ld-shared: failed to clone $REPO@$REF" >&2; exit 1; }

# The shared repo root IS the ld-shared payload: scripts/ (post_to_kiosk.py +
# its tests) and references/ (kiosk-protocol.md, config.example.json,
# connectors.md). Replace the destination wholesale so a removed upstream file
# does not linger.
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/scripts" "$TMP/references" "$DEST/"
echo "sync-ld-shared: materialized ld-shared from $REPO@$REF" >&2
