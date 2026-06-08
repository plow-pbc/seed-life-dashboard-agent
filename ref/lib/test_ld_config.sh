#!/usr/bin/env bash
# Behavioral tests for ref/lib/ld_config.sh — the install/verify ld-config
# landing + minimal install gate. This is the operator-facing contract that
# `ref/install-bundles.sh` and `ref/verify.sh` both enforce, so it is the
# part that, if it regressed, would let an unedited/malformed household config
# pass install. The minimal gate checks two structural invariants:
# calendar.sources is a non-empty array, and no [UPPER_SNAKE] placeholder
# survives anywhere. We assert the OBSERVABLE outcome of each scenario (did a
# file land with the right bytes + mode? what did the gate name?), not internal
# call order.
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

# A filled, gate-passing household config: no [UPPER_SNAKE] placeholders remain
# and calendar.sources is a non-empty array.
GOOD_CFG='{"family":{"owner":{"name":"Sam","imessage":"sam@example.com"},"timezone":"America/Los_Angeles"},
           "calendar":{"sources":[{"account":"sam@example.com","calendar_id":"primary"}]},
           "calendar_nudge":{"lookahead_virtual_minutes":30,"lookahead_in_person_minutes":60}}'

newdir() { mktemp -d "${TMPDIR:-/tmp}/ld-test.XXXXXX"; }

# ─────────────────────────── minimal gate matrix ───────────────────────────
# One parametrized matrix: each row is (label, config-json, expected-substr).
# expected-substr empty means "gate must pass (emit nothing)". The minimal gate
# enforces exactly two invariants: calendar.sources is a non-empty array, and
# no [UPPER_SNAKE] placeholder survives anywhere. Per-field requirements
# (timezone, lookaheads, owner source) are enforced at runtime by the bundles,
# NOT by this gate — so a config that omits them still passes here.
gate_cases=(
  "filled config (no placeholders, non-empty sources array) -> passes|$GOOD_CFG|"
  "single-parent / single-calendar (minimal filled) -> passes|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|"
  "any remaining [UPPER_SNAKE] placeholder rejected (owner)|{\"family\":{\"owner\":{\"name\":\"[OWNER_NAME]\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|[UPPER_SNAKE] placeholders"
  "placeholder anywhere rejected (calendar account)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"[CALENDAR_ACCOUNT]\",\"calendar_id\":\"primary\"}]}}|[UPPER_SNAKE] placeholders"
  "placeholder in an OPTIONAL section still rejected (no template residue)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"},\"partner\":{\"name\":\"[PARTNER_NAME]\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|[UPPER_SNAKE] placeholders"
  "non-array calendar.sources rejected (object-valued)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":{\"account\":\"a@b\",\"calendar_id\":\"primary\"}}}|must be a non-empty array"
  "empty calendar.sources array rejected|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[]}}|need at least one"
  "missing calendar.sources rejected (null is not an array)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}}}|must be a non-empty array"
  "vendored example with empty optionals -> only owner+account placeholders block|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"},\"partner\":null,\"people\":[]},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]},\"weekly_digest\":{\"long_lead\":[]}}|"
  # The gate DELIBERATELY does not check per-field runtime requirements — these
  # pin the loosened half so a future re-tightening trips a test. Each is a
  # config the bundles would later reject at runtime but the install gate passes.
  "source missing calendar_id -> passes the gate (runtime-deferred)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\"}]}}|"
  "all-self:false sources -> passes the gate (runtime-deferred)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\",\"self\":false}]}}|"
  # A real value that merely CONTAINS a bracketed token is NOT a placeholder —
  # the match is anchored to whole-string placeholders only.
  "value containing a bracketed token is not a placeholder -> passes|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\",\"name\":\"Work [TEAM]\"}]}}|"
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

# Octal mode of a file, portable across GNU (-c %a) and BSD/macOS (-f %Lp) stat.
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# (b) file source, gate-passing -> lands the EXACT supplied bytes at mode 600.
d="$(newdir)"; printf '%s' "$GOOD_CFG" > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$GOOD_CFG" ] && [ "$(filemode "$d/ld/config.json")" = "600" ]
check "LD_CONFIG_SRC=file lands the supplied bytes verbatim at mode 600" "$?"

# (b) stdin source (`-`), gate-passing -> lands the EXACT piped bytes at mode 600.
d="$(newdir)"
printf '%s' "$GOOD_CFG" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$GOOD_CFG" ] && [ "$(filemode "$d/ld/config.json")" = "600" ]
check "LD_CONFIG_SRC=- lands the piped bytes verbatim at mode 600" "$?"

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
