# shellcheck shell=bash
# ld-config minimal install gate — shared by ref/install-bundles.sh (the
# pre-mutation install gate) and ref/verify.sh (the post-install check),
# so the two enforce EXACTLY the same contract from a single source.
#
# The gate is deliberately MINIMAL. Rather than mirror run.js's field-by-field
# requirements (a list that drifted from the runtime contract across four review
# rounds), it checks only the two structural invariants that distinguish an
# UNEDITED template from a FILLED config:
#   1. calendar.sources is a non-empty ARRAY. (run.js requires Array.isArray +
#      length>=1; an object-valued or empty sources is an unusable config.)
#   2. NO [UPPER_SNAKE] placeholder token survives ANYWHERE in the config — the
#      example ships placeholders ONLY for fields the operator MUST provide, so
#      "no placeholder remains" is exactly "every required field was filled."
#
# The "what must be filled" requirement now lives in the EXAMPLE template, not
# here: the example carries [UPPER_SNAKE] placeholders for owner identity and at
# least one calendar `account`, real defaults for timezone/lookaheads, and
# empty/omitted optional sections — so single-parent / single-calendar homes
# pass without editing optional fields. Per-field runtime requirements (a finite
# lookahead, a non-`self:false` owner source, etc.) are enforced at runtime by
# each bundle, which is the single source of truth for them.
#
# Echoes the NAMES of failing checks only (never the PII values).
# bash-3.2-safe; requires `jq` on PATH.

# ld_config_missing_required <config-path>
# Prints a line per failing check to stdout; prints nothing when the config
# passes the minimal gate. Returns jq's exit status (non-zero only on a
# malformed config / read error).
ld_config_missing_required() {
  local cfg="$1"
  jq -r '
    [ (if (.calendar.sources | type) != "array"
         then "calendar.sources (must be a non-empty array)"
       elif (.calendar.sources | length) == 0
         then "calendar.sources (need at least one calendar source)"
       else empty end),
      # A string leaf that is EXACTLY an [UPPER_SNAKE] placeholder means the
      # operator left a required field unedited. Walk every string leaf via `..`
      # and anchor the match (^...$) so a real value that merely CONTAINS a
      # bracketed token (e.g. a calendar name "Work [TEAM]") is not a false
      # positive — the template only ever ships whole-string placeholders.
      (if [ .. | strings | select(test("^\\[[A-Z][A-Z0-9_]*\\]$")) ] | length > 0
         then "config still contains [UPPER_SNAKE] placeholders (fill them in)"
       else empty end)
    ] | .[]
  ' "$cfg"
}

# ld_config_resolve_and_land <dest> <example-path>
# Populate <dest> (the runtime config.json) by exactly one of three paths,
# in priority order — the install-time landing contract shared with the
# test suite so the behavior is covered by `just test`:
#
#   (a) <dest> already present — operator's prior edits are canonical;
#       leave it untouched (re-run safety).
#   (b) LD_CONFIG_SRC set       — consume a supplied household config from a
#       file path or `-` (stdin). The bytes are
#       JSON-validated AND run through ld_config_missing_required BEFORE the
#       atomic mv, so a malformed OR incomplete supplied config NEVER lands
#       (a landed-but-bad file would make case (a) short-circuit every
#       retry). Fails loud, non-zero, no partial write.
#   (c) neither                 — copy the vendored example (placeholders the
#       operator fills in). The SEED never invents household values.
#
# Config values are PII (iMessage handles, family names) — never echoed.
# Returns non-zero on any read/fetch/parse/incomplete failure.
ld_config_resolve_and_land() {
  local dest="$1" example="$2" dest_dir tmp src_missing dest_missing
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir"
  if [ -f "$dest" ]; then
    # (a) preserve a gate-PASSING existing config — operator's edits are
    #     canonical. But a gate-FAILING existing config (e.g. the placeholder
    #     example landed by a first run with no LD_CONFIG_SRC, OR a manually
    #     corrupted / malformed-JSON file) must NOT short-circuit a corrected
    #     supplied config: when LD_CONFIG_SRC is set, fall through to consume +
    #     atomically replace it via the (b) path. The gate must both EXIT 0
    #     (parsed cleanly) AND emit nothing — a malformed dest makes jq exit
    #     non-zero with empty stdout, which would otherwise read as "passing."
    if { dest_missing=$(ld_config_missing_required "$dest" 2>/dev/null) && [ -z "$dest_missing" ]; } \
       || [ -z "${LD_CONFIG_SRC:-}" ]; then
      return 0
    fi
  fi
  if [ -z "${LD_CONFIG_SRC:-}" ]; then
    # (c) first install with no supplied config — copy the example.
    cp "$example" "$dest" || { echo "ld-config: failed to copy example into $dest" >&2; return 1; }
    chmod 600 "$dest"
    echo "" >&2
    echo "ld-config landed at $dest from the vendored example." >&2
    return 0
  fi
  # (b) consume supplied config. Read raw bytes first, JSON-validate, gate,
  #     then write atomically — so a malformed/incomplete source never lands.
  tmp=$(mktemp "$dest_dir/.config.json.XXXXXX")
  trap 'rm -f "$tmp"' RETURN
  case "$LD_CONFIG_SRC" in
    -)
      cat > "$tmp" || { echo "LD_CONFIG_SRC=-: failed to read config from stdin" >&2; return 1; }
      ;;
    *)
      [ -f "$LD_CONFIG_SRC" ] || { echo "LD_CONFIG_SRC: no such file: $LD_CONFIG_SRC" >&2; return 1; }
      cat "$LD_CONFIG_SRC" > "$tmp" || { echo "LD_CONFIG_SRC: failed to read $LD_CONFIG_SRC" >&2; return 1; }
      ;;
  esac
  jq -e . "$tmp" >/dev/null 2>&1 \
    || { echo "LD_CONFIG_SRC: supplied config is not valid JSON — refusing to land a partial config" >&2; return 1; }
  # Gate the SUPPLIED config BEFORE it lands. Field NAMES only — never PII.
  src_missing=$(ld_config_missing_required "$tmp")
  if [ -n "$src_missing" ]; then
    echo "" >&2
    echo "LD_CONFIG_SRC supplied a config missing REQUIRED household values:" >&2
    echo "$src_missing" | sed 's/^/  - /' >&2
    echo "" >&2
    echo "Refusing to land an incomplete supplied config. Fix the source and" >&2
    echo "re-run — nothing was written, so the retry is honored." >&2
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$dest"
  echo "" >&2
  echo "ld-config landed at $dest from LD_CONFIG_SRC." >&2
}
