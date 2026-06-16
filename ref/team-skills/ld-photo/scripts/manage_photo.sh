#!/usr/bin/env bash
# ld-photo — put a texted photo into the life-dashboard kiosk's banner rotation,
# or clear the texted set.
#
#   manage_photo.sh add <image-path>   # resize/convert + add ONE photo to the rotation
#   manage_photo.sh clear              # remove ALL texted (up_*) photos
#
# How it works: the image is resized + converted to JPEG locally with `sips`
# (the Pi has no ImageMagick), then scp'd over Tailscale into the Pi's banner
# folder. The kiosk serves files from that folder and rotates hourly, so the
# new photo appears on the next hourly rotation / ~5-min client reload — no
# restart, no sudo (the folder is owned by `marydyer`).
#
# RUNTIME: unlike the other ld-* bundles (VM-runnable producers that POST a
# card over HTTP), this one shells out to HOST tooling — `sips` (macOS) and
# key-based SSH/Tailscale to the Pi (`marydyer@rpi5mary`). It must run with the
# household agent host's filesystem + network identity (the Neo, where those
# are present).
#
# SCOPING (important): this script only ever creates/deletes the AGENT-uploaded
# `up_*.jpg` files. It NEVER touches the curated family photos (`s2_*` and any
# other non-`up_` files) — those are managed by hand and left alone.
set -euo pipefail

PI="marydyer@rpi5mary"
REMOTE_DIR="services/life-dashboard/banners"   # relative to marydyer's home on the Pi
MAXSIDE=1600        # longest side, px
QUALITY=82          # JPEG quality
CAP=10              # keep at most this many texted photos (newest win)

die() { echo "ld-photo: $*" >&2; exit 1; }

mode="${1:-}"
case "$mode" in
  add)
    src="${2:-}"
    [ -n "$src" ] || die "usage: manage_photo.sh add <image-path>"
    [ -f "$src" ] || die "no such file: $src"

    # Validate it is a real image: sips must report positive pixel dimensions.
    # (Rejects non-images / corrupt files so we never push junk to the kiosk.)
    w="$(sips -g pixelWidth "$src" 2>/dev/null | awk '/pixelWidth:/{print $2}')"
    { [ -n "${w:-}" ] && [ "$w" -gt 0 ] 2>/dev/null; } || die "not a readable image: $src"

    # Convert + downscale to a temp JPEG (HEIC/PNG/… -> JPEG, longest side <= MAXSIDE).
    tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
    out="$tmpd/photo.jpg"
    sips -s format jpeg -s formatOptions "$QUALITY" -Z "$MAXSIDE" "$src" --out "$out" >/dev/null 2>&1 \
      || die "image conversion failed: $src"

    # Sortable, namespaced filename: up_<epoch>_<slug>.jpg
    epoch="$(date +%s)"
    slug="$(basename "$src" | tr '[:upper:]' '[:lower:]' \
            | sed -E 's/\.[a-z0-9]+$//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24)"
    [ -n "$slug" ] || slug="photo"
    name="up_${epoch}_${slug}.jpg"

    # Deliver over Tailscale.
    scp -q "$out" "$PI:$REMOTE_DIR/$name" || die "scp to the Pi failed (is Tailscale up?)"

    # Cap the texted set to the newest $CAP (up_* ONLY). A failed cap must NOT
    # report success — otherwise more than $CAP private texted photos can
    # silently linger on the Pi past the promised limit.
    if ! ssh "$PI" "ls -t \"\$HOME/$REMOTE_DIR\"/up_*.jpg 2>/dev/null | tail -n +$((CAP + 1)) | xargs -r rm --"; then
      die "added $name, but the retention cap FAILED — older texted photos may remain; re-run or use 'clear'"
    fi

    echo "ld-photo: added $name — live in the kiosk rotation (newest $CAP texted photos kept; curated set untouched)"
    ;;

  clear)
    ssh "$PI" "rm -f \"\$HOME/$REMOTE_DIR\"/up_*.jpg" \
      && echo "ld-photo: cleared all texted (up_*) photos; curated family set untouched" \
      || die "clear failed over ssh"
    ;;

  ""|-h|--help|help)
    echo "usage: manage_photo.sh add <image-path>   # add a photo to the kiosk rotation"
    echo "       manage_photo.sh clear              # remove all texted (up_*) photos"
    ;;

  *)
    die "unknown mode '$mode' (use: add <image-path> | clear)"
    ;;
esac
