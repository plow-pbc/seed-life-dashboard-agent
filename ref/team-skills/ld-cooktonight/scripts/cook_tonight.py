#!/usr/bin/env python3
"""cook_tonight.py — set or clear the life-dashboard's "Cook Tonight" pick.

A thin HTTP client for the kiosk's Pinch featured-recipe endpoints. The head
chef's agent runs it to pin tonight's dinner on the Cook Tonight tile (or clear
it, so the tile auto-falls-back to the most-recently-cooked recipe).

  set    cook_tonight.py set "Sheet-Pan Chicken"      # pin by recipe NAME (resolved → id)
         cook_tonight.py set R-abc123 --note "kids loved it"
         cook_tonight.py set "Tacos" --date 2026-06-23
  clear  cook_tonight.py clear                         # clear today's pick → fallback
         cook_tonight.py clear --date 2026-06-23

Endpoints (same-origin Pinch API, bearer-gated writes):
  GET    {base}/api/pinch/collection   → resolve a recipe NAME to its id
  PUT    {base}/api/pinch/featured      {recipeId, date?, note?}   (Bearer)
  DELETE {base}/api/pinch/featured?date=YYYY-MM-DD                 (Bearer)

Config — base URL + bearer token, read FILE-FIRST then ENV (never from argv, so a
prompt-injected turn can't redirect the credential):
  base URL:  file /config/secrets/pinch-base-url   else env PINCH_BASE_URL
  token:     file /config/secrets/pinch-recipe-token else env PINCH_RECIPE_TOKEN

The recipe NAME/id is the only caller-supplied argument (it is not a secret); the
token is never placed on the command line and never printed (--dry-run redacts it).

Local testing against the 5180 mock:
  PINCH_BASE_URL=http://127.0.0.1:5180 PINCH_RECIPE_TOKEN=<mock-token> \
      ./cook_tonight.py set "Some Recipe Name"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date as _date
from pathlib import Path

BASE_URL_FILE = "/config/secrets/pinch-base-url"
TOKEN_FILE = "/config/secrets/pinch-recipe-token"
BASE_URL_ENV = "PINCH_BASE_URL"
TOKEN_ENV = "PINCH_RECIPE_TOKEN"


def read_config(file_path, env_name, label):
    """File-first, then env. Exit non-zero with a clear label if neither is set."""
    try:
        value = Path(file_path).read_text().strip()
        if value:
            return value
    except OSError:
        pass  # fall through to env
    value = (os.environ.get(env_name) or "").strip()
    if value:
        return value
    sys.exit(f"error: {label} not configured (set file {file_path} or env {env_name})")


def require_safe_url(url):
    """Require https:// — except plain http to localhost/127.0.0.1 (the local mock)."""
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    if parts.scheme == "https":
        return url
    if parts.scheme == "http" and host in ("127.0.0.1", "localhost", "::1"):
        return url
    sys.exit(f"error: base URL must be https:// (or http://127.0.0.1 for local), got: {url}")


def _no_redirect_opener():
    """An opener that refuses 3xx redirects so the bearer is never forwarded to a
    rewritten origin (urllib otherwise replays the Authorization header)."""

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *_args, **_kwargs):
            return None

    return urllib.request.build_opener(_NoRedirect)


def http_json(method, url, token=None, body=None):
    """Send a request; return (status, parsed-json-or-text). Never logs the token."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("content-type", "application/json")
    if token is not None:
        req.add_header("authorization", f"Bearer {token}")
    try:
        with _no_redirect_opener().open(req, timeout=15) as resp:
            raw = resp.read().decode()
            return resp.status, _try_json(raw)
    except urllib.error.HTTPError as exc:
        return exc.code, _try_json(exc.read().decode())
    except urllib.error.URLError as exc:
        sys.exit(f"error: request to {url} failed: {exc.reason}")


def _try_json(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def fetch_collection(base):
    # GET /api/pinch/collection is an UNAUTHENTICATED read — send no bearer here, so the
    # token is presented only on the writes (PUT/DELETE) that actually require it.
    status, body = http_json("GET", f"{base}/api/pinch/collection")
    if status != 200 or not isinstance(body, dict):
        sys.exit(f"error: could not read collection (GET /api/pinch/collection → {status})")
    return body.get("recipes", []) or []


def resolve_recipe(recipes, query):
    """Resolve a recipe NAME or id to an id. Exact-id → exact-title (ci) → unique
    substring (ci). Ambiguous or not-found exits with a helpful message."""
    by_id = {r.get("id"): r for r in recipes if r.get("id")}
    if query in by_id:
        return query, by_id[query].get("title", query)

    q = query.strip().lower()
    exact = [r for r in recipes if (r.get("title") or "").strip().lower() == q]
    if len(exact) == 1:
        return exact[0]["id"], exact[0].get("title", query)
    if len(exact) > 1:
        _exit_ambiguous(query, exact)

    subs = [r for r in recipes if q in (r.get("title") or "").lower()]
    if len(subs) == 1:
        return subs[0]["id"], subs[0].get("title", query)
    if len(subs) > 1:
        _exit_ambiguous(query, subs)

    sys.exit(
        f'error: no recipe matches "{query}". '
        "Check the name (or pass the recipe id) — names are matched case-insensitively."
    )


def _exit_ambiguous(query, matches):
    names = "\n".join(f'  - "{m.get("title")}"  (id {m.get("id")})' for m in matches[:10])
    extra = "" if len(matches) <= 10 else f"\n  …and {len(matches) - 10} more"
    sys.exit(
        f'error: "{query}" is ambiguous — {len(matches)} recipes match:\n{names}{extra}\n'
        "Use a more specific name or pass the exact recipe id."
    )


def main():
    parser = argparse.ArgumentParser(
        description='Set or clear the life-dashboard "Cook Tonight" featured recipe.'
    )
    parser.add_argument("--dry-run", action="store_true", help="print the request instead of sending it")
    sub = parser.add_subparsers(dest="action", required=True)

    p_set = sub.add_parser("set", help="pin tonight's recipe (by name or id)")
    p_set.add_argument("recipe", help="recipe NAME (resolved against the collection) or id")
    p_set.add_argument("--note", help="optional short note shown with the pick", default=None)
    p_set.add_argument("--date", help="YYYY-MM-DD (default: today)", default=None)

    p_clear = sub.add_parser("clear", help="clear the pick (→ tile auto-fallback)")
    p_clear.add_argument("--date", help="YYYY-MM-DD (default: today)", default=None)

    args = parser.parse_args()

    base = require_safe_url(read_config(BASE_URL_FILE, BASE_URL_ENV, "Pinch base URL")).rstrip("/")
    token = read_config(TOKEN_FILE, TOKEN_ENV, "Pinch recipe token")
    day = args.date or _date.today().isoformat()

    if args.action == "set":
        recipes = fetch_collection(base)  # unauth read — no bearer on discovery
        recipe_id, title = resolve_recipe(recipes, args.recipe)
        payload = {"recipeId": recipe_id, "date": day}
        if args.note:
            payload["note"] = args.note
        if args.dry_run:
            _print_dry("PUT", f"{base}/api/pinch/featured", payload)
            print(f"(would pin: \"{title}\" for {day})")
            return
        status, body = http_json("PUT", f"{base}/api/pinch/featured", token=token, body=payload)
        if status != 200:
            sys.exit(f"error: PUT /api/pinch/featured → {status}: {_msg(body)}")
        note_str = f' — {args.note}' if args.note else ""
        print(f'set Cook Tonight: "{title}" for {day}{note_str} · visible on the kiosk within ~5 min')
        return

    # clear
    url = f"{base}/api/pinch/featured?date={urllib.parse.quote(day)}"
    if args.dry_run:
        _print_dry("DELETE", url, None)
        print(f"(would clear the pick for {day})")
        return
    status, body = http_json("DELETE", url, token=token)
    if status != 200:
        sys.exit(f"error: DELETE /api/pinch/featured → {status}: {_msg(body)}")
    print(f"cleared Cook Tonight for {day} — tile returns to its auto-fallback · within ~5 min")


def _print_dry(method, url, payload):
    env = {"method": method, "url": url, "authorization": "Bearer <redacted>"}
    if payload is not None:
        env["body"] = payload
    print(json.dumps(env, indent=2))


def _msg(body):
    if isinstance(body, dict) and "error" in body:
        return body["error"]
    return str(body)


if __name__ == "__main__":
    main()
