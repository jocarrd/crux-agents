#!/usr/bin/env python3
"""Rehace un flujo OAuth de escritorio y guarda los tokens.

    oauth-authorize.py --dir ~/.config/<servicio> --scope "<scope> [<scope>...]"

Levanta un servidor HTTP efímero en loopback que captura el `code` del
redirect, lo intercambia por tokens y los escribe con permisos 600.

Espera un `client.json` en el directorio indicado (el que descarga la consola
del proveedor). El cliente debe ser de tipo escritorio: esos aceptan cualquier
puerto bajo loopback sin registrarlo, los de tipo web no.
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
    ap.add_argument("--dir", required=True, help="directorio con client.json, donde se escriben los tokens")
    ap.add_argument("--scope", required=True, help="scopes separados por espacio")
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
        print(f"ERROR: falta {directory}/client.json", file=sys.stderr)
        return 1
    client = raw.get("installed") or raw.get("web") or raw

    state = secrets.token_urlsafe(16)
    auth_url = args.auth_url + "?" + urllib.parse.urlencode({
        "client_id": client["client_id"],
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": args.scope,
        # Sin estos dos, un proveedor que reutilice un grant previo devuelve
        # solo access_token y el refresh_token no llega nunca.
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
            msg = "Codigo recibido. Vuelve a la terminal." if "code" in qs else "Sin code. Revisa la terminal."
            self.wfile.write(f"<p>{msg}</p>".encode())

        def log_message(self, *a, **k):
            pass

    print("Abre esta URL e inicia sesión con la cuenta que tiene el acceso:\n")
    print(auth_url, "\n")
    try:
        webbrowser.open(auth_url)
    except Exception:
        pass

    with socketserver.TCPServer(("127.0.0.1", args.port), Handler) as httpd:
        httpd.handle_request()

    if "error" in captured:
        print(f"ERROR del proveedor: {captured['error']} ({captured.get('error_description', '')})", file=sys.stderr)
        return 1
    if captured.get("state") != state:
        print("ERROR: el state no coincide (posible CSRF). Aborto.", file=sys.stderr)
        return 1
    if not captured.get("code"):
        print("ERROR: no llegó code en el redirect.", file=sys.stderr)
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
        print(f"ERROR al intercambiar el code: HTTP {e.code}\n{e.read().decode()}", file=sys.stderr)
        return 1

    if "refresh_token" not in tok:
        print("ERROR: la respuesta no trae refresh_token. Revoca el acceso anterior en la",
              file=sys.stderr)
        print("página de permisos de tu cuenta y vuelve a lanzar esto.", file=sys.stderr)
        return 1

    for name in ("refresh_token", "access_token"):
        path = f"{directory}/{name}"
        with open(path, "w") as f:
            f.write(tok[name])
        os.chmod(path, 0o600)

    print(f"OK. refresh_token y access_token escritos en {directory} con permisos 600.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
