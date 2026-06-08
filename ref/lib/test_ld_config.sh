#!/usr/bin/env bash
# Behavioral tests for ref/lib/ld_config.sh — the install/verify ld-config
# landing + required-field gate. This is the operator-facing contract that
# `ref/install-bundles.sh` and `ref/verify.sh` both enforce, so it is the
# part that, if it regressed, would let a placeholder/empty/incomplete
# household config pass install and then break the bundles at their first
# scheduled tick. We assert the OBSERVABLE outcome of each scenario (did a
# file land? what fields did the gate name?), not internal call order.
#
# bash-3.2-safe; requires jq + python3 on PATH (same as the scripts).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$HERE/ld_config.sh"
EXAMPLE="$HERE/../team-skills/ld-shared/references/config.example.json"

passed=0
failed=0
check() {
  # check <label> <condition-rc>  (0 == pass)
  if [ "$2" = "0" ]; then
    passed=$((passed + 1))
    printf 'PASS - %s\n' "$1"
  else
    failed=$((failed + 1))
    printf 'FAIL - %s\n' "$1"
  fi
}

# A complete, gate-passing household config: every field the scheduled bundles
# throw-on-missing is filled (owner name/imessage, family.timezone, a source
# with real account+calendar_id, and both calendar_nudge lookaheads).
GOOD_CFG='{"family":{"owner":{"name":"Sam","imessage":"sam@example.com"},"timezone":"America/Los_Angeles"},
           "calendar":{"sources":[{"account":"sam@example.com","calendar_id":"primary"}]},
           "calendar_nudge":{"lookahead_virtual_minutes":30,"lookahead_in_person_minutes":60}}'

newdir() { mktemp -d "${TMPDIR:-/tmp}/ld-test.XXXXXX"; }

# ───────────────────────── gate: required fields ─────────────────────────
# One parametrized matrix: each row is (label, config-json, expected-substr).
# expected-substr empty means "gate must pass (emit nothing)".
# A reusable "everything else filled" prefix so each row varies only the
# field under test. ${GG} expands to the GOOD_CFG fields EXCEPT calendar, which
# each row appends so it can vary the sources.
GG='"family":{"owner":{"name":"Sam","imessage":"x@y"},"timezone":"America/Los_Angeles"},"calendar_nudge":{"lookahead_virtual_minutes":30,"lookahead_in_person_minutes":60}'
gate_cases=(
  "all required present -> passes|$GOOD_CFG|"
  "minimal complete (GG prefix + one real source) -> passes|{$GG,\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|"
  "placeholder owner.name rejected|{\"family\":{\"owner\":{\"name\":\"[OWNER_NAME]\",\"imessage\":\"x@y\"},\"timezone\":\"America/Los_Angeles\"},\"calendar_nudge\":{\"lookahead_virtual_minutes\":30,\"lookahead_in_person_minutes\":60},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|family.owner.name"
  "placeholder owner.imessage rejected|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"[OWNER_IMESSAGE]\"},\"timezone\":\"America/Los_Angeles\"},\"calendar_nudge\":{\"lookahead_virtual_minutes\":30,\"lookahead_in_person_minutes\":60},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|family.owner.imessage"
  "missing family.timezone rejected|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar_nudge\":{\"lookahead_virtual_minutes\":30,\"lookahead_in_person_minutes\":60},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|family.timezone"
  "empty account rejected|{$GG,\"calendar\":{\"sources\":[{\"account\":\"\",\"calendar_id\":\"primary\"}]}}|calendar.sources[].account"
  "placeholder account among real rows rejected|{$GG,\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"},{\"account\":\"[CALENDAR_ACCOUNT_2]\",\"calendar_id\":\"primary\"}]}}|calendar.sources[].account"
  "missing calendar_id rejected|{$GG,\"calendar\":{\"sources\":[{\"account\":\"a@b\"}]}}|calendar.sources[].calendar_id"
  "placeholder calendar_id rejected|{$GG,\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"[FAMILY_CALENDAR_ID]\"}]}}|calendar.sources[].calendar_id"
  "zero calendar sources rejected|{$GG,\"calendar\":{\"sources\":[]}}|calendar.sources (need at least one"
  "all-self:false sources rejected (no owner identity)|{$GG,\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\",\"self\":false}]}}|calendar.sources[].self"
  "mixed self:false + one owner source passes|{$GG,\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\",\"self\":false},{\"account\":\"c@d\",\"calendar_id\":\"primary\"}]}}|"
  "missing lookahead_virtual_minutes rejected|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"},\"timezone\":\"America/Los_Angeles\"},\"calendar_nudge\":{\"lookahead_in_person_minutes\":60},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|calendar_nudge.lookahead_virtual_minutes"
  "non-numeric lookahead_in_person_minutes rejected|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"},\"timezone\":\"America/Los_Angeles\"},\"calendar_nudge\":{\"lookahead_virtual_minutes\":30,\"lookahead_in_person_minutes\":\"60\"},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|calendar_nudge.lookahead_in_person_minutes"
  "optional placeholders (partner/people/long_lead) allowed|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"},\"timezone\":\"America/Los_Angeles\",\"partner\":{\"name\":\"[PARTNER_NAME]\"},\"people\":[\"[FAMILY_PERSON_1]\"]},\"calendar_nudge\":{\"lookahead_virtual_minutes\":30,\"lookahead_in_person_minutes\":60},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]},\"weekly_digest\":{\"long_lead\":[{\"type\":\"[LONG_LEAD_TYPE]\"}]}}|"
)
for row in "${gate_cases[@]}"; do
  label="${row%%|*}"; rest="${row#*|}"
  cfg="${rest%|*}"; want="${rest##*|}"
  f="$(newdir)/c.json"; printf '%s' "$cfg" > "$f"
  out="$(ld_config_missing_required "$f")"
  if [ -z "$want" ]; then
    [ -z "$out" ]; check "$label" "$?"
  else
    case "$out" in *"$want"*) check "$label" 0 ;; *) check "$label" 1 ;; esac
  fi
done

# The vendored example must FAIL the gate (it ships placeholders for the
# operator to fill) — proves the example and the gate stay in lockstep.
out="$(ld_config_missing_required "$EXAMPLE")"
[ -n "$out" ]; check "vendored example fails the gate (placeholders unfilled)" "$?"

# ──────────────────── landing: resolve_and_land paths ────────────────────

# (b) file source, gate-passing -> lands the file.
d="$(newdir)"; printf '%s' "$GOOD_CFG" > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ -f "$d/ld/config.json" ]; check "LD_CONFIG_SRC=file lands a complete config" "$?"

# (b) stdin source (`-`), gate-passing -> lands the piped bytes.
d="$(newdir)"
printf '%s' "$GOOD_CFG" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ -f "$d/ld/config.json" ]; check "LD_CONFIG_SRC=- reads config from stdin" "$?"

# (b) invalid JSON -> non-zero, NO file written.
d="$(newdir)"; printf 'not json{' > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
rc=$?
[ "$rc" != "0" ] && [ ! -f "$d/ld/config.json" ]; check "invalid JSON exits non-zero and writes nothing" "$?"

# (b) valid JSON but gate-failing supplied config -> non-zero, NO file
#     written (so a corrected retry isn't short-circuited by a bad file).
d="$(newdir)"
printf '{"family":{"owner":{"name":"[OWNER_NAME]","imessage":"x@y"}},"calendar":{"sources":[{"account":"a@b"}]}}' > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
rc=$?
[ "$rc" != "0" ] && [ ! -f "$d/ld/config.json" ]; check "incomplete supplied config is gated before landing (no write)" "$?"

# (c) no source -> copy the vendored example (lands placeholders to edit).
d="$(newdir)"
unset LD_CONFIG_SRC
ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ -f "$d/ld/config.json" ]; check "no LD_CONFIG_SRC copies the vendored example" "$?"

# (a) existing GATE-PASSING config preserved verbatim (re-run safety) even with
#     a source set — the operator's landed edits are canonical, never clobbered.
d="$(newdir)"; mkdir -p "$d/ld"
existing='{"family":{"owner":{"name":"Operator","imessage":"op@example.com"},"timezone":"America/New_York"},"calendar":{"sources":[{"account":"op@example.com","calendar_id":"primary"}]},"calendar_nudge":{"lookahead_virtual_minutes":15,"lookahead_in_person_minutes":45}}'
printf '%s' "$existing" > "$d/ld/config.json"
printf '%s' "$GOOD_CFG" > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$existing" ]; check "existing gate-passing config is preserved (operator edits canonical)" "$?"

# (a→b) retry path: a first run with no LD_CONFIG_SRC lands the gate-FAILING
#       placeholder example; a retry WITH a corrected LD_CONFIG_SRC must consume
#       it and replace the bad landed file (not short-circuit on its existence).
d="$(newdir)"
unset LD_CONFIG_SRC
ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1   # lands placeholder example (gate-failing)
[ -n "$(ld_config_missing_required "$d/ld/config.json")" ]                  # sanity: landed file fails the gate
landed_fails=$?
printf '%s' "$GOOD_CFG" > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$landed_fails" = "0" ] && [ -z "$(ld_config_missing_required "$d/ld/config.json")" ]
check "gate-failing landed config is replaced by a corrected LD_CONFIG_SRC retry" "$?"

# ─────────────── verify.sh consumes the SAME gate as install ───────────────
# verify.sh sources ld_config.sh and runs ld_config_missing_required at its
# v-ld-config step, so a gate-passing config must reach "OK   v-ld-config"
# and a gate-failing one must not. We drive the REAL verify.sh against a
# fixture HOME tree (complete secrets + the config under test). verify.sh's
# mode-600 check uses `stat -f '%Lp'` (macOS); on a non-Darwin host we shim
# a tiny `stat` wrapper onto PATH that maps `-f '%Lp'` to GNU `stat -c '%a'`
# so the run reaches v-ld-config — the step this test actually exercises.
run_verify() {  # run_verify <config-json> -> prints verify.sh output
  local cfg="$1" d secrets lddir shim
  d="$(newdir)"
  secrets="$d/home/Library/Application Support/co.plow.app/agent-runtime/secrets"
  lddir="$d/home/Library/Application Support/co.plow.app/agent-runtime/runtime/ld"
  mkdir -p "$secrets" "$lddir"
  printf 'https://x.test/api/message' > "$secrets/dashboard-endpoint-url"; chmod 600 "$secrets/dashboard-endpoint-url"
  printf 'tok' > "$secrets/dashboard-token"; chmod 600 "$secrets/dashboard-token"
  printf '%s' "$cfg" > "$lddir/config.json"
  shim="$d/bin"; mkdir -p "$shim"
  if [ "$(uname -s)" != "Darwin" ]; then
    cat > "$shim/stat" <<'SH'
#!/usr/bin/env bash
# Map BSD `stat -f '%Lp' <f>` (octal mode) to GNU `stat -c '%a' <f>`.
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then exec /usr/bin/stat -c '%a' "$3"; fi
exec /usr/bin/stat "$@"
SH
    chmod +x "$shim/stat"
  fi
  HOME="$d/home" PATH="$shim:$PATH" bash "$HERE/../verify.sh" 2>&1
}

out="$(run_verify '{"family":{"owner":{"name":"[OWNER_NAME]","imessage":"[OWNER_IMESSAGE]"}},"calendar":{"sources":[]}}')"
case "$out" in *"OK   v-ld-config"*) check "verify.sh rejects an incomplete ld-config (shares the gate)" 1 ;;
              *) check "verify.sh rejects an incomplete ld-config (shares the gate)" 0 ;; esac

out="$(run_verify "$GOOD_CFG")"
case "$out" in *"OK   v-ld-config"*) check "verify.sh accepts a complete ld-config (shares the gate)" 0 ;;
              *) check "verify.sh accepts a complete ld-config (shares the gate)" 1 ;; esac

# ───────────────────────────── summary ─────────────────────────────
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
