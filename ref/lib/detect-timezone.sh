# shellcheck shell=bash
# Single source of truth for the Mac's IANA timezone, shared by config
# assembly (ld_config_assemble, which writes family.timezone into the
# assembled config) and the gate (ld_config_missing_required, which asserts
# the landed config carries the SAME zone). Sourcing this in both places
# means there is exactly one readlink/fallback rule — a tz-autodetect
# regression can't ship a wrong zone that the gate still passes.
#
# macOS symlinks /etc/localtime into .../zoneinfo/<Area>/<City> (e.g.
# /var/db/timezone/zoneinfo/America/New_York or /usr/share/zoneinfo/...); the
# IANA name is everything after the last `/zoneinfo/`. Fall back to
# America/Los_Angeles only if detection yields nothing. bash-3.2-safe.
ld_detect_timezone() {
  local link tz
  link=$(readlink /etc/localtime 2>/dev/null || true)
  case "$link" in
    */zoneinfo/*) tz="${link##*/zoneinfo/}" ;;
    *) tz="" ;;
  esac
  # An empty tail (a symlink ending exactly at .../zoneinfo/) counts as
  # "detection yielded nothing" — fall back rather than land an empty zone.
  [ -n "$tz" ] && printf '%s' "$tz" || printf '%s' "America/Los_Angeles"
}
