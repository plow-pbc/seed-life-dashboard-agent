#!/usr/bin/env python3
"""Tests for post_to_kiosk.py — the shared POST helper used by all ld- bundles.

post_to_kiosk.py reads three fixed-path inputs: message text, endpoint URL,
and bearer token. The text
path (MESSAGE_FILE) and the body shape (CARD + BODY_TYPE) are set by each
bundle's thin wrapper before calling main(). These tests import the module and
rebind those module-level constants to scratch files — a seam reachable
only by an importer, never by the CLI a scheduled agent invokes.

Bundle wrappers are also verified end-to-end: each wrapper sets its own
MESSAGE_FILE + CARD + BODY_TYPE and then dispatches to this module, so the
wrappers' rebinds must reach `main()` correctly.
"""
import contextlib
import io
import json
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import post_to_kiosk  # noqa: E402

TEAM_SKILLS = Path(__file__).resolve().parents[2]
TOKEN = "test-token-abc"
passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print(f"PASS - {label}")
    else:
        failed += 1
        print(f"FAIL - {label}")


def run(*args):
    """Invoke post_to_kiosk.main() with the given CLI args.

    Returns (exit_code, stdout_text).
    """
    out = io.StringIO()
    code = 0
    saved = sys.argv
    sys.argv = ["post_to_kiosk.py", *args]
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            post_to_kiosk.main()
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 1
    finally:
        sys.argv = saved
    return code, out.getvalue()


def write_fixtures(
    tmp: Path,
    text: str = "the alert",
    endpoint: str = "https://x.test/api/message",
    card: str = "1",
    body_type: str = "alert",
):
    """Write the three fixed-path inputs to tmp and rebind module constants.

    Returns (msg_file, endpoint_file, token_file).
    """
    msg_file = tmp / "message-text"
    endpoint_file = tmp / "endpoint-url"
    token_file = tmp / "dashboard-token"
    msg_file.write_text(text)
    endpoint_file.write_text(endpoint)
    token_file.write_text(TOKEN)
    post_to_kiosk.MESSAGE_FILE = str(msg_file)
    post_to_kiosk.CARD = card
    post_to_kiosk.BODY_TYPE = body_type
    post_to_kiosk.ENDPOINT_FILE = str(endpoint_file)
    post_to_kiosk.TOKEN_FILE = str(token_file)
    return msg_file, endpoint_file, token_file


class _CapturingHandler(BaseHTTPRequestHandler):
    received = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        type(self).received.append(
            {
                "path": self.path,
                "auth": self.headers.get("Authorization", ""),
                "content_type": self.headers.get("Content-Type", ""),
                "body": json.loads(body),
            }
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *_args):
        pass


def _start_capturing_server():
    _CapturingHandler.received = []
    server = HTTPServer(("127.0.0.1", 0), _CapturingHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    return server, f"http://127.0.0.1:{port}"


# ────────────────────────── tests ──────────────────────────


def test_live_post_hits_endpoint_with_correct_payload():
    server, base = _start_capturing_server()
    try:
        with tempfile.TemporaryDirectory() as d:
            msg_file, _, _ = write_fixtures(
                Path(d),
                text="follow up with Stephanie",
                endpoint=f"{base}/api/message",
                body_type="alert",
            )
            # http:// is now accepted (Pi backend on household LAN/tailnet).
            code, _ = run()
            handoff_consumed_after_success = not msg_file.exists()
    finally:
        server.shutdown()

    check("live POST exit zero", code == 0)
    check("server received exactly one POST", len(_CapturingHandler.received) == 1)
    if _CapturingHandler.received:
        r = _CapturingHandler.received[0]
        check("path is /api/message", r["path"] == "/api/message")
        check("auth header is bearer + token", r["auth"] == f"Bearer {TOKEN}")
        check("content-type is application/json", r["content_type"] == "application/json")
        check("body card matches CARD", r["body"]["card"] == "1")
        check("body type matches BODY_TYPE", r["body"]["type"] == "alert")
        check("body text matches fixture", r["body"]["text"] == "follow up with Stephanie")
        check(
            "body carries only card + type + text (no expiry)",
            set(r["body"]) == {"card", "type", "text"},
        )
    check("handoff file is consumed after a successful POST", handoff_consumed_after_success)


def test_dry_run_redacts_body_and_token():
    """--dry-run always redacts body.text and bearer from stdout. The operator
    can read MESSAGE_FILE directly if they need to verify exact text;
    agent-visible stdout never carries either secret.
    """
    distinctive_alert = "Stephanie asked about the proposal yesterday"
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(Path(d), text=distinctive_alert, body_type="alert")
        code, out = run("--dry-run")
        printed = json.loads(out)
    check("dry-run exit zero", code == 0)
    check("method is POST", printed["method"] == "POST")
    check("authorization is redacted", printed["authorization"] == "Bearer <redacted>")
    check("live token never appears in dry-run stdout", TOKEN not in out)
    check("content-type is json", printed["content_type"] == "application/json")
    check("body card matches CARD", printed["body"]["card"] == "1")
    check("body type matches BODY_TYPE", printed["body"]["type"] == "alert")
    check(
        "body text is redacted with length",
        printed["body"]["text"] == f"<redacted, {len(distinctive_alert)} chars>",
    )
    check("live message text never appears in dry-run stdout", distinctive_alert not in out)


class _Failing500Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(500)
        self.end_headers()

    def log_message(self, *_args):
        pass


def test_non_200_exits_non_zero_and_keeps_handoff_file():
    server = HTTPServer(("127.0.0.1", 0), _Failing500Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        with tempfile.TemporaryDirectory() as d:
            msg_file, _, _ = write_fixtures(Path(d), endpoint=f"{base}/api/message")
            # http:// is accepted — Pi backend on household LAN/tailnet.
            code, _ = run()
            file_exists_after_run = msg_file.exists()
    finally:
        server.shutdown()

    check("non-200 exits non-zero", code != 0)
    check("handoff file is retained after a failed POST", file_exists_after_run)


def test_missing_or_empty_inputs_fail_fast():
    """Each of the three fixed-path inputs fails loudly when missing or
    empty — the helper has no defaults and no fallbacks. Verifies
    read_required's fail-fast contract: cron operator sees a clear
    "<label> not readable" or "<label> is empty" message and a non-zero
    exit, not a half-attempted POST or a misleading "success" log line.
    """
    for label, mutate in (
        ("message text file not readable", lambda p: p["msg"].unlink()),
        ("endpoint file not readable", lambda p: p["endpoint"].unlink()),
        ("token file not readable", lambda p: p["token"].unlink()),
        ("message text file is empty", lambda p: p["msg"].write_text("")),
        ("endpoint file is empty", lambda p: p["endpoint"].write_text("")),
        ("token file is empty", lambda p: p["token"].write_text("")),
    ):
        with tempfile.TemporaryDirectory() as d:
            msg, ep, tok = write_fixtures(Path(d))
            mutate({"msg": msg, "endpoint": ep, "token": tok})
            code, _ = run("--dry-run")
        check(f"--dry-run exits non-zero when {label}", code != 0)


def test_unset_wrapper_constants_fail_fast():
    """The wrapper contract requires MESSAGE_FILE, CARD, and BODY_TYPE to be
    set before main(). A wrapper that forgets one must crash loudly rather
    than silently posting to the wrong slot or with an unset body type.
    """
    for constant in ("MESSAGE_FILE", "CARD", "BODY_TYPE"):
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(Path(d))
            setattr(post_to_kiosk, constant, None)
            code, _ = run("--dry-run")
        check(f"unset {constant} exits non-zero", code != 0)


def test_non_http_schemes_rejected_with_no_token_leak():
    """ftp:// and garbage schemes must fail fast — only http(s):// is allowed.
    Guards against a tampered endpoint file pointing to an unsupported scheme.
    (http:// acceptance is pinned by test_live_post_hits_endpoint_with_correct_payload,
    whose capturing server is plain http; the empty-endpoint case lives in
    test_missing_or_empty_inputs_fail_fast.)"""
    for scheme_url in ("ftp://attacker.test/api/message", "notaurl"):
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(Path(d), endpoint=scheme_url)
            code, out = run("--dry-run")
        check(f"non-http(s) endpoint {scheme_url!r} exits non-zero", code != 0)
        check(f"bearer token not echoed for {scheme_url!r}", TOKEN not in out)


class _RedirectHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(302)
        self.send_header("Location", "https://attacker.test/api/message")
        self.end_headers()

    def log_message(self, *_args):
        pass


def test_redirect_not_followed():
    """A 3xx response must not be followed: the no-redirect opener turns it
    into an HTTPError, which the helper surfaces as a non-zero exit. Without
    this guard, urllib would re-issue the POST (with the Authorization
    header) to the redirect target."""
    server = HTTPServer(("127.0.0.1", 0), _RedirectHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        with tempfile.TemporaryDirectory() as d:
            msg_file, _, _ = write_fixtures(Path(d), endpoint=f"{base}/api/message")
            # http:// is accepted — Pi backend on household LAN/tailnet.
            code, _ = run()
            handoff_kept = msg_file.exists()
    finally:
        server.shutdown()
    check("redirect 302 causes non-zero exit", code != 0)
    check("handoff retained on redirect (not consumed)", handoff_kept)


# ─────────── wrapper smoke tests: each bundle's thin wrapper ───────────


def test_wrapper_contracts():
    """Each bundle's thin wrapper must set CARD / BODY_TYPE / MESSAGE_FILE on
    the shared module at import time, per the pinned producer→card mapping
    (the viewer's slots: 1=alert, 2=affirmation, 3=weather, 4=digest).
    Run each wrapper in a fresh interpreter — the parent test already
    imported `post_to_kiosk` via its own `sys.path.insert`, so an
    in-process import of the wrapper would find `post_to_kiosk` in
    `sys.modules` even if the wrapper's relative `sys.path.insert` were
    broken. A subprocess makes the wrapper's import path actually
    load-bearing.
    """
    import subprocess

    snippet = (
        "import importlib.util, sys\n"
        "spec = importlib.util.spec_from_file_location('wrapper', sys.argv[1])\n"
        "module = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(module)\n"
        # post_to_kiosk now lives in sys.modules with the wrapper's mutations applied.
        "import post_to_kiosk\n"
        "print(post_to_kiosk.CARD)\n"
        "print(post_to_kiosk.BODY_TYPE)\n"
        "print(post_to_kiosk.MESSAGE_FILE)\n"
    )

    for rel_path, expected_card, expected_type, expected_msg_file in (
        ("ld-morning-updates/scripts/post_message.py", "2", "affirmation", "/tmp/ld-morning-updates-message"),
        ("ld-morning-triage/scripts/post_alert.py", "1", "alert", "/tmp/ld-morning-triage-text"),
        ("ld-weekly-digest/scripts/post_digest.py", "4", "digest", "/tmp/ld-weekly-digest-text"),
        # calendar nudges share card 1 (the alert slot) with ld-morning-triage.
        ("ld-calendar-nudge/scripts/post_nudge.py", "1", "alert", "/tmp/ld-calendar-nudge-text"),
    ):
        wrapper = TEAM_SKILLS / rel_path
        check(f"{rel_path} wrapper exists", wrapper.exists())
        if not wrapper.exists():
            continue
        proc = subprocess.run(
            [sys.executable, "-c", snippet, str(wrapper)], capture_output=True, text=True
        )
        check(f"{rel_path} wrapper imports cleanly via its own sys.path", proc.returncode == 0)
        if proc.returncode != 0:
            print(f"  stderr: {proc.stderr.strip()}")
            continue
        card, body_type, msg_file = proc.stdout.strip().split("\n")
        check(f"{rel_path} sets CARD={expected_card!r}", card == expected_card)
        check(f"{rel_path} sets BODY_TYPE={expected_type!r}", body_type == expected_type)
        check(f"{rel_path} sets MESSAGE_FILE={expected_msg_file!r}", msg_file == expected_msg_file)


def main():
    test_dry_run_redacts_body_and_token()
    test_live_post_hits_endpoint_with_correct_payload()
    test_non_200_exits_non_zero_and_keeps_handoff_file()
    test_missing_or_empty_inputs_fail_fast()
    test_unset_wrapper_constants_fail_fast()
    test_non_http_schemes_rejected_with_no_token_leak()
    test_redirect_not_followed()
    test_wrapper_contracts()
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
