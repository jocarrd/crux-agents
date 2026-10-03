#!/usr/bin/env bash
# Encodes the frames to MP4/H.264 yuv420p, which is what social networks accept.
#   encode.sh <frames-folder> <output.mp4> [fps] [--sub N] [--audio track.wav]
# With --sub N the frames were rendered at fps*N and are blended N at a time:
# motion blur. With --audio the track is mixed in, normalized to -14 LUFS.
set -euo pipefail

FRAMES="${1:?frames folder}"
OUTPUT="${2:?output .mp4 file}"
shift 2
FPS=30; SUB=1; AUDIO=""
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then FPS="$1"; shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --sub) SUB="${2:?--sub needs a number}"; shift 2 ;;
    --audio) AUDIO="${2:?--audio needs a file}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -d "$FRAMES" ] || { echo "folder does not exist: $FRAMES" >&2; exit 1; }
[ -z "$AUDIO" ] || [ -f "$AUDIO" ] || { echo "audio does not exist: $AUDIO" >&2; exit 1; }

source "$(dirname "$0")/ffmpeg.sh"
echo "ffmpeg: $FF"

VF="null"
if [ "$SUB" -gt 1 ]; then
  VF="tmix=frames=$SUB,select='eq(mod(n\\,$SUB)\\,$((SUB - 1)))',setpts=N/$FPS/TB"
fi

VIDEO="$OUTPUT"
[ -z "$AUDIO" ] || VIDEO="${OUTPUT%.mp4}.mute.mp4"

"$FF" -y -loglevel error -framerate "$((FPS * SUB))" -i "$FRAMES/f%05d.png" -vf "$VF" -r "$FPS" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 17 -preset slow -movflags +faststart "$VIDEO"

if [ -n "$AUDIO" ]; then
  "$FF" -y -loglevel error -i "$VIDEO" -i "$AUDIO" -map 0:v -map 1:a -c:v copy \
    -af "alimiter=limit=0.95,loudnorm=I=-14:TP=-1.5:LRA=11" -ar 48000 -c:a aac -b:a 192k \
    -shortest -movflags +faststart "$OUTPUT"
  rm -f "$VIDEO"
fi

echo "done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
