#!/usr/bin/env python3
"""Tests for post_to_kiosk.py — the shared POST helper used by all ld- bundles.

post_to_kiosk.py reads three fixed-path inputs: message text, endpoint URL,
and bearer token. The text
path (MESSAGE_FILE) and the body shape (BODY_TYPE) are set by each bundle's
thin wrapper before calling main(). These tests import the module and
rebind those module-level constants to scratch files — a seam reachable
only by an importer, never by the CLI a scheduled agent invokes.

Bundle wrappers are also verified end-to-end: each wrapper sets its own
MESSAGE_FILE + BODY_TYPE + DEFAULT_CARD and then dispatches to this module,
so the wrappers' rebinds must reach `main()` correctly.
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

    Returns (exit_code, stdout_text, err_text). err_text carries both captured
    stderr and a sys.exit(message) string (the interpreter would print that to
    stderr; under this harness it travels in SystemExit.code).
    """
    out = io.StringIO()
    err = io.StringIO()
    code = 0
    saved = sys.argv
    sys.argv = ["post_to_kiosk.py", *args]
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            post_to_kiosk.main()
    except SystemExit as exc:
        if isinstance(exc.code, int):
            code = exc.code
        else:
            code = 1
            if exc.code is not None:
                err.write(str(exc.code))
    finally:
        sys.argv = saved
    return code, out.getvalue(), err.getvalue()


def write_fixtures(
    tmp: Path,
    text: str = "the alert",
    endpoint: str = "https://x.test/api/message",
    body_type: str = "alert",
    default_card: str | None = "1",
    config: dict | None = None,
):
    """Write the three fixed-path inputs to tmp and rebind module constants.

    Returns (msg_file, endpoint_file, token_file).
    config, if given, is written to a config.json in tmp and CONFIG_FILE is rebound.
    """
    msg_file = tmp / "message-text"
    endpoint_file = tmp / "endpoint-url"
    token_file = tmp / "dashboard-token"
    msg_file.write_text(text)
    endpoint_file.write_text(endpoint)
    token_file.write_text(TOKEN)
    post_to_kiosk.MESSAGE_FILE = str(msg_file)
    post_to_kiosk.BODY_TYPE = body_type
    post_to_kiosk.DEFAULT_CARD = default_card
    post_to_kiosk.ENDPOINT_FILE = str(endpoint_file)
    post_to_kiosk.TOKEN_FILE = str(token_file)
    if config is not None:
        cfg_file = tmp / "config.json"
        cfg_file.write_text(json.dumps(config))
        post_to_kiosk.CONFIG_FILE = str(cfg_file)
    else:
        # Point at a non-existent path so tests that rely on DEFAULT_CARD
        # are not accidentally influenced by a real config on the host.
        post_to_kiosk.CONFIG_FILE = str(tmp / "no-config.json")
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
                default_card="1",
            )
            # http:// is now accepted (Pi backend on household LAN/tailnet).
            code, _, _err = run()
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
        check("body type matches BODY_TYPE", r["body"]["type"] == "alert")
        check("body text matches fixture", r["body"]["text"] == "follow up with Stephanie")
        check("body card is default_card", r["body"]["card"] == "1")
        check("body carries card + type + text only", set(r["body"]) == {"card", "type", "text"})
    check("handoff file is consumed after a successful POST", handoff_consumed_after_success)


def test_dry_run_redacts_body_and_token():
    """--dry-run always redacts body.text and bearer from stdout. The operator
    can read MESSAGE_FILE directly if they need to verify exact text;
    agent-visible stdout never carries either secret. card is NOT secret
    and IS shown in dry-run output.
    """
    distinctive_alert = "Stephanie asked about the proposal yesterday"
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(Path(d), text=distinctive_alert, body_type="alert", default_card="1")
        code, out, _err = run("--dry-run")
        printed = json.loads(out)
    check("dry-run exit zero", code == 0)
    check("method is POST", printed["method"] == "POST")
    check("authorization is redacted", printed["authorization"] == "Bearer <redacted>")
    check("live token never appears in dry-run stdout", TOKEN not in out)
    check("content-type is json", printed["content_type"] == "application/json")
    check("body type matches BODY_TYPE", printed["body"]["type"] == "alert")
    check("body card shown in dry-run (not secret)", printed["body"]["card"] == "1")
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
            code, _, _err = run()
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
            code, _, _err = run("--dry-run")
        check(f"--dry-run exits non-zero when {label}", code != 0)


def test_unset_message_file_or_body_type_fails_fast():
    """The wrapper contract requires both MESSAGE_FILE and BODY_TYPE to be
    set before main(). A wrapper that forgets one must crash loudly rather
    than silently posting to the wrong slot or with an unset body type.
    """
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(Path(d))
        post_to_kiosk.MESSAGE_FILE = None
        code, _, _err = run("--dry-run")
        check("unset MESSAGE_FILE exits non-zero", code != 0)
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(Path(d))
        post_to_kiosk.BODY_TYPE = None
        code, _, _err = run("--dry-run")
        check("unset BODY_TYPE exits non-zero", code != 0)


def test_non_http_schemes_rejected_with_no_token_leak():
    """ftp:// and garbage schemes must fail fast — only http(s):// is allowed.
    Guards against a tampered endpoint file pointing to an unsupported scheme.
    (http:// acceptance is pinned by test_live_post_hits_endpoint_with_correct_payload,
    whose capturing server is plain http; the empty-endpoint case lives in
    test_missing_or_empty_inputs_fail_fast.)"""
    for scheme_url in ("ftp://attacker.test/api/message", "notaurl"):
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(Path(d), endpoint=scheme_url)
            code, out, _err = run("--dry-run")
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
            code, _, _err = run()
            handoff_kept = msg_file.exists()
    finally:
        server.shutdown()
    check("redirect 302 causes non-zero exit", code != 0)
    check("handoff retained on redirect (not consumed)", handoff_kept)


# ─────────── card-targeting tests ───────────


def test_card_default_used_when_no_config():
    """DEFAULT_CARD is used when CONFIG_FILE is absent (no config.json)."""
    server, base = _start_capturing_server()
    try:
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(
                Path(d),
                text="hello",
                endpoint=f"{base}/api/message",
                body_type="alert",
                default_card="1",
                config=None,  # ensures CONFIG_FILE points at a non-existent path
            )
            code, _, _err = run()
    finally:
        server.shutdown()
    check("default card fallback: exit zero", code == 0)
    if _CapturingHandler.received:
        check("default card fallback: card is '1'", _CapturingHandler.received[0]["body"]["card"] == "1")


def test_config_card_target_overrides_default():
    """dashboard.card_targets[BODY_TYPE] in config.json overrides DEFAULT_CARD."""
    server, base = _start_capturing_server()
    try:
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(
                Path(d),
                text="hello",
                endpoint=f"{base}/api/message",
                body_type="alert",
                default_card="1",
                config={"dashboard": {"card_targets": {"alert": "3"}}},
            )
            code, _, _err = run()
    finally:
        server.shutdown()
    check("config override: exit zero", code == 0)
    if _CapturingHandler.received:
        check("config override: card is '3' (from config)", _CapturingHandler.received[0]["body"]["card"] == "3")


def test_missing_card_both_default_and_config_fails_fast():
    """When DEFAULT_CARD is None and config has no matching card_target, fail fast."""
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(
            Path(d),
            body_type="alert",
            default_card=None,
            config={"dashboard": {"card_targets": {"weather": "3"}}},  # no 'alert' key
        )
        code, _, _err = run("--dry-run")
    check("missing card fails fast (non-zero exit)", code != 0)


def test_missing_card_no_config_no_default_fails_fast():
    """DEFAULT_CARD=None with no config file at all → fail fast."""
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(
            Path(d),
            body_type="alert",
            default_card=None,
            config=None,
        )
        code, _, _err = run("--dry-run")
    check("missing card (no config, no default) fails fast", code != 0)


def test_dry_run_shows_card_from_config():
    """card from config.json appears in --dry-run output (not secret)."""
    with tempfile.TemporaryDirectory() as d:
        write_fixtures(
            Path(d),
            text="some text",
            body_type="digest",
            default_card="4",
            config={"dashboard": {"card_targets": {"digest": "2"}}},
        )
        code, out, _err = run("--dry-run")
        printed = json.loads(out)
    check("dry-run with config card: exit zero", code == 0)
    check("dry-run with config card: card is '2' (from config)", printed["body"]["card"] == "2")


def test_malformed_json_config_fails_fast():
    """A config file that exists but is not valid JSON must exit non-zero with a
    clear message — not silently fall back to DEFAULT_CARD."""
    with tempfile.TemporaryDirectory() as d:
        cfg_file = Path(d) / "config.json"
        cfg_file.write_text("{not valid json")
        write_fixtures(Path(d), body_type="alert", default_card="1")
        post_to_kiosk.CONFIG_FILE = str(cfg_file)
        code, _, _err = run("--dry-run")
    check("malformed JSON config exits non-zero", code != 0)


def test_invalid_card_config_fails_fast():
    """A PRESENT-but-invalid override or wrong-shape config node must exit
    non-zero with a clear message — never silently fall back to DEFAULT_CARD
    (a silent fallback would misroute the card with exit 0). Absent / null
    nodes are the legitimate fallback (covered by the tests above)."""
    cases = [
        ("numeric leaf", {"dashboard": {"card_targets": {"alert": 3}}}, "card_targets.alert"),
        ("whitespace-only leaf", {"dashboard": {"card_targets": {"alert": "  "}}}, "card_targets.alert"),
        ("non-dict dashboard", {"dashboard": "x"}, "dashboard"),
        ("non-dict card_targets", {"dashboard": {"card_targets": 5}}, "card_targets"),
        ("non-object top level", ["not", "an", "object"], "JSON object"),
    ]
    for label, cfg, named in cases:
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(
                Path(d),
                body_type="alert",
                default_card="1",
                config=cfg,
            )
            code, _, err = run("--dry-run")
        check(f"invalid card config ({label}) exits non-zero", code != 0)
        check(f"invalid card config ({label}) names the offending node", named in err)


def test_dashboard_null_falls_back_to_default():
    """'dashboard': null means the key is absent/unconfigured → fallback to
    DEFAULT_CARD is correct (the shape is merely absent, not invalid)."""
    server, base = _start_capturing_server()
    try:
        with tempfile.TemporaryDirectory() as d:
            write_fixtures(
                Path(d),
                text="hello",
                endpoint=f"{base}/api/message",
                body_type="alert",
                default_card="1",
                config={"dashboard": None},
            )
            code, _, _err = run()
    finally:
        server.shutdown()
    check("dashboard:null falls back to DEFAULT_CARD (exit zero)", code == 0)
    if _CapturingHandler.received:
        check("dashboard:null uses default card '1'", _CapturingHandler.received[0]["body"]["card"] == "1")


# ─────────── wrapper smoke tests: each bundle's thin wrapper ───────────


def test_wrapper_contracts():
    """Each bundle's thin wrapper must set BODY_TYPE / MESSAGE_FILE / DEFAULT_CARD
    on the shared module at import time.
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
        "print(post_to_kiosk.BODY_TYPE)\n"
        "print(post_to_kiosk.MESSAGE_FILE)\n"
        "print(post_to_kiosk.DEFAULT_CARD)\n"
    )

    for rel_path, expected_type, expected_msg_file, expected_card in (
        ("ld-morning-affirmation/scripts/post_affirmation.py", "affirmation", "/tmp/ld-morning-affirmation-text", "2"),
        ("ld-morning-triage/scripts/post_alert.py", "alert", "/tmp/ld-morning-triage-text", "1"),
        ("ld-weekly-digest/scripts/post_digest.py", "digest", "/tmp/ld-weekly-digest-text", "4"),
        ("ld-calendar-nudge/scripts/post_nudge.py", "nudge", "/tmp/ld-calendar-nudge-text", "2"),
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
        lines = proc.stdout.strip().split("\n")
        body_type, msg_file, default_card = lines[0], lines[1], lines[2]
        check(f"{rel_path} sets BODY_TYPE={expected_type!r}", body_type == expected_type)
        check(f"{rel_path} sets MESSAGE_FILE={expected_msg_file!r}", msg_file == expected_msg_file)
        check(f"{rel_path} sets DEFAULT_CARD={expected_card!r}", default_card == expected_card)


def main():
    test_dry_run_redacts_body_and_token()
    test_live_post_hits_endpoint_with_correct_payload()
    test_non_200_exits_non_zero_and_keeps_handoff_file()
    test_missing_or_empty_inputs_fail_fast()
    test_unset_message_file_or_body_type_fails_fast()
    test_non_http_schemes_rejected_with_no_token_leak()
    test_redirect_not_followed()
    test_card_default_used_when_no_config()
    test_config_card_target_overrides_default()
    test_missing_card_both_default_and_config_fails_fast()
    test_missing_card_no_config_no_default_fails_fast()
    test_dry_run_shows_card_from_config()
    test_malformed_json_config_fails_fast()
    test_invalid_card_config_fails_fast()
    test_dashboard_null_falls_back_to_default()
    test_wrapper_contracts()
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
