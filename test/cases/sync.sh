#!/usr/bin/env bash

# `crux sync` is for switching machines: one falls behind while work happens
# on the other. Here the two machines are two clones of the same local remote,
# and `gh` is a fake with no session, so it never goes to real GitHub.

_no_gh() {
  mkdir -p "$SB/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/bin/gh"
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

_two_machines() {
  # A remote with one commit, cloned on this machine (inside the root) and on
  # the other (outside). Leaves OTHER with the path of the second clone.
  _no_gh
  git init -q --bare -b main "$SB/remote.git"
  git clone -q "$SB/remote.git" "$SB/seed" 2>/dev/null
  git -C "$SB/seed" commit -q --allow-empty -m "first"
  git -C "$SB/seed" push -q origin main
  mkdir -p "$CRUX_PROJECTS_DIR/alpha"
  git clone -q "$SB/remote.git" "$CRUX_PROJECTS_DIR/alpha/app"
  OTHER="$SB/seed"
  export CRUX_STATE_DIR="$SB/state"
}

_work_on_the_other() {
  echo "$1" > "$OTHER/$1"
  git -C "$OTHER" add "$1"
  git -C "$OTHER" commit -q -m "$1"
  git -C "$OTHER" push -q origin main
}

test_sync_advances_the_branch_that_is_behind() {
  sandbox >/dev/null
  _two_machines
  _work_on_the_other done-there

  local out
  out="$(crux sync 2>&1)"

  assert_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "what the other machine did arrives"
  assert_contains "$out" "alpha/app" "it says which repo advanced"
  assert_contains "$out" "1 new commit" "and how many"
  teardown
}

test_sync_does_not_touch_a_branch_with_uncommitted_changes() {
  sandbox >/dev/null
  _two_machines
  echo "half done" > "$CRUX_PROJECTS_DIR/alpha/app/note"
  git -C "$CRUX_PROJECTS_DIR/alpha/app" add note
  _work_on_the_other done-there

  local out rc
  out="$(crux sync 2>&1)"; rc=$?

  assert_no_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "it does not advance over uncommitted work"
  assert_contains "$out" "uncommitted changes" "and says why"
  assert_eq 1 "$rc" "it exits with an error: there is something to decide"
  teardown
}

test_sync_does_not_join_diverged_branches() {
  sandbox >/dev/null
  _two_machines
  git -C "$CRUX_PROJECTS_DIR/alpha/app" commit -q --allow-empty -m "here"
  _work_on_the_other done-there

  local out before
  before="$(git -C "$CRUX_PROJECTS_DIR/alpha/app" rev-parse HEAD)"
  out="$(crux sync 2>&1)"

  assert_eq "$before" "$(git -C "$CRUX_PROJECTS_DIR/alpha/app" rev-parse HEAD)" "neither merges nor rewrites"
  assert_contains "$out" "have diverged" "it warns that a decision is needed"
  teardown
}

test_sync_leave_fails_with_unpushed_commits() {
  sandbox >/dev/null
  _two_machines
  git -C "$CRUX_PROJECTS_DIR/alpha/app" commit -q --allow-empty -m "unpushed"

  local out rc
  out="$(crux sync --leave 2>&1)"; rc=$?

  assert_eq 1 "$rc" "it does not let you leave with trapped commits"
  assert_contains "$out" "not pushed" "and says which"
  teardown
}

test_sync_leave_fails_with_a_branch_not_on_the_remote() {
  sandbox >/dev/null
  _two_machines
  git -C "$CRUX_PROJECTS_DIR/alpha/app" switch -q -c only-here
  git -C "$CRUX_PROJECTS_DIR/alpha/app" commit -q --allow-empty -m "local"
  git -C "$CRUX_PROJECTS_DIR/alpha/app" switch -q main

  local out
  out="$(crux sync --leave 2>&1)"

  assert_contains "$out" "only-here is in no remote" "the local branch comes out by name"
  teardown
}

test_sync_leave_does_not_block_on_merged_branches() {
  sandbox >/dev/null
  _two_machines
  local app="$CRUX_PROJECTS_DIR/alpha/app"
  # A proposal merged with squash: its branch was deleted from the remote and its
  # commits are not in the main one. Blocking on this would be noise.
  git -C "$app" switch -q -c proposal
  git -C "$app" commit -q --allow-empty -m "change"
  git -C "$app" push -q -u origin proposal 2>/dev/null
  git -C "$app" switch -q main
  git -C "$app" push -q origin --delete proposal 2>/dev/null
  git -C "$app" fetch -q --prune

  assert_exit 0 "a merged branch traps nothing" crux sync --leave
  teardown
}

test_sync_leave_passes_if_everything_is_pushed() {
  sandbox >/dev/null
  _two_machines

  local out
  out="$(crux sync --leave 2>&1)"
  assert_contains "$out" "nothing trapped" "it says so plainly"
  assert_exit 0 "and it exits fine" crux sync --leave
  teardown
}

test_sync_hook_stays_quiet_if_up_to_date_and_does_not_repeat() {
  sandbox >/dev/null
  _two_machines
  mkdir -p "$SB/home"

  local out
  out="$(HOME="$SB/home" crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "with no news it puts nothing in the context"

  _work_on_the_other done-there
  out="$(HOME="$SB/home" crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "within the interval it does not sync again"

  out="$(HOME="$SB/home" CRUX_SYNC_EVERY_MIN=0 crux sync --hook < /dev/null 2>&1)"
  assert_contains "$out" "1 new commit" "past the interval it brings what is new and says so"
  teardown
}

test_hooks_install_hooks_the_sync() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  ( cd "$SB" && crux hooks install ) >/dev/null 2>&1

  assert_contains "$(cat "$CLAUDE_SETTINGS")" "session-sync.sh" "install hooks the session start hook"
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "SessionStart" "on the start event"
  ( cd "$SB" && crux hooks remove ) >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "session-sync" "and remove takes it off"
  teardown
}

test_sync_hook_does_not_repeat_a_remote_that_no_longer_exists() {
  sandbox >/dev/null
  _two_machines
  mkdir -p "$SB/home" "$CRUX_PROJECTS_DIR/beta"
  git init -q "$CRUX_PROJECTS_DIR/beta/orphan"
  git -C "$CRUX_PROJECTS_DIR/beta/orphan" remote add origin "$SB/does-not-exist.git"

  local out
  out="$(HOME="$SB/home" crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "a deleted remote is not announced in every session"
  out="$(crux sync 2>&1)"
  assert_contains "$out" "beta/orphan" "but by hand it is listed"
  teardown
}

test_sync_does_not_bring_projects_the_machine_does_not_have() {
  sandbox >/dev/null
  _two_machines
  # A gh with a session that announces a project with a contract. Each machine
  # has its own: sync brings up to date what is there, it does not clone what is not.
  _ready_machine
  _fake_gh "other-docs" "other"

  local out
  out="$(crux sync 2>&1)"
  assert_no_file "$CRUX_PROJECTS_DIR/other" "a project on the remote that is not here stays out"
  # But silence would leave you believing this machine has everything.
  assert_contains "$out" "other" "it says the project exists"
  assert_contains "$out" "crux clone other" "and how to bring it"
  assert_not_contains "$out" "warn  other" "a missing project is news, not a warning"

  rm -f "$CRUX_STATE_DIR/sync-last"
  out="$(crux sync --hook </dev/null 2>&1)"
  assert_not_contains "$out" "crux clone other" "the session hook does not go asking the remote for it"
  teardown
}

test_sync_leave_sees_a_remote_that_no_longer_exists() {
  sandbox >/dev/null
  _two_machines
  # With the remote deleted, the local references say everything is pushed.
  mv "$SB/remote.git" "$SB/remote-deleted.git"

  local out rc
  out="$(crux sync --leave 2>&1)"; rc=$?
  assert_contains "$out" "its remote no longer exists" "it says so"
  assert_eq 1 "$rc" "and it does not let you leave believing it is safe"
  teardown
}

test_sync_leave_sees_commits_on_a_detached_head() {
  sandbox >/dev/null
  _two_machines
  git -C "$CRUX_PROJECTS_DIR/alpha/app" checkout -q --detach
  git -C "$CRUX_PROJECTS_DIR/alpha/app" commit -q --allow-empty -m "outside any branch"

  local out rc
  out="$(crux sync --leave 2>&1)"; rc=$?
  assert_contains "$out" "detached HEAD" "the loose commit shows up"
  assert_eq 1 "$rc" "and it blocks"
  teardown
}

test_sync_also_advances_branches_that_are_not_in_use() {
  sandbox >/dev/null
  _two_machines
  git -C "$CRUX_PROJECTS_DIR/alpha/app" switch -q -c work
  _work_on_the_other done-there

  local out
  out="$(crux sync 2>&1)"
  assert_eq 0 "$(git -C "$CRUX_PROJECTS_DIR/alpha/app" rev-list --count main..origin/main)" \
    "main is up to date even when on another branch"
  assert_contains "$out" "main, 1 new commit" "and says so"
  teardown
}

test_sync_two_at_once_do_not_step_on_each_other() {
  sandbox >/dev/null
  _two_machines
  _work_on_the_other done-there
  # Another sync running, represented by its lock. Launching them for real in
  # parallel only clashes sometimes, and a test that sometimes fails is useless.
  mkdir -p "$CRUX_STATE_DIR/sync.lock"

  local out
  out="$(HOME="$SB" CRUX_SYNC_EVERY_MIN=0 crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "the hook does not step in if one is already running"
  assert_no_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "nor touches anything"

  ( sleep 2; rmdir "$CRUX_STATE_DIR/sync.lock" ) &
  out="$(crux sync 2>&1)"
  wait
  assert_contains "$out" "another sync is running" "by hand, it waits and says so"
  assert_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "and when it is free it syncs"
  teardown
}

test_sync_says_if_a_contract_cannot_be_read() {
  sandbox >/dev/null
  _two_machines
  mkdir -p "$CRUX_PROJECTS_DIR/alpha/alpha-docs"
  printf '{"crux":"0.60.0","repos":["app","nue' > "$CRUX_PROJECTS_DIR/alpha/alpha-docs/crux.json"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "crux.json unreadable" "a broken contract is not taken for one with nothing to bring"
  teardown
}

test_sync_a_down_secondary_remote_does_not_leave_the_repo_unanswered() {
  sandbox >/dev/null
  _two_machines
  git -C "$CRUX_PROJECTS_DIR/alpha/app" remote add old "$SB/does-not-exist.git"
  _work_on_the_other done-there

  local out
  out="$(crux sync 2>&1)"
  assert_not_contains "$out" "no answer" "origin answered: the repo is up to date"
  assert_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "and it advances"
  teardown
}

test_sync_says_why_it_cannot_advance() {
  sandbox >/dev/null
  _two_machines
  _work_on_the_other clashes
  echo "mine" > "$CRUX_PROJECTS_DIR/alpha/app/clashes"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "clashes with one that is arriving" "it names the cause"
  assert_eq "mine" "$(cat "$CRUX_PROJECTS_DIR/alpha/app/clashes")" "and does not overwrite the local file"
  teardown
}

test_sync_installs_the_hooks_of_the_new_kernel() {
  sandbox >/dev/null
  _no_gh
  local home="$SB/home-upgrade" clone="$CRUX_PROJECTS_DIR/crux"
  mkdir -p "$home/.crux" "$clone"
  printf 'CRUX_MODE="release"\n' > "$home/.crux/config"
  echo "99.0.0" > "$clone/VERSION"
  # A stand-in installer: the new kernel's crux writes down which kernel it believes it is.
  cat > "$clone/install.sh" <<'SH'
mkdir -p "$HOME/.crux/kernel/99.0.0/bin"
printf '#!/usr/bin/env bash\necho "$CRUX_HOME" > "$HOME/hooks-from"\n' > "$HOME/.crux/kernel/99.0.0/bin/crux"
chmod +x "$HOME/.crux/kernel/99.0.0/bin/crux"
SH
  git -C "$clone" init -q -b main
  git -C "$clone" add -A && git -C "$clone" commit -q -m "release"
  git -C "$clone" tag v99.0.0

  local out
  out="$(env HOME="$home" CRUX_SYNC_NO_INSTALL=0 "$CRUX_HOME/bin/crux" sync 2>&1)"

  assert_contains "$out" "99.0.0, with its hooks" "it installs the published version"
  assert_eq "$home/.crux/kernel/99.0.0" "$(cat "$home/hooks-from" 2>/dev/null)" \
    "and registers the hooks of the new kernel, not of the one running the sync"
  teardown
}

test_sync_updates_the_kernel_from_a_clone_inside_its_own_project() {
  sandbox >/dev/null
  _no_gh
  local home="$SB/home-project" clone="$CRUX_PROJECTS_DIR/crux/crux"
  mkdir -p "$home/.crux" "$clone" "$CRUX_PROJECTS_DIR/crux/crux-docs"
  printf 'CRUX_MODE="release"\n' > "$home/.crux/config"
  echo "99.0.0" > "$clone/VERSION"
  cat > "$clone/install.sh" <<'SH'
mkdir -p "$HOME/.crux/kernel/99.0.0/bin"
printf '#!/usr/bin/env bash\ntrue\n' > "$HOME/.crux/kernel/99.0.0/bin/crux"
chmod +x "$HOME/.crux/kernel/99.0.0/bin/crux"
SH
  git -C "$clone" init -q -b main
  git -C "$clone" add -A && git -C "$clone" commit -q -m "release"
  git -C "$clone" tag v99.0.0

  local out
  out="$(env HOME="$home" CRUX_SYNC_NO_INSTALL=0 "$CRUX_HOME/bin/crux" sync 2>&1)"
  assert_contains "$out" "99.0.0, with its hooks" \
    "the kernel cloned next to its docs repo, like any project's code, is still the one it updates from"
  teardown
}

_workspace_on_both() {
  # The ws/feat branch, checked out in a worktree here and pushed; OTHER is
  # left on that branch, as when the task is resumed on the other machine.
  _two_machines
  local app="$CRUX_PROJECTS_DIR/alpha/app"
  git -C "$app" worktree add -q -b ws/feat "$CRUX_PROJECTS_DIR/alpha/app-ws-feat" 2>/dev/null
  git -C "$CRUX_PROJECTS_DIR/alpha/app-ws-feat" push -q -u origin ws/feat 2>/dev/null
  git -C "$OTHER" fetch -q origin
  git -C "$OTHER" checkout -q -b ws/feat origin/ws/feat
  echo "from-there" > "$OTHER/from-there"
  git -C "$OTHER" add from-there && git -C "$OTHER" commit -q -m "from there"
  git -C "$OTHER" push -q origin ws/feat
}

test_sync_advances_a_workspace_the_other_machine_moved_on() {
  sandbox >/dev/null
  _workspace_on_both

  local out
  out="$(crux sync 2>&1)"

  # Left behind, the next commit here diverges and it only shows on pushing.
  assert_file "$CRUX_PROJECTS_DIR/alpha/app-ws-feat/from-there" "the workspace gets what was done on the other machine"
  assert_contains "$out" "alpha/app-ws-feat" "and it says which one"
  teardown
}

test_sync_leaves_a_dirty_workspace_alone_and_says_so() {
  sandbox >/dev/null
  _workspace_on_both
  local ws="$CRUX_PROJECTS_DIR/alpha/app-ws-feat"
  echo "half" > "$ws/half" && git -C "$ws" add half

  local out
  out="$(crux sync 2>&1)"

  assert_no_file "$ws/from-there" "it does not advance over uncommitted work"
  assert_contains "$out" "alpha/app-ws-feat" "but it says the workspace is behind"
  teardown
}

test_sync_points_out_a_workspace_whose_task_was_archived() {
  sandbox >/dev/null
  _two_machines
  local app="$CRUX_PROJECTS_DIR/alpha/app" tasks
  git -C "$app" worktree add -q -b ws/old "$CRUX_PROJECTS_DIR/alpha/app-ws-old" 2>/dev/null
  git -C "$app" worktree add -q -b ws/live "$CRUX_PROJECTS_DIR/alpha/app-ws-live" 2>/dev/null
  tasks="$("$CRUX_BIN" __fn task_dir)"
  mkdir -p "$tasks/alpha/done"
  echo "task: old" > "$tasks/alpha/done/2026-10-01-old.md"
  echo "task: live" > "$tasks/alpha/live.md"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "crux workspace rm old" "says the closed task's workspace can go"
  assert_not_contains "$out" "crux workspace rm live" "and leaves the open one alone"
  assert_file "$CRUX_PROJECTS_DIR/alpha/app-ws-old/.git" "without removing anything itself"
  teardown
}

test_sync_names_the_copy_left_by_a_task_conflict() {
  sandbox >/dev/null
  _two_machines
  local tasks
  tasks="$("$CRUX_BIN" __fn task_dir)"
  mkdir -p "$tasks/alpha"
  echo "task: feat" > "$tasks/alpha/feat.md"
  echo "task: feat" > "$tasks/alpha/feat.conflicto-remota.md"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "alpha/feat.conflicto-remota.md" "names the copy that lost"
  assert_not_contains "$out" "alpha/feat.md holds" "and not the task itself"
  teardown
}

test_sync_names_a_project_materialized_with_an_old_kernel() {
  sandbox >/dev/null
  _two_machines
  mkdir -p "$CRUX_PROJECTS_DIR/old/old-docs" "$CRUX_PROJECTS_DIR/new/new-docs"
  local current; current="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  echo '{"crux":"0.1.0","project":"old","repos":[]}' > "$CRUX_PROJECTS_DIR/old/old-docs/crux.json"
  echo "{\"crux\":\"$current\",\"project\":\"new\",\"repos\":[]}" > "$CRUX_PROJECTS_DIR/new/new-docs/crux.json"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "old is materialized with crux 0.1.0" "names the project that fell behind"
  assert_contains "$out" "crux upgrade" "and how to bring it up"
  assert_not_contains "$out" "new is materialized" "and not the one up to date"
  teardown
}

test_sync_names_a_repo_whose_origin_is_not_the_one_the_contract_declares() {
  sandbox >/dev/null
  _two_machines
  mkdir -p "$CRUX_PROJECTS_DIR/alpha/alpha-docs"
  echo '{"crux":"0.60.0","project":"alpha","repos":["app"],"remote":{"repos":{"app":"git@github.com:new-owner/app.git"}}}' \
    > "$CRUX_PROJECTS_DIR/alpha/alpha-docs/crux.json"

  local out rc
  out="$(crux sync 2>&1)"; rc=$?
  assert_contains "$out" "alpha/app: origin is $SB/remote.git and crux.json declares git@github.com:new-owner/app.git" \
    "a repo moved to another owner is named, because its old URL keeps answering"
  assert_contains "$out" "remote set-url origin git@github.com:new-owner/app.git" "with the command that aligns it"
  assert_eq "1" "$rc" "it asks for a decision, so it does not end as if everything were fine"
  teardown
}

test_sync_says_nothing_of_an_origin_that_matches_the_contract() {
  sandbox >/dev/null
  _two_machines
  mkdir -p "$CRUX_PROJECTS_DIR/alpha/alpha-docs"
  echo "{\"crux\":\"0.60.0\",\"project\":\"alpha\",\"repos\":[\"app\"],\"remote\":{\"repos\":{\"app\":\"$SB/remote.git\"}}}" \
    > "$CRUX_PROJECTS_DIR/alpha/alpha-docs/crux.json"

  local out
  out="$(crux sync 2>&1)"
  assert_not_contains "$out" "origin is" "an origin that is where the contract says is not news"
  teardown
}

_pointer_on_both() {
  # A pointer committed on both machines, with its generated block and a line
  # of its own below it.
  printf '# app\n\n<!-- crux:begin -->\nold block\n<!-- crux:end -->\n\nown line\n' > "$OTHER/CLAUDE.md"
  git -C "$OTHER" add CLAUDE.md; git -C "$OTHER" commit -q -m "pointer"; git -C "$OTHER" push -q origin main
  git -C "$CRUX_PROJECTS_DIR/alpha/app" pull -q
}

test_sync_advances_over_a_pointer_whose_only_change_is_the_generated_block() {
  sandbox >/dev/null
  _two_machines
  _pointer_on_both
  sed -i.bak 's/old block/block of an older kernel/' "$CRUX_PROJECTS_DIR/alpha/app/CLAUDE.md"
  rm -f "$CRUX_PROJECTS_DIR/alpha/app/CLAUDE.md.bak"
  _work_on_the_other done-there

  local out
  out="$(crux sync 2>&1)"
  assert_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "a rewritten generated block does not hold the repo back"
  assert_contains "$out" "the crux block of the pointers was discarded" "and it says what it discarded"
  teardown
}

test_sync_does_not_discard_what_was_written_outside_the_generated_block() {
  sandbox >/dev/null
  _two_machines
  _pointer_on_both
  echo "a rule of my own" >> "$CRUX_PROJECTS_DIR/alpha/app/CLAUDE.md"
  _work_on_the_other done-there

  local out
  out="$(crux sync 2>&1)"
  assert_no_file "$CRUX_PROJECTS_DIR/alpha/app/done-there" "what someone wrote outside the block stops it as before"
  assert_contains "$(cat "$CRUX_PROJECTS_DIR/alpha/app/CLAUDE.md")" "a rule of my own" "and nothing of it is lost"
  teardown
}
