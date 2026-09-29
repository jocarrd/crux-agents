#!/usr/bin/env bash
# Hojas para el bucle de crítica: una por pulso, prueba de móvil y tira de acción.
#   sheets.sh <video.mp4> <carpeta> [pulso_s=0.5] [segundo_de_la_tira]
set -euo pipefail
video="${1:?uso: sheets.sh <video.mp4> <carpeta> [pulso_s] [segundo_tira]}"
dest="${2:?falta la carpeta de salida}"
beat="${3:-0.5}"
strip_at="${4:-}"
[ -f "$video" ] || { echo "no existe: $video" >&2; exit 1; }
source "$(dirname "$0")/ffmpeg.sh"
mkdir -p "$dest"
probe="$("$FF" -i "$video" 2>&1 || true)"
dur="$(printf '%s\n' "$probe" | sed -n 's/.*Duration: \([0-9:.]*\).*/\1/p' | awk -F: '{print $1*3600+$2*60+$3}')"
[ -n "$dur" ] || { echo "no puedo leer la duración de $video" >&2; exit 1; }
n="$(awk -v d="$dur" -v b="$beat" 'BEGIN{print int(d/b)+1}')"
cols=11; rows=$(( (n + cols - 1) / cols ))
"$FF" -y -loglevel error -i "$video" -vf "fps=1/$beat,scale=180:-1,tile=${cols}x${rows}" -frames:v 1 "$dest/pulsos.png"
"$FF" -y -loglevel error -i "$video" -vf "fps=0.5,scale=360:-1,tile=6x3" -frames:v 1 "$dest/movil.png"
if [ -n "$strip_at" ]; then
  "$FF" -y -loglevel error -ss "$strip_at" -i "$video" -vf "scale=320:-1,tile=12x1" -frames:v 1 "$dest/tira.png"
fi
echo "hojas en $dest: pulsos.png ($n fotogramas), movil.png${strip_at:+, tira.png}"
