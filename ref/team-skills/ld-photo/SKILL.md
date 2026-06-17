---
name: ld-photo
description: Add a texted photo to the life-dashboard kiosk's banner (photo) rotation, or clear the texted set. Use when the user texts/sends a photo and wants it on the family dashboard ("put this on the kiosk / fridge screen / dashboard"), or says "clear the texted photos" / "remove the photos I sent". Calls the viewer's banner CRUD endpoint over Tailscale; only manages photos sent through the agent (the up_ set) and never touches the curated family photos.
---

# Life Dashboard — Photos

Put a photo the head chef **texted to you** onto the kiosk's rotating banner
(the big photo tile), or clear the ones they've sent. This is a **request-only**
skill — no scheduled runner, no cron; it runs when the user sends a photo (or
asks to clear).

It POSTs the image to the **viewer's banner endpoint**, which validates +
resizes it (longest side ≤1600px, JPEG q82), names it `up_<epoch>_<slug>.jpg`,
and keeps the **newest 10** texted photos. It only ever manages the agent's
`up_*` set — the **curated family photos (`s2_*`) are never touched**.

## When to use it

- The user **texts/sends a photo** for the dashboard → **add**.
- The user wants to **clear** what they've sent → **clear**.

It does NOT manage the curated family photos — those are placed by hand and left
alone.

## How to run it

**Add** — save the texted image attachment to a temp file, then pass the path:

```
/workspace/host/skills/ld-photo/scripts/manage_photo.py add /tmp/<the-saved-image>
```

**Clear** the texted set (curated photos stay):

```
/workspace/host/skills/ld-photo/scripts/manage_photo.py clear
```

On success `add` prints the stored filename + how many texted photos are kept.

## Inputs (config — not hardcoded)

- **`DASHBOARD_TOKEN`** — the household bearer, the SAME token the message
  producers use. Read **file-first** from `/config/secrets/dashboard-token`
  (the read-only secrets mount), env `DASHBOARD_TOKEN` as fallback. Never
  printed.
- **`VIEWER_BASE_URL`** — the viewer's base URL, **required** (no default — each
  household's viewer is a different host). Read from env `VIEWER_BASE_URL`, then
  `/config/secrets/viewer-base-url`; if neither is set, `add`/`clear` fail loudly.
  It MUST be the **full tailnet FQDN + the `/fd` serve prefix**
  (e.g. `http://<viewer-host>.<tailnet>.ts.net/fd`) — the bare host doesn't
  resolve inside the agent VM, and the raw tailnet IP is rejected by the viewer's
  Host guard.

## HEIC / iPhone photos

The agent VM has **no HEIC decoder** (no ImageMagick / libheif / vips /
pillow-heif), and the viewer rejects HEIC server-side. So a **HEIC/HEIF file is
refused with a clear error before any upload** — it never pushes junk. If the
texted photo is HEIC, hand a **JPEG/PNG rendition** instead (many messaging
layers already provide one). JPEG/PNG/WebP/GIF go straight through — the viewer
does the resize/re-encode.

## Responses

`add`/`clear` translate the endpoint's replies: **200** ok; **401** = the token
doesn't match the Pi's (tell the head chef the token is wrong); **400** =
undecodable image (e.g. an un-normalized HEIC); **413** = image too large
(>15 MB).

## Runtime note

The agent VM reaches the Pi over the **host's Tailscale** — the load-bearing
link. It's already up (it's how the kiosk runs); if it's down, `add`/`clear`
report that the viewer is unreachable rather than failing silently.

## Trust note

Anything sent through this skill is shown on the **family** kiosk. It assumes
the sender (the head chef's phone → their agent) is trusted.
