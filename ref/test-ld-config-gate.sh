#!/usr/bin/env bash
#
# Contract test for ref/ld-config-gate.sh — the seed's ld_config_gate() that
# both install-bundles.sh and verify.sh source. Exercises the behavior THIS
# seed adds on top of the shared gate: the local family.owner.imessage check,
# the union/join with the shared-core failures, and the "not valid JSON"
# sentinel pass-through. Run AFTER sync-ld-shared.sh has materialized ld-shared.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=ref/ld-config-gate.sh
. "$HERE/ld-config-gate.sh"

pass=0
fail=0

# expect LABEL EXPECTED JSON  — feeds JSON through the real ld_config_gate().
expect() {
  local label="$1" want="$2" json="$3" tmp got
  tmp="$(mktemp)"
  printf '%s' "$json" > "$tmp"
  got="$(ld_config_gate "$tmp")"
  rm -f "$tmp"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf 'PASS - %s\n' "$label"
  else
    fail=$((fail + 1)); printf 'FAIL - %s\n      want: %q\n      got:  %q\n' "$label" "$want" "$got"
  fi
}

VALID='{"family":{"owner":{"name":"Sam","imessage":"sam@example.com"},"timezone":"America/Los_Angeles"},"calendar":{"sources":[{"account":"a@b.com","calendar_id":"primary"}]}}'
BLANK_IM='{"family":{"owner":{"name":"Sam","imessage":"   "},"timezone":"America/Los_Angeles"},"calendar":{"sources":[{"account":"a@b.com","calendar_id":"primary"}]}}'
PLACEHOLDER_AND_BLANK_IM='{"family":{"owner":{"name":"[OWNER_NAME]","imessage":""},"timezone":"America/Los_Angeles"},"calendar":{"sources":[{"account":"a@b.com","calendar_id":"primary"}]}}'
# Mixed calendar.sources array (object + bare string) — the shape the old inline
# jq filter errored on and SILENTLY treated as passing; the shared python gate
# correctly maps it to the sentinel.
MALFORMED_SOURCES='{"family":{"owner":{"name":"Sam","imessage":""}},"calendar":{"sources":[{"account":"  "},"x"]}}'

# A fully valid config (with imessage) passes — empty output.
expect "valid config with imessage passes" "" "$VALID"
# Shared core passes but imessage is blank → ONLY the local imessage failure.
expect "blank imessage reports only the imessage failure" \
  "family.owner.imessage is blank" "$BLANK_IM"
# Shared-core failure AND blank imessage → the UNION, shared first, joined by "; ".
expect "placeholder + blank imessage reports both, joined" \
  "an unfilled [UPPER_SNAKE] placeholder remains; family.owner.imessage is blank" \
  "$PLACEHOLDER_AND_BLANK_IM"
# Unparseable / filter-erroring shape → the sentinel passes through untouched
# (the imessage line is NOT appended). This is the edge case the old inline jq
# silently passed.
expect "malformed calendar.sources yields the sentinel (not a silent pass)" \
  "not valid JSON" "$MALFORMED_SOURCES"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
