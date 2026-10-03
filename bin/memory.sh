#!/usr/bin/env bash
# crux memory — what the agent knows that the project does not know yet.
#
#   crux memory           the memories by type, and the ones missing from git
#   crux memory --brief   one line with what is missing, to hook into a hook
#   crux memory --check   silent; exits 1 if any should have been promoted
#
# The standard splits things by who each one belongs to: `project` and
# `reference` belong to the project and go to git; `user` and `feedback`
# belong to the person and stay local. The rule was written from day one and
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

CHECK=false
BRIEF=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    --brief) BRIEF=true ;;
    *) die "usage: crux memory [--brief|--check]" ;;
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

total=0; scopes=""; unpromoted=""; untyped=""; unreadable=""
n_user=0; n_feedback=0; n_scopes=0

while IFS=$'\t' read -r kind scope_name path_value; do
  [[ -n "${kind:-}" ]] || continue
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
      unpromoted+="$kind	$name	${target:-scope $scope_name}	$path_value"$'\n'
      ;;
    user)     n_user=$((n_user + 1)) ;;
    feedback) n_feedback=$((n_feedback + 1)) ;;
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

if $CHECK; then
  (( n_unpromoted > 0 )) && exit 1
  exit 0
fi

if $BRIEF; then
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

summary=""
(( n_user > 0 )) && summary+="$n_user user"
(( n_feedback > 0 )) && summary+="${summary:+ · }$n_feedback feedback"
[[ -n "$summary" ]] && info "local by design: $summary"

exit 0
