# shellcheck shell=bash
# ld-config assembly + minimal install gate — shared by ref/install-bundles.sh
# (assembles from the operator inputs, then gates pre-mutation) and ref/verify.sh
# (the post-install check), so the two enforce EXACTLY the same contract from a
# single source.
#
# This SEED DECLARES three operator inputs (see SEED.md ### Requirements) and
# ASSEMBLES its own household config.json from them — the installer collects the
# inputs once up front and exports them; this SEED reads them from the env:
#   LD_OWNER_NAME       — owner display name (non-blank).
#   LD_OWNER_IMESSAGE   — owner iMessage handle (E.164 phone or email).
#   LD_CALENDAR_ACCOUNT — calendar account address.
# family.timezone is AUTODETECTED from the host (ref/lib/detect-timezone.sh) —
# not an input — so a non-Pacific household gets the right zone with no extra
# question.
#
# The gate checks the invariants that distinguish a USABLE assembled/supplied
# config from an unedited template or a blank-filled one:
#   1. calendar.sources is a non-empty ARRAY, each source's `account` non-blank.
#   2. family.owner.{name,imessage} are present and non-blank.
#   3. family.timezone equals the host-autodetected zone (when the caller passes
#      the expected zone — install/verify do; the pure structural tests omit it).
#   4. NO string value is left as a bare [UPPER_SNAKE] placeholder — the match is
#      whole-string anchored, so a real value that merely CONTAINS a bracketed
#      token (e.g. a calendar named "Work [TEAM]") is fine.
# Per-field runtime requirements (a finite lookahead, a non-`self:false` owner
# source, etc.) are enforced at runtime by each bundle, the single source of
# truth for them.
#
# Echoes the NAMES of failing checks only (never the PII values).
# bash-3.2-safe; requires `jq` on PATH.

# ld_config_missing_required <config-path> [expected-timezone]
# Prints a line per failing check to stdout; prints nothing when the config
# passes the minimal gate. When <expected-timezone> is given, also asserts
# family.timezone equals it (install/verify pass the host-autodetected zone so a
# tz regression can't ship a wrong local time and still pass). Returns jq's exit
# status (non-zero only on a malformed config / read error).
ld_config_missing_required() {
  local cfg="$1" want_tz="${2:-}"
  jq -r --arg want_tz "$want_tz" '
    def blank: (. // "") | (type != "string") or (test("\\S") | not);
    [ (if (.calendar.sources | type) != "array"
         then "calendar.sources (must be a non-empty array)"
       elif (.calendar.sources | length) == 0
         then "calendar.sources (need at least one calendar source)"
       elif ([.calendar.sources[] | select(.account | blank)] | length) > 0
         then "calendar.sources[].account (each source needs a non-blank account)"
       else empty end),
      (if (.family.owner.name | blank)
         then "family.owner.name (owner display name must be non-blank)" else empty end),
      (if (.family.owner.imessage | blank)
         then "family.owner.imessage (owner handle must be non-blank)" else empty end),
      (if ($want_tz != "") and (.family.timezone != $want_tz)
         then "family.timezone (must match the host-autodetected zone)" else empty end),
      # A string leaf that is EXACTLY an [UPPER_SNAKE] placeholder means a
      # required field was left unedited. Walk every string leaf via `..` and
      # anchor the match (^...$) so a real value that merely CONTAINS a bracketed
      # token (e.g. a calendar name "Work [TEAM]") is not a false positive.
      (if [ .. | strings | select(test("^\\[[A-Z][A-Z0-9_]*\\]$")) ] | length > 0
         then "config still contains [UPPER_SNAKE] placeholders (fill them in)"
       else empty end)
    ] | .[]
  ' "$cfg"
}

# ld_config_assemble <example-path> <timezone> > <dest>
# Build a complete household config from the three operator inputs in the env
# (LD_OWNER_NAME / LD_OWNER_IMESSAGE / LD_CALENDAR_ACCOUNT) plus the autodetected
# <timezone>, mirroring the vendored example's shape. The config carries PII
# (owner identity, calendar account) so the PII values are fed to jq as data over
# STDIN (a `--rawfile`/here-string), NEVER as `--arg` argv (which would surface
# them in /proc/<pid>/cmdline); only the non-PII <timezone> is passed via --arg.
# Writes the assembled JSON to stdout. Returns non-zero on a missing/blank input
# or a jq failure.
ld_config_assemble() {
  local example="$1" tz="$2" v
  for v in LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT; do
    eval "val=\${$v:-}"
    case "$val" in
      *[![:space:]]*) ;;
      *) echo "ld-config: $v is unset or blank — cannot assemble config" >&2; return 1 ;;
    esac
  done
  # PII in over stdin as a JSON object (jq reads it as the input `.`); the
  # example shape + non-PII timezone come via --argjson/--arg. The owner handle
  # and calendar account never touch argv.
  printf '%s\n%s\n%s' "$LD_OWNER_NAME" "$LD_OWNER_IMESSAGE" "$LD_CALENDAR_ACCOUNT" \
    | jq -Rsn --arg tz "$tz" --slurpfile example "$example" '
        ( input | rtrimstr("\n") | split("\n") ) as $in |
        $example[0]
        | .family.owner.name = $in[0]
        | .family.owner.imessage = $in[1]
        | .family.timezone = $tz
        | .calendar.sources = [ ( .calendar.sources[0] // {"calendar_id":"primary","name":"Personal"} )
                                | .account = $in[2] ]
      '
}

# ld_config_resolve_and_land <dest> <example-path> [expected-timezone]
# Populate <dest> (the runtime config.json) by exactly one of three paths, in
# priority order — the install-time landing contract shared with the test suite
# so the behavior is covered by the gate:
#
#   (a) <dest> already present AND gate-passing — operator's prior edits are
#       canonical; leave it untouched (re-run safety).
#   (b) the three inputs are present in the env — ASSEMBLE the config from them
#       (the default single-shot path; the installer collects + exports them).
#       The assembled bytes are gated BEFORE the atomic mv, so a blank/incomplete
#       input never lands. LD_CONFIG_SRC=- is an escape hatch: a complete config
#       supplied on stdin is consumed instead of assembling (for a directly
#       supplied full config). Either way, a malformed/incomplete config fails
#       loud, non-zero, with no partial write.
#   (c) neither inputs nor LD_CONFIG_SRC — copy the vendored example (the
#       placeholders the operator fills in). The SEED never invents household
#       values.
#
# Config values are PII (iMessage handles, family names) — never echoed.
# Returns non-zero on any read/parse/assemble/incomplete failure.
ld_config_resolve_and_land() {
  local dest="$1" example="$2" want_tz="${3:-}"
  local dest_dir tmp src_missing dest_missing
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir"
  # Is at least one operator input present? (any of the three -> assemble path)
  local have_inputs=""
  if [ -n "${LD_OWNER_NAME:-}" ] || [ -n "${LD_OWNER_IMESSAGE:-}" ] || [ -n "${LD_CALENDAR_ACCOUNT:-}" ]; then
    have_inputs=1
  fi
  if [ -f "$dest" ]; then
    # (a) preserve a gate-PASSING existing config — operator's edits are
    #     canonical. But a gate-FAILING existing config (e.g. the placeholder
    #     example landed by a first run with no inputs, OR a manually corrupted /
    #     malformed-JSON file) must NOT short-circuit a corrected supply: when a
    #     supply source is present, fall through to assemble/consume + atomically
    #     replace it. The gate must both EXIT 0 (parsed cleanly) AND emit nothing
    #     — a malformed dest makes jq exit non-zero with empty stdout, which would
    #     otherwise read as "passing."
    if { dest_missing=$(ld_config_missing_required "$dest" "$want_tz" 2>/dev/null) && [ -z "$dest_missing" ]; } \
       || { [ -z "$have_inputs" ] && [ -z "${LD_CONFIG_SRC:-}" ]; }; then
      return 0
    fi
  fi
  if [ -z "$have_inputs" ] && [ -z "${LD_CONFIG_SRC:-}" ]; then
    # (c) first install with no supplied config — copy the example.
    cp "$example" "$dest" || { echo "ld-config: failed to copy example into $dest" >&2; return 1; }
    chmod 600 "$dest"
    echo "" >&2
    echo "ld-config landed at $dest from the vendored example." >&2
    return 0
  fi
  tmp=$(mktemp "$dest_dir/.config.json.XXXXXX")
  trap 'rm -f "$tmp"' RETURN
  if [ -n "${LD_CONFIG_SRC:-}" ]; then
    # (b-escape) consume a complete config supplied on stdin. Stdin is the ONLY
    #     supported supply value; any other LD_CONFIG_SRC is rejected loud.
    if [ "$LD_CONFIG_SRC" != "-" ]; then
      echo "LD_CONFIG_SRC accepts only '-' (read config from stdin)." >&2
      echo "Pipe the config via stdin (LD_CONFIG_SRC=-), set the operator inputs," >&2
      echo "or unset both and edit the vendored example in place." >&2
      return 1
    fi
    cat > "$tmp" || { echo "LD_CONFIG_SRC=-: failed to read config from stdin" >&2; return 1; }
    jq -e . "$tmp" >/dev/null 2>&1 \
      || { echo "LD_CONFIG_SRC: supplied config is not valid JSON — refusing to land a partial config" >&2; return 1; }
  else
    # (b) assemble from the declared operator inputs (the default path).
    ld_config_assemble "$example" "$want_tz" > "$tmp" \
      || { echo "ld-config: assembly from operator inputs failed — nothing landed" >&2; return 1; }
  fi
  # Gate the assembled/supplied config BEFORE it lands. Field NAMES only — never PII.
  src_missing=$(ld_config_missing_required "$tmp" "$want_tz")
  if [ -n "$src_missing" ]; then
    echo "" >&2
    echo "The ld-config to land is missing REQUIRED household values:" >&2
    echo "$src_missing" | sed 's/^/  - /' >&2
    echo "" >&2
    echo "Refusing to land an incomplete config. Fix the inputs/source and" >&2
    echo "re-run — nothing was written, so the retry is honored." >&2
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$dest"
  echo "" >&2
  if [ -n "${LD_CONFIG_SRC:-}" ]; then
    echo "ld-config landed at $dest from LD_CONFIG_SRC." >&2
  else
    echo "ld-config assembled from operator inputs and landed at $dest." >&2
  fi
}
