#!/usr/bin/env bash
# Gathers a project's env files into a folder you can take with you.
#
#   collect.sh [--project <dir>] [--out <dir>]
#
# Copies them with `cp` and never opens them: if an agent runs this, no value
# enters its context or stays in the session transcript.
#
# Leaves a map of where each one goes and the script that puts them back.
# Twelve files with flat names and no hint of their path are useless three
# months from now, which is exactly when they get used.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT="$PWD"
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --out)     OUTPUT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

PROJECT="$(cd "$PROJECT" && pwd)"

# The anchor is the project root, not the repo it is called from. Pointing
# this at a repo makes the bundle useless in two ways at once: the map stores
# repo-relative paths, and the bundle claims the repo's name, so restoring looks
# for <root>/<repo> (which does not exist) instead of <root>/<project>.
# The failure is not visible when gathering: it shows up months later, on the
# new machine.
docs_repo() {
  local probe="$1" d
  while [[ "$probe" != "/" ]]; do
    [[ -f "$probe/crux.json" ]] && { echo "$probe"; return 0; }
    for d in "$probe"/*-docs; do
      [[ -f "$d/crux.json" ]] && { echo "$d"; return 0; }
    done
    probe="$(dirname "$probe")"
  done
  return 1
}

NAME=""
if DOCS="$(docs_repo "$PROJECT")"; then
  ROOT="$(dirname "$DOCS")"
  if [[ "$ROOT" != "$PROJECT" ]]; then
    echo "$(basename "$PROJECT") is a repo of $(basename "$ROOT"): gathering the whole project"
    echo "from $ROOT, which is what the other machine will know how to find."
    echo
    PROJECT="$ROOT"
  fi
  # The declared name wins over the directory name: it is the one
  # `crux bootstrap` uses to create the folder on the destination machine.
  NAME="$(sed -n 's/.*"project"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DOCS/crux.json" | head -1)"
fi
NAME="${NAME:-$(basename "$PROJECT")}"
OUTPUT="${OUTPUT:-$HOME/entornos-$NAME}"

# What is excluded, and why:
#
#   *-ws-*                  copies `crux workspace` generates of the main
#                           repo. They are derived, and restoring them over
#                           the good ones is a blunder.
#   .next, dist, build, out build artifacts: the same file copied by the
#                           tool. Restoring one fixes nothing.
#   *.example and friends   templates without values; already in the repo.
search() {
  find "$PROJECT" -maxdepth 6 \
    \( -name ".env" -o -name ".env.*" \) \
    -not -path "*/node_modules/*" -not -path "*/.git/*" \
    -not -path "*-ws-*" \
    -not -path "*/.next/*" -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/out/*" \
    -not -name "*.example" -not -name "*.sample" -not -name "*.template" \
    -type f 2>/dev/null | sort
}

# .env -> no suffix; .env.local -> .local. If the file is nested inside the
# repo, its containing directory goes into the name: otherwise the root .env
# and one from a service inside would overwrite each other.
plain_name() {
  local rel="${1#$PROJECT/}"
  local variant; variant="$(basename "$1")"; variant="${variant#.env}"

  # A file at the project root has no repo to take the name from.
  # Without this `.env` is taken as the repo name and yields `.env..env.`,
  # the opposite of what these names are for: saying where it came from.
  [[ "$rel" == */* ]] || { echo ".env${variant}"; return; }

  local repo="${rel%%/*}"
  local dir; dir="$(dirname "$rel")"
  local suffix=""
  local sheet; sheet="$(basename "$dir")"
  [[ "$dir" != "$repo" && "$sheet" != "$repo" ]] && suffix=".$sheet"
  echo ".env.${repo}${suffix}${variant}"
}

# Not mapfile: it is bash 4, and macOS ships 3.2.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(search)
[[ ${#FILES[@]} -gt 0 ]] || { echo "no env file under $PROJECT"; exit 1; }

rm -rf "$OUTPUT"; mkdir -p "$OUTPUT"; chmod 700 "$OUTPUT"

echo "# proyecto: $NAME" > "$OUTPUT/mapa.txt"
for f in "${FILES[@]}"; do
  n="$(plain_name "$f")"
  cp -p "$f" "$OUTPUT/$n"
  chmod 600 "$OUTPUT/$n"
  echo "$n|${f#$PROJECT/}" >> "$OUTPUT/mapa.txt"
  printf "  ok   %-44s ← %s\n" "$n" "${f#$PROJECT/}"
done

cp "$HERE/restaurar.sh" "$OUTPUT/restaurar.sh"
chmod 700 "$OUTPUT/restaurar.sh"

{
  echo "# Environments of $NAME: copy for another machine"
  echo
  echo "**There are no secrets here**: this file only says what goes where."
  echo
  echo "## First of all"
  echo
  echo "The folder holds keys and tokens in plain text. Do not leave it where it"
  echo "syncs by itself, do not show it on a shared screen, and delete it as soon"
  echo "as you finish restoring."
  echo
  echo "## How to restore"
  echo
  echo '```bash'
  echo "./restaurar.sh           # says what it would do, touching nothing"
  echo "./restaurar.sh --apply   # copies them into place"
  echo '```'
  echo
  echo "It looks for \`$NAME\` in the projects folder crux uses on that machine; if it is elsewhere, pass it"
  echo "as an argument. It never overwrites: if the destination exists it skips it and says so."
  echo
  echo "## What goes where"
  echo
  echo "| File | Destination, relative to the project root |"
  echo "| ---- | ---------------------------------------- |"
  while IFS='|' read -r n d; do
    [[ -n "$n" && "$n" != \#* ]] && echo "| \`$n\` | \`$d\` |"
  done < "$OUTPUT/mapa.txt"
  echo
  echo "## What is NOT here"
  echo
  echo "**Nothing from the server.** Production env files live where the service"
  echo "runs; this is for working locally."
  echo
  echo "**Nothing personal and regenerable**: SSH keys, CLI sessions, registry"
  echo "tokens, OAuth. Those are generated on each machine and not copied: copying"
  echo "is worse, because a token that travels is one you no longer know where it has been."
  echo
  echo "**No workspace copies or build artifacts either**, which are derived from"
  echo "the main repo."
} > "$OUTPUT/RESTAURAR.md"

echo
echo "${#FILES[@]} files in $OUTPUT (folder 0700, files 0600)"
echo "the map is in RESTAURAR.md and the way back in restaurar.sh"
