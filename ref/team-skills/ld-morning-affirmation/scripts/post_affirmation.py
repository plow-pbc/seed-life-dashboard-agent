#!/usr/bin/env python3
"""post_affirmation.py — post ld-morning-affirmation's kiosk affirmation.

Thin wrapper over `team-skills/ld-shared/scripts/post_to_kiosk.py`: sets
the bundle-specific MESSAGE_FILE + BODY_TYPE + DEFAULT_CARD, then dispatches.
"""
import os
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "ld-shared", "scripts"),
)
import post_to_kiosk  # noqa: E402

post_to_kiosk.MESSAGE_FILE = "/tmp/ld-morning-affirmation-text"
post_to_kiosk.BODY_TYPE = "affirmation"
post_to_kiosk.DEFAULT_CARD = "2"


if __name__ == "__main__":
    post_to_kiosk.main()
