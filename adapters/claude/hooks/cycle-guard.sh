#!/usr/bin/env bash
# Claude Code hook (UserPromptSubmit).
#
# Reminds about the cycle when about to work on the main branch of a managed
# repo. Once per session, and silent the rest of the time.
#
# It does not guess from the prompt text: the signal is the state —where you
# are and on which branch—, which is deterministic. Guessing intent from words
# ends up warning when it should not and staying silent when it should.
#
# It exists because we measured that describing it was not enough: the cycle
# skill was written, installed and had its description, and in 31 sessions it
# was invoked zero times. A description competes for attention; a hook arrives
# on its own.

set -u

entry="$(cat 2>/dev/null || true)"

silence() { exit 0; }

git rev-parse --git-dir >/dev/null 2>&1 || silence

# In a workspace the right thing is already being done.
[[ "$PWD" == *-ws-* ]] && silence

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || silence
main_name="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
[[ -n "$main_name" ]] || main_name=main
[[ "$branch" == "$main_name" ]] || silence

# --- Is it a repo managed by crux? ------------------------------------------
#
# It is the kernel itself, a docs repo, or any repo living under the projects
# root. The root comes from the configuration, not from an assumed folder: on a
# machine with another convention this did not fail, it simply did nothing, and
# the system looked watched without being so.
#
# Previously the layout <root>/<project>/<repo> with its docs repo next to it
# was also required, and that left out the loose repos at the root: five on the
# machine where it was measured. The standard already says what to do without a
# contract —a repo without crux.json is treated as 'light'—, so the absence of
# a docs repo lowers the rigor, it does not erase the repo from the map.
# Measured on 2026-09-17 in personal-site: with no warning, one session
# worked on main while another merged, and the push ended in a rebase.

root="${CRUX_PROJECTS_DIR:-}"
kernel=""
if [[ -f "$HOME/.crux/config" ]]; then
  kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  [[ -n "$root" ]] || root="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  [[ -n "$root" || -z "$kernel" ]] || root="$(dirname "$kernel")"
fi

# An extra slash in the configuration left the pattern unmatched and the guard
# silent everywhere, which is the failure mode this hook cannot have.
root="${root%/}"

toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || silence
managed=0

[[ -n "$kernel" && "$toplevel" == "$kernel" ]] && managed=1

# In the docs repo you work on main and push directly: there the cycle
# reminder is superfluous.
if [[ -f "$toplevel/crux.json" ]]; then
  case "$(basename "$toplevel")" in *-docs|docs) silence ;; esac
fi

if [[ $managed -eq 0 && -n "$root" ]]; then
  case "$toplevel/" in
    "$root"/*/) managed=1 ;;
  esac
fi

# The way out for what is not yours even though it is there: a foreign clone
# left under the root to read it. Paths or patterns separated by ':' in the
# configuration. Without the variable there is nothing to check, which is the
# normal case.
if [[ $managed -eq 1 ]]; then
  foreign_items="${CRUX_UNMANAGED:-}"
  if [[ -z "$foreign_items" && -f "$HOME/.crux/config" ]]; then
    foreign_items="$(grep -E '^CRUX_UNMANAGED=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  fi
  if [[ -n "$foreign_items" ]]; then
    IFS=':' read -ra patterns <<< "$foreign_items"
    for pattern in "${patterns[@]}"; do
      [[ -n "$pattern" ]] || continue
      # Unquoted on purpose: the pattern may carry wildcards.
      # shellcheck disable=SC2053
      [[ "$toplevel" == $pattern ]] && silence
    done
  fi
fi

[[ $managed -eq 1 ]] || silence

# --- Once per session ------------------------------------------------------
#
# Repeating it every turn turns it into noise, and noise is learned to be
# ignored before it is obeyed.

session="$(printf '%s' "$entry" | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try { process.stdout.write(String(JSON.parse(s).session_id || "")); } catch { }
  });
' 2>/dev/null || true)"
[[ -n "$session" ]] || session="$PPID"

# The marker goes to ~/.crux/state and not to /tmp: the name carried the repo
# path inside, i.e. the client and the task, in a directory readable by anyone
# on the machine and never cleaned up by anybody.
status="$HOME/.crux/state"
( umask 077 && mkdir -p "$status" ) 2>/dev/null || true
marker="$status/cycle-guard-$(printf '%s' "$session-$toplevel" | \
  cksum | tr -d ' ' | tr -c 'A-Za-z0-9' '_')"
find "$status" -name 'cycle-guard-*' -type f -mtime +2 -delete 2>/dev/null || true
[[ -e "$marker" ]] && silence
: > "$marker"

cat <<EOF
You are on '$branch', the main branch of $(basename "$toplevel"), which is a repo
managed by crux. If what comes next is a development task, the work enters
through its own workspace and leaves as a proposal:

  crux workspace new <task>        isolated branch, worktree and runtime
  /ship                            the gate before committing
  crux workspace finish <task>     pushes the branch and opens the proposal

Isolating after starting forces moving changes already made between branches,
which is exactly the mess this avoids. For questions, exploration or a typo,
carry on as is: the cycle does not apply to everything.
EOF
