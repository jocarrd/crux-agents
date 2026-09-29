# Se carga con `source`. Deja en FF un ffmpeg con libx264 o para con un mensaje.
# El ffmpeg de Playwright esta recortado y solo saca WebM: hay que buscar uno
# con libx264 antes de dar por hecho que "hay ffmpeg".
# Aqui no se puede usar `... | grep -q`: grep sale al primer acierto, ffmpeg
# recibe SIGPIPE y con `pipefail` la tuberia da error aunque el codec este.
tiene_x264() {
  local salida
  salida=$("$1" -hide_banner -encoders 2>/dev/null || true)
  [[ "$salida" == *libx264* ]]
}

buscar_ffmpeg() {
  local c p
  if [ -n "${FFMPEG:-}" ] && tiene_x264 "$FFMPEG"; then echo "$FFMPEG"; return 0; fi
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
  echo "No hay ffmpeg con libx264. Instala ffmpeg, 'pip install imageio-ffmpeg' o exporta FFMPEG." >&2
  exit 1
}
