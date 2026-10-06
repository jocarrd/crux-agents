#!/usr/bin/env bash
# crux profile — the person's memory, in a repo that travels between machines.
#
#   crux profile            where it is, what it holds and whether something is unpublished
#   crux profile init       creates it: skeleton, private repo on the remote, and loads it
#   crux profile link       loads it into each agent on this machine (Claude, Codex)
#   crux profile clone      brings it from the remote if this machine does not have it
#
# A project's knowledge lives in its docs repo. What belongs to the person —how
# they want to work, who they are, what only holds on one machine— had nowhere
# to go but the agent's local memory, which does not travel and which each
# agent keeps in its own way. This is that place (ADR-018).
#
# It lives at <projects root>/agent-profile (another name with
# CRUX_PROFILE_REPO in ~/.crux/config) and `crux sync` treats it like any other
# repo: it brings it up to date on arrival and complains on leaving if
# something is unpublished.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
# shellcheck source=../adapters/claude/materialize.sh
source "$CRUX_HOME/adapters/claude/materialize.sh"
# shellcheck source=../adapters/codex/materialize.sh
source "$CRUX_HOME/adapters/codex/materialize.sh"

NAME="$(profile_repo_name)"
DIR="$(projects_root)/$NAME"

link() {
  local dir note
  if ! dir="$(profile_dir)"; then
    # An import of a profile that is gone would be loaded as nothing, without a
    # word: the blocks are removed so that what is left says the truth.
    claude_materialize_profile ""
    [[ -d "$CODEX_HOME_DIR" ]] && codex_materialize_profile ""
    die "there is no profile at $DIR — removed its block from the agents; 'crux profile init' or 'crux profile clone'"
  fi
  note="$(profile_machine_note "$dir")"
  claude_materialize_profile "$dir" "$note"
  ok "Claude: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md imports $dir/PROFILE.md"
  # Only if Codex is on the machine: creating its folder installs nothing.
  if [[ -d "$CODEX_HOME_DIR" ]]; then
    codex_materialize_profile "$dir" "$note"
    ok "Codex: $CODEX_HOME_DIR/AGENTS.md carries a copy of the index"
    local size
    size="$(wc -c < "$CODEX_HOME_DIR/AGENTS.md")"
    (( size > 24576 )) && warn "Codex's AGENTS.md weighs $size bytes: it stops reading at 32 KiB, keep the index short"
  fi
  [[ -n "$note" ]] && info "and this machine's note: $note"
  return 0
}

status() {
  local dir
  if ! dir="$(profile_dir)"; then
    warn "no profile on this machine ($DIR)"
    info "'crux profile clone' brings it if it exists; 'crux profile init' creates it"
    return 0
  fi
  echo "profile in $dir"
  local reminder; reminder="$(profile_field "$dir" reminder)"
  [[ -n "$reminder" ]] && info "reminder on every message: $reminder" || info "no reminder on every message (reminder: in PROFILE.md)"
  local sub n
  for sub in preferences about machines; do
    # git does not keep empty folders: a cloned profile may not have them yet.
    n=0
    [[ -d "$dir/$sub" ]] && n="$(find "$dir/$sub" -maxdepth 1 -name '*.md' | wc -l)"
    info "$sub: $n"
  done
  local note; note="$(profile_machine_note "$dir")"
  [[ -n "$note" ]] && info "this machine: $(basename "$note")" || info "this machine has no note of its own"
  local dirty ahead
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l)"
  ahead="$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")"
  (( dirty > 0 )) && warn "$(count "$dirty" "file" "files") not committed"
  [[ "$ahead" != "0" && "$ahead" != "?" ]] && warn "$(count "$ahead" "commit" "commits") not pushed"
  [[ "$ahead" == "?" ]] && warn "no remote branch: what it holds lives only here"
  local file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md"
  grep -qF "@$dir/PROFILE.md" "$file" 2>/dev/null \
    && ok "Claude loads it" || warn "Claude does not load it — 'crux profile link'"
  return 0
}

skeleton() {
  mkdir -p "$DIR/preferences" "$DIR/about" "$DIR/machines"
  # Empty folders do not travel in git; the other machine would get none.
  touch "$DIR/preferences/.gitkeep" "$DIR/about/.gitkeep" "$DIR/machines/.gitkeep"
  [[ -f "$DIR/PROFILE.md" ]] || cat > "$DIR/PROFILE.md" <<'EOF'
---
# reminder: a line the agents get on every message, in your words (optional)
---

# Profile for agents

Write here, in your own language, how agents should work with you. Whatever
goes in this index is read in every session: keep it short and link the detail.

**When the person states a preference or something about themselves**, save it
here and not in the agent's local memory: one note per fact in `preferences/`
(how they want you to work) or `about/` (who they are, their plans, their
accounts), one line in this index, then `git commit` and `git push` right away.
What only holds on one computer goes in `machines/<hostname>.md`. A project's
knowledge goes to its `-docs` repo; keys and passwords go nowhere in git.

## Preferences

## About

## Machines
EOF
  [[ -f "$DIR/README.md" ]] || cat > "$DIR/README.md" <<'EOF'
# agent-profile

The person's memory for their agents: preferences, who they are and what only
holds on one machine. Plain markdown, tied to no agent: `crux profile link`
loads it into each one and `crux sync` carries it between machines.

| Folder | What goes there |
| ------ | --------------- |
| `PROFILE.md` | The index loaded in every session. Short: the rest is opened when needed |
| `preferences/` | How the agents should work |
| `about/` | Who the person is, their plans, their accounts |
| `machines/<hostname>.md` | What only holds on one computer; loaded only there |

What does not go here: a project's knowledge (its `-docs` repo) and keys (each machine).
EOF
}

init() {
  local remote=1 owner=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-remote) remote=0; shift ;;
      --owner) owner="$2"; shift 2 ;;
      *) die "usage: crux profile init [--owner <owner>] [--no-remote]" ;;
    esac
  done
  if [[ -f "$DIR/PROFILE.md" ]]; then
    ok "there is already a profile in $DIR"
  else
    skeleton
    ok "skeleton in $DIR"
  fi
  if [[ ! -d "$DIR/.git" ]]; then
    git -C "$DIR" init -q -b main
    git -C "$DIR" add -A
    git -C "$DIR" commit -qm "chore: agent profile skeleton"
  fi
  if (( remote )) && ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
    command -v gh >/dev/null 2>&1 || die "gh is needed to create the repo on the remote (or --no-remote)"
    [[ -n "$owner" ]] || owner="$(default_owner)"
    [[ -n "$owner" ]] || die "I do not know which account to create it under — pass it with --owner"
    # Private: it says how the person works and who they are.
    gh repo create "$owner/$NAME" --private --source "$DIR" --push \
      -d "Agent profile: preferences, about, machines" >/dev/null
    ok "private repo $owner/$NAME"
  fi
  link
}

clone() {
  local owner=""
  [[ "${1:-}" == "--owner" ]] && owner="${2:-}"
  if [[ -d "$DIR/.git" ]]; then ok "the profile is already here: $DIR"; link; return 0; fi
  command -v gh >/dev/null 2>&1 || die "gh is needed to look for the profile on the remote"
  [[ -n "$owner" ]] || owner="$(default_owner)"
  [[ -n "$owner" ]] || die "I do not know which account to look under — pass it with --owner"
  if ! gh repo view "$owner/$NAME" >/dev/null 2>&1; then
    warn "$owner/$NAME does not exist — 'crux profile init' creates it"
    return 0
  fi
  gh repo clone "$owner/$NAME" "$DIR" -- -q
  ok "profile cloned in $DIR"
  link
}

case "${1:-status}" in
  status) status ;;
  link)   link ;;
  init)   shift; init "$@" ;;
  clone)  shift; clone "$@" ;;
  *) die "usage: crux profile [status|link|init|clone]" ;;
esac
