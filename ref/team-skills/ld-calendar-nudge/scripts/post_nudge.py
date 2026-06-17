#!/usr/bin/env python3
"""post_nudge.py — post ld-calendar-nudge's kiosk reminder.

Thin wrapper over `team-skills/ld-shared/scripts/post_to_kiosk.py`: sets
the bundle-specific CARD + BODY_TYPE + TITLE, then dispatches. The
reminder text is fed to the helper on stdin (quoted heredoc).

Posts as card 1 / type "alert" — calendar reminders share the alert slot
with ld-morning-triage (the store is latest-per-card, so the newest of
the two wins the slot).
"""
import os
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "ld-shared", "scripts"),
)
import post_to_kiosk  # noqa: E402

post_to_kiosk.CARD = "1"
post_to_kiosk.BODY_TYPE = "alert"
post_to_kiosk.TITLE = ""  # hide the eyebrow — matches the scheduled run.js alert post


if __name__ == "__main__":
    post_to_kiosk.main()
