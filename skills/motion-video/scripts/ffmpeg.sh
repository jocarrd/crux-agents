# shellcheck shell=bash
# Loaded with `source`. Leaves an ffmpeg with libx264 in FF or stops with a message.
# Playwright's ffmpeg is stripped down and only outputs WebM: look for one with
# libx264 before assuming "there is ffmpeg".
# `... | grep -q` cannot be used here: grep exits at the first match, ffmpeg
# gets SIGPIPE and under `pipefail` the pipe fails even though the codec is there.
has_x264() {
  local output
  output=$("$1" -hide_banner -encoders 2>/dev/null || true)
  [[ "$output" == *libx264* ]]
}

find_ffmpeg() {
  local c p
  if [ -n "${FFMPEG:-}" ] && has_x264 "$FFMPEG"; then echo "$FFMPEG"; return 0; fi
  for c in ffmpeg /usr/bin/ffmpeg /usr/local/bin/ffmpeg /snap/bin/ffmpeg; do
    if command -v "$c" >/dev/null 2>&1 && has_x264 "$c"; then
      command -v "$c"; return 0
    fi
  done
  p=$(python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())" 2>/dev/null || true)
  if [ -n "$p" ] && [ -x "$p" ] && has_x264 "$p"; then
    echo "$p"; return 0
  fi
  return 1
}

# FF is used by the script that loads this one.
# shellcheck disable=SC2034
FF=$(find_ffmpeg) || {
  echo "No ffmpeg with libx264. Install ffmpeg, 'pip install imageio-ffmpeg' or export FFMPEG." >&2
  exit 1
}
