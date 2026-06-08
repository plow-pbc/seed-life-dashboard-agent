# shellcheck shell=bash
# ld-config required-field gate — shared by ref/install-bundles.sh (the
# pre-mutation install gate) and ref/verify.sh (the post-install check),
# so the two enforce EXACTLY the same contract from a single source.
#
# Block on EXACTLY the fields the scheduled bundles throw-on-missing at their
# first tick — no more (so single-parent/single-calendar homes still pass),
# no less (so an install can't pass the gate yet die on the first tick). The
# set is derived from ld-calendar-nudge/scheduled/run.js (the only bundle
# with runtime code today):
#   - family.owner.name      ([OWNER_NAME] placeholder, empty, or missing) —
#     household identity consumed by the bundles.
#   - family.owner.imessage  ([OWNER_IMESSAGE] placeholder, empty, or missing)
#   - family.timezone        (run.js:135 throws if missing/empty — drives the
#     :20/:50 self-gate and reminder time formatting)
#   - calendar.sources       — at least ONE row (run.js:146), and EVERY present
#     row must have a non-empty, non-placeholder `account` (run.js:150 — fetched
#     at the first tick, so a "" or [UPPER_SNAKE] account is a bogus target)
#     AND a non-empty, non-placeholder `calendar_id` (run.js:150).
#   - calendar_nudge.lookahead_virtual_minutes  (run.js:157 throws unless a
#     finite number) and
#   - calendar_nudge.lookahead_in_person_minutes (run.js:157, same).
#
# Optional fields ([PARTNER_*], [FAMILY_PERSON_*], extra calendars beyond the
# first row's id, [LONG_LEAD_TYPE], and the morning_*/weekly_digest blocks the
# skeleton bundles don't yet read) intentionally do NOT block — single-parent /
# single-calendar households leave them as-is.
#
# Echoes the NAMES of unfilled required fields only (never the PII values).
# bash-3.2-safe; requires `jq` on PATH.

# ld_config_missing_required <config-path>
# Prints the field-name lines that are still unfilled (one per line) to
# stdout; prints nothing when all required fields are satisfied. Returns
# jq's exit status (non-zero only on a malformed config / read error).
ld_config_missing_required() {
  local cfg="$1"
  # `$ph` matches an [UPPER_SNAKE] placeholder; an empty string fails the
  # non-placeholder test below because "" is not a real value either.
  local ph='test("\\[[A-Z][A-Z0-9_]*\\]")'
  jq -r "
    # realstr: a real string value — non-empty and NOT an [UPPER_SNAKE]
    # placeholder. (Callers funnel every checked field through \`// \"\"\`, so
    # the input is always a string here; \"\" fails as not a real value.)
    def realstr: . != \"\" and ($ph | not);
    # finitenum: a JSON number (valid JSON has no NaN/Inf, so any number is
    # finite — matches run.js Number.isFinite()).
    def finitenum: type == \"number\";
    [ (if (.family.owner.name     // \"\" | realstr | not) then \"family.owner.name\"     else empty end),
      (if (.family.owner.imessage // \"\" | realstr | not) then \"family.owner.imessage\" else empty end),
      (if (.family.timezone       // \"\" | realstr | not) then \"family.timezone\"        else empty end),
      (if ((.calendar.sources // []) | length) == 0
         then \"calendar.sources (need at least one calendar source)\"
       elif ([ .calendar.sources[] | .account // \"\" | select(realstr | not) ] | length) > 0
         then \"calendar.sources[].account (every source needs a real, non-placeholder account)\"
       elif ([ .calendar.sources[] | .calendar_id // \"\" | select(realstr | not) ] | length) > 0
         then \"calendar.sources[].calendar_id (every source needs a real, non-placeholder calendar_id)\"
       else empty end),
      (if (.calendar_nudge.lookahead_virtual_minutes   | finitenum | not) then \"calendar_nudge.lookahead_virtual_minutes\"   else empty end),
      (if (.calendar_nudge.lookahead_in_person_minutes | finitenum | not) then \"calendar_nudge.lookahead_in_person_minutes\" else empty end)
    ] | .[]
  " "$cfg"
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
  local dest="$1" example="$2" dest_dir tmp src_missing
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir"
  if [ -f "$dest" ]; then
    return 0  # (a) preserve operator edits
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
