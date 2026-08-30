#!/usr/bin/env bash
# Copia el perfil de Chrome que TIENE la sesión a un directorio no-default y
# arranca Chrome HEADED con puerto de depuración y llavero, para que las cookies
# se descifren. Pensado para lanzarse desacoplado (background) y luego pilotar
# con cdp.py mientras vive.
#
# Uso: chrome-session.sh <src-profile-dir> [workdir] [port]
#   src-profile-dir : p.ej. ~/.config/google-chrome/"Profile 1"  (el que tiene la sesión)
#   workdir         : dónde va la copia (default: /tmp/cdp-profile)
#   port            : puerto de depuración (default 9222)
#
# OJO: kill por PUERTO (fuser -k), nunca `pkill -f remote-debugging-port` (se
# mata a sí mismo porque tu propia línea de comando contiene ese texto).
set -u
SRC="${1:?perfil de origen requerido}"
WORK="${2:-/tmp/cdp-profile}"
PORT="${3:-9222}"
CHROME="${CHROME_BIN:-/opt/google/chrome/chrome}"
CFG="$(dirname "$(dirname "$SRC")")"   # .../google-chrome

fuser -k "${PORT}/tcp" >/dev/null 2>&1; sleep 1
rm -rf "$WORK"; mkdir -p "$WORK/Default"
# Local State lleva la clave de cifrado envuelta por el llavero: imprescindible.
cp "$CFG/Local State" "$WORK/" 2>/dev/null
for f in Cookies Cookies-wal Preferences "Login Data"; do
  [ -e "$SRC/$f" ] && cp "$SRC/$f" "$WORK/Default/$f" 2>/dev/null
done
for d in "Local Storage" "Session Storage"; do
  [ -e "$SRC/$d" ] && cp -r "$SRC/$d" "$WORK/Default/$d" 2>/dev/null
done

exec "$CHROME" \
  --user-data-dir="$WORK" --profile-directory=Default \
  --password-store=gnome-libsecret \
  --remote-debugging-port="$PORT" --remote-allow-origins='*' \
  --no-first-run --no-default-browser-check --disable-features=Translate \
  --window-size=1500,1120 "about:blank"
