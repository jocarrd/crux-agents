#!/usr/bin/env bash
# crux memory — what the agent knows that the project does not know yet.
#
#   crux memory           the memories by type, and the ones missing from git
#   crux memory --brief   one line with what is missing, to hook into a hook
#   crux memory --check   silent; exits 1 if any should have been promoted
#   crux memory search <t> looks for the text in the profile and every docs repo
#
# The standard splits things by who each one belongs to: `project` and
# `reference` belong to the project and go to git; `user` and `feedback`
# belong to the person and go to their profile. The rule was written from day one and
# nobody checked it, so there was project analysis living on a single machine.
# This is what makes it verifiable.
#
# It does not decide where each memory goes nor move it: that is a decision,
# and decisions are not made by a hook. It says what is missing and which docs
# repo it goes in.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

# --- Search ---------------------------------------------------------------------
#
# The interface stays even if what is behind it changes. Today it is a plain
# search over the markdown: the profile and every project's docs repo. If one
# day there is so much that an index pays off (SQLite, vectors), it is built
# from these same files and answered here; neither the content nor the agents
# notice (ADR-018).
if [[ "${1:-}" == "search" ]]; then
  shift
  [[ $# -gt 0 ]] || die "usage: crux memory search <text>"
  query="$*"
  root="$(projects_root)"
  places=()
  p_dir="$(profile_dir 2>/dev/null)" && places+=("$p_dir")
  for d in "$root"/*/*-docs; do [[ -d "$d" ]] && places+=("$d"); done
  (( ${#places[@]} > 0 )) || die "nothing to search: no profile and no docs repo in $root"
  found="$(grep -rniF --include='*.md' --exclude-dir=node_modules --exclude-dir=.git \
    -m 3 -- "$query" "${places[@]}" 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    info "nothing found for \"$query\""
    exit 0
  fi
  printf '%s\n' "$found" | sed "s#^$root/##" | cut -c1-220 | head -60
  exit 0
fi

CHECK=false
BRIEF=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    --brief) BRIEF=true ;;
    *) die "usage: crux memory [--brief|--check] | crux memory search <text>" ;;
  esac
done

# --- Which project each scope is ---------------------------------------------
#
# Agents name a memory's scope with the working path and the separators
# replaced by hyphens. Undoing that is ambiguous —a project can contain
# hyphens—, but doing it forwards is not: the name of every existing project
# is computed and the one that fits is looked for. The longest wins, so that a
# project does not take the memories of another whose name starts the same.

root="$(projects_root)"

# Without a projects root every memory would come out as "no project", which
# reads the same as "belongs to none" and is not: it is said, and the listing
# goes on because detecting the leak does not depend on knowing its destination.
if [[ ! -d "$root" ]] && ! $CHECK && ! $BRIEF; then
  warn "the projects root does not exist: $root"
  info "without it there is no telling which docs repo each memory belongs to"
  echo
fi

slug_of() { printf '%s' "$1" | tr '/.' '-'; }

# Folders that are not the profile owner's: on a shared machine another person
# works with the agent too, and their memories are neither a leak nor go to
# this profile. Declared per machine, comma-separated paths, in ~/.crux/config:
#   CRUX_MEMORY_IGNORE="/home/me/Desktop/Novel,/home/me/Other"
ignored_slugs=()
IFS=',' read -r -a ignored_paths <<< "$(preference CRUX_MEMORY_IGNORE)"
for p in "${ignored_paths[@]}"; do
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  [[ -n "$p" ]] && ignored_slugs+=("$(slug_of "${p/#\~/$HOME}")")
done
is_ignored() {
  local s
  for s in "${ignored_slugs[@]}"; do
    [[ "$1" == "$s" || "$1" == "$s"-* ]] && return 0
  done
  return 1
}

project_of_scope() {
  local scope_name="$1" best="" best_len=0 dir name slug
  for dir in "$root"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    [[ -d "$root/$name/$name-docs" ]] || continue
    slug="$(slug_of "$root/$name")"
    if [[ "$scope_name" == "$slug" || "$scope_name" == "$slug"-* ]] && (( ${#slug} > best_len )); then
      best="$name"; best_len=${#slug}
    fi
  done
  echo "$best"
}

# --- Collection --------------------------------------------------------------

lines=""
adapters=0
for scan in "$CRUX_HOME"/adapters/*/memory-scan.sh; do
  [[ -f "$scan" ]] || continue
  adapters=$((adapters + 1))
  output="$(bash "$scan")" || die "the adapter $scan failed; it cannot be asserted that there are no unpromoted memories"
  [[ -n "$output" ]] && lines+="$output"$'\n'
done

(( adapters > 0 )) || die "no memory adapter in $CRUX_HOME/adapters"

total=0; scopes=""; unpromoted=""; untyped=""; unreadable=""; personal=""
n_user=0; n_feedback=0; n_scopes=0

# With a profile, what belongs to the person also has a place in git and stops
# being "local by design" (ADR-018). Without one, the old rule holds.
profile=""
profile="$(profile_dir 2>/dev/null)" || profile=""

n_ignored=0
while IFS=$'\t' read -r kind scope_name path_value; do
  [[ -n "${kind:-}" ]] || continue
  if is_ignored "$scope_name"; then n_ignored=$((n_ignored + 1)); continue; fi
  total=$((total + 1))
  [[ "$scopes" == *"|$scope_name|"* ]] || { scopes+="|$scope_name|"; n_scopes=$((n_scopes + 1)); }
  name="$(basename "$path_value" .md)"

  case "$kind" in
    project|reference)
      project="$(project_of_scope "$scope_name")"
      # Without a project it is not guessed: it says which scope it came from,
      # which is the datum that allows deciding. Deducing it from the file name
      # would be right sometimes and would put documentation in the wrong
      # project the rest.
      target="${project:+$project-docs}"
      # Outside every project, what is about the person's own plans has a
      # destination too once there is a profile: its about/ folder.
      [[ -z "$target" && -n "$profile" ]] && target="$(basename "$profile")/about or a -docs repo"
      unpromoted+="$kind	$name	${target:-scope $scope_name}	$path_value"$'\n'
      ;;
    user|feedback)
      if [[ -n "$profile" ]]; then
        folder="preferences"; [[ "$kind" == user ]] && folder="about"
        personal+="$kind	$name	$(basename "$profile")/$folder	$path_value"$'\n'
      fi
      [[ "$kind" == user ]] && n_user=$((n_user + 1)) || n_feedback=$((n_feedback + 1))
      ;;
    '?')
      untyped+="$name	$path_value"$'\n'
      ;;
    '!')
      unreadable+="$path_value"$'\n'
      ;;
    *)
      untyped+="$name ($kind)	$path_value"$'\n'
      ;;
  esac
done <<< "$lines"

# A file that is there and cannot be read does not count as "nothing to
# promote": that is exactly the failure that looks like it works.
if [[ -n "$unreadable" ]]; then
  err "there are memories that cannot be read:"
  printf '%s' "$unreadable" | sed 's/^/      /'
  exit 1
fi

n_unpromoted=0
[[ -n "$unpromoted" ]] && n_unpromoted=$(grep -c . <<< "${unpromoted%$'\n'}")
n_personal=0
[[ -n "$personal" ]] && n_personal=$(grep -c . <<< "${personal%$'\n'}")

if $CHECK; then
  (( n_unpromoted + n_personal > 0 )) && exit 1
  exit 0
fi

if $BRIEF; then
  if (( n_personal > 0 )); then
    warn "$n_personal personal memories are not in the profile ($(basename "$profile")): they do not reach the other machine"
    info "crux memory lists them · move each one to its folder, add it to PROFILE.md and push"
    (( n_unpromoted > 0 )) || exit 1
  fi
  (( n_unpromoted > 0 )) || exit 0
  sample="$(cut -f2 <<< "${unpromoted%$'\n'}" | head -3 |
    awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')"
  (( n_unpromoted > 3 )) && sample+=", +$((n_unpromoted - 3))"
  warn "$n_unpromoted project memories live only on this machine: $sample"
  info "crux memory lists them · /promote-to-docs puts them in git"
  exit 1
fi

# --- Report -------------------------------------------------------------------

echo "agent memories — $total in $n_scopes scope(s)"
echo

if (( n_unpromoted > 0 )); then
  warn "unpromoted ($n_unpromoted)"
  echo
  printf '%s' "$unpromoted" | while IFS=$'\t' read -r kind name target _; do
    printf '      %-10s %-34s → %s\n' "$kind" "$name" "$target"
  done
  echo
  info "they go to git: locally they do not survive a change of machine."
  info "/promote-to-docs puts them in the docs repo and deletes the local copy."
  if [[ "$unpromoted" == *"	scope "* ]]; then
    info "those shown with a scope instead of a docs repo come from a"
    info "directory that is not any project: the destination is up to you."
  fi
  echo
else
  ok "nothing unpromoted"
  echo
fi

if [[ -n "$untyped" ]]; then
  warn "no declared type ($(grep -c . <<< "${untyped%$'\n'}"))"
  printf '%s' "$untyped" | while IFS=$'\t' read -r name _; do
    printf '      %s\n' "$name"
  done
  info "none is assumed for them: declare the type or delete them."
  echo
fi

if (( n_personal > 0 )); then
  warn "personal, not in the profile ($n_personal)"
  echo
  printf '%s' "$personal" | while IFS=$'\t' read -r kind name target _; do
    printf '      %-10s %-34s → %s\n' "$kind" "$name" "$target"
  done
  echo
  info "they go to $profile: one note per fact, a line in PROFILE.md, commit and push;"
  info "then delete the local copy, or the agent reads both and they drift apart."
  echo
  exit 0
fi

(( n_ignored > 0 )) && info "ignored by CRUX_MEMORY_IGNORE: $(count "$n_ignored" "memory" "memories") of folders that are someone else's"
if [[ -n "$profile" ]]; then
  ok "no personal memory outside the profile ($profile)"
else
  summary=""
  (( n_user > 0 )) && summary+="$n_user user"
  (( n_feedback > 0 )) && summary+="${summary:+ · }$n_feedback feedback"
  [[ -n "$summary" ]] && info "local, with no profile to go to: $summary — 'crux profile init' gives them a repo that travels"
fi

exit 0
