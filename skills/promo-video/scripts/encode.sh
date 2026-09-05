#!/usr/bin/env bash
# Codifica los fotogramas a MP4/H.264, que es lo que aceptan X y LinkedIn.
#   encode.sh <carpeta-fotogramas> <salida.mp4> [fps]
set -euo pipefail

FRAMES="${1:?carpeta de fotogramas}"
SALIDA="${2:?fichero .mp4 de salida}"
FPS="${3:-30}"

# El ffmpeg de Playwright esta recortado y solo saca WebM: hay que buscar uno
# con libx264 antes de dar por hecho que "hay ffmpeg".
# Ojo: aqui no se puede usar `... | grep -q`. grep sale al primer acierto,
# ffmpeg recibe SIGPIPE y con `pipefail` la tuberia da error aunque el codec
# este. Se vuelca la salida a una variable y se busca dentro.
tiene_x264() {
  local salida
  salida=$("$1" -hide_banner -encoders 2>/dev/null || true)
  [[ "$salida" == *libx264* ]]
}

buscar_ffmpeg() {
  local c p
  for c in ffmpeg /usr/bin/ffmpeg /usr/local/bin/ffmpeg /snap/bin/ffmpeg; do
    if command -v "$c" >/dev/null 2>&1 && tiene_x264 "$c"; then
      command -v "$c"; return 0
    fi
  done
  p=$(python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())" 2>/dev/null || true)
  if [ -n "$p" ] && [ -x "$p" ] && tiene_x264 "$p"; then
    echo "$p"; return 0
  fi
  return 1
}

FF=$(buscar_ffmpeg) || {
  echo "No hay ffmpeg con libx264. Instala ffmpeg o 'pip install imageio-ffmpeg'." >&2
  exit 1
}
echo "ffmpeg: $FF"

"$FF" -y -framerate "$FPS" -i "$FRAMES/f%05d.png" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -crf 19 -preset slow -movflags +faststart "$SALIDA"

echo "listo: $SALIDA ($(du -h "$SALIDA" | cut -f1))"
