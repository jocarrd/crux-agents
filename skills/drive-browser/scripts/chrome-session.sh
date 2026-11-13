#!/usr/bin/env bash
# Copies the Chrome profile that HAS the session to a non-default directory and
# starts Chrome HEADED with a debugging port and keyring, so the cookies get
# decrypted. Meant to be launched detached (background) and then driven with
# cdp.py while it lives.
#
# Usage: [KEEP_PROFILE=1] chrome-session.sh <src-profile-dir> [workdir] [port]
#   src-profile-dir : the profile that has the session, e.g.
#                     Linux: ~/.config/google-chrome/"Profile 1"
#                     macOS: ~/Library/Application\ Support/Google/Chrome/Default
#   workdir         : where the copy goes (default: /tmp/cdp-profile)
#   port            : debugging port (default 9222)
#
# NOTE: kill by PORT, never `pkill -f remote-debugging-port` (it kills itself
# because your own command line contains that text).
set -u
SRC="${1:?source profile required}"
WORK="${2:-/tmp/cdp-profile}"
PORT="${3:-9222}"
CFG="$(dirname "$SRC")"   # the user data dir that holds the profile and Local State

# macOS keeps the cookie key in the Keychain, which Chrome reaches on its own;
# Linux needs to be told which keyring holds it.
if [[ "$(uname -s)" == "Darwin" ]]; then
  CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
  KEYRING=()
else
  CHROME="${CHROME_BIN:-/opt/google/chrome/chrome}"
  KEYRING=(--password-store=gnome-libsecret)
fi

free_port() {
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${1}/tcp" >/dev/null 2>&1
  else
    lsof -ti "tcp:${1}" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null
  fi
}

launch() {
  exec "$CHROME" \
    --user-data-dir="$WORK" --profile-directory=Default \
    "${KEYRING[@]+"${KEYRING[@]}"}" \
    --remote-debugging-port="$PORT" --remote-allow-origins='*' \
    --no-first-run --no-default-browser-check --disable-features=Translate \
    --window-size=1500,1120 "about:blank"
}

free_port "$PORT"; sleep 1
# KEEP_PROFILE=1 reuses a copy made earlier: what was signed in inside it, Google
# included, is still there. Without it the copy starts again from the source.
if [[ "${KEEP_PROFILE:-0}" == "1" && -f "$WORK/Default/Cookies" ]]; then
  rm -f "$WORK"/Singleton*
  launch
fi
rm -rf "$WORK"; mkdir -p "$WORK/Default"
# Local State holds the encryption key wrapped by the keyring: essential.
cp "$CFG/Local State" "$WORK/" || { echo "FATAL: $CFG/Local State not found; without it Chrome cannot decrypt the cookies" >&2; exit 1; }
for f in Cookies Cookies-wal Cookies-journal Preferences "Login Data"; do
  [ -e "$SRC/$f" ] && cp "$SRC/$f" "$WORK/Default/$f" 2>/dev/null
done
for d in "Local Storage" "Session Storage"; do
  [ -e "$SRC/$d" ] && cp -R "$SRC/$d" "$WORK/Default/$d" 2>/dev/null
done

launch
