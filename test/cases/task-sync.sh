#!/usr/bin/env bash

# Tasks travel between machines on the crux/tasks branch of the docs repo.
# Here the two machines are two project roots with their own state, cloned
# from the same local remote. See ADR-016.

_tasks_two_machines() {
  git init -q --bare -b main "$SB/docs.git"
  git clone -q "$SB/docs.git" "$SB/seed" 2>/dev/null
  git -C "$SB/seed" commit -q --allow-empty -m "docs"
  git -C "$SB/seed" push -q origin main
  local m
  for m in A B; do
    mkdir -p "$SB/$m/P/alpha"
    git clone -q "$SB/docs.git" "$SB/$m/P/alpha/alpha-docs" 2>/dev/null
  done
  mkdir -p "$SB/bin"
  printf '#!/bin/sh\nexit 1\n' > "$SB/bin/gh"
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

# en <machine> <command...> — the command with that machine's environment.
en() {
  local m="$1"; shift
  CRUX_PROJECTS_DIR="$SB/$m/P" CRUX_TASKS_DIR="$SB/$m/tasks" CRUX_STATE_DIR="$SB/$m/state" \
    CRUX_REGISTRY="$SB/$m/registry.json" "$@"
}

engine() { local m="$1"; shift; en "$m" node "$CRUX_HOME/lib/task.mjs" "$@"; }
replicate() { en "$1" node "$CRUX_HOME/lib/task-sync.mjs" sync --all; }
task_record() { echo "$SB/$1/tasks/alpha/$2.md"; }

_new_task() {
  # _new_task <machine> <task> <next step>
  engine "$1" ensure --file "$(task_record "$1" "$2")" --task "$2" --project alpha --repo app --workspace "$2" >/dev/null
  engine "$1" set --file "$(task_record "$1" "$2")" --section "Next step" --text "$3"
}

test_tasks_one_created_on_a_machine_reaches_the_other() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"

  replicate A >/dev/null
  replicate B >/dev/null

  assert_file "$(task_record B t1)" "the task arrives"
  assert_contains "$(cat "$(task_record B t1)")" "do X" "with its next step"
  assert_eq "" "$(git -C "$SB/A/P/alpha/alpha-docs" status --porcelain)" "the docs repo stays clean"
  assert_eq 1 "$(git -C "$SB/A/P/alpha/alpha-docs" rev-list --count main)" "and main receives no commit"
  assert_contains "$(git -C "$SB/seed" ls-remote origin)" "refs/heads/crux/tasks" "it travels on its own branch"
  teardown
}

test_tasks_a_change_on_the_other_machine_comes_back() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  replicate A >/dev/null; replicate B >/dev/null

  engine B set --file "$(task_record B t1)" --section "Next step" --text "do Y"
  replicate B >/dev/null
  replicate A >/dev/null

  assert_contains "$(cat "$(task_record A t1)")" "do Y" "what changed on B reaches A"
  assert_no_file "$SB/A/tasks/alpha/t1.conflicto-remota.md" "no conflict: it changed in one place only"
  teardown
}

test_tasks_if_both_change_the_recent_wins_and_the_other_is_kept() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "base"
  replicate A >/dev/null; replicate B >/dev/null

  engine B set --file "$(task_record B t1)" --section "Next step" --text "version of B"
  replicate B >/dev/null
  engine A set --file "$(task_record A t1)" --section "Next step" --text "version of A"
  # A is the most recent: the minutes clock would tie.
  sed -i 's/^updated: .*/updated: 2099-01-01T00:00/' "$(task_record A t1)"

  local out
  out="$(replicate A)"
  assert_contains "$(cat "$(task_record A t1)")" "version of A" "the most recent stays"
  assert_contains "$(cat "$SB"/A/tasks/alpha/t1.conflicto-*.md 2>/dev/null)" "version of B" "the other is kept alongside"
  assert_contains "$out" "changed on both" "and it is warned"

  replicate B >/dev/null
  assert_contains "$(cat "$(task_record B t1)")" "version of A" "the other machine ends up with the same"
  teardown
}

test_tasks_archiving_on_one_retires_the_open_one_on_the_other() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  replicate A >/dev/null; replicate B >/dev/null

  engine A archive --file "$(task_record A t1)" >/dev/null
  replicate A >/dev/null
  replicate B >/dev/null

  assert_no_file "$(task_record B t1)" "the open one disappears on B"
  assert_eq 1 "$(find "$SB/B/tasks/alpha/done" -name '*-t1.md' | wc -l | tr -d ' ')" "and the archived one arrives"
  replicate A >/dev/null
  assert_no_file "$(task_record A t1)" "and B does not send it back to A as open"
  teardown
}

test_tasks_publish_themselves_when_written() {
  sandbox >/dev/null
  _tasks_two_machines

  CRUX_TASK_SYNC=1 _new_task A t1 "do X"
  local _
  for _ in $(seq 1 50); do
    git -C "$SB/seed" ls-remote origin refs/heads/crux/tasks | grep -q . && break
    sleep 0.2
  done
  git -C "$SB/seed" fetch -q origin crux/tasks 2>/dev/null
  assert_contains "$(git -C "$SB/seed" show FETCH_HEAD:t1.md 2>/dev/null)" "t1" \
    "with nobody launching anything, the task is on the remote"
  teardown
}

test_tasks_without_network_stay_pending_and_leave_says_so() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  mv "$SB/docs.git" "$SB/docs-away.git"

  replicate A >/dev/null
  assert_contains "$(en A node "$CRUX_HOME/lib/task-sync.mjs" pending)" "alpha" "it is marked as pending"
  local out rc
  out="$(en A crux sync --leave 2>&1)"; rc=$?
  assert_contains "$out" "unpublished tasks" "--leave counts it as stuck"
  assert_eq 1 "$rc" "and does not let you leave"

  mv "$SB/docs-away.git" "$SB/docs.git"
  replicate A >/dev/null
  assert_eq "" "$(en A node "$CRUX_HOME/lib/task-sync.mjs" pending)" "with network, it publishes and stops being pending"
  teardown
}

test_tasks_a_project_can_opt_out() {
  sandbox >/dev/null
  _tasks_two_machines
  echo '{"tasks":{"sync":false}}' > "$SB/A/P/alpha/alpha-docs/crux.json"
  _new_task A t1 "do X"

  replicate A >/dev/null
  assert_not_contains "$(git -C "$SB/seed" ls-remote origin)" "crux/tasks" "with tasks.sync false nothing is published"
  teardown
}

test_tasks_two_machines_publishing_at_once_lose_nothing() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A by-a "a"
  _new_task B by-b "b"

  replicate A >/dev/null & replicate B >/dev/null & wait
  replicate A >/dev/null; replicate B >/dev/null

  assert_file "$(task_record A by-b)" "A has the one from B"
  assert_file "$(task_record B by-a)" "B has the one from A"
  teardown
}

test_tasks_crux_sync_brings_them_on_arrival() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  replicate A >/dev/null

  local out
  out="$(en B crux sync 2>&1)"
  assert_contains "$out" "alpha: 1 task pulled" "it says so"
  assert_file "$(task_record B t1)" "and brings it"
  teardown
}

test_tasks_the_reminder_informs_without_pushing() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task B t1 "do X"
  _new_task B finished "nothing"
  engine B status --file "$(task_record B finished)" --to merged

  local out
  out="$(en B node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/B/P/alpha/alpha-docs")"
  assert_contains "$out" "alpha/t1" "it shows the open one"
  assert_not_contains "$out" "alpha/finished" "not the one already merged"
  assert_contains "$out" "in case you want to resume one" "the person is offered it"
  assert_contains "$out" "Do not resume any" "and the agent is told not to push"
  assert_contains "$out" "crux workspace resume t1" "with how to resume it here"
  # The same data, structured, for whoever renders it another way
  assert_contains "$out" '"tasks":[{"task":"alpha/t1"' "the reminder brings the tasks as data"
  assert_contains "$out" '"here":false' "and says whether they have a workspace on this machine"

  assert_eq "" "$(en A node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/A/P")" "with no tasks, it says nothing"
  teardown
}

test_tasks_the_start_hook_shows_them_and_stays_quiet_on_compact() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  local hook="$CRUX_HOME/adapters/claude/hooks/session-sync.sh" out

  out="$(printf '{"source":"startup","session_id":"s1","cwd":"%s"}' "$SB/A/P/alpha" \
    | en A env HOME="$SB" bash "$hook")"
  assert_contains "$out" '"systemMessage"' "the person sees it directly"
  assert_contains "$out" "alpha/t1" "with the task"
  assert_contains "$out" '"additionalContext"' "and the agent knows it was already shown"

  out="$(printf '{"source":"compact","session_id":"s1","cwd":"%s"}' "$SB/A/P/alpha" \
    | en A env HOME="$SB" bash "$hook")"
  assert_eq "" "$out" "on compact it does not interrupt"
  teardown
}

test_tasks_returning_to_an_idle_session_reminds_once() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  local hook="$CRUX_HOME/adapters/claude/hooks/session-idle.sh" out
  local msg
  msg="$(printf '{"session_id":"s2","cwd":"%s"}' "$SB/A/P/alpha")"

  out="$(printf '%s' "$msg" | en A env HOME="$SB" bash "$hook")"
  assert_eq "" "$out" "the first message says nothing: session start already spoke"

  touch -d "5 hours ago" "$SB/A/state/sessions/s2"
  out="$(printf '%s' "$msg" | en A env HOME="$SB" bash "$hook")"
  assert_contains "$out" "You are back in this session" "after hours idle, it says so"
  assert_contains "$out" "alpha/t1" "and reminds the task"

  out="$(printf '%s' "$msg" | en A env HOME="$SB" bash "$hook")"
  assert_eq "" "$out" "the next message no longer repeats"
  teardown
}

test_tasks_resume_opens_the_workspace_with_the_branch_and_task_of_the_other_machine() {
  sandbox >/dev/null
  _tasks_two_machines
  git init -q --bare -b main "$SB/app.git"
  git clone -q "$SB/app.git" "$SB/seed-app" 2>/dev/null
  git -C "$SB/seed-app" commit -q --allow-empty -m "app"
  git -C "$SB/seed-app" push -q origin main
  local m
  for m in A B; do git clone -q "$SB/app.git" "$SB/$m/P/alpha/app" 2>/dev/null; done

  # On A: the workspace, a commit on its branch, pushed, and the next step noted.
  ( cd "$SB/A/P/alpha/app" && en A crux workspace new t2 ) >/dev/null 2>&1
  local ws="$SB/A/P/alpha/app-ws-t2"
  echo "half done" > "$ws/file"
  git -C "$ws" add file && git -C "$ws" commit -q -m "wip"
  git -C "$ws" push -q -u origin HEAD 2>/dev/null
  engine A set --file "$(task_record A t2)" --section "Next step" --text "carry on with the file"
  replicate A >/dev/null

  # On B: bring the tasks and resume it.
  replicate B >/dev/null
  local out
  out="$(en B crux workspace resume t2 2>&1)"
  assert_file "$SB/B/P/alpha/app-ws-t2/file" "the workspace arrives with the branch work"
  assert_contains "$out" "carry on with the file" "and shows the next step"
  assert_contains "$(cat "$(task_record B t2)")" "carry on with the file" "the task does not start empty"
  assert_eq 1 "$(grep -c 'app=' "$(task_record B t2)")" "the branch is noted only once"
  teardown
}

test_tasks_resume_says_what_to_do_if_the_task_is_missing() {
  sandbox >/dev/null
  _tasks_two_machines
  local out rc
  out="$(en B crux workspace resume does-not-exist 2>&1)"; rc=$?
  assert_eq 1 "$rc" "it fails"
  assert_contains "$out" "crux sync" "and tells to bring the tasks"
  teardown
}

test_tasks_reusing_an_archived_name_does_not_delete_it() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A release "the old one"
  sed -i 's/^created: .*/created: 2026-01-01T10:00/' "$(task_record A release)"
  replicate A >/dev/null; replicate B >/dev/null
  engine A archive --file "$(task_record A release)" >/dev/null
  replicate A >/dev/null; replicate B >/dev/null

  # Months later, another task with the same name.
  _new_task B release "the new one"
  replicate B >/dev/null; replicate A >/dev/null
  assert_file "$(task_record A release)" "the new one reaches the other machine"
  assert_file "$(task_record B release)" "and stays alive where it was born"
  assert_contains "$(cat "$(task_record A release)")" "the new one" "and it is the new one, not the old one"
  teardown
}

test_tasks_publish_with_mandatory_signing_and_a_failing_pre_push() {
  sandbox >/dev/null
  _tasks_two_machines
  local docs="$SB/A/P/alpha/alpha-docs"
  git -C "$docs" config commit.gpgSign true
  git -C "$docs" config gpg.program false
  printf '#!/bin/sh\nexit 1\n' > "$docs/.git/hooks/pre-push"
  chmod +x "$docs/.git/hooks/pre-push"
  _new_task A t1 "do X"

  replicate A >/dev/null
  assert_contains "$(git -C "$SB/seed" ls-remote origin)" "crux/tasks" \
    "the internal branch is published even if the repo demands signing and its pre-push rejects everything"
  teardown
}

test_tasks_without_remote_leave_warns_they_stay() {
  sandbox >/dev/null
  _tasks_two_machines
  git -C "$SB/A/P/alpha/alpha-docs" remote remove origin
  _new_task A t1 "do X"

  local out
  out="$(en A crux sync --leave 2>&1)"
  assert_contains "$out" "the tasks stay on this machine" "it says so"
  teardown
}

test_tasks_the_reminder_mentions_pending_conflicts() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "do X"
  echo "copy" > "$SB/A/tasks/alpha/t1.conflicto-remota.md"

  assert_contains "$(en A node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/A/P/alpha")" \
    "of a conflict between machines" "they are not forgotten"
  teardown
}

test_tasks_already_merged_close_themselves_and_are_not_reminded() {
  sandbox >/dev/null
  _tasks_two_machines
  # A gh that says any proposal is merged.
  printf '#!/bin/sh\n[ "$1 $2" = "pr view" ] && echo MERGED && exit 0\nexit 1\n' > "$SB/bin/gh"
  _new_task A old "nothing"
  engine A meta --file "$(task_record A old)" --key pr --value "https://github.com/o/r/pull/1"
  engine A status --file "$(task_record A old)" --to proposed

  local out
  out="$(en A crux sync 2>&1)"
  assert_contains "$out" "already merged" "it says so"
  assert_no_file "$(task_record A old)" "with no workspace here, it is archived"
  assert_eq "" "$(en A node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/A/P/alpha")" "and the reminder no longer shows it"

  replicate B >/dev/null
  assert_no_file "$(task_record B old)" "it does not reach the other machine as open"
  teardown
}

test_tasks_are_not_published_in_a_public_repo() {
  sandbox >/dev/null
  _tasks_two_machines
  # The remote looks like GitHub and gh says it is public.
  local docs="$SB/A/P/alpha/alpha-docs"
  git -C "$docs" remote set-url origin "git@github.com:o/alpha-docs.git"
  git -C "$docs" config "url.$SB/docs.git.insteadOf" "git@github.com:o/alpha-docs.git"
  printf '#!/bin/sh\n[ "$1 $2" = "repo view" ] && echo PUBLIC && exit 0\nexit 1\n' > "$SB/bin/gh"
  _new_task A t1 "private note"

  local out
  out="$(en A crux sync --leave 2>&1)"
  assert_not_contains "$(git -C "$SB/seed" ls-remote origin)" "crux/tasks" "nothing is published"
  assert_contains "$out" "its repo is public" "and it says why they stay here"

  echo '{"tasks":{"sync":true}}' > "$docs/crux.json"
  replicate A >/dev/null
  assert_contains "$(git -C "$SB/seed" ls-remote origin)" "crux/tasks" "declared in the contract, yes"
  teardown
}

test_tasks_one_recycled_in_the_same_minute_survives() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A t1 "the old one"
  replicate A >/dev/null; replicate B >/dev/null
  engine A archive --file "$(task_record A t1)" >/dev/null
  replicate A >/dev/null
  sleep 1
  _new_task A t1 "the new one"
  replicate A >/dev/null; replicate B >/dev/null
  assert_contains "$(cat "$(task_record B t1)" 2>/dev/null)" "the new one" "a new task with the name of a just archived one is not deleted"
  teardown
}

test_tasks_one_merged_on_the_other_machine_reconciles_on_arrival() {
  sandbox >/dev/null
  _tasks_two_machines
  printf '#!/bin/sh\n[ "$1 $2" = "pr view" ] && echo MERGED && exit 0\nexit 1\n' > "$SB/bin/gh"
  _new_task A t1 "x"
  replicate A >/dev/null; replicate B >/dev/null
  # A proposes it; B does not know yet.
  engine A meta --file "$(task_record A t1)" --key pr --value "https://github.com/o/r/pull/2"
  engine A status --file "$(task_record A t1)" --to proposed
  replicate A >/dev/null

  en B crux sync >/dev/null 2>&1
  assert_no_file "$(task_record B t1)" "B brings it, sees it is merged and archives it in the same round"
  teardown
}

test_tasks_with_a_stale_already_fetched_branch_nothing_is_overwritten() {
  sandbox >/dev/null
  _tasks_two_machines
  _new_task A by-a "a"
  replicate A >/dev/null
  # B has fetched nothing and trusts what it has: its publication clashes with
  # the one from A, and the second pass has to go and fetch it.
  _new_task B by-b "b"
  en B node "$CRUX_HOME/lib/task-sync.mjs" sync --all --fetched >/dev/null
  replicate A >/dev/null

  assert_file "$(task_record B by-a)" "B ends up with the one from A"
  assert_file "$(task_record A by-b)" "and A with the one from B"
  teardown
}
