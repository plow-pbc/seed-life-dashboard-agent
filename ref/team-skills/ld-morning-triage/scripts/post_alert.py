#!/usr/bin/env python3
"""post_alert.py — post ld-morning-triage's kiosk alert.

Thin wrapper over `team-skills/ld-shared/scripts/post_to_kiosk.py`: sets
the bundle-specific MESSAGE_FILE + CARD + BODY_TYPE, then dispatches.
"""
import os
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "ld-shared", "scripts"),
)
import post_to_kiosk  # noqa: E402

post_to_kiosk.MESSAGE_FILE = "/tmp/ld-morning-triage-text"
post_to_kiosk.CARD = "1"
post_to_kiosk.BODY_TYPE = "alert"


if __name__ == "__main__":
    post_to_kiosk.main()
