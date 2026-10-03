#!/usr/bin/env bash
# crux visual — the visual review a person approves, with a receipt.
#
#   crux visual approve <folder> [--note "<text>"]      records the approval
#   crux visual show                                    shows the receipt
#   crux visual section [--publish] [--lang en|es]      the proposal's section
#   crux visual pr <number|url>                         puts it in an open one
#   crux visual clear                                   discards the receipt
#
# `approve` is run after whoever decides has seen the comparisons and said
# yes. The receipt stores the commit they were captured on: if another one
# lands afterwards, the images no longer show what is proposed, and finish
# says so instead of publishing them as if they were current.
#
# The images are not committed to the proposal's branch: they would end up on
# the main branch. They go to a separate branch that is never merged, written
# with plumbing so as not to touch the working tree.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "this is not a git repository"
RECEIPT="$REPO/.crux-visual"
START_MARKER="<!-- visual-review:start -->"
END_MARKER="<!-- visual-review:end -->"
IMAGES='\.(png|webp|jpe?g)$'

repo_profile() {
  local docs profile=""
  docs="$(find_docs_repo "$REPO" 2>/dev/null || echo "")"
  [[ -n "$docs" && -f "$docs/crux.json" ]] &&
    profile="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"
  printf '%s\t%s' "$profile" "$docs"
}

publish_mode() {
  local profile docs
  IFS=$'\t' read -r profile docs <<< "$(repo_profile)"
  profile_get "$profile" "$docs" visual.publish branch 2>/dev/null || echo branch
}

review_branch() {
  local profile docs
  IFS=$'\t' read -r profile docs <<< "$(repo_profile)"
  profile_get "$profile" "$docs" visual.branch crux-review 2>/dev/null || echo crux-review
}

receipt_value() { awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$RECEIPT"; }

read_receipt() {
  [[ -f "$RECEIPT" ]] || die "no visual review approved: 'crux visual approve <folder>' after the yes"
  local dir
  dir="$(receipt_value dir)"
  [[ -n "$dir" && -d "$dir" ]] || die "the receipt folder does not exist: ${dir:-empty}"
}

images_of() { find "$1" -maxdepth 1 -type f | grep -Ei "$IMAGES" | sort; }

cmd_approve() {
  local dir="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="${2:-}"; shift 2 ;;
      *) dir="$1"; shift ;;
    esac
  done
  [[ -n "$dir" ]] || die "usage: crux visual approve <folder> [--note \"<text>\"]"
  [[ -d "$dir" ]] || die "folder does not exist: $dir"
  dir="$(cd "$dir" && pwd)"
  local total
  total="$(images_of "$dir" | grep -c . || true)"
  [[ "$total" -gt 0 ]] || die "no images in $dir (png, webp or jpg)"
  {
    printf '# visual review approved — crux\n'
    printf 'sha %s\n' "$(git -C "$REPO" rev-parse HEAD)"
    printf 'branch %s\n' "$(git -C "$REPO" branch --show-current)"
    printf 'dir %s\n' "$dir"
    printf 'approved %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "$note" ]] && printf 'note %s\n' "$note"
  } > "$RECEIPT"
  ok "visual review recorded on $(git -C "$REPO" rev-parse --short HEAD) with $(count "$total" image images)"
}

cmd_show() {
  read_receipt
  local sha head
  sha="$(receipt_value sha)"; head="$(git -C "$REPO" rev-parse HEAD)"
  info "approved on $(receipt_value approved) on ${sha:0:8}"
  info "$(images_of "$(receipt_value dir)" | grep -c .) images in $(receipt_value dir)"
  if [[ "$sha" != "$head" ]]; then
    warn "the captures are from ${sha:0:8} and HEAD is ${head:0:8}: show them again"
    return 1
  fi
}

repo_github() {
  local url
  url="$(git -C "$REPO" config --get remote.origin.url)" || return 1
  [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 1
  printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
}

publish_review() {
  # publish_review <review branch> <prefix> <folder> — writes the images to
  # the review branch without a checkout: temporary index, tree and commit by hand.
  local branch="$1" prefix="$2" dir="$3" parent="" index tree commit
  if git -C "$REPO" fetch -q origin "$branch" 2>/dev/null; then
    parent="$(git -C "$REPO" rev-parse FETCH_HEAD)"
  fi
  index="$(mktemp "${TMPDIR:-/tmp}/crux-visual-index.XXXXXX")"
  rm -f "$index"
  if [[ -n "$parent" ]]; then
    GIT_INDEX_FILE="$index" git -C "$REPO" read-tree "$parent" || { rm -f "$index"; return 1; }
  fi
  GIT_INDEX_FILE="$index" git -C "$REPO" rm -rq --cached --ignore-unmatch "$prefix" >/dev/null
  local file blob
  while IFS= read -r file; do
    blob="$(git -C "$REPO" hash-object -w "$file")" || { rm -f "$index"; return 1; }
    GIT_INDEX_FILE="$index" git -C "$REPO" update-index --add \
      --cacheinfo "100644,$blob,$prefix/$(basename "$file")" || { rm -f "$index"; return 1; }
  done < <(images_of "$dir")
  tree="$(GIT_INDEX_FILE="$index" git -C "$REPO" write-tree)"
  rm -f "$index"
  commit="$(git -C "$REPO" commit-tree "$tree" ${parent:+-p "$parent"} -m "chore(review): before and after for $prefix")" || return 1
  git -C "$REPO" push -q origin "$commit:refs/heads/$branch"
}

text() {
  # text <language> <key>
  case "$1:$2" in
    es:title) echo "Antes y después" ;;
    en:title) echo "Before and after" ;;
    es:approved) echo "Revisión visual aprobada el" ;;
    en:approved) echo "Visual review approved on" ;;
    es:caption) echo "Antes a la izquierda, después a la derecha." ;;
    en:caption) echo "Before on the left, after on the right." ;;
  esac
}

cmd_section() {
  local publish=0 language="en"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish) publish=1; shift ;;
      --lang) language="${2:-en}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$language" == "es" ]] || language="en"
  read_receipt
  local sha head dir date note mode
  sha="$(receipt_value sha)"; head="$(git -C "$REPO" rev-parse HEAD)"
  [[ "$sha" == "$head" ]] || die "the captures are from ${sha:0:8} and HEAD is ${head:0:8}: show them again"
  dir="$(receipt_value dir)"; date="$(receipt_value approved)"; note="$(receipt_value note)"
  mode="$(publish_mode)"

  printf '%s\n## %s\n\n%s %s.' "$START_MARKER" "$(text "$language" title)" \
    "$(text "$language" approved)" "${date:0:10}"
  [[ -n "$note" ]] && printf ' %s' "$note"
  printf '\n'

  if [[ "$mode" == "branch" && "$publish" -eq 1 ]]; then
    local slug branch prefix
    slug="$(repo_github)" || die "the remote is not on GitHub: I do not know where to link the images"
    branch="$(review_branch)"
    prefix="$(receipt_value branch)"
    [[ -n "$prefix" ]] || prefix="${sha:0:8}"
    publish_review "$branch" "$prefix" "$dir" || die "could not push the images to the $branch branch"
    printf '\n%s\n' "$(text "$language" caption)"
    local file name
    while IFS= read -r file; do
      name="$(basename "$file")"
      printf '\n![%s](https://github.com/%s/blob/%s/%s/%s?raw=true)\n' \
        "${name%.*}" "$slug" "$branch" "$prefix" "$name"
    done < <(images_of "$dir")
  fi
  printf '%s\n' "$END_MARKER"
}

replace_section() {
  # replace_section <current body> <new section> — replaces it if it was already
  # between the markers; otherwise appends it at the end.
  node -e '
    const [body, section, open, close] = process.argv.slice(1);
    const a = body.indexOf(open), b = body.indexOf(close);
    const output = a !== -1 && b > a
      ? body.slice(0, a) + section.trim() + body.slice(b + close.length)
      : `${body.trimEnd()}\n\n${section.trim()}\n`;
    process.stdout.write(output);
  ' "$1" "$2" "$START_MARKER" "$END_MARKER"
}

cmd_pr() {
  local pr="${1:-}" language="${2:-en}"
  [[ -n "$pr" ]] || die "usage: crux visual pr <number|url>"
  command -v gh >/dev/null || die "gh is needed to edit the proposal"
  local section_text body_text new_value tmp
  section_text="$(cmd_section --publish --lang "$language")" || exit 1
  body_text="$(cd "$REPO" && gh pr view "$pr" --json body -q .body)" || die "could not read proposal $pr"
  new_value="$(replace_section "$body_text" "$section_text")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/crux-visual-body.XXXXXX")"
  printf '%s\n' "$new_value" > "$tmp"
  ( cd "$REPO" && bash "$CRUX_HOME/bin/ship.sh" body "$tmp" >/dev/null 2>&1 ) ||
    { rm -f "$tmp"; die "the new body does not pass the proposal filter"; }
  ( cd "$REPO" && gh pr edit "$pr" --body-file "$tmp" >/dev/null ) || { rm -f "$tmp"; die "could not edit proposal $pr"; }
  rm -f "$tmp"
  ok "visual review put in proposal $pr"
}

cmd_clear() { rm -f "$RECEIPT"; ok "visual review discarded"; }

case "${1:-}" in
  approve) shift; cmd_approve "$@" ;;
  show)    cmd_show ;;
  section) shift; cmd_section "$@" ;;
  pr)      shift; cmd_pr "$@" ;;
  clear)   cmd_clear ;;
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
