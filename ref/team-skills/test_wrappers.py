#!/usr/bin/env python3
"""Wrapper-contract test for this seed's ld- producers.

The shared POST helper (post_to_kiosk.py) and its own tests live in
plow-pbc/life-dashboard-skills, pulled in as ld-shared by ref/sync-ld-shared.sh
(run this AFTER that sync). This test verifies the part that lives in THIS seed:
each producer's thin wrapper sets the right CARD / BODY_TYPE on the shared
module at import, per the pinned producer→card mapping the viewer renders
(1=alert, 2=affirmation, 4=digest). ld-weather (3) and ld-sports (5) post
directly from their scheduled/run.js on this platform — no Python wrapper — so
they are not listed here.

Each wrapper runs in a fresh interpreter: an in-process import would find
post_to_kiosk already in sys.modules and mask a broken relative sys.path in the
wrapper. A subprocess makes the wrapper's import path actually load-bearing.
"""
import subprocess
import sys
from pathlib import Path

TEAM_SKILLS = Path(__file__).resolve().parent
passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print(f"PASS - {label}")
    else:
        failed += 1
        print(f"FAIL - {label}")


SNIPPET = (
    "import importlib.util, sys\n"
    "spec = importlib.util.spec_from_file_location('wrapper', sys.argv[1])\n"
    "module = importlib.util.module_from_spec(spec)\n"
    "spec.loader.exec_module(module)\n"
    "import post_to_kiosk\n"
    "print(post_to_kiosk.CARD)\n"
    "print(post_to_kiosk.BODY_TYPE)\n"
)

WRAPPERS = (
    ("ld-morning-updates/scripts/post_message.py", "2", "affirmation"),
    ("ld-morning-triage/scripts/post_alert.py", "1", "alert"),
    ("ld-weekly-digest/scripts/post_digest.py", "4", "digest"),
    # calendar nudges share card 1 (the alert slot) with ld-morning-triage.
    ("ld-calendar-nudge/scripts/post_nudge.py", "1", "alert"),
)


def main():
    shared = TEAM_SKILLS / "ld-shared" / "scripts" / "post_to_kiosk.py"
    check("ld-shared synced (run ref/sync-ld-shared.sh first)", shared.exists())
    if not shared.exists():
        print(f"\n{passed} passed, {failed} failed")
        sys.exit(1)

    for rel_path, expected_card, expected_type in WRAPPERS:
        wrapper = TEAM_SKILLS / rel_path
        check(f"{rel_path} wrapper exists", wrapper.exists())
        if not wrapper.exists():
            continue
        proc = subprocess.run(
            [sys.executable, "-c", SNIPPET, str(wrapper)], capture_output=True, text=True
        )
        check(f"{rel_path} imports cleanly via its own sys.path", proc.returncode == 0)
        if proc.returncode != 0:
            print(f"  stderr: {proc.stderr.strip()}")
            continue
        card, body_type = proc.stdout.strip().split("\n")
        check(f"{rel_path} sets CARD={expected_card!r}", card == expected_card)
        check(f"{rel_path} sets BODY_TYPE={expected_type!r}", body_type == expected_type)

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
