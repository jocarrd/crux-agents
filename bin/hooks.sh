#!/usr/bin/env bash
# crux hooks — hooks the standard into the moments where it applies.
#
#   crux hooks status     what is installed and whether it points at something real
#   crux hooks install    installs the agent's hooks and, where it applies, git's
#   crux hooks remove     removes only the ones crux manages
#
# A standard you have to remember to check gets checked sometimes. These hooks
# check it every time.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DOC_SYNC="$CRUX_HOME/adapters/claude/hooks/doc-sync.sh"
CYCLE_GUARD="$CRUX_HOME/adapters/claude/hooks/cycle-guard.sh"
MEMORY_GUARD="$CRUX_HOME/adapters/claude/hooks/memory-guard.sh"
TASK_CONTEXT="$CRUX_HOME/adapters/claude/hooks/task-context.sh"
WORKTREE_GUARD="$CRUX_HOME/adapters/claude/hooks/worktree-guard.sh"
DESTRUCTIVE_GUARD="$CRUX_HOME/adapters/claude/hooks/destructive-guard.sh"
PROPOSAL_GUARD="$CRUX_HOME/adapters/claude/hooks/proposal-guard.sh"
SESSION_SYNC="$CRUX_HOME/adapters/claude/hooks/session-sync.sh"
SESSION_IDLE="$CRUX_HOME/adapters/claude/hooks/session-idle.sh"
PROFILE_REMINDER="$CRUX_HOME/adapters/claude/hooks/profile-reminder.sh"
CLAUDE_PLUGIN="$CRUX_HOME/adapters/claude/plugin"
CODEX_DIR="${CODEX_HOME_DIR:-${CODEX_HOME:-$HOME/.codex}}"
CODEX_HOOKS="$CODEX_DIR/hooks.json"
CODEX_CONTEXT="$CRUX_HOME/adapters/codex/hooks/contexto.sh"
COMMIT_MSG="$CRUX_HOME/adapters/git/commit-msg.sh"
MARK="crux/adapters"

# In a worktree, .git is a file and the hooks live in the repo's common
# directory. Asking git is the only thing that works in both cases.
dir_hooks() {
  local d
  d="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$d" = /* ]] || d="$1/$d"
  mkdir -p "$d/hooks"
  echo "$d/hooks"
}

# A repo with core.hooksPath —its own versioned hooks, as many clients have—
# makes git ignore .git/hooks, and with it every hook crux installs there: the
# commit-msg that checks the language and the pre-push that guards the main
# branch never ran, and nothing said so. crux keeps writing its hooks where it
# always did, and points core.hooksPath at a directory of wrappers that run
# crux's hook first and then the repo's own. It is local config, not versioned:
# nothing of the client's repo changes.
GIT_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push
post-rewrite pre-auto-gc push-to-checkout"

chain_hooks_path() {
  local repo="$1" common own chain name
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  chain="$common/crux-hooks"
  own="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"
  [[ -n "$own" ]] || return 0
  if [[ "$own" != "$chain" ]]; then
    git -C "$repo" config crux.originalHooksPath "$own"
    git -C "$repo" config core.hooksPath "$chain"
  fi
  mkdir -p "$chain"
  for name in $GIT_HOOK_NAMES; do
    cat > "$chain/$name" <<'EOF'
#!/usr/bin/env bash
# Installed by crux hooks install: crux's hook, then the repo's own.
name="$(basename "$0")"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
original="$(git config --get crux.originalHooksPath || true)"
[[ -z "$original" || "$original" = /* ]] || original="$(git rev-parse --show-toplevel)/$original"
input="$(mktemp)"; trap 'rm -f "$input"' EXIT
[[ -t 0 ]] || cat > "$input"
if [[ -x "$common/hooks/$name" ]]; then
  "$common/hooks/$name" "$@" < "$input" || exit $?
fi
if [[ -n "$original" && -x "$original/$name" ]]; then
  "$original/$name" "$@" < "$input" || exit $?
fi
exit 0
EOF
    chmod +x "$chain/$name"
  done
  info "$(basename "$repo") has its own hooks ($own): crux runs its hooks first, then those"
}

unchain_hooks_path() {
  local repo="$1" common original
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [[ "$(git -C "$repo" config --get core.hooksPath 2>/dev/null)" == "$common/crux-hooks" ]] || return 0
  original="$(git -C "$repo" config --get crux.originalHooksPath 2>/dev/null || true)"
  if [[ -n "$original" ]]; then
    git -C "$repo" config core.hooksPath "$original"
  else
    git -C "$repo" config --unset core.hooksPath
  fi
  git -C "$repo" config --unset crux.originalHooksPath 2>/dev/null || true
  rm -rf "$common/crux-hooks"
  ok "$(basename "$repo"): core.hooksPath back to ${original:-the default}"
}

cmd_status() {
  echo "agent hooks — $SETTINGS"
  if [[ ! -f "$SETTINGS" ]]; then
    warn "does not exist yet"
  else
    node -e '
      const fs = require("fs");
      const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const hooks = s.hooks || {};
      let n = 0;
      for (const [event, groups] of Object.entries(hooks)) {
        for (const g of groups) for (const h of (g.hooks || [])) {
          n++;
          const cmd = h.command || "";
          const path = cmd.replace(/^~/, process.env.HOME).split(" ")[0];
          const exists = fs.existsSync(path);
          const own = cmd.includes(process.argv[2]);
          console.log(`      ${exists ? "ok " : "BROKEN"}  ${event.padEnd(12)} ${own ? "[crux] " : ""}${cmd}`);
        }
      }
      if (!n) console.log("      none configured");
    ' "$SETTINGS" "$MARK"
  fi

  echo
  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)"; then
    echo "git hooks — $(basename "$docs")"
    if [[ -f "$(dir_hooks "$docs")/pre-commit" ]] && grep -q "$MARK\|crux doctor" "$(dir_hooks "$docs")/pre-commit"; then
      ok "pre-commit installed"
    else
      info "no crux pre-commit"
    fi
    if [[ -f "$(dir_hooks "$docs")/pre-push" ]] && grep -q "crux workspace" "$(dir_hooks "$docs")/pre-push"; then
      ok "pre-push installed — no direct push to the main branch"
    else
      info "no crux pre-push"
    fi
    if [[ -f "$(dir_hooks "$docs")/commit-msg" ]]; then
      ok "commit-msg installed — messages in English"
    else
      info "no crux commit-msg"
    fi
  fi
}

# Replaces the entries that point at an earlier version of the same hook
# (including the ones left broken when the scripts moved into the kernel) and
# leaves the rest untouched: the file is the user's, not ours.
hook_up() {
  # hook_up <event> <command> <pattern of the previous one>
  node -e '
    const fs = require("fs");
    const [file, event, cmd, pattern, matcher = ""] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(file, "utf8"));
    s.hooks = s.hooks || {};
    const groups = (s.hooks[event] = s.hooks[event] || []);
    const previous = new RegExp(pattern);
    let replaced = 0;
    for (const g of groups) {
      g.hooks = (g.hooks || []).map((h) => {
        if (!previous.test(h.command || "")) return h;
        replaced++;
        return { ...h, command: cmd };
      });
    }
    if (!replaced) {
      groups.push({ matcher, hooks: [{ type: "command", command: cmd }] });
    }
    fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
    console.log(replaced ? `      replaced ${replaced} previous entries` : "      new entry");
  ' "$SETTINGS" "$1" "$2" "$3" "${4:-}"
}

# The Claude Code plugin (adapters/claude/plugin) only exists for Claude: it is
# loaded through CLAUDE_CODE_PLUGIN_DIRS in Claude's settings.json, which no
# other agent reads. It carries the mod that draws the task reminder as a panel.
plugin_claude() {
  # plugin_claude add|remove
  node -e '
    const fs = require("fs");
    const [file, action, dir] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(file, "utf8"));
    s.env = s.env || {};
    const others = (s.env.CLAUDE_CODE_PLUGIN_DIRS || "").split(":")
      .filter((d) => d && !/\/adapters\/claude\/plugin\/?$/.test(d));
    if (action === "add") others.push(dir);
    if (others.length) s.env.CLAUDE_CODE_PLUGIN_DIRS = others.join(":");
    else delete s.env.CLAUDE_CODE_PLUGIN_DIRS;
    if (!Object.keys(s.env).length) delete s.env;
    fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
  ' "$SETTINGS" "$1" "$CLAUDE_PLUGIN"
}

# Codex reads its hooks from ~/.codex/hooks.json in the same format as Claude
# Code, so the same scripts are registered. Differences: Codex has no file
# tools of its own (it edits with apply_patch and reads through Bash), the
# hooks that give context as text go through adapters/codex/hooks/contexto.sh,
# and the memory guard is left out because it reviews Claude's memories.
codex_hooks() {
  # codex_hooks add|remove
  node -e '
    const fs = require("fs");
    const [file, action, ctx, sync, idle, cycle, task, destr, wt, prop, doc, lang] = process.argv.slice(1);
    const s = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
    s.hooks = s.hooks || {};
    const isCrux = /doc-sync|cycle-guard|memory-guard|task-context|worktree-guard|destructive-guard|proposal-guard|session-sync|session-idle|profile-reminder|contexto\.sh/;
    for (const [ev, groups] of Object.entries(s.hooks)) {
      s.hooks[ev] = groups
        .map((g) => ({ ...g, hooks: (g.hooks || []).filter((h) => !isCrux.test(h.command || "")) }))
        .filter((g) => g.hooks.length);
      if (!s.hooks[ev].length) delete s.hooks[ev];
    }
    if (action === "add") {
      const cmd = (c) => ({ type: "command", command: c });
      const q = (p) => JSON.stringify(p);
      const put = (ev, matcher, commands) =>
        (s.hooks[ev] = s.hooks[ev] || []).push({ ...(matcher ? { matcher } : {}), hooks: commands.map(cmd) });
      put("SessionStart", "startup|resume|clear", [sync]);
      put("UserPromptSubmit", "", [
        `${q(ctx)} UserPromptSubmit ${q(cycle)}`,
        `${q(ctx)} UserPromptSubmit ${q(task)}`,
        `${q(ctx)} UserPromptSubmit ${q(lang)}`,
        idle,
      ]);
      put("PreToolUse", "Bash", [destr, wt, prop]);
      put("Stop", "", [doc]);
    }
    if (!Object.keys(s.hooks).length) delete s.hooks;
    fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
  ' "$CODEX_HOOKS" "$1" "$CODEX_CONTEXT" "$SESSION_SYNC" "$SESSION_IDLE" "$CYCLE_GUARD" "$TASK_CONTEXT" \
    "$DESTRUCTIVE_GUARD" "$WORKTREE_GUARD" "$PROPOSAL_GUARD" "$DOC_SYNC" "$PROFILE_REMINDER"
}

cmd_install() {
  [[ -f "$DOC_SYNC" ]] || die "missing $DOC_SYNC"
  [[ -f "$CYCLE_GUARD" ]] || die "missing $CYCLE_GUARD"
  [[ -f "$MEMORY_GUARD" ]] || die "missing $MEMORY_GUARD"
  [[ -f "$TASK_CONTEXT" ]] || die "missing $TASK_CONTEXT"
  [[ -f "$WORKTREE_GUARD" ]] || die "missing $WORKTREE_GUARD"
  [[ -f "$DESTRUCTIVE_GUARD" ]] || die "missing $DESTRUCTIVE_GUARD"
  [[ -f "$PROPOSAL_GUARD" ]] || die "missing $PROPOSAL_GUARD"
  [[ -f "$SESSION_SYNC" ]] || die "missing $SESSION_SYNC"
  [[ -f "$SESSION_IDLE" ]] || die "missing $SESSION_IDLE"
  [[ -f "$PROFILE_REMINDER" ]] || die "missing $PROFILE_REMINDER"
  [[ -f "$COMMIT_MSG" ]] || die "missing $COMMIT_MSG"
  chmod +x "$DOC_SYNC" "$CYCLE_GUARD" "$MEMORY_GUARD" "$TASK_CONTEXT" "$WORKTREE_GUARD" "$DESTRUCTIVE_GUARD" "$PROPOSAL_GUARD" "$SESSION_SYNC" "$SESSION_IDLE" "$PROFILE_REMINDER" "$COMMIT_MSG"

  mkdir -p "$(dirname "$SETTINGS")"
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak"

  hook_up Stop "$DOC_SYNC" 'doc-sync|check-doc-sync'
  ok "hook for documentation drift when closing a session"

  hook_up UserPromptSubmit "$CYCLE_GUARD" 'cycle-guard'
  ok "hook for the cycle when starting on the main branch"

  hook_up Stop "$MEMORY_GUARD" 'memory-guard'
  ok "hook for unpromoted project memories when closing a session"

  hook_up UserPromptSubmit "$TASK_CONTEXT" 'task-context'
  ok "hook that brings the task back when resuming a workspace"

  hook_up PreToolUse "$WORKTREE_GUARD" 'worktree-guard' Bash
  ok "hook that stops manual deletion of a registered workspace"

  hook_up PreToolUse "$DESTRUCTIVE_GUARD" 'destructive-guard' 'Bash|Read|Edit|Write|MultiEdit|NotebookEdit'
  ok "hook that stops destructive commands and reading private keys"

  hook_up PreToolUse "$PROPOSAL_GUARD" 'proposal-guard' Bash
  ok "hook that stops opening a proposal by hand without the gate receipt"

  hook_up SessionStart "$SESSION_SYNC" 'session-sync'
  ok "hook that syncs the machine with the remote when opening a session"

  hook_up UserPromptSubmit "$SESSION_IDLE" 'session-idle'
  ok "hook that does the same when returning to a session idle for hours"

  hook_up UserPromptSubmit "$PROFILE_REMINDER" 'profile-reminder'
  ok "hook that repeats the reminder the person set in their profile"

  # Only if Codex is on the machine: creating its folder installs nothing.
  if [[ -d "$CODEX_DIR" && -f "$CODEX_CONTEXT" ]]; then
    chmod +x "$CODEX_CONTEXT"
    codex_hooks add
    ok "Codex hooks in $CODEX_HOOKS (approve them the first time you open Codex)"
  fi

  if [[ -f "$CLAUDE_PLUGIN/.claude-plugin/plugin.json" ]]; then
    plugin_claude add
    ok "Claude Code plugin: the task reminder as a panel (Claude only)"
  fi

  info "previous copy in $SETTINGS.bak"

  # Block direct pushes to the main branch. The real protection is server
  # side, but on a private repo without a paid plan it is not available: this
  # covers the slip, which is the real case. `--no-verify` skips it, and that
  # is acceptable because then it is a decision.
  install_pre_push() {
    local repo="$1" main_name hooks
    hooks="$(dir_hooks "$repo")" || return 1
    # The repo's main branch, not that of the worktree we happen to be in.
    # `|| true`: without origin/HEAD the pipeline fails and with pipefail it
    # takes the whole script down with it.
    # In order: what the project declares, what the remote says, and what the
    # repo is using. Assuming "main" left the hook watching a branch that does
    # not exist, and then it blocks nothing.
    main_name="$(main_branch "$repo")"
    # The name ends up inside an unquoted heredoc, that is, as hook code. It
    # comes from crux.json, which is a versioned file: whoever sends a proposal
    # can change it. A valid refname carries none of this.
    if [[ ! "$main_name" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
      warn "main branch with invalid characters: '$main_name'"
      info "the pre-push of $(basename "$repo") is not installed"
      return 1
    fi
    cat > "$hooks/pre-push" <<EOF
#!/usr/bin/env bash
# Installed by crux hooks install.
# Work comes in through a proposal, not by direct push to $main_name.
while read -r _ _ remote_ref remote_sha; do
  [[ "\$remote_ref" == "refs/heads/$main_name" ]] || continue
  # If the remote does not have the branch yet, this push creates it: it is the
  # first upload of a new repo, not work skipping the proposal.
  [[ "\$remote_sha" =~ ^0+\$ ]] && continue
  echo
  echo "direct push to $main_name blocked"
  echo
  echo "  crux workspace new <task>      # own branch and isolated environment"
  echo "  crux workspace finish <task>   # pushes the branch and opens the proposal"
  echo
  echo "If you really need to: git push --no-verify"
  exit 1
done
exit 0
EOF
    chmod +x "$hooks/pre-push"
  }

  # It is copied instead of calling the kernel from the hook: that way it keeps
  # working even if `crux` is not on the PATH of whoever commits.
  #
  # The scope is fixed at install time. In a client's repo only the tool's
  # signature is stripped: their language and commit format are theirs, and
  # imposing ours would be the same mistake the client-repo profile exists to
  # avoid.
  install_commit_msg() {
    local repo="$1" scope="${2:-full}" language="${3:-en}" hooks
    hooks="$(dir_hooks "$repo")" || return 1
    # Both go into a sed replacement that writes the hook. They come from the
    # profile, which is another versioned file.
    [[ "$language" =~ ^[a-z]{2}$ ]] || { warn "invalid commit language: '$language'"; language=en; }
    [[ "$scope" =~ ^[a-z]+$ ]] || { warn "invalid commit scope: '$scope'"; scope=full; }
    sed -e "s|^SCOPE=\"\${CRUX_COMMIT_MSG_SCOPE:-full}\"|SCOPE=\"\${CRUX_COMMIT_MSG_SCOPE:-$scope}\"|" \
        -e "s|^COMMIT_LANG=\"\${CRUX_COMMIT_MSG_LANG:-en}\"|COMMIT_LANG=\"\${CRUX_COMMIT_MSG_LANG:-$language}\"|" \
      "$COMMIT_MSG" > "$hooks/commit-msg"
    chmod +x "$hooks/commit-msg"
  }

  local kernel
  kernel="$(crux_home)"
  if [[ -n "$kernel" ]] && git -C "$kernel" rev-parse --git-dir >/dev/null 2>&1; then
    install_pre_push "$kernel"
    install_commit_msg "$kernel"
    chain_hooks_path "$kernel"
    ok "pre-push and commit-msg in the kernel"
  fi

  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)" && git -C "$docs" rev-parse --git-dir >/dev/null 2>&1; then
    # The docs repo is pushed directly, as the profile rule says, and that is
    # what is done: in September, 326 of 336 commits of a docs repo went
    # straight to the main branch. The hook contradicted the rule and only
    # served to be skipped. The one crux installed earlier is removed.
    local pre_push_docs; pre_push_docs="$(dir_hooks "$docs")/pre-push"
    if [[ -f "$pre_push_docs" ]] && grep -q "Instalado por crux hooks install\|Installed by crux hooks install" "$pre_push_docs"; then
      rm -f "$pre_push_docs"
      ok "pre-push removed from $(basename "$docs"): documentation is pushed directly"
    fi
    cat > "$(dir_hooks "$docs")/pre-commit" <<'EOF'
#!/usr/bin/env bash
# Installed by crux hooks install.
# Checks conformance before allowing a commit in the docs repo.
command -v crux >/dev/null || exit 0
if ! crux doctor >/tmp/crux-precommit.$$ 2>&1; then
  echo
  echo "crux doctor does not pass — the commit is stopped:"
  echo
  grep -E "^error" /tmp/crux-precommit.$$ | sed 's/^/  /'
  echo
  echo "Fix it, or skip the check with: git commit --no-verify"
  rm -f /tmp/crux-precommit.$$
  exit 1
fi
rm -f /tmp/crux-precommit.$$
EOF
    chmod +x "$(dir_hooks "$docs")/pre-commit"
    install_commit_msg "$docs"
    chain_hooks_path "$docs"
    ok "pre-commit and commit-msg in $(basename "$docs")"

    # Commits in code repos are the majority, so that is where it is needed
    # most. Client repos too: `.git/hooks/` is not versioned, travels in no
    # push and is not "writing in their repo". By skipping them, the one place
    # where the tool's signature must not appear was precisely the one
    # without the net that removes it.
    local root repo profile writes scope
    profile="$(json_get "$docs/crux.json" profile 2>/dev/null || echo multi-repo)"
    writes="$(profile_get "$profile" "$docs" pointers.write true)"
    scope=full
    [[ "$writes" == "false" ]] && scope=signature
    local language; language="$(commit_language "$profile" "$docs")"
    root="$(dirname "$docs")"
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      valid_name "$repo" || { warn "invalid repo name in the contract: $repo"; continue; }
      git -C "$root/$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
      # With `cmd && ok` a repo without accessible hooks would abort the whole
      # install under set -e, and the following repos would be left unhooked.
      if install_commit_msg "$root/$repo" "$scope" "$language"; then
        ok "commit-msg in $repo${scope:+ ($scope)}"
      fi
      # The main branch was protected in the kernel and the docs repo, and not
      # in the code repos, which is where almost all the work happens. Like
      # commit-msg, it is local state: it touches nothing of a client's repo.
      install_pre_push "$root/$repo" && ok "pre-push in $repo"
      chain_hooks_path "$root/$repo"
    done < <(json_get "$docs/crux.json" repos 2>/dev/null)
  else
    info "no docs repo in the current directory: the pre-commit is not installed"
    info "enter one and repeat to hook it"
  fi
}

cmd_remove() {
  [[ -f "$SETTINGS" ]] || die "no $SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak"
  node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const [event, groups] of Object.entries(s.hooks || {})) {
      s.hooks[event] = groups
        .map((g) => ({ ...g, hooks: (g.hooks || []).filter((h) => !/doc-sync|cycle-guard|memory-guard|task-context|worktree-guard|destructive-guard|proposal-guard|session-sync|session-idle|profile-reminder/.test(h.command || "")) }))
        .filter((g) => (g.hooks || []).length);
      if (!s.hooks[event].length) delete s.hooks[event];
    }
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");
  ' "$SETTINGS"
  plugin_claude remove
  [[ -f "$CODEX_HOOKS" ]] && codex_hooks remove
  ok "crux hooks removed (the rest is left as it was)"

  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)"; then
    if [[ -f "$(dir_hooks "$docs")/pre-commit" ]]; then
      grep -q "crux doctor" "$(dir_hooks "$docs")/pre-commit" && rm "$(dir_hooks "$docs")/pre-commit" && ok "pre-commit removed"
    fi
    if [[ -f "$(dir_hooks "$docs")/commit-msg" ]]; then
      grep -q "crux hooks install" "$(dir_hooks "$docs")/commit-msg" && rm "$(dir_hooks "$docs")/commit-msg" && ok "commit-msg removed"
    fi
    unchain_hooks_path "$docs"
    local repo
    while IFS= read -r repo; do
      [[ -n "$repo" ]] && valid_name "$repo" && [[ -d "$(dirname "$docs")/$repo" ]] &&
        unchain_hooks_path "$(dirname "$docs")/$repo"
    done < <(json_get "$docs/crux.json" repos 2>/dev/null)
  fi
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) die "usage: crux hooks {status|install|remove}" ;;
esac
