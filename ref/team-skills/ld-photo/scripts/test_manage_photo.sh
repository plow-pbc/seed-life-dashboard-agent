#!/usr/bin/env bash
# Behavior test for manage_photo.sh — covers the destructive branches (the
# `up_*` cap + `clear`) and the safety invariant that curated `s2_*` photos are
# never touched, plus that an invalid image exits before any remote mutation.
#
# Runs anywhere (CI included): `sips`, `scp`, and `ssh` are stubbed on PATH and
# a fake remote home stands in for the Pi — no macOS, no network, no Pi needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/manage_photo.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
export FAKE_REMOTE="$WORK/remote"          # stands in for marydyer@rpi5mary:$HOME
BANNERS="$FAKE_REMOTE/services/life-dashboard/banners"
export SHIM_LOG="$WORK/shim.log"

# ---- stub host tools on PATH ------------------------------------------------
cat > "$BIN/sips" <<'SIPS'
#!/usr/bin/env bash
# -g pixelWidth <src>  -> emit dims (none if basename starts with "bad")
# -s ... -Z N <src> --out <out>  -> "convert": create the out file
args=("$@"); out=""
for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = "--out" ] && out="${args[i+1]}"; done
if [ -n "$out" ]; then : > "$out"; exit 0; fi
src="${args[${#args[@]}-1]}"
case "$(basename "$src")" in bad*) exit 0;; *) echo "  pixelWidth: 4000"; echo "  pixelHeight: 3000";; esac
SIPS

cat > "$BIN/scp" <<'SCP'
#!/usr/bin/env bash
echo scp >> "$SHIM_LOG"
local=""; dest=""
for a in "$@"; do case "$a" in -*) ;; *@*:*) dest="$a";; *) [ -z "$local" ] && local="$a";; esac; done
rel="${dest#*:}"; mkdir -p "$FAKE_REMOTE/$(dirname "$rel")"; cp "$local" "$FAKE_REMOTE/$rel"
SCP

cat > "$BIN/ssh" <<'SSH'
#!/usr/bin/env bash
echo ssh >> "$SHIM_LOG"
cmd=""
for a in "$@"; do case "$a" in *@*) ;; -*) ;; *) cmd="$a";; esac; done
HOME="$FAKE_REMOTE" bash -c "$cmd"
SSH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

run() { : > "$SHIM_LOG"; "$SCRIPT" "$@"; }
ups() { ls "$BANNERS"/up_*.jpg 2>/dev/null | wc -l | tr -d ' '; }
s2s() { ls "$BANNERS"/s2_*.jpg 2>/dev/null | wc -l | tr -d ' '; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS - $1"; else echo "FAIL - $1 (got '$2', want '$3')"; fail=1; fi; }

# ---- fixtures: 11 texted + 2 curated already on the "Pi" --------------------
mkdir -p "$BANNERS"
for i in $(seq -w 1 11); do touch -t "202401010000.$i" "$BANNERS/up_old_$i.jpg" 2>/dev/null \
  || touch -d "2024-01-01 00:00:$i" "$BANNERS/up_old_$i.jpg"; done
touch "$BANNERS/s2_curated_a.jpg" "$BANNERS/s2_curated_b.jpg"

# ---- 1) invalid image: must reject BEFORE any scp --------------------------
echo "x" > "$WORK/bad-not-an-image.png"
if run add "$WORK/bad-not-an-image.png" >/dev/null 2>&1; then check "invalid image is rejected" reject ok; else check "invalid image is rejected" reject reject; fi
check "invalid image never scp'd to the Pi" "$(grep -c scp "$SHIM_LOG" 2>/dev/null || true)" 0

# ---- 2) valid add: lands an up_, caps to newest 10, curated survive --------
echo "img" > "$WORK/Beach Day.heic"
run add "$WORK/Beach Day.heic" >/dev/null
check "add caps texted set to newest 10" "$(ups)" 10
check "curated s2_* untouched by add+cap" "$(s2s)" 2
check "a slugged up_ file is present" "$(ls "$BANNERS"/up_*beach-day.jpg 2>/dev/null | wc -l | tr -d ' ')" 1

# ---- 3) clear: removes up_* only, curated survive --------------------------
run clear >/dev/null
check "clear removes all texted up_*" "$(ups)" 0
check "clear leaves curated s2_* intact" "$(s2s)" 2

[ "$fail" = 0 ] && echo "OK   ld-photo behavior tests" || { echo "ld-photo tests FAILED" >&2; exit 1; }
