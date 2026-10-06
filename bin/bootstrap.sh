#!/usr/bin/env bash
# crux bootstrap — get a new machine ready to work.
#
#   crux bootstrap [--owner <owner>[,<owner>]] [--parent <dir>] [--only a,b] [--dry-run]
#
# Checks the machine, discovers all the projects and fetches them. It is
# `crux clone` repeated, plus the two things you do not have on a blank
# machine: knowing which projects exist and knowing what you still have to
# install.
#
# The list comes from the remote, not from an inventory in a file. A
# hand-written inventory goes stale as soon as you create a project, and this
# is used precisely on the day you do not remember which ones you had. It is
# the same criterion `crux clone` already uses for a project's repo list: it
# comes from the contract. It searches your account and every organisation
# you are an active member of, unless --owner says where.
#
# What it does NOT do, on purpose: move credentials. SSH keys, tokens and
# secrets are not copied from one machine to another by a tool. When it
# finishes it says what each project needs and where it is documented.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

OWNERS=""
PARENT="$(projects_root)"
ONLY=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)   OWNERS+="${OWNERS:+,}$2"; shift 2 ;;
    --parent)  PARENT="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- 1. The machine, first of all -------------------------------------------
#
# Cloning twenty repos to discover afterwards that node is missing is the worst
# way to find out. The machine doctor already tells the indispensable apart
# from what only limits some skills, so here the only decision is whether to go on.

echo "1. the machine"
echo
if ! bash "$CRUX_HOME/bin/machine.sh"; then
  echo
  die "fix the errors above and run it again"
fi

# --- 2. Who you are on the remote ----------------------------------------------

command -v gh >/dev/null 2>&1 \
  || die "gh is needed to discover the projects — install it, or clone them one by one with 'crux clone'"
gh auth status >/dev/null 2>&1 \
  || die "gh not authenticated — 'gh auth login' and come back"

# The first owner is yours: the profile and the loose repos are looked for there.
owners=()
while IFS= read -r o; do
  [[ -n "$o" ]] && owners+=("$o")
done < <(if [[ -n "$OWNERS" ]]; then echo "$OWNERS" | tr ',' '\n' | awk 'NF && !seen[$0]++'; else search_owners; fi)
[[ ${#owners[@]} -gt 0 ]] || die "I do not know which account to search under — pass it with --owner"
OWNER="${owners[0]}"

# --- 3. Which projects exist ----------------------------------------------------
#
# A project is a `<something>-docs` repo that carries a contract. The second
# part matters: without checking it, any repo ending in -docs would count as a project.

echo
echo "2. projects of ${owners[*]}"
echo

all_repos="$(gh repo list "$OWNER" --limit 300 --json name --jq '.[].name' 2>/dev/null | sort -u)"
filter=""
[[ -n "$ONLY" ]] && filter="$(echo "$ONLY" | tr ',' '\n' | sed '/^$/d' | sort -u)"

# Both live under $PARENT/<project>: two owners with the same project name
# cannot share the machine, and the first one found keeps it.
# project<TAB>owner, one per line: macOS bash has no associative arrays.
projects=()
owner_map=""
owner_of() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' <<< "$owner_map"; }
any_candidate=0
for o in "${owners[@]}"; do
  candidates="$(candidate_projects "$o")"
  [[ -n "$filter" ]] && candidates="$(comm -12 <(echo "$candidates") <(echo "$filter"))"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    any_candidate=1
    first="$(owner_of "$p")"
    if [[ -n "$first" ]]; then
      warn "$o/$p-docs has the same name as $first/$p-docs — only the first one comes"
      continue
    fi
    label="$p"; [[ "$o" == "$OWNER" ]] || label="$p ($o)"
    if has_contract "$o" "$p"; then
      projects+=("$p"); owner_map+="$p"$'\t'"$o"$'\n'
      ok "$label"
    else
      info "$label: $p-docs has no contract — not a crux project, skipped"
    fi
  done <<< "$candidates"
done

[[ $any_candidate -eq 1 ]] || die "no *-docs repo under ${owners[*]}"

[[ ${#projects[@]} -gt 0 ]] || die "none carries a contract"

# The person's profile is not a project but comes the same: without it the
# agents on this machine start knowing nothing about who they work for (ADR-018).
PROFILE_NAME="$(profile_repo_name)"
bring_profile() {
  echo
  if [[ -f "$PARENT/$PROFILE_NAME/PROFILE.md" ]]; then
    ok "profile already in $PARENT/$PROFILE_NAME"
    (( DRY )) || CRUX_PROJECTS_DIR="$PARENT" bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1 \
      || warn "could not load the profile into the agents — 'crux profile link'"
  elif grep -qx "$PROFILE_NAME" <<< "$all_repos"; then
    if (( DRY )); then
      info "[dry-run] would clone the profile $OWNER/$PROFILE_NAME"
    elif CRUX_PROJECTS_DIR="$PARENT" bash "$CRUX_HOME/bin/profile.sh" clone --owner "$OWNER" >/dev/null 2>&1; then
      ok "profile $OWNER/$PROFILE_NAME cloned and loaded into the agents"
    else
      warn "could not bring the profile — 'crux profile clone'"
    fi
  else
    info "no profile on $OWNER: 'crux profile init' creates one, so preferences travel too"
  fi
}

if [[ $DRY -eq 1 ]]; then
  echo
  echo "would fetch ${#projects[@]} projects to $PARENT: ${projects[*]}"
  bring_profile
  exit 0
fi

# --- 4. Fetching them -------------------------------------------------------------

echo
echo "3. fetching ${#projects[@]} projects to $PARENT"

fetched=(); failed_items=()
for p in "${projects[@]}"; do
  echo
  echo "── $p"
  # Your own projects use the machine template as is, whatever host it points at.
  from=()
  o="$(owner_of "$p")"
  [[ "$o" == "$OWNER" ]] || from=(--from "$(template_for_owner "$o")")
  if bash "$CRUX_HOME/bin/clone.sh" "$p" --parent "$PARENT" ${from[@]+"${from[@]}"}; then
    fetched+=("$p")
  else
    failed_items+=("$p")
  fi
done

# --- 5. What is still missing ------------------------------------------------
#
# An environment with all the code and no credentials is not ready, and the
# worst possible ending is one that says it is.

echo
echo "4. what is missing"
echo

ok "${#fetched[@]} projects in $PARENT"
if [[ ${#failed_items[@]} -gt 0 ]]; then
  err "could not do: ${failed_items[*]}"
fi

with_credentials=()
for p in "${fetched[@]}"; do
  doc="$PARENT/$p/$p-docs/operations/machine-onboarding.md"
  [[ -f "$doc" ]] && with_credentials+=("$p")
done

if [[ ${#with_credentials[@]} -gt 0 ]]; then
  echo
  warn "credentials to put in by hand — they are not copied from one machine to another:"
  for p in "${with_credentials[@]}"; do
    info "$p  →  $p/$p-docs/operations/machine-onboarding.md"
  done
fi

bring_profile

# A remote repo that belongs to no project is not fetched by this, and keeping
# quiet about it would be worse than not fetching it: you leave believing
# everything is there.
# With --only the rest was left out on purpose, and listing it would be noise.
standalone_items=()
[[ -n "$ONLY" ]] && all_repos=""
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  [[ "$r" == "$PROFILE_NAME" ]] && continue
  found=0
  for d in "$PARENT/$r" "$PARENT"/*/"$r"; do
    [[ -d "$d" ]] && { found=1; break; }
  done
  [[ $found -eq 0 ]] && standalone_items+=("$r")
done <<< "$all_repos"

if [[ ${#standalone_items[@]} -gt 0 ]]; then
  echo
  warn "repos of $OWNER that belong to no project, so they do not come here:"
  info "${standalone_items[*]}"
  info "if one is needed: git clone, or 'crux adopt' if it deserves to be a project"
fi

# Fetching the projects and hooking nothing leaves a machine that looks ready
# and is not: everything that really sustains the standard is automatic, and
# without the hooks not one is left. It is done here, with the projects already
# on disk, because the per-repo hooks need them to exist.
echo
for p in "${fetched[@]}"; do
  docs="$PARENT/$p/$p-docs"
  [[ -f "$docs/crux.json" ]] || continue
  ( cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1 \
    && ok "hooks installed in $p" \
    || warn "could not install the hooks in $p — do it with 'crux hooks install' from its docs repo"
  if json_has "$docs/crux.json" 'mcp && Object.keys(root.mcp).length'; then
    ( cd "$docs" && bash "$CRUX_HOME/bin/mcp.sh" install ) >/dev/null 2>&1 \
      && ok "MCP servers written in $p" \
      || warn "could not write the MCP servers in $p — 'crux mcp install' from its docs repo"
  fi
done

echo
info "'crux status' to see how everything turned out"
exit $(( ${#failed_items[@]} > 0 ? 1 : 0 ))
