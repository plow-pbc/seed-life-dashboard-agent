# shellcheck shell=bash
# ld-config required-field gate — shared by ref/install-bundles.sh (the
# pre-mutation install gate) and ref/verify.sh (the post-install check),
# so the two enforce EXACTLY the same contract from a single source.
#
# Block ONLY on the fields the bundles cannot function without:
#   - family.owner.name      ([OWNER_NAME] placeholder, empty, or missing)
#   - family.owner.imessage  ([OWNER_IMESSAGE] placeholder, empty, or missing)
#   - calendar.sources       — at least ONE row, and EVERY present row must
#     have a non-empty, non-placeholder `account`. (run.js fetches every
#     source at the first scheduled tick, so a "" or [UPPER_SNAKE] account
#     is a bogus fetch target — reject it at install/verify, not at runtime.)
#
# Optional fields ([PARTNER_*], [FAMILY_PERSON_*], [FAMILY_CALENDAR_ID],
# [LONG_LEAD_TYPE]) intentionally do NOT block — single-parent /
# single-calendar households leave them as-is. family.timezone already
# ships a real default.
#
# Echoes the NAMES of unfilled required fields only (never the PII values).
# bash-3.2-safe; requires `jq` on PATH.

# ld_config_missing_required <config-path>
# Prints the field-name lines that are still unfilled (one per line) to
# stdout; prints nothing when all required fields are satisfied. Returns
# jq's exit status (non-zero only on a malformed config / read error).
ld_config_missing_required() {
  local cfg="$1"
  # `_ph` matches an [UPPER_SNAKE] placeholder; an empty string fails the
  # non-placeholder test below because "" is not a real account either.
  local ph='test("\\[[A-Z][A-Z0-9_]*\\]")'
  jq -r "
    def realvalue: . != null and . != \"\" and ($ph | not);
    [ (if (.family.owner.name     // \"\" | realvalue | not) then \"family.owner.name\"     else empty end),
      (if (.family.owner.imessage // \"\" | realvalue | not) then \"family.owner.imessage\" else empty end),
      (if ((.calendar.sources // []) | length) == 0
         then \"calendar.sources (need at least one calendar source)\"
       elif ([ .calendar.sources[] | .account // \"\" | select(realvalue | not) ] | length) > 0
         then \"calendar.sources[].account (every source needs a real, non-placeholder account)\"
       else empty end)
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
#       file path, `-` (stdin), or an `https://` URL. The bytes are
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
    https://*)
      # Fetch via Python stdlib (same _NoRedirect discipline as the bundle
      # POST). Operators may pass pre-signed / tokenized URLs, so on failure
      # the redirect Location and raw exception are NEVER surfaced — only a
      # sanitized failure class (HTTP status / network class) reaches stderr.
      LD_CONFIG_SRC="$LD_CONFIG_SRC" python3 - > "$tmp" <<'PY' \
        || { echo "LD_CONFIG_SRC: failed to fetch config from URL" >&2; return 1; }
import os, sys, urllib.error, urllib.request

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code,
            "unexpected redirect (refusing to follow)", headers, fp,
        )

opener = urllib.request.build_opener(_NoRedirect())
req = urllib.request.Request(os.environ["LD_CONFIG_SRC"], method="GET")
try:
    with opener.open(req, timeout=60) as resp:
        sys.stdout.buffer.write(resp.read())
except urllib.error.HTTPError as exc:
    sys.exit(f"HTTP {exc.code}")
except (urllib.error.URLError, TimeoutError):
    sys.exit("network/timeout error")
PY
      ;;
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
