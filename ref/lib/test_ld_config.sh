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
. "$HERE/detect-timezone.sh"
EXAMPLE="$HERE/../team-skills/ld-shared/references/config.example.json"
# The zone install/verify autodetect on THIS host. The real install-bundles.sh
# and verify.sh pass it to the gate, so the integration fixtures below must
# carry it (a config landed with a different zone would fail the tz check) —
# keeping these tests hermetic across hosts regardless of /etc/localtime.
HOST_TZ="$(ld_detect_timezone)"

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
  "vendored example with empty optionals -> only owner+account placeholders block|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"},\"partner\":null},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]},\"weekly_digest\":{\"long_lead\":[]}}|"
  # The gate DELIBERATELY does not check per-field runtime requirements — these
  # pin the loosened half so a future re-tightening trips a test. Each is a
  # config the bundles would later reject at runtime but the install gate passes.
  "source missing calendar_id -> passes the gate (runtime-deferred)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\"}]}}|"
  "all-self:false sources -> passes the gate (runtime-deferred)|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\",\"self\":false}]}}|"
  # A real value that merely CONTAINS a bracketed token is NOT a placeholder —
  # the match is anchored to whole-string placeholders only.
  "value containing a bracketed token is not a placeholder -> passes|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\",\"name\":\"Work [TEAM]\"}]}}|"
  # Non-blank owner identity + calendar account — the gate rejects whitespace-
  # only / missing values, not just empty strings (mirrors the umbrella's
  # v-config contract for the config this SEED assembles).
  "blank owner name rejected|{\"family\":{\"owner\":{\"name\":\"  \",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|family.owner.name"
  "missing owner imessage rejected|{\"family\":{\"owner\":{\"name\":\"Sam\"}},\"calendar\":{\"sources\":[{\"account\":\"a@b\",\"calendar_id\":\"primary\"}]}}|family.owner.imessage"
  "blank calendar account rejected|{\"family\":{\"owner\":{\"name\":\"Sam\",\"imessage\":\"x@y\"}},\"calendar\":{\"sources\":[{\"account\":\"   \",\"calendar_id\":\"primary\"}]}}|calendar.sources[].account"
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

# timezone match: when the caller passes an expected zone (install/verify pass
# the host-autodetected one), family.timezone MUST equal it — so a tz regression
# can't ship a wrong local time and still pass. Without the arg the check is
# skipped (the structural matrix above runs zone-agnostic).
f="$(newdir)/c.json"; printf '%s' "$GOOD_CFG" > "$f"   # GOOD_CFG zone is America/Los_Angeles
out="$(ld_config_missing_required "$f" "America/New_York")"
case "$out" in *"family.timezone"*) check "gate flags a timezone != expected zone" 0 ;; *) check "gate flags a timezone != expected zone" 1 ;; esac
out="$(ld_config_missing_required "$f" "America/Los_Angeles")"
[ -z "$out" ]; check "gate passes when family.timezone equals expected zone" "$?"

# ─────────────────────── assembly: ld_config_assemble ───────────────────────
# The single-shot path: 3 scalar inputs in (owner name/handle, calendar
# account) + an autodetected zone -> a complete, gate-PASSING household config
# that mirrors the example shape. PII is fed to jq over stdin, never argv.
out="$(LD_OWNER_NAME="Sam Odio" LD_OWNER_IMESSAGE="+15551234567" LD_CALENDAR_ACCOUNT="cal@example.com" \
       ld_config_assemble "$EXAMPLE" "America/New_York")"
asm="$(newdir)/asm.json"; printf '%s' "$out" > "$asm"
[ -z "$(ld_config_missing_required "$asm" "America/New_York")" ]
check "assembled config from inputs passes the gate (incl. tz match)" "$?"
# The three inputs land where expected; the autodetected zone is used verbatim.
[ "$(jq -r '.family.owner.name' "$asm")" = "Sam Odio" ] \
  && [ "$(jq -r '.family.owner.imessage' "$asm")" = "+15551234567" ] \
  && [ "$(jq -r '.calendar.sources[0].account' "$asm")" = "cal@example.com" ] \
  && [ "$(jq -r '.family.timezone' "$asm")" = "America/New_York" ]
check "assembled config places each input + autodetected zone correctly" "$?"
# A blank/missing input fails loud, non-zero, with no output config.
out="$(LD_OWNER_NAME="  " LD_OWNER_IMESSAGE="x@y" LD_CALENDAR_ACCOUNT="a@b" ld_config_assemble "$EXAMPLE" "UTC" 2>/dev/null)"; rc=$?
[ "$rc" != "0" ] && [ -z "$out" ]; check "assembly fails non-zero on a blank input" "$?"
# An embedded newline would shift the newline-split indices and silently land a
# corrupted config — assembly must reject a multi-line value loud, non-zero.
out="$(LD_OWNER_NAME="$(printf 'Sam\nInjected')" LD_OWNER_IMESSAGE="x@y" LD_CALENDAR_ACCOUNT="a@b" ld_config_assemble "$EXAMPLE" "UTC" 2>/dev/null)"; rc=$?
[ "$rc" != "0" ] && [ -z "$out" ]; check "assembly rejects an input with an embedded newline (no silent corruption)" "$?"

# ──────────────────── landing: resolve_and_land paths ────────────────────

# Octal mode of a file, portable across GNU (-c %a) and BSD/macOS (-f %Lp) stat.
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Build a deterministic PATH for running the REAL verify.sh / install-bundles.sh
# against a fixture HOME, so these integration tests pass in ANY environment
# (clean CI containers included) instead of only on a dev host that happens to
# have every host tool installed. Prints the PATH to use.
#
# The fixture <dir>/bin is PREPENDED to the real PATH (not a replacement) so the
# real `jq` and coreutils stay reachable — `jq` is actually USED (it parses
# relay-state + the ld-config and detects placeholders), so it must be
# functional, not a stub. We add two kinds of fixture entries:
#   1. a `stat` shim that maps BSD `stat -f '%Lp'` (the mode-600 check both
#      scripts run, macOS-shaped) to GNU `stat -c '%a'`, on non-Darwin hosts;
#   2. empty stubs for the tools install-bundles.sh only `command -v`-checks at
#      its preflight but never executes before the ld-config gate the test
#      exercises (tar/lsof/pgrep/python3/awk) — so the preflight passes even on
#      a host where those aren't installed.
fixture_path() {  # fixture_path <dir> -> prints PATH with fixture bin prepended
  local bin="$1/bin" t
  mkdir -p "$bin"
  for t in tar lsof pgrep python3 awk; do
    command -v "$t" >/dev/null 2>&1 || { printf '#!/bin/sh\n' > "$bin/$t"; chmod +x "$bin/$t"; }
  done
  if [ "$(uname -s)" != "Darwin" ]; then
    cat > "$bin/stat" <<'SH'
#!/usr/bin/env bash
# Map BSD `stat -f '%Lp' <f>` (octal mode) to GNU `stat -c '%a' <f>`.
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then exec /usr/bin/stat -c '%a' "$3"; fi
exec /usr/bin/stat "$@"
SH
    chmod +x "$bin/stat"
  fi
  printf '%s:%s' "$bin" "$PATH"
}

# (b-default) inputs in env, no LD_CONFIG_SRC -> ASSEMBLE + land a gate-passing
#     config at mode 600 with the autodetected zone the caller passes.
d="$(newdir)"
unset LD_CONFIG_SRC
LD_OWNER_NAME="Sam" LD_OWNER_IMESSAGE="+15551234567" LD_CALENDAR_ACCOUNT="cal@example.com" \
  ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" "America/New_York" >/dev/null 2>&1
[ -z "$(ld_config_missing_required "$d/ld/config.json" "America/New_York")" ] \
  && [ "$(filemode "$d/ld/config.json")" = "600" ] \
  && [ "$(jq -r '.calendar.sources[0].account' "$d/ld/config.json")" = "cal@example.com" ]
check "inputs in env assemble + land a gate-passing config at mode 600" "$?"

# (a→b-default) a gate-FAILING landed config (placeholder example) must be
#     REPLACED by a fresh assembly when the inputs are set on a rerun — not
#     short-circuited on its existence.
d="$(newdir)"
unset LD_CONFIG_SRC
ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" "America/New_York" >/dev/null 2>&1  # lands placeholder (gate-failing)
[ -n "$(ld_config_missing_required "$d/ld/config.json" "America/New_York")" ]; landed_fails=$?
LD_OWNER_NAME="Sam" LD_OWNER_IMESSAGE="x@y" LD_CALENDAR_ACCOUNT="a@b" \
  ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" "America/New_York" >/dev/null 2>&1
[ "$landed_fails" = "0" ] && [ -z "$(ld_config_missing_required "$d/ld/config.json" "America/New_York")" ]
check "gate-failing landed config is replaced by a fresh assembly from inputs" "$?"

# (a) a structurally-valid existing config whose TIMEZONE differs from the
#     current host zone is PRESERVED, even with inputs set on a rerun — a zone
#     drift (laptop moved / hand-set zone) must not discard the whole config and
#     all of the operator's other edits. The preservation gate omits the
#     tz-match; only a fresh assembly enforces the host zone.
d="$(newdir)"; mkdir -p "$d/ld"
drifted='{"family":{"owner":{"name":"Operator","imessage":"op@example.com"},"timezone":"Europe/Berlin"},"calendar":{"sources":[{"account":"op@example.com","calendar_id":"primary"}]}}'
printf '%s' "$drifted" > "$d/ld/config.json"
unset LD_CONFIG_SRC
LD_OWNER_NAME="Sam" LD_OWNER_IMESSAGE="x@y" LD_CALENDAR_ACCOUNT="a@b" \
  ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" "America/New_York" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$drifted" ]
check "existing valid config with a drifted timezone is preserved, not reassembled" "$?"

# (b-escape) a config supplied via LD_CONFIG_SRC=- with a NON-host timezone is
#     accepted — the escape hatch trusts the caller's zone (a remote/headless
#     caller may supply a config for a different host). The tz-match is enforced
#     only on the assemble path, not the supplied-config path.
d="$(newdir)"
foreign='{"family":{"owner":{"name":"Sam","imessage":"x@y"},"timezone":"Asia/Tokyo"},"calendar":{"sources":[{"account":"a@b","calendar_id":"primary"}]}}'
printf '%s' "$foreign" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" "America/New_York" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$foreign" ]
check "LD_CONFIG_SRC=- accepts a supplied config with a non-host timezone (escape hatch trusts caller)" "$?"

# (b) stdin source (`-`), gate-passing -> lands the EXACT piped bytes at mode 600.
d="$(newdir)"
printf '%s' "$GOOD_CFG" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$GOOD_CFG" ] && [ "$(filemode "$d/ld/config.json")" = "600" ]
check "LD_CONFIG_SRC=- lands the piped bytes verbatim at mode 600" "$?"

# (b) invalid JSON via stdin -> non-zero, NO file written.
d="$(newdir)"
printf 'not json{' | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
rc=$?
[ "$rc" != "0" ] && [ ! -f "$d/ld/config.json" ]; check "invalid JSON via stdin exits non-zero and writes nothing" "$?"

# (b) a non-`-` LD_CONFIG_SRC value is rejected loud -> non-zero, NO file
#     written. Pins the removal of the file-path supply arm (stdin-only).
d="$(newdir)"; printf '%s' "$GOOD_CFG" > "$d/src.json"
LD_CONFIG_SRC="$d/src.json" ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
rc=$?
[ "$rc" != "0" ] && [ ! -f "$d/ld/config.json" ]; check "non-'-' LD_CONFIG_SRC is rejected non-zero and writes nothing" "$?"

# (b) valid JSON but gate-failing supplied config (via stdin) -> non-zero, NO
#     file written (so a corrected retry isn't short-circuited by a bad file).
d="$(newdir)"
printf '{"family":{"owner":{"name":"[OWNER_NAME]","imessage":"x@y"}},"calendar":{"sources":[{"account":"a@b"}]}}' \
  | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
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
printf '%s' "$GOOD_CFG" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$existing" ]; check "existing gate-passing config is preserved (operator edits canonical)" "$?"

# (a→b) retry path: a first run with no LD_CONFIG_SRC lands the gate-FAILING
#       placeholder example; a retry WITH a corrected LD_CONFIG_SRC must consume
#       it and replace the bad landed file (not short-circuit on its existence).
d="$(newdir)"
unset LD_CONFIG_SRC
ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1   # lands placeholder example (gate-failing)
[ -n "$(ld_config_missing_required "$d/ld/config.json")" ]                  # sanity: landed file fails the gate
landed_fails=$?
printf '%s' "$GOOD_CFG" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$landed_fails" = "0" ] && [ -z "$(ld_config_missing_required "$d/ld/config.json")" ]
check "gate-failing landed config is replaced by a corrected LD_CONFIG_SRC retry" "$?"

# (a→b) a MALFORMED-JSON existing dest must NOT be treated as gate-passing: the
#       gate exits non-zero with empty stdout on bad JSON, so without the exit-
#       status check the preserve branch would short-circuit and keep the corrupt
#       file. With LD_CONFIG_SRC set, it must fall through and replace it.
d="$(newdir)"; mkdir -p "$d/ld"
printf 'not json{' > "$d/ld/config.json"
printf '%s' "$GOOD_CFG" | LD_CONFIG_SRC=- ld_config_resolve_and_land "$d/ld/config.json" "$EXAMPLE" >/dev/null 2>&1
[ "$(cat "$d/ld/config.json")" = "$GOOD_CFG" ]
check "malformed-JSON existing config is replaced by a valid LD_CONFIG_SRC" "$?"

# ─────────────── verify.sh consumes the SAME gate as install ───────────────
# verify.sh sources ld_config.sh and runs ld_config_missing_required at its
# v-ld-config step, so a gate-passing config must reach "OK   v-ld-config"
# and a gate-failing one must not. We drive the REAL verify.sh against a
# fixture HOME tree (complete secrets + the config under test). verify.sh's
# mode-600 check uses `stat -f '%Lp'` (macOS); on a non-Darwin host we shim
# a tiny `stat` wrapper onto PATH that maps `-f '%Lp'` to GNU `stat -c '%a'`
# so the run reaches v-ld-config — the step this test actually exercises.
run_verify() {  # run_verify <config-json> -> prints verify.sh output
  local cfg="$1" d secrets lddir
  d="$(newdir)"
  secrets="$d/home/Library/Application Support/co.plow.app/agent-runtime/secrets"
  lddir="$d/home/Library/Application Support/co.plow.app/agent-runtime/runtime/ld"
  mkdir -p "$secrets" "$lddir"
  printf 'https://x.test/api/message' > "$secrets/dashboard-endpoint-url"; chmod 600 "$secrets/dashboard-endpoint-url"
  printf 'tok' > "$secrets/dashboard-token"; chmod 600 "$secrets/dashboard-token"
  # Stamp the host-autodetected zone into the fixture so a gate-passing config
  # also passes verify.sh's tz check (it autodetects + asserts the same zone).
  printf '%s' "$cfg" | jq --arg tz "$HOST_TZ" '.family.timezone = $tz' > "$lddir/config.json"
  HOME="$d/home" PATH="$(fixture_path "$d")" bash "$HERE/../verify.sh" 2>&1
}

out="$(run_verify '{"family":{"owner":{"name":"[OWNER_NAME]","imessage":"[OWNER_IMESSAGE]"}},"calendar":{"sources":[]}}')"; rc=$?
case "$out" in *"OK   v-ld-config"*) check "verify.sh rejects an incomplete ld-config (shares the gate)" 1 ;;
              *) check "verify.sh rejects an incomplete ld-config (shares the gate)" 0 ;; esac
# The non-zero exit is the operator/CI contract verify.sh promises on a failed
# gate — assert it, not just the absent OK line, so a regression to exit 0
# (the original false-success bug) fails here too.
check "verify.sh exits non-zero on an incomplete ld-config" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

out="$(run_verify "$GOOD_CFG")"
case "$out" in *"OK   v-ld-config"*) check "verify.sh accepts a complete ld-config (shares the gate)" 0 ;;
              *) check "verify.sh accepts a complete ld-config (shares the gate)" 1 ;; esac

# ─────────── the REAL installer gates before any marketplace POST ───────────
# The unit cases above drive ld_config.sh directly; this one runs the actual
# ref/install-bundles.sh end-to-end against a fixture HOME so the installer's
# ORIGINAL false-success bug (POSTing bundles despite an unfilled config) can't
# silently regress. With a placeholder config landed and NO LD_CONFIG_SRC, the
# installer must reach its step-6 gate, exit non-zero with "NOT installed.",
# and NEVER reach the step-7 marketplace POST. We point dev-plowd-port at a
# closed port so that IF the gate ever wrongly passed, the POST would still
# fail loudly (no live plowd) rather than mutate anything — but the assertion
# is that the gate stops it first. Config values are PII — never echoed.
d="$(newdir)"; hdir="$d/home"
appsupport="$hdir/Library/Application Support/co.plow.app"
secrets="$appsupport/agent-runtime/secrets"
lddir="$appsupport/agent-runtime/runtime/ld"
relaydir="$hdir/Library/Application Support/seed-life-dashboard-relay"
mkdir -p "$secrets" "$lddir" "$relaydir"
printf 'fake-local-token' > "$secrets/plow-local-token"; chmod 600 "$secrets/plow-local-token"
printf '{"endpoint_url":"https://x.test","dashboard_token":"tok"}' > "$relaydir/state.json"
chmod 600 "$relaydir/state.json"
# A closed, never-listening port: the gate must stop the run before any POST,
# but if it didn't, the connect would fail loudly instead of hitting real plowd.
printf '9' > "$appsupport/dev-plowd-port"
# Land a placeholder (gate-FAILING) config — the unfilled-template case the
# original bug let through.
printf '{"family":{"owner":{"name":"[OWNER_NAME]","imessage":"[OWNER_IMESSAGE]"}},"calendar":{"sources":[]}}' > "$lddir/config.json"
unset LD_CONFIG_SRC
inst_out="$(HOME="$hdir" PATH="$(fixture_path "$d")" bash "$HERE/../install-bundles.sh" 2>&1)"; inst_rc=$?
[ "$inst_rc" != "0" ]; check "install-bundles.sh exits non-zero on a placeholder config (false-success guard)" "$?"
case "$inst_out" in *"NOT installed."*) check "install-bundles.sh prints 'NOT installed.' for a gated config" 0 ;;
              *) check "install-bundles.sh prints 'NOT installed.' for a gated config" 1 ;; esac
case "$inst_out" in *"posted in one"*|*"Agent installed:"*) check "install-bundles.sh attempts NO marketplace POST when gated" 1 ;;
              *) check "install-bundles.sh attempts NO marketplace POST when gated" 0 ;; esac

# ───────────────────────────── summary ─────────────────────────────
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
