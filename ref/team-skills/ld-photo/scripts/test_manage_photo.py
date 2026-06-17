#!/usr/bin/env python3
"""Contract test for ld-photo's manage_photo.py.

Verifies the part that lives in THIS skill — request construction against the
viewer's banner CRUD contract (PR #50) and the HEIC guard — with the network
stubbed (an injected `send`). The endpoint itself is tested in the viewer repo.

Stdlib only; run directly: `python3 test_manage_photo.py`.
"""
import base64
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import manage_photo as mp  # noqa: E402

# Deterministic config regardless of host: point the secret files at nonexistent
# paths so token()/viewer_base() fall back to the env we set here.
mp.TOKEN_FILE = "/nonexistent/ld-photo-token"
mp.BASE_FILE = "/nonexistent/ld-photo-base"
os.environ["DASHBOARD_TOKEN"] = "testtok"
os.environ["VIEWER_BASE_URL"] = "http://pi.example/fd"

passed = failed = 0


def check(label, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"PASS - {label}")
    else:
        failed += 1
        print(f"FAIL - {label}")


calls = []


def fake_send(method, url, tok, body=None):
    calls.append({"method": method, "url": url, "tok": tok, "body": body})
    return fake_send.ret


fake_send.ret = (200, json.dumps({"stored": "up_1700000000_x.jpg", "upCount": 1}))

d = tempfile.mkdtemp()
jpg = os.path.join(d, "Sunset Pic.jpg")
open(jpg, "wb").write(b"\xff\xd8\xff\xe0" + b"x" * 64)  # JPEG magic + filler


def expect_exit(fn):
    try:
        fn()
        return False
    except SystemExit:
        return True


# --- add: correct request construction ---
calls.clear()
mp.add(jpg, send=fake_send)
c = calls[0] if calls else {}
check("add POSTs to {base}/api/banners", c.get("method") == "POST" and c.get("url") == "http://pi.example/fd/api/banners")
check("add sends the bearer token", c.get("tok") == "testtok")
check("add body filename is the basename", (c.get("body") or {}).get("filename") == "Sunset Pic.jpg")
check("add body data is base64 of the file bytes",
      base64.b64decode((c.get("body") or {}).get("data", "")) == open(jpg, "rb").read())

# --- clear: DELETE the up_* set ---
calls.clear()
fake_send.ret = (200, json.dumps({"removed": 3, "upCount": 0}))
mp.clear(send=fake_send)
c = calls[0] if calls else {}
check("clear DELETEs {base}/api/banners", c.get("method") == "DELETE" and c.get("url") == "http://pi.example/fd/api/banners")
check("clear sends the bearer token", c.get("tok") == "testtok")

# --- HEIC guard: rejected BEFORE any upload (by extension AND by magic bytes) ---
heic_ext = os.path.join(d, "img.heic")
open(heic_ext, "wb").write(b"\x00\x00\x00\x18ftypheic" + b"\x00" * 16)
calls.clear()
check("HEIC by extension is rejected before upload", expect_exit(lambda: mp.add(heic_ext, send=fake_send)) and not calls)

heic_magic = os.path.join(d, "actually_heic.jpg")  # .jpg name but HEIC major brand
open(heic_magic, "wb").write(b"\x00\x00\x00\x18ftypmif1" + b"\x00" * 16)
calls.clear()
check("HEIC magic (major brand) caught even with a .jpg name", expect_exit(lambda: mp.add(heic_magic, send=fake_send)) and not calls)

# HEIC where the MAJOR brand is benign but a COMPATIBLE brand is heic — still caught.
# ftyp box (size 0x18=24): size + 'ftyp' + major 'mp42' + minor 0 + compat 'mp41','heic'
heic_compat = os.path.join(d, "looks_ok.jpg")
open(heic_compat, "wb").write(b"\x00\x00\x00\x18ftyp" + b"mp42" + b"\x00\x00\x00\x00" + b"mp41heic")
calls.clear()
check("HEIC via a COMPATIBLE brand is refused", expect_exit(lambda: mp.add(heic_compat, send=fake_send)) and not calls)

# --- positive allowlist: a non-image is refused before upload ---
notimg = os.path.join(d, "not-image.jpg")  # .jpg name, but it's text
open(notimg, "wb").write(b"This is plain text, not an image.\n")
calls.clear()
check("non-image (text) refused before upload", expect_exit(lambda: mp.add(notimg, send=fake_send)) and not calls)

# --- a real PNG passes the guard and uploads ---
png = os.path.join(d, "pic.png")
open(png, "wb").write(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32)
calls.clear()
fake_send.ret = (200, json.dumps({"stored": "up_1_p.jpg", "upCount": 1}))
mp.add(png, send=fake_send)
check("real PNG passes the allowlist and uploads", len(calls) == 1 and calls[0]["method"] == "POST")

# --- HTTP error mapping: clean exit, no crash ---
for status in (401, 400, 413):
    calls.clear()
    fake_send.ret = (status, "rejected")
    check(f"HTTP {status} → clean error exit", expect_exit(lambda: mp.add(jpg, send=fake_send)))

# --- missing token → clean error ---
fake_send.ret = (200, "{}")
os.environ.pop("DASHBOARD_TOKEN", None)
check("missing token → clean error", expect_exit(mp.token))
os.environ["DASHBOARD_TOKEN"] = "testtok"

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
