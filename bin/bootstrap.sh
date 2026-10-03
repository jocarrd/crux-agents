#!/usr/bin/env bash
# crux bootstrap — get a new machine ready to work.
#
#   crux bootstrap [--owner <owner>] [--parent <dir>] [--only a,b] [--dry-run]
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
# comes from the contract.
#
# What it does NOT do, on purpose: move credentials. SSH keys, tokens and
# secrets are not copied from one machine to another by a tool. When it
# finishes it says what each project needs and where it is documented.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

OWNER=""
PARENT="$(projects_root)"
ONLY=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)   OWNER="$2"; shift 2 ;;
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

[[ -n "$OWNER" ]] || OWNER="$(default_owner)"
[[ -n "$OWNER" ]] || die "I do not know which account to search under — pass it with --owner"

# --- 3. Which projects exist ----------------------------------------------------
#
# A project is a `<something>-docs` repo that carries a contract. The second
# part matters: without checking it, any repo ending in -docs would count as a project.

echo
echo "2. projects of $OWNER"
echo

all_repos="$(gh repo list "$OWNER" --limit 300 --json name --jq '.[].name' 2>/dev/null | sort -u)"
candidates="$(candidate_projects "$OWNER")"

if [[ -n "$ONLY" ]]; then
  filter="$(echo "$ONLY" | tr ',' '\n' | sed '/^$/d' | sort -u)"
  candidates="$(comm -12 <(echo "$candidates") <(echo "$filter"))"
fi

[[ -n "$candidates" ]] || die "no *-docs repo under $OWNER"

projects=()
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  if has_contract "$OWNER" "$p"; then
    projects+=("$p")
    ok "$p"
  else
    info "$p-docs has no contract — not a crux project, skipped"
  fi
done <<< "$candidates"

[[ ${#projects[@]} -gt 0 ]] || die "none carries a contract"

if [[ $DRY -eq 1 ]]; then
  echo
  echo "would fetch ${#projects[@]} projects to $PARENT: ${projects[*]}"
  exit 0
fi

# --- 4. Fetching them -------------------------------------------------------------

echo
echo "3. fetching ${#projects[@]} projects to $PARENT"

fetched=(); failed_items=()
for p in "${projects[@]}"; do
  echo
  echo "── $p"
  if bash "$CRUX_HOME/bin/clone.sh" "$p" --parent "$PARENT"; then
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

# A remote repo that belongs to no project is not fetched by this, and keeping
# quiet about it would be worse than not fetching it: you leave believing
# everything is there.
standalone_items=()
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  found=0
  for d in "$PARENT"/*/"$r"; do
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
