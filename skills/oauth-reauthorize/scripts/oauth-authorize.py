#!/usr/bin/env python3
"""Redoes a desktop OAuth flow and saves the tokens.

    oauth-authorize.py --dir ~/.config/<service> --scope "<scope> [<scope>...]"

Starts an ephemeral HTTP server on loopback that captures the redirect's
`code`, exchanges it for tokens and writes them with 600 permissions.

Expects a `client.json` in the given directory (the one the provider's console
downloads). The client must be of desktop type: those accept any loopback port
without registering it, web ones do not.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import socketserver
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="directory with client.json, where the tokens are written")
    ap.add_argument("--scope", required=True, help="space-separated scopes")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--auth-url", default=GOOGLE_AUTH)
    ap.add_argument("--token-url", default=GOOGLE_TOKEN)
    args = ap.parse_args()

    directory = os.path.expanduser(args.dir)
    redirect_uri = f"http://127.0.0.1:{args.port}"

    try:
        with open(f"{directory}/client.json") as f:
            raw = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: {directory}/client.json is missing", file=sys.stderr)
        return 1
    client = raw.get("installed") or raw.get("web") or raw

    state = secrets.token_urlsafe(16)
    auth_url = args.auth_url + "?" + urllib.parse.urlencode({
        "client_id": client["client_id"],
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": args.scope,
        # Without these two, a provider that reuses a previous grant returns
        # only access_token and the refresh_token never arrives.
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
    })

    captured: dict[str, str] = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            qs = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
            captured.update(qs)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            msg = "Code received. Go back to the terminal." if "code" in qs else "No code. Check the terminal."
            self.wfile.write(f"<p>{msg}</p>".encode())

        def log_message(self, *a, **k):
            pass

    print("Open this URL and sign in with the account that has access:\n")
    print(auth_url, "\n")
    try:
        webbrowser.open(auth_url)
    except Exception:
        pass

    with socketserver.TCPServer(("127.0.0.1", args.port), Handler) as httpd:
        httpd.handle_request()

    if "error" in captured:
        print(f"ERROR from the provider: {captured['error']} ({captured.get('error_description', '')})", file=sys.stderr)
        return 1
    if captured.get("state") != state:
        print("ERROR: the state does not match (possible CSRF). Aborting.", file=sys.stderr)
        return 1
    if not captured.get("code"):
        print("ERROR: no code arrived in the redirect.", file=sys.stderr)
        return 1

    body = urllib.parse.urlencode({
        "code": captured["code"],
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "redirect_uri": redirect_uri,
        "grant_type": "authorization_code",
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(args.token_url, data=body, method="POST")) as r:
            tok = json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"ERROR exchanging the code: HTTP {e.code}\n{e.read().decode()}", file=sys.stderr)
        return 1

    if "refresh_token" not in tok:
        print("ERROR: the response has no refresh_token. Revoke the previous access on the",
              file=sys.stderr)
        print("permissions page of your account and run this again.", file=sys.stderr)
        return 1

    for name in ("refresh_token", "access_token"):
        path = f"{directory}/{name}"
        with open(path, "w") as f:
            f.write(tok[name])
        os.chmod(path, 0o600)

    print(f"OK. refresh_token and access_token written to {directory} with 600 permissions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
