#!/usr/bin/env python3
"""ld-photo — add a texted photo to the life-dashboard kiosk's banner rotation,
or clear the texted set, by calling the viewer's banner CRUD endpoint.

  add:   POST   {VIEWER_BASE_URL}/api/banners   {"filename": ..., "data": <base64>}
  clear: DELETE {VIEWER_BASE_URL}/api/banners

Bearer <DASHBOARD_TOKEN> on every call. The viewer validates the image, resizes
it (longest side <=1600px, JPEG q82), names it up_<epoch>_<slug>.jpg, and caps
the up_* set to the newest 10 — and NEVER touches the curated s2_* family
photos. This skill only manages the up_* (texted) set; it does NOT resize
(the viewer does that) — it stays thin.

Runtime: the agent VM reaches the Pi over the *host's* Tailscale (the
load-bearing link; up because it's how the kiosk runs). VIEWER_BASE_URL MUST be
the full tailnet FQDN + the `/fd` serve prefix — the bare host doesn't resolve
inside the VM, and the raw tailnet IP is rejected by the viewer's Host guard.

HEIC: the agent VM has NO HEIC decoder (no ImageMagick / libheif / vips /
pillow-heif), and the viewer rejects HEIC too. So HEIC/HEIF input fails CLEANLY
here — nothing junk is uploaded; the agent should hand a JPEG/PNG rendition
instead. Non-HEIC images are sent as-is (the viewer re-encodes).

Reads config file-first (the read-only /config/secrets mount), env fallback —
the same posture as ld-shared's post_to_kiosk. The token is never printed.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_BASE = "http://rpi5mary.tail3b4d58.ts.net/fd"
TOKEN_FILE = "/config/secrets/dashboard-token"
BASE_FILE = "/config/secrets/viewer-base-url"
MAX_BYTES = 15 * 1024 * 1024  # mirror the viewer's upload cap; fail before a wasted POST

# HEIF/HEIC family brands (HEIC = HEVC-coded HEIF). A file is HEIC/HEIF if its
# ISO-BMFF `ftyp` box names any of these as the MAJOR brand OR a COMPATIBLE one.
HEIF_BRANDS = {b"heic", b"heix", b"heif", b"heim", b"heis", b"hevc", b"hevx",
               b"hevm", b"hevs", b"mif1", b"msf1"}


def _die(msg):
    sys.stderr.write(f"ld-photo: {msg}\n")
    sys.exit(1)


def _read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def viewer_base():
    return (os.environ.get("VIEWER_BASE_URL", "").strip() or _read_file(BASE_FILE) or DEFAULT_BASE).rstrip("/")


def token():
    t = _read_file(TOKEN_FILE) or os.environ.get("DASHBOARD_TOKEN", "").strip()
    if not t:
        _die("no DASHBOARD_TOKEN (set /config/secrets/dashboard-token or the DASHBOARD_TOKEN env var)")
    return t


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # Don't follow 30x: default urllib forwards the Authorization header to the
    # new origin, so a rewritten endpoint could steer the bearer elsewhere.
    def redirect_request(self, *_args, **_kwargs):
        return None


def _send(method, url, tok, body=None):
    """Issue one request; return (status, text). The default transport — tests
    inject a fake `send` to assert request construction without the network."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Authorization": f"Bearer {tok}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except urllib.error.URLError as e:
        _die(f"cannot reach the viewer at {url} — is the host's Tailscale up? ({e.reason})")


def _ftyp_brands(buf):
    """All brands (major + compatible) from a leading ISO-BMFF `ftyp` box,
    lowercased; empty set if the buffer doesn't start with one."""
    if len(buf) < 12 or buf[4:8] != b"ftyp":
        return set()
    size = int.from_bytes(buf[0:4], "big")
    # size 0 (box runs to EOF), 1 (64-bit largesize), or an oversized/garbage
    # value → just scan what we actually have.
    if size < 16 or size > len(buf):
        size = len(buf)
    brands = {buf[8:12].lower()}  # major brand
    off = 16  # compatible brands follow the 4-byte minor_version at 12:16
    while off + 4 <= size:
        brands.add(buf[off:off + 4].lower())
        off += 4
    return brands


def is_heic(buf, path):
    # Match the HEIF/HEIC family by ANY ftyp brand (major or compatible), so a
    # .jpg-named HEIC whose major brand is benign but lists heic/mif1/… as a
    # compatible brand is still caught. Extension check kept as a backstop.
    if HEIF_BRANDS & _ftyp_brands(buf):
        return True
    return path.lower().endswith((".heic", ".heif"))


def sniff_image(buf):
    """Positive magic-byte allowlist of formats the viewer's sharp can decode.
    Returns the format name, or None for anything not recognized (→ refused
    before upload, so non-images never reach the POST)."""
    if buf[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if buf[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if buf[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if len(buf) >= 12 and buf[:4] == b"RIFF" and buf[8:12] == b"WEBP":
        return "webp"
    if buf[:4] in (b"II*\x00", b"MM\x00*"):
        return "tiff"
    return None


def _explain(status, text):
    hint = {
        401: "the DASHBOARD_TOKEN does not match the Pi's — tell the head chef the token is wrong",
        400: "the viewer rejected the image (undecodable, or a HEIC that wasn't normalized to JPEG)",
        413: "the image is too large (the viewer caps uploads at 15 MB)",
    }.get(status, f"unexpected HTTP {status}")
    _die(f"{hint}: {text.strip()[:200]}")


def add(image_path, send=_send):
    try:
        with open(image_path, "rb") as f:
            buf = f.read()
    except OSError as e:
        _die(f"cannot read {image_path}: {e}")
    if not buf:
        _die("the file is empty")
    if len(buf) > MAX_BYTES:
        _die(f"the image is {len(buf) // 1024 // 1024} MB — over the 15 MB upload cap")
    if is_heic(buf, image_path):
        _die("HEIC/HEIF can't be uploaded from this environment (no decoder in the agent VM, and the "
             "viewer rejects HEIC). Provide a JPEG/PNG rendition of the photo instead.")
    if sniff_image(buf) is None:
        _die("that file isn't a supported image — send a JPEG, PNG, GIF, WEBP, or TIFF "
             "(the kiosk viewer can't decode this format).")
    payload = {"filename": os.path.basename(image_path), "data": base64.b64encode(buf).decode("ascii")}
    status, text = send("POST", viewer_base() + "/api/banners", token(), payload)
    if status == 200:
        r = json.loads(text) if text else {}
        print(f"ld-photo: added {r.get('stored', '?')} to the kiosk rotation "
              f"(texted photos kept: {r.get('upCount', '?')}; curated family set untouched)")
        return
    _explain(status, text)


def clear(send=_send):
    status, text = send("DELETE", viewer_base() + "/api/banners", token(), None)
    if status == 200:
        r = json.loads(text) if text else {}
        print(f"ld-photo: cleared {r.get('removed', '?')} texted (up_*) photo(s); curated family set untouched")
        return
    _explain(status, text)


def main(argv):
    if len(argv) == 3 and argv[1] == "add":
        add(argv[2])
    elif len(argv) == 2 and argv[1] == "clear":
        clear()
    else:
        sys.stderr.write("usage: manage_photo.py add <image-path> | manage_photo.py clear\n")
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
