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
#   workdir         : where the copy goes (default: $TMPDIR/cdp-profile)
#   port            : debugging port (default 9222)
#
# NOTE: kill by PORT, never `pkill -f remote-debugging-port` (it kills itself
# because your own command line contains that text).
set -u
umask 077
SRC="${1:?source profile required}"
WORK="${2:-${TMPDIR:-/tmp}/cdp-profile}"
WORK="${WORK%/}"
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

# By system, not by whether fuser exists: macOS ships a BSD fuser with no -k.
free_port() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    lsof -ti "tcp:${1}" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null
  else
    fuser -k "${1}/tcp" >/dev/null 2>&1
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

# The copy holds live sessions: never into a directory someone else owns, and
# only a directory this script made is deleted.
if [[ -e "$WORK" ]]; then
  if [[ ! -O "$WORK" ]]; then
    echo "FATAL: $WORK belongs to another user; pass a workdir of yours" >&2
    exit 1
  fi
  if [[ -n "$(ls -A "$WORK" 2>/dev/null)" && ! -e "$WORK/Local State" ]]; then
    echo "FATAL: $WORK is not a profile copy made by this script; refusing to replace it" >&2
    exit 1
  fi
fi

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
# Not Login Data: the session is in the cookies, the saved passwords are not needed.
for f in Cookies Cookies-wal Cookies-journal Preferences; do
  [ -e "$SRC/$f" ] && cp "$SRC/$f" "$WORK/Default/$f" 2>/dev/null
done
for d in "Local Storage" "Session Storage"; do
  [ -e "$SRC/$d" ] && cp -R "$SRC/$d" "$WORK/Default/$d" 2>/dev/null
done

launch
