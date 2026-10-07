#!/usr/bin/env bash

_hygiene_project() {
  local root="$CRUX_PROJECTS_DIR/proj"
  mkdir -p "$root/app" "$root/proj-docs"
  git -C "$root/app" init -q
  echo x > "$root/app/f.txt"
  git -C "$root/app" add -A
  git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/proj-docs/crux.json"
  echo "$root"
}

test_the_registry_self_heals_only_if_neither_folder_nor_branch_remain() {
  sandbox >/dev/null
  local root; root="$(_hygiene_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new deleted --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new with-branch --repo "$root/app" >/dev/null 2>&1

  # What sessions did to free disk: outside crux.
  git -C "$root/app" worktree remove --force "$root/app-ws-deleted" >/dev/null 2>&1
  git -C "$root/app" branch -D ws/deleted >/dev/null 2>&1
  git -C "$root/app" worktree remove --force "$root/app-ws-with-branch" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" heal 2>&1)"
  assert_contains "$out" "'deleted' removed from the registry" "with no folder or branch, the entry is surplus"
  assert_contains "$out" "its branch ws/with-branch is still alive" "with the branch alive there may be work: it warns"
  assert_not_contains "$(cat "$CRUX_REGISTRY")" '"deleted"' "the entry disappears"
  assert_contains "$(cat "$CRUX_REGISTRY")" '"with-branch"' "the other one stays"

  # And there is no need to remember: opening a new workspace already heals.
  git -C "$root/app" branch -D ws/with-branch >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new other --repo "$root/app" >/dev/null 2>&1
  assert_not_contains "$(cat "$CRUX_REGISTRY")" '"with-branch"' "workspace new heals the registry unasked"
}

test_adopt_registers_a_hand_made_worktree() {
  sandbox >/dev/null
  local root; root="$(_hygiene_project)"
  git -C "$root/app" worktree add -q -b fix/by-hand "$root/app-ws-by-hand" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" adopt "$root/app-ws-by-hand" 2>&1)"
  assert_contains "$out" "'by-hand' adopted (fix/by-hand" "it registers it with its branch"
  assert_contains "$(cat "$CRUX_REGISTRY")" '"path": "'"$root"'/app-ws-by-hand"' "it enters the registry"
  assert_file "$SB/tasks/proj/by-hand.md" "and opens its task"

  assert_exit 1 "it is not adopted twice" bash "$CRUX_HOME/bin/workspace.sh" adopt "$root/app-ws-by-hand"
  mkdir -p "$root/loose"
  assert_exit 1 "nor something that is not a worktree" bash "$CRUX_HOME/bin/workspace.sh" adopt "$root/loose"
}

test_status_warns_of_unknown_worktrees_and_already_merged_workspaces() {
  sandbox >/dev/null
  local root; root="$(_hygiene_project)"
  git -C "$root/app" worktree add -q -b fix/loose "$root/app-ws-loose" >/dev/null 2>&1

  # A workspace whose branch had a remote and no longer does: merged and deleted.
  git init -q --bare "$SB/remote.git"
  git -C "$root/app" remote add origin "$SB/remote.git"
  bash "$CRUX_HOME/bin/workspace.sh" new finished --repo "$root/app" >/dev/null 2>&1
  git -C "$root/app-ws-finished" push -q -u origin ws/finished >/dev/null 2>&1
  git -C "$root/app" push -q origin --delete ws/finished >/dev/null 2>&1
  git -C "$root/app" fetch -q --prune origin >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "app-ws-loose is a worktree crux does not know about" "status shows the hand-made worktree"
  assert_contains "$out" "crux workspace adopt" "with how to register it"
  assert_contains "$out" "'finished': its branch is no longer on the remote" "and the workspace that was already merged"
}

test_the_guard_stops_manual_deletion_of_a_registered_workspace() {
  sandbox >/dev/null
  local root; root="$(_hygiene_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new guarded --repo "$root/app" >/dev/null 2>&1
  local hook="$CRUX_HOME/adapters/claude/hooks/worktree-guard.sh"
  _asks() { printf '{"tool_input":{"command":%s}}' "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" 2>&1; }

  local out; out="$(_asks "git worktree remove --force $root/app-ws-guarded")"
  assert_contains "$out" "crux workspace rm guarded" "it stops the shortcut and says what to use"
  assert_exit 2 "it exits with 2, which is what blocks the tool" \
    bash -c "printf '{\"tool_input\":{\"command\":\"rm -rf $root/app-ws-guarded\"}}' | bash $hook"
  assert_eq "" "$(_asks "rm -rf $root/app-ws-guarded/node_modules")" "deleting something inside the workspace is allowed"
  assert_eq "" "$(_asks "rm -rf $root/app-ws-guarded-other")" "a similar name is not the workspace"
  assert_eq "" "$(_asks "git worktree list")" "nor a command that does not delete"
}

test_the_guard_covers_the_other_ways_of_taking_a_workspace_away() {
  # The canonical form was covered; the rest slipped through. And the other way
  # round: it blocked commands that only mentioned the words in a comment.
  sandbox >/dev/null
  local root; root="$(_hygiene_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new variants --repo "$root/app" >/dev/null 2>&1
  local hook="$CRUX_HOME/adapters/claude/hooks/worktree-guard.sh"
  local ws="$root/app-ws-variants"
  _cut() {
    printf '{"tool_input":{"command":%s}}' \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" >/dev/null 2>&1
    echo $?
  }

  assert_eq "2" "$(_cut "rm --recursive --force $ws")" "with long flags"
  assert_eq "2" "$(_cut "rm -f -r $ws")" "with separate flags"
  assert_eq "2" "$(_cut "find $ws -delete")" "with find -delete"
  assert_eq "2" "$(_cut "find $ws -type f -exec rm {} ;")" "with find -exec rm"

  assert_eq "0" "$(_cut "echo done  # careful with rm -rf $ws")" "the path in a comment does not count"
  assert_eq "0" "$(_cut "grep -n 'worktree remove' $ws/notes.md")" "nor mentioning the words"
  assert_eq "0" "$(_cut "cd $ws && rm -rf node_modules")" "nor naming it before deleting something else"

  assert_eq "2" "$(_cut "rm -Rf $ws")" "with a capital R"
  assert_eq "2" "$(_cut "rm -rf $root/app-ws-*")" "with a wildcard that matches the workspace"
  assert_eq "2" "$(_cut "rm -rf $root/*")" "and with one that takes the whole project folder"
  assert_eq "0" "$(_cut "rm -rf $root/*.log")" "but not with one that reaches no workspace"
  assert_eq "0" "$(_cut "rm -rf ./dist/*")" "nor with one relative to another folder"

  # It used to look at everything after the rm, later commands included.
  assert_eq "0" "$(_cut "rm -rf /tmp/scratch; export CRUX_HOME=$ws")" "a later command that names it is not the rm"
  assert_eq "2" "$(_cut "rm -rf /tmp/scratch; rm -rf $ws")" "but a second rm on it is still stopped"
  assert_eq "2" "$(_cut "rm -rf \"$ws\" && echo ok")" "and the path in quotes before an &&"
}

test_the_guard_does_not_read_heredoc_bodies_as_commands() {
  # A heredoc body is text: an apostrophe in it opened a quote that swallowed
  # the rest, and its brackets were taken as a wildcard over the workspace.
  sandbox >/dev/null
  local root; root="$(_hygiene_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new design --repo "$root/app" >/dev/null 2>&1
  local hook="$CRUX_HOME/adapters/claude/hooks/worktree-guard.sh"
  local ws="$root/app-ws-design"
  _cut() {
    printf '{"tool_input":{"command":%s}}' \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" >/dev/null 2>&1
    echo $?
  }
  local nl=$'\n'

  assert_eq "0" "$(_cut "cat > notes.md <<'EOF'${nl}Don't rm -rf by hand${nl}see app-ws-[a-z]*${nl}EOF${nl}echo ok")" \
    "an apostrophe and brackets in the body do not reach the rm"
  assert_eq "0" "$(_cut "cat <<-EOF > notes.md${nl}	rm -rf $ws${nl}	EOF${nl}echo ok")" \
    "nor a body that only talks about deleting it"
  assert_eq "2" "$(_cut "cat > a <<EOF${nl}text${nl}EOF${nl}rm -rf $ws")" \
    "an rm after the heredoc is still stopped"
  assert_eq "2" "$(_cut "bash <<'EOF'${nl}rm -rf $ws${nl}EOF")" \
    "and a body fed to a shell is a command"
  assert_eq "2" "$(_cut "rm -rf $ws <<< yes")" "a here-string is not a heredoc"
}

test_hooks_install_hooks_the_guard_for_bash_only() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  local pre; pre="$(node -e 'const s=require(process.argv[1]); console.log(JSON.stringify(s.hooks.PreToolUse||[]))' "$CLAUDE_SETTINGS")"
  assert_contains "$pre" "worktree-guard.sh" "install hooks the guard"
  assert_contains "$pre" '"matcher":"Bash"' "only on shell commands"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "worktree-guard" "and remove takes it off"
}

test_the_registry_does_not_say_ok_if_it_could_not_be_written() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/readonly"
  mkdir -p "$root/app" "$root/readonly-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"readonly","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/readonly-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new ro --repo "$root/app" >/dev/null 2>&1

  # The directory, not the file: writing is creating a temp file and renaming it,
  # and for that being able to write in the directory is enough.
  chmod 500 "$(dirname "$CRUX_REGISTRY")"
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm ro 2>&1)" || rc=$?
  chmod 700 "$(dirname "$CRUX_REGISTRY")"

  assert_eq "1" "$rc" "it exits red if it could not remove the entry"
  assert_not_contains "$out" "slot released" "and does not say it released the slot"
  # The exact point where it fails depends on whether it could take the lock
  # first; what the change guarantees is that something not done is not
  # announced as done.
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "its entry is still in the registry" \
    "and there is a message that says so when the failure is on removing the entry"
}

test_the_registry_is_written_in_one_piece() {
  sandbox >/dev/null
  local reg="$SB/registry.json"
  source "$CRUX_HOME/lib/registry.sh"
  # registry_init reads them when the library is loaded.
  # shellcheck disable=SC2034
  REGISTRY="$reg"
  # shellcheck disable=SC2034
  LOCK="$SB/.lock"
  registry_init
  assert_file "$reg" "registry_init creates it"
  assert_contains "$(cat "$CRUX_HOME/lib/registry.sh")" "renameSync" \
    "it is written to a temp file and renamed, not over it"
  assert_contains "$(cat "$CRUX_HOME/lib/registry.sh")" "unreadable registry" \
    "and a broken registry is reported instead of passing as empty"
}

test_a_staging_password_does_not_travel_on_the_command_line() {
  sandbox >/dev/null
  local stg; stg="$(cat "$CRUX_HOME/bin/stg.sh")"
  assert_not_contains "$stg" "hash-password --plaintext" \
    "the password does not go as an argument, which sudo leaves written in auth.log"
  assert_contains "$stg" "docker exec -i" "it comes in through standard input"
}

test_a_project_skill_does_not_replace_the_kernels() {
  sandbox >/dev/null
  local mat; mat="$(cat "$CRUX_HOME/adapters/claude/materialize.sh")"
  assert_contains "$mat" "already shipped by the kernel" "it warns instead of replacing"
  assert_not_contains "$mat" 'ln -sfn "$src" "$CLAUDE_SKILLS_DIR/$name"' \
    "the link is no longer forced blindly"
}

test_check_secrets_sees_a_password_in_an_assignment() {
  sandbox >/dev/null
  local d="$SB/docs"; mkdir -p "$d"
  printf '# Notes\n\nDB_PASSWORD=Ab3xKq91zzTT\n' > "$d/notes.md"
  local out; out="$(node "$CRUX_HOME/lib/check-secrets.mjs" "$d" 2>&1 || true)"
  assert_contains "$out" "notes.md" "the KEY=value form is no longer dropped because of the ="

  printf '# Notes\n\nDB_PASSWORD=changeme\nPORT=3000\n' > "$d/notes.md"
  local clean; clean="$(node "$CRUX_HOME/lib/check-secrets.mjs" "$d" 2>&1 || true)"
  assert_not_contains "$clean" "notes.md" "and an example value does not shout"
}

test_the_task_record_does_not_lose_what_crux_did_not_write() {
  sandbox >/dev/null
  local f="$SB/t.md"
  cat > "$f" <<'MD'
---
task: t
project: p
status: open
owner-name: Jorge
---

A paragraph of context.

## Deviations and decisions

- The example is:

```markdown
## Example header
text
```

- And that is why X.
MD
  node "$CRUX_HOME/lib/task.mjs" note --file "$f" --text "new decision" >/dev/null 2>&1
  local after_step; after_step="$(cat "$f")"
  assert_contains "$after_step" "owner-name: Jorge" "a header key with a hyphen survives"
  assert_contains "$after_step" "A paragraph of context." "and what was written before the first section"
  assert_contains "$after_step" "- And that is why X." "what came after the code block stays in place"
  local lines; lines="$(grep -n 'new decision' "$f" | cut -d: -f1)"
  local closing; closing="$(grep -n '^```$' "$f" | tail -1 | cut -d: -f1)"
  [[ "$lines" -gt "$closing" ]] && PASS=$((PASS + 1)) \
    || _fail "the new note goes outside the code block"
}

test_the_gate_shows_the_contract_commands_the_first_time() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/gate"
  mkdir -p "$root/app" "$root/gate-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"gate","profile":"multi-repo","repos":["app"],"quality":{"gate":["echo checking"]},"sections":[]}\n' \
    > "$root/gate-docs/crux.json"

  local out
  out="$(cd "$root/app" && CRUX_GATE_ASSUME_YES=1 bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)" || true
  assert_contains "$out" "declared in the contract" "the first time it shows them"
  assert_contains "$out" "echo checking" "with the command in front"

  # The second time, with the same fingerprint, it does not interrupt again.
  local other
  other="$(cd "$root/app" && CRUX_GATE_ASSUME_YES=1 bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)" || true
  assert_not_contains "$other" "declared in the contract" "the second time it does not bother"

  # And if they change, it says so.
  printf '{"crux":"0.1.0","project":"gate","profile":"multi-repo","repos":["app"],"quality":{"gate":["echo something else"]},"sections":[]}\n' \
    > "$root/gate-docs/crux.json"
  local changed
  changed="$(cd "$root/app" && CRUX_GATE_ASSUME_YES=1 bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)" || true
  assert_contains "$changed" "has changed since last time" "when it changes, it warns"
}

test_the_guard_stops_what_destroys_work() {
  local hook="$CRUX_HOME/adapters/claude/hooks/destructive-guard.sh"
  _bash() {
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" >/dev/null 2>&1
    echo $?
  }
  assert_eq "2" "$(_bash "git reset --hard HEAD~1")" "reset --hard"
  assert_eq "2" "$(_bash "git -C repo reset --hard")" "reset --hard with -C"
  assert_eq "2" "$(_bash "git push --force origin main")" "push --force"
  assert_eq "2" "$(_bash "git push -f")" "push -f"
  assert_eq "2" "$(_bash "git clean -fdx")" "clean -fdx"
  assert_eq "2" "$(_bash "git clean -f -d")" "clean -f -d"
  assert_eq "2" "$(_bash "git checkout -- .")" "discarding the tree with checkout"
  assert_eq "2" "$(_bash "git restore .")" "discarding the tree with restore"
  assert_eq "2" "$(_bash "git stash clear")" "emptying the shared stash"
  assert_eq "2" "$(_bash "rm -rf ~")" "rm -rf ~"
  assert_eq "2" "$(_bash "rm -rf \$HOME")" "rm -rf \$HOME"
  assert_eq "2" "$(_bash "rm -rf .")" "rm -rf ."
  assert_eq "2" "$(_bash "rm -Rf *")" "rm -Rf *"
  assert_eq "2" "$(_bash "chmod -R 777 .")" "chmod -R 777"
  assert_eq "2" "$(_bash "sudo chown -R me /srv")" "chown -R"
  assert_eq "2" "$(_bash "pkill -f next-server")" "pkill"
  assert_eq "2" "$(_bash "cd /tmp && killall node")" "killall after another command"
  assert_eq "2" "$(_bash "bash -c \"git reset --hard\"")" "inside bash -c"
}

test_the_guard_lets_through_what_looks_like_it() {
  local hook="$CRUX_HOME/adapters/claude/hooks/destructive-guard.sh"
  _bash() {
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" >/dev/null 2>&1
    echo $?
  }
  assert_eq "0" "$(_bash "git push --force-with-lease")" "force-with-lease is the safe form"
  assert_eq "0" "$(_bash "git push -u origin feat/x")" "a normal push"
  assert_eq "0" "$(_bash "git push --follow-tags")" "a long option that starts with f"
  assert_eq "0" "$(_bash "git reset --soft HEAD~1")" "reset --soft"
  assert_eq "0" "$(_bash "git clean -n -d")" "clean as a dry run"
  assert_eq "0" "$(_bash "git checkout -- src/a.ts")" "discarding a specific file"
  assert_eq "0" "$(_bash "rm -rf ./dist node_modules")" "rm -rf of specific paths"
  assert_eq "0" "$(_bash "rm -rf ~/.cache/foo")" "rm -rf of a path inside ~"
  assert_eq "0" "$(_bash "kill 12345")" "kill by PID"
  assert_eq "0" "$(_bash "pgrep -a node")" "pgrep only searches"
  assert_eq "0" "$(_bash "echo 'never use git reset --hard'")" "mentioning it in quotes"
  assert_eq "0" "$(_bash "ls  # git push --force")" "mentioning it in a comment"
  assert_eq "0" "$(_bash "$(printf 'git commit -F - <<EOF\nfix: no more git reset --hard\nEOF')")" \
    "mentioning it in a commit message"
  assert_eq "0" "$(_bash "ssh -i ~/.ssh/id_ed25519 host")" "using a key without dumping it"
  assert_eq "0" "$(_bash "cat ~/.ssh/id_ed25519.pub")" "reading the public key"
}

test_the_guard_does_not_let_private_keys_be_read() {
  local hook="$CRUX_HOME/adapters/claude/hooks/destructive-guard.sh"
  _tool() {
    printf '{"tool_name":"%s","tool_input":{"%s":%s}}' "$1" "$2" \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$3")" | bash "$hook" >/dev/null 2>&1
    echo $?
  }
  assert_eq "2" "$(_tool Bash command "cat ~/.ssh/id_ed25519")" "cat of the private key"
  assert_eq "2" "$(_tool Bash command "base64 certs/server.pem")" "dumping a .pem"
  assert_eq "2" "$(_tool Bash command "cat ~/.config/gh/hosts.yml")" "the gh token"
  assert_eq "2" "$(_tool Read file_path "$HOME/.ssh/id_ed25519_github")" "Read of the private key"
  # shellcheck disable=SC2088  # the literal tilde is what is tested
  assert_eq "2" "$(_tool Read file_path "~/.aws/credentials")" "Read of the AWS credentials"
  assert_eq "0" "$(_tool Read file_path "$HOME/.ssh/id_ed25519.pub")" "Read of the public one"
  assert_eq "0" "$(_tool Read file_path "/repo/.env")" "carry-env moves the .env and it is allowed"
  assert_eq "0" "$(_tool Read file_path "/repo/src/keys.ts")" "a file with key in the name"
}

test_hooks_install_hooks_the_destructive_guard() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  local pre; pre="$(node -e 'const s=require(process.argv[1]); console.log(JSON.stringify(s.hooks.PreToolUse||[]))' "$CLAUDE_SETTINGS")"
  assert_contains "$pre" "destructive-guard.sh" "install hooks the guard"
  assert_contains "$pre" '"matcher":"Bash|Read|Edit|Write|MultiEdit|NotebookEdit"' "on the shell and files"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "destructive-guard" "and remove takes it off"
}

test_the_proposal_guard_sends_to_finish() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_hygiene_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new cover --repo "$root/app" >/dev/null 2>&1
  local hook="$CRUX_HOME/adapters/claude/hooks/proposal-guard.sh"
  mkdir -p "$SB/loose"; git -C "$SB/loose" init -q
  _pr() {
    printf '{"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$2")" | bash "$hook" 2>&1
    echo "rc=$?"
  }
  local out
  out="$(_pr "$root/app-ws-cover" 'gh pr create --title "x" --body "y"')"
  assert_contains "$out" "rc=2" "in a workspace, gh pr create is stopped"
  assert_contains "$out" "crux workspace finish cover" "and says the exact finish"
  out="$(_pr "$root/app" "git checkout -b shortcut && gh pr create --fill")"
  assert_contains "$out" "rc=2" "in the main checkout too"
  assert_contains "$out" "crux workspace new <task>" "and there it sends you to open a workspace"
  out="$(_pr "$SB" "cd $root/app-ws-cover && gh pr create --fill")"
  assert_contains "$out" "rc=2" "entering a managed repo with cd"
  assert_contains "$(_pr "$SB/loose" "gh pr create --fill")" "rc=0" "a repo without a docs repo is not touched"
  assert_contains "$(_pr "$root/app-ws-cover" "gh pr view 9")" "rc=0" "nor other gh commands"
  assert_contains "$(_pr "$root/app-ws-cover" "echo 'use gh pr create'")" "rc=0" "nor mentioning it"
}

test_hooks_install_hooks_the_proposal_guard() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "proposal-guard.sh" "install hooks it"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "proposal-guard" "and remove takes it off"
}

test_no_skill_sends_a_command_the_guard_blocks() {
  # A skill that tells to run what the guard stops leaves the agent against a
  # wall: share-local closed the tunnel with pkill.
  local hook="$CRUX_HOME/adapters/claude/hooks/destructive-guard.sh" bad_items="" f line
  for f in "$CRUX_HOME"/skills/*/SKILL.md; do
    while IFS= read -r line; do
      [[ -n "${line// }" ]] || continue
      if ! printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
          "$(node -e 'console.log(JSON.stringify(process.argv[1]))' -- "$line")" \
          | bash "$hook" >/dev/null 2>&1; then
        bad_items+="${f#"$CRUX_HOME"/}: $line"$'\n'
      fi
    done < <(awk '/^```/{ if (inside) { inside = 0; cmd = 0 } else { inside = 1; cmd = ($0 ~ /^```(bash|sh)?[[:space:]]*$/) } ; next } inside && cmd' "$f")
  done
  assert_eq "" "$bad_items" "no command block of a skill clashes with the guard"
}

_wait_guard() {
  # _wait_guard <command> [background] — the hook's exit code
  local bg="${2:-false}"
  printf '{"tool_name":"Bash","tool_input":{"command":%s,"run_in_background":%s}}' \
    "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" "$bg" \
    | bash "$CRUX_HOME/adapters/claude/hooks/wait-guard.sh" >/dev/null 2>&1
  echo $?
}

test_the_wait_guard_sends_long_commands_to_the_background() {
  assert_eq "2" "$(_wait_guard "./test/run.sh")" "the whole suite"
  assert_eq "2" "$(_wait_guard "cd x && ./test/run.sh > out.txt 2>&1")" "the suite with its output redirected"
  assert_eq "2" "$(_wait_guard "crux ship run -- npm run check")" "the gate"
  assert_eq "2" "$(_wait_guard "gh pr checks 12 --watch")" "watching CI"
  assert_eq "2" "$(_wait_guard "until grep -q done log; do sleep 10; done")" "a waiting loop"
  assert_eq "2" "$(_wait_guard "docker build -t x .")" "an image build"
  assert_eq "2" "$(_wait_guard "(cd android && ./gradlew assembleDebug)")" "an Android build"
  assert_eq "2" "$(_wait_guard "npx eas-cli build --platform android")" "a waited cloud build"
}

test_the_wait_guard_lets_short_or_decided_commands_through() {
  assert_eq "0" "$(_wait_guard "./test/run.sh doctor")" "a filtered run of the suite"
  assert_eq "0" "$(_wait_guard "./test/run.sh" true)" "the suite in the background"
  assert_eq "0" "$(_wait_guard "CRUX_WAIT=1 ./test/run.sh")" "waiting, said out loud"
  assert_eq "0" "$(_wait_guard "eas build --platform android --no-wait")" "a cloud build that is not waited for"
  assert_eq "0" "$(_wait_guard "sleep 5")" "a short pause"
  assert_eq "0" "$(_wait_guard "git commit -m \"test/run.sh passed\"")" "the words inside a message"
}
