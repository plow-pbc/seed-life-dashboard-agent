#!/usr/bin/env bash
#
# The seed's minimal structural ld-config gate, sourced by BOTH
# ref/install-bundles.sh (the install-time + pre-cron gate) and ref/verify.sh
# (the v-ld-config assertion) so they enforce one identical contract and can
# never drift.
#
# The UNIVERSAL core (family.owner.name non-blank, calendar.sources a non-empty
# array, no blank source account, no leftover [UPPER_SNAKE] placeholder) is
# single-homed in the shared ld-shared gate
# (plow-pbc/life-dashboard-skills :: scripts/ld_config_gate.py), materialized
# under ref/team-skills/ld-shared/ by sync-ld-shared.sh. On top of that shared
# core this seed adds ONE Plow-specific invariant — family.owner.imessage
# non-blank — because this seed delivers via iMessage and its producers read
# owner.imessage (the Hermes seed delivers via plow_chat, so the shared gate
# deliberately omits it).
#
# ld_config_gate FILE -> prints the failing invariant name(s) joined by "; ";
# empty output == PASS. Never prints the PII values, only the invariant names.
# Requires jq + python3 (callers already require both). Source this AFTER
# sync-ld-shared.sh has materialized ld-shared.

# Resolve the shared gate relative to THIS file (ref/) so install, verify, and
# the test all locate the same materialized copy.
LD_CONFIG_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LD_SHARED_GATE="$LD_CONFIG_GATE_DIR/team-skills/ld-shared/scripts/ld_config_gate.py"

ld_config_gate() {  # ld_config_gate FILE -> prints failures (empty == pass)
  [ -f "$LD_SHARED_GATE" ] || {
    echo "shared ld-config gate not found at $LD_SHARED_GATE — ld-shared not synced; run sync-ld-shared.sh / install first" >&2
    return 1
  }
  # Universal core: delegate to the shared gate (single source of truth).
  local fails
  fails=$(python3 "$LD_SHARED_GATE" "$1")
  # When the file does not parse (or its shape would error the universal
  # checks) the shared gate emits exactly "not valid JSON"; the imessage
  # check is redundant then, so pass that sentinel through untouched.
  if [ "$fails" != "not valid JSON" ] \
     && [ "$(jq -r '(.family.owner.imessage // "") | test("\\S")' "$1" 2>/dev/null)" != "true" ]; then
    # Plow-specific addition: owner.imessage must be non-blank (this seed's
    # iMessage producers require it). jq is already a required tool here.
    fails="${fails:+$fails; }family.owner.imessage is blank"
  fi
  printf '%s' "$fails"
}
