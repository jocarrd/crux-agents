#!/usr/bin/env bash
# Puts each env file back in its place, reading the map next to it.
#
#   ./restaurar.sh                     says what it would do, touching nothing
#   ./restaurar.sh --apply             copies them (--hazlo still works)
#   ./restaurar.sh /path/project --apply   if the project is not where expected
#
# Never overwrites: losing a value that only existed at the destination is
# worse than copying too little.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP="$HERE/mapa.txt"
[[ -f "$MAP" ]] || { echo "mapa.txt is missing next to this script"; exit 1; }

NAME="$(head -1 "$MAP" | sed -n 's/^# \(project\|proyecto\): //p')"
DO_IT=0; TARGET=""
for a in "$@"; do
  if [[ "$a" == "--hazlo" || "$a" == "--apply" ]]; then DO_IT=1; else TARGET="$a"; fi
done

# The root on THIS machine, which need not match the one the folder came from:
# the variable, then the folder crux saved, then crux's own default.
# A machine without crux has no config: under pipefail, sed failing on it ended
# the script with exit 2 and not a word, on exactly the machine this is for.
CONFIGURED=""
if [[ -f "$HOME/.crux/config" ]]; then
  CONFIGURED="$(sed -n 's/^CRUX_PROJECTS_DIR="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$HOME/.crux/config" | tail -1)"
fi
ROOT="${CRUX_PROJECTS_DIR:-${CONFIGURED:-$HOME/Projects}}"
PROJECT="${TARGET:-$ROOT/$NAME}"

# A folder gathered before collect.sh anchored on the project root is named
# after a repo, not the project, so the destination is one level deeper.
# Looking for it here avoids having to redo those folders (already built and
# holding secrets) from the source machine.
if [[ -z "$TARGET" && ! -d "$PROJECT" ]]; then
  for c in "$ROOT"/*/"$NAME"; do
    [[ -d "$c" ]] || continue
    echo "$NAME is not a project but a repo of $(basename "$(dirname "$c")")"
    PROJECT="$c"; break
  done
fi

[[ -d "$PROJECT" ]] || {
  echo "cannot find the project at $ROOT/$NAME nor as a repo of any project"
  echo "pass it as an argument: ./restaurar.sh /path/to/project --apply"
  exit 1
}
echo "restoring into $PROJECT"
echo

placed=0; skipped=0; no_repo=0
while IFS='|' read -r origin target; do
  [[ -n "$origin" && "$origin" != \#* ]] || continue
  src="$HERE/$origin"; dst="$PROJECT/$target"
  [[ -f "$src" ]] || { echo "  missing here $origin"; continue; }
  if [[ ! -d "$(dirname "$dst")" ]]; then
    echo "  no repo      $target"; no_repo=$((no_repo+1)); continue
  fi
  if [[ -f "$dst" ]]; then
    echo "  exists       $target"; skipped=$((skipped+1)); continue
  fi
  if [[ $DO_IT -eq 1 ]]; then
    cp -p "$src" "$dst"; chmod 600 "$dst"; echo "  placed       $target"
  else
    echo "  would place  $target"
  fi
  placed=$((placed+1))
done < "$MAP"

echo
if [[ $DO_IT -eq 1 ]]; then
  echo "$placed placed, $skipped already there, $no_repo without a cloned repo"
  echo "when you are done, delete this folder"
else
  echo "$placed to place, $skipped already there, $no_repo without a cloned repo"
  echo "to do it for real: ./restaurar.sh --apply"
fi
