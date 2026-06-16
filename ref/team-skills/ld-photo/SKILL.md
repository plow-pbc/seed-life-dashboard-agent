---
name: ld-photo
description: Add a texted photo to the life-dashboard kiosk's banner (photo) rotation, or clear the texted set. Use when the user texts/sends a photo and wants it shown on the family dashboard, asks to "put this on the dashboard / kiosk / fridge screen", or says "clear the texted photos" / "remove the photos I sent". Resizes + converts the image and copies it onto the household Pi over Tailscale; only manages photos sent through the agent (the `up_` set) and never touches the curated family photos.
---

# Life Dashboard — Photos

Put a photo the head chef **texted to you** onto the kiosk's rotating banner
(the big photo tile on the family dashboard), or clear the ones they've sent.

The kiosk shows photos from a folder on the Pi and rotates through them hourly.
This skill resizes/converts an image and drops it into that folder over
Tailscale — no restart, no sudo. The new photo appears on the next hourly
rotation (and within ~5 min the kiosk reloads and re-reads the folder).

**It only manages the photos sent through you** — files named `up_*` — and
**never touches the curated family photos** (`s2_*`). Capped at the **newest
10** texted photos (oldest texted ones drop off as new ones arrive).

## When to use it

- The user **texts/sends a photo** and wants it on the dashboard ("put this on
  the kiosk", "add this to the fridge screen", "show this on the dashboard").
- The user wants to **clear** what they've sent ("clear the photos", "remove
  the photos I texted").

It does **not** manage the curated family photos — those are placed by hand and
left alone.

## How to run it

This bundle is a host-side helper, not a scheduled producer. It carries **no
`scheduled/` runner and no cron** — it runs only when the user sends a photo (or
asks to clear).

**Add a photo** — first save the texted image attachment to a temp file, then
pass that path:

```
/workspace/host/skills/ld-photo/scripts/manage_photo.sh add /tmp/<the-saved-image>
```

- Accepts JPEG / PNG / **HEIC** (iPhone) / most common formats — it converts to
  JPEG and downscales to ≤1600px automatically.
- Non-images / unreadable files are rejected (nothing is pushed to the kiosk).
- On success it prints the stored filename (e.g. `up_1750000000_beach.jpg`).

**Clear the texted set** — remove every photo sent through the agent (leaves the
curated family photos in place):

```
/workspace/host/skills/ld-photo/scripts/manage_photo.sh clear
```

## What it does (under the hood)

1. **Validate** the file is a real image (`sips` reports pixel dimensions).
2. **Convert + resize** with `sips` → JPEG, longest side ≤ 1600px, quality 82
   (~0.5–0.9 MB). HEIC → JPG handled.
3. **Name** it `up_<epoch>_<slug>.jpg` — the `up_` prefix namespaces agent
   uploads; the epoch keeps them ordered.
4. **Copy** it to `marydyer@rpi5mary:~/services/life-dashboard/banners/` over
   Tailscale (`scp`).
5. **Cap** the texted set to the newest **10** `up_*.jpg` (scoped to `up_*`
   only — the curated `s2_*` photos are never touched). A failed cap is surfaced
   as an error, not a false "kept 10" success.

## Runtime requirements

Unlike the data→HTTP-POST producers in this repo, this bundle shells out to
**host tooling**, so it must run with the household agent host's filesystem and
network identity (the Neo):

- **`sips`** (built into macOS) for the resize/convert. (The Pi has no
  ImageMagick/`sharp`, so the image work happens host-side.)
- **Key-based SSH over Tailscale** to the Pi (`marydyer@rpi5mary`): verify with
  `ssh -o BatchMode=yes marydyer@rpi5mary hostname` → `rpi5mary`, no prompt.
  (The agent host's key is authorized on the Pi; the Pi's host key is trusted in
  the agent host's `known_hosts`.)

## Trust note

Anything sent through this skill is displayed on the **family** kiosk. The
image-type validation guards against junk, but it assumes the sender (the head
chef's phone → their agent) is trusted — don't run it on images from untrusted
sources.
