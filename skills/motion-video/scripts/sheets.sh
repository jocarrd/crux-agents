#!/usr/bin/env bash
# Sheets for the critique loop: one per beat, a mobile test and an action strip.
#   sheets.sh <video.mp4> <folder> [beat_s=0.5] [strip_second]
set -euo pipefail
video="${1:?usage: sheets.sh <video.mp4> <folder> [beat_s] [strip_second]}"
dest="${2:?missing output folder}"
beat="${3:-0.5}"
strip_at="${4:-}"
[ -f "$video" ] || { echo "does not exist: $video" >&2; exit 1; }
source "$(dirname "$0")/ffmpeg.sh"
mkdir -p "$dest"
probe="$("$FF" -i "$video" 2>&1 || true)"
dur="$(printf '%s\n' "$probe" | sed -n 's/.*Duration: \([0-9:.]*\).*/\1/p' | awk -F: '{print $1*3600+$2*60+$3}')"
[ -n "$dur" ] || { echo "cannot read the duration of $video" >&2; exit 1; }
n="$(awk -v d="$dur" -v b="$beat" 'BEGIN{print int(d/b)+1}')"
cols=11; rows=$(( (n + cols - 1) / cols ))
"$FF" -y -loglevel error -i "$video" -vf "fps=1/$beat,scale=180:-1,tile=${cols}x${rows}" -frames:v 1 "$dest/pulsos.png"
"$FF" -y -loglevel error -i "$video" -vf "fps=0.5,scale=360:-1,tile=6x3" -frames:v 1 "$dest/movil.png"
if [ -n "$strip_at" ]; then
  "$FF" -y -loglevel error -ss "$strip_at" -i "$video" -vf "scale=320:-1,tile=12x1" -frames:v 1 "$dest/tira.png"
fi
echo "sheets in $dest: pulsos.png ($n frames), movil.png${strip_at:+, tira.png}"
