#!/usr/bin/env bash
# Codifica los fotogramas a MP4/H.264 yuv420p, que es lo que aceptan las redes.
#   encode.sh <carpeta-fotogramas> <salida.mp4> [fps] [--sub N] [--audio pista.wav]
# Con --sub N los fotogramas se renderizaron a fps*N y se mezclan de N en N:
# desenfoque de movimiento. Con --audio se mezcla la pista normalizada a -14 LUFS.
set -euo pipefail

FRAMES="${1:?carpeta de fotogramas}"
SALIDA="${2:?fichero .mp4 de salida}"
shift 2
FPS=30; SUB=1; AUDIO=""
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then FPS="$1"; shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --sub) SUB="${2:?--sub necesita un numero}"; shift 2 ;;
    --audio) AUDIO="${2:?--audio necesita un fichero}"; shift 2 ;;
    *) echo "opcion desconocida: $1" >&2; exit 1 ;;
  esac
done
[ -d "$FRAMES" ] || { echo "no existe la carpeta: $FRAMES" >&2; exit 1; }
[ -z "$AUDIO" ] || [ -f "$AUDIO" ] || { echo "no existe el audio: $AUDIO" >&2; exit 1; }

source "$(dirname "$0")/ffmpeg.sh"
echo "ffmpeg: $FF"

VF="null"
if [ "$SUB" -gt 1 ]; then
  VF="tmix=frames=$SUB,select='eq(mod(n\\,$SUB)\\,$((SUB - 1)))',setpts=N/$FPS/TB"
fi

VIDEO="$SALIDA"
[ -z "$AUDIO" ] || VIDEO="${SALIDA%.mp4}.mudo.mp4"

"$FF" -y -loglevel error -framerate "$((FPS * SUB))" -i "$FRAMES/f%05d.png" -vf "$VF" -r "$FPS" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 17 -preset slow -movflags +faststart "$VIDEO"

if [ -n "$AUDIO" ]; then
  "$FF" -y -loglevel error -i "$VIDEO" -i "$AUDIO" -map 0:v -map 1:a -c:v copy \
    -af "alimiter=limit=0.95,loudnorm=I=-14:TP=-1.5:LRA=11" -ar 48000 -c:a aac -b:a 192k \
    -shortest -movflags +faststart "$SALIDA"
  rm -f "$VIDEO"
fi

echo "listo: $SALIDA ($(du -h "$SALIDA" | cut -f1))"
