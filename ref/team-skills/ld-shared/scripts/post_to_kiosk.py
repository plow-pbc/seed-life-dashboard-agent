#!/usr/bin/env python3
"""post_to_kiosk.py — shared POST helper for the WRAPPER-BASED ld- bundles.

Each wrapper-based ld- bundle ships a tiny wrapper (`post_message.py`,
`post_alert.py`, `post_digest.py`, `post_nudge.py`) that sets three
module-level constants and calls `main()`. The wrapper is the only file the
cron/agent invokes; this module is never on the agent's invocation path
directly. That keeps the no-CLI-content security model intact: the
bundle-specific `MESSAGE_FILE` path lives in the wrapper (one fixed string
per bundle), not on the command line.

The Pattern-B *scheduled* runners post to the kiosk directly from their
`scheduled/run.js` (same http(s)-allowed, no-redirect, fail-loud posture, in JS),
not via this helper: `ld-weather` posts only that way (no wrapper at all),
and `ld-calendar-nudge` is a hybrid — its scheduled `run.js` posts directly
while it still ships `post_nudge.py` for its manual reminder path (which
uses this helper).

Read from fixed paths the caller cannot redirect — not from argv, not from
the environment:
  - message text:  caller-set MESSAGE_FILE (per-bundle, e.g. /tmp/ld-<x>-text)
  - endpoint URL:  /config/secrets/dashboard-endpoint-url
  - bearer token:  /config/secrets/dashboard-token

The test suite imports this module directly and rebinds these constants — a
seam reachable only by an importer, not by the CLI.

Caller contract (the viewer requires all three of card/type/text; `card`
picks the kiosk slot — latest post per card wins. The card's eyebrow defaults
to `type`; set the optional module var TITLE to "" to hide it or to a string to
override it):

    import post_to_kiosk
    post_to_kiosk.MESSAGE_FILE = "/tmp/ld-<bundle>-text"
    post_to_kiosk.CARD = "1" | "2" | "3" | "4"
    post_to_kiosk.BODY_TYPE = "alert" | "affirmation" | "digest"
    post_to_kiosk.main()

`--dry-run` always redacts the body text to `<redacted, N chars>` — some
bundles paraphrase private mail/iMessage bodies and the operator can read
MESSAGE_FILE directly to verify exact text, so the dry-run output stays
non-sensitive across all bundles.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Bundle-specific — wrapper sets these before calling main().
MESSAGE_FILE: str | None = None
CARD: str | None = None
BODY_TYPE: str | None = None
# Optional producer-controlled eyebrow. Leave None to show the card's type as
# its title (default); set "" to HIDE the title (reclaim vertical space); set a
# string to override it.
TITLE: str | None = None

# Shared across all ld- bundles.
ENDPOINT_FILE = "/config/secrets/dashboard-endpoint-url"
TOKEN_FILE = "/config/secrets/dashboard-token"
# The Pi backend rides the household LAN/tailnet, not the public internet —
# http:// is an accepted trade-off for that trust zone.
REQUIRED_URL_PREFIXES = ("http://", "https://")


def read_required(path, label):
    """Read the stripped contents of `path` or exit non-zero with a clear label.

    Used for both single-line config files (endpoint URL, bearer token) and
    multi-line message bodies (digest text, alert text) — `.strip()` only
    removes leading/trailing whitespace, so embedded newlines round-trip.
    """
    try:
        value = Path(path).read_text().strip()
    except OSError as exc:
        sys.exit(f"error: {label} not readable: {path} ({exc.strerror})")
    if not value:
        sys.exit(f"error: {label} is empty: {path}")
    return value


def _no_redirect_opener():
    """urllib opener that refuses 3xx redirects.

    Default urllib follows redirects AND forwards the Authorization header
    to the new origin — a rewritten endpoint or compromised host could
    steer the bearer to an attacker URL. Refuse the redirect; the existing
    HTTPError handler then fails loudly.
    """

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *_args, **_kwargs):
            return None

    return urllib.request.build_opener(_NoRedirect)


def main():
    if not MESSAGE_FILE:
        sys.exit("error: post_to_kiosk.MESSAGE_FILE not set by caller")
    if not CARD:
        sys.exit("error: post_to_kiosk.CARD not set by caller")
    if not BODY_TYPE:
        sys.exit("error: post_to_kiosk.BODY_TYPE not set by caller")

    parser = argparse.ArgumentParser(
        description=f"Post a {BODY_TYPE!r} message to the life-dashboard kiosk."
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print the request instead of sending it"
    )
    args = parser.parse_args()

    text = read_required(MESSAGE_FILE, f"{BODY_TYPE} text file")
    url = read_required(ENDPOINT_FILE, "endpoint file")
    if not any(url.startswith(p) for p in REQUIRED_URL_PREFIXES):
        sys.exit(f"error: endpoint URL must start with http:// or https://, got: {url}")
    token = read_required(TOKEN_FILE, "token file")

    body = {"card": CARD, "type": BODY_TYPE, "text": text}
    if TITLE is not None:
        body["title"] = TITLE

    if args.dry_run:
        # Always redact the body text — some bundles paraphrase private
        # mail/iMessage content, and a single redaction policy across all
        # bundles avoids a per-bundle privacy branch. The operator can read
        # MESSAGE_FILE directly to verify exact text.
        print(
            json.dumps(
                {
                    "method": "POST",
                    "url": url,
                    "authorization": "Bearer <redacted>",
                    "content_type": "application/json",
                    "body": {**body, "text": f"<redacted, {len(text)} chars>"},
                },
                indent=2,
            )
        )
        return

    req = urllib.request.Request(
        url=url,
        method="POST",
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    opener = _no_redirect_opener()
    try:
        # urllib's default HTTPErrorProcessor raises HTTPError on any non-2xx,
        # so reaching this block means success — discard the response body
        # rather than echoing it to stdout. The endpoint may echo submitted
        # text on success, and that text can be derived from private content
        # (e.g. ld-morning-triage's paraphrased mail bodies).
        opener.open(req, timeout=30).close()
        # Consume the one-shot handoff file so a later run can't repost this
        # text. Left intact on the error paths below so a retry resends it.
        os.unlink(MESSAGE_FILE)
    except urllib.error.HTTPError as exc:
        # Don't decode exc.read() — same echoed-text concern as the success path.
        sys.exit(f"error: message API returned HTTP {exc.code} {exc.reason}")
    except urllib.error.URLError as exc:
        sys.exit(f"error: POST to {url} failed: {exc.reason}")


if __name__ == "__main__":
    main()
