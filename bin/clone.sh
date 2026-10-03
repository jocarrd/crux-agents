#!/usr/bin/env bash
# crux clone — bring a whole project to a new machine.
#
#   crux clone <project> [--from <template|url>] [--parent <dir>]
#
# Clones the docs repo, reads its contract and clones the repos it declares.
# Two things come from the contract and not from an assumption: the list of
# repos —which in a hand-written guide goes stale as soon as you add one— and
# **where they are cloned from**, which can differ for documentation and code.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

PROJECT="${1:-}"
[[ -n "$PROJECT" ]] || die "usage: crux clone <project> [--from <template|url>] [--parent <dir>]"
shift

FROM=""
PARENT="$(projects_root)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)   FROM="$2"; shift 2 ;;
    --parent) PARENT="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

PROJECT="${PROJECT##*/}"
PROJECT="${PROJECT%-docs}"

ROOT="$PARENT/$PROJECT"
DOCS="$ROOT/$PROJECT-docs"

# Fetching the docs repo needs a URL, and there is no contract yet to give it:
# either the user passes it, or it is inherited from the machine default.
initial_template() {
  [[ -n "$FROM" ]] && { echo "$FROM"; return; }
  local cfg="${CRUX_CONFIG:-$HOME/.crux/config}"
  if [[ -f "$cfg" ]]; then
    local default_value
    default_value="$(grep -E '^CRUX_REMOTE=' "$cfg" | cut -d= -f2- | tr -d '"')"
    [[ -n "$default_value" ]] && { echo "$default_value"; return; }
  fi
  echo ""
}

echo "cloning $PROJECT"
echo

mkdir -p "$ROOT"

# --- 1. The docs repo, which knows the rest ------------------------------

if [[ -d "$DOCS/.git" ]]; then
  ok "$PROJECT-docs already there"
else
  TMPL="$(initial_template)"
  if [[ -z "$TMPL" ]]; then
    err "I do not know where to fetch $PROJECT-docs from"
    info "pass it with --from 'git@your-remote:org/{repo}.git' (or the full URL),"
    info "or set a default with CRUX_REMOTE in ~/.crux/config"
    exit 1
  fi
  URL="${TMPL//\{repo\}/$PROJECT-docs}"
  git clone -q "$URL" "$DOCS" || die "could not clone from $URL"
  ok "$PROJECT-docs"
fi

CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "$PROJECT-docs is not adopted (no crux.json): clone the rest by hand"

PROFILE="$(json_get "$CONFIG" profile 2>/dev/null || echo "?")"

# --- 2. The repos the contract declares -------------------------------------

cloned=0; failed_items=(); without_remote=()
while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  # The name comes from crux.json and is concatenated into a path. valid_name
  # exists precisely for this and only add-repo called it, i.e. the entry
  # point; a contract that arrives cloned never went through there.
  valid_name "$repo" || { warn "invalid repo name in the contract: $repo"; continue; }
  if [[ -d "$ROOT/$repo/.git" ]]; then
    info "$repo already there"
    continue
  fi
  url="$(remote_url "$CONFIG" "$repo" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    without_remote+=("$repo")
    continue
  fi
  if git clone -q "$url" "$ROOT/$repo" 2>/dev/null; then
    ok "$repo"
    cloned=$((cloned + 1))
  else
    failed_items+=("$repo  ($url)")
  fi
done < <(json_get "$CONFIG" repos 2>/dev/null || true)

if [[ ${#without_remote[@]} -gt 0 ]]; then
  echo
  warn "no remote declared: ${without_remote[*]}"
  info "add \"remote\" to $PROJECT-docs/crux.json, or an override in remote.repos"
fi

if [[ ${#failed_items[@]} -gt 0 ]]; then
  echo
  warn "could not clone:"
  for f in "${failed_items[@]}"; do info "$f"; done
  # In a client project the code is normally in another organization, so this
  # is not a failure: it is information.
  [[ "$PROFILE" == "client-repo" ]] \
    && info "profile $PROFILE: the code usually lives on the client's remote, clone it yourself" \
    || info "check the name or the permissions"
fi

# --- 3. Pointers and verification ----------------------------------------------

echo
bash "$CRUX_HOME/bin/link.sh" "$DOCS"

echo
bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" || true

# Bringing a project over without hooking anything leaves a copy that looks
# ready and is not: everything that upholds the standard is automatic. It is
# done with the repos already on disk, because the per-repo hooks need them.
echo
( cd "$DOCS" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1 \
  && ok "hooks installed" \
  || warn "could not install the hooks — do it with 'crux hooks install' from $PROJECT-docs"

# And for the same reason the MCP servers the project declares: without this
# the new machine goes without them and the doctor would have nothing to
# compare against.
if json_has "$DOCS/crux.json" 'mcp && Object.keys(root.mcp).length'; then
  ( cd "$DOCS" && bash "$CRUX_HOME/bin/mcp.sh" install ) >/dev/null 2>&1 \
    && ok "MCP servers written" \
    || warn "could not write the MCP servers — do it with 'crux mcp install' from $PROJECT-docs"
fi

echo
echo "done: $ROOT"
if [[ -f "$DOCS/operations/machine-onboarding.md" ]]; then
  info "project credentials and secrets: $PROJECT-docs/operations/machine-onboarding.md"
fi
exit 0
