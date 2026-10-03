#!/usr/bin/env bash

_tasks_project() {
  # A project with two code repos and its docs repo, each repo with one commit.
  local root="$CRUX_PROJECTS_DIR/proj"
  mkdir -p "$root/app" "$root/web" "$root/proj-docs"
  local r
  for r in app web; do
    git -C "$root/$r" init -q
    echo x > "$root/$r/f.txt"
    git -C "$root/$r" add -A
    git -C "$root/$r" commit -qm init
  done
  printf '{"crux":"0.1.0","project":"proj","profile":"%s","repos":["app","web"],"sections":[]}\n' \
    "${1:-multi-repo}" > "$root/proj-docs/crux.json"
  echo "$root"
}

test_workspace_new_registers_the_task() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new maps --repo "$root/app" 2>&1)"
  assert_contains "$out" "task 'maps' registered" "opening a workspace registers its task"

  local f="$SB/tasks/proj/maps.md"
  assert_file "$f" "the record lives in local state, per project and task"
  assert_contains "$(cat "$f")" "status: open" "it starts open"
  assert_contains "$(cat "$f")" "repos: [app]" "it knows which repo is worked on"
  assert_no_file "$root/app-ws-maps/maps.md" "and writes nothing inside the repo"
  assert_contains "$(cat "$CRUX_REGISTRY")" '"task": "maps"' "the workspace points to its task"
}

test_a_multi_repo_task_shares_one_record() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"

  bash "$CRUX_HOME/bin/workspace.sh" new maps --repo "$root/app" >/dev/null 2>&1
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new maps-web --repo "$root/web" --task maps 2>&1)"
  assert_contains "$out" "joins the already open task 'maps'" "the second repo joins the same task"

  local f="$SB/tasks/proj/maps.md"
  assert_contains "$(cat "$f")" "repos: [app, web]" "one record with both repos"
  assert_contains "$(cat "$f")" "workspaces: [maps, maps-web]" "and with both workspaces"

  # A step added from one workspace is seen from the other.
  ( cd "$root/app-ws-maps" && bash "$CRUX_HOME/bin/task.sh" add "fix the map" >/dev/null 2>&1 )
  local from_web; from_web="$(cd "$root/web-ws-maps-web" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$from_web" "T1 fix the map" "what is noted in one repo is read from the other"
}

test_task_records_steps_evidence_and_next() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new t --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-t" f="$SB/tasks/proj/t.md"

  ( cd "$ws" || exit 1
    bash "$CRUX_HOME/bin/task.sh" goal "Make the map follow the UN" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "fix borders" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "regenerate the svg" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "review the widget" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" "done" T1 "before and after screenshots" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" note "Kosovo inside Serbia" >/dev/null ) 2>&1

  local t; t="$(cat "$f")"
  assert_contains "$t" "- [x] T1 fix borders · evidence: before and after screenshots" "the done step carries its evidence"
  assert_contains "$t" "- [ ] T2 regenerate the svg
- [ ] T3 review the widget" "the steps stay consecutive, without gaps"
  assert_contains "$t" "status: in-progress" "completing a step puts it in progress"
  assert_contains "$t" "- Kosovo inside Serbia" "the decision is noted"

  local show; show="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$show" "steps 1/3" "it shows how much is done"
  assert_contains "$show" "next: T2 regenerate the svg" "with no next step written, it proposes the first pending one"

  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" next "test on staging" >/dev/null 2>&1 )
  show="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$show" "next: test on staging" "the written next step wins"

  local without; without="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" "done" T2 2>&1)"
  assert_contains "$without" "no evidence" "marking without evidence is allowed, but it is said"
  assert_exit 1 "a step that does not exist is not invented" \
    env -C "$ws" bash "$CRUX_HOME/bin/task.sh" "done" T9 "something"
}

test_task_outside_a_workspace_says_what_to_do() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"

  local out; out="$(cd "$root/app" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$out" "you are not in a workspace with a task" "in the main repo there is no task to guess"
  assert_exit 1 "and it exits with an error" env -C "$root/app" bash "$CRUX_HOME/bin/task.sh"
}

test_seal_verifies_the_task_and_status_never_goes_back() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new v --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-v" f="$SB/tasks/proj/v.md"

  echo change > "$ws/g.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: change"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local t; t="$(cat "$f")"
  assert_contains "$t" "status: verified" "closing the gate verifies the task"
  assert_contains "$t" "- ok · true" "and dumps what was run as evidence"
  assert_contains "$t" "On $(git -C "$ws" rev-parse --short=8 HEAD)" "on the commit that was verified"

  # A task already merged does not go back to "verified" by repeating the gate.
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  assert_contains "$(cat "$f")" "status: merged" "status only moves forward"
}

test_the_proposal_comes_from_the_task_without_showing_the_scaffolding() {
  sandbox >/dev/null
  local root; root="$(_tasks_project client-repo)"
  bash "$CRUX_HOME/bin/workspace.sh" new c --repo "$root/app" --force >/dev/null 2>&1
  local ws="$root/app-ws-c" f="$SB/tasks/proj/c.md"

  ( cd "$ws" || exit 1
    bash "$CRUX_HOME/bin/task.sh" goal "Borders follow the UN map" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "fix the world atlas" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" "done" T1 "before and after screenshots" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" note "Kosovo inside Serbia, as the UN map shows" >/dev/null ) 2>&1

  local body="$SB/BODY.md"
  node "$CRUX_HOME/lib/task.mjs" body --file "$f" --lang en > "$body"
  local b; b="$(cat "$body")"
  assert_contains "$b" "## What changes" "the description says what changes"
  assert_contains "$b" "fix the world atlas (before and after screenshots)" "what was done, with its evidence in parentheses"
  assert_not_contains "$b" "evidence:" "without the record label"
  assert_contains "$b" "Kosovo inside Serbia" "and what was decided"
  assert_not_contains "$b" "T1" "without the internal step ids"
  assert_not_contains "$b" ".crux" "without paths of our local state"

  # What was checked ran on this machine: its paths are not published.
  node "$CRUX_HOME/lib/task.mjs" set --file "$f" --section "Verification" \
    --text "- ok · $HOME/Proyectos/tool --check (2s)" >/dev/null
  assert_not_contains "$(node "$CRUX_HOME/lib/task.mjs" body --file "$f" --lang en)" "$HOME/" \
    "without the machine paths in what was checked"
  assert_exit 0 "and it passes the client repo filter" \
    env -C "$ws" bash "$CRUX_HOME/bin/ship.sh" body "$body"
}

test_the_hook_brings_the_task_once_per_session() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new h --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-h" hook="$CRUX_HOME/adapters/claude/hooks/task-context.sh"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" next "try the hover" >/dev/null 2>&1 )

  local first second outside
  first="$(cd "$ws" && echo '{"session_id":"s-hook"}' | env TMPDIR="$SB" bash "$hook" 2>&1)"
  second="$(cd "$ws" && echo '{"session_id":"s-hook"}' | env TMPDIR="$SB" bash "$hook" 2>&1)"
  outside="$(cd "$root/app" && echo '{"session_id":"s-hook"}' | env TMPDIR="$SB" bash "$hook" 2>&1)"

  assert_contains "$first" "next: try the hover" "on resuming it says where it was left"
  assert_contains "$first" "$SB/tasks/proj/h.md" "and where the record is"
  assert_eq "" "$second" "the second time in the same session it stays quiet"
  assert_eq "" "$outside" "outside a workspace it says nothing"
  assert_eq 2 "$(printf '%s\n' "$first" | wc -l | tr -d ' ')" "and it fits in two lines"
}

test_workspace_list_shows_where_each_task_stands() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new l --repo "$root/app" >/dev/null 2>&1
  ( cd "$root/app-ws-l" && bash "$CRUX_HOME/bin/task.sh" next "review the widget" >/dev/null 2>&1 )

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" list --all 2>&1)"
  assert_contains "$out" "task l: open · review the widget" "the workspace list carries status and next step"

  out="$(bash "$CRUX_HOME/bin/task.sh" list --all 2>&1)"
  assert_contains "$out" "proj/l" "the task list groups them by project"
  assert_contains "$out" "review the widget" "with its next step"
}

test_an_unreadable_record_is_reported_and_stops() {
  sandbox >/dev/null
  local f="$SB/tasks/proj/broken.md"
  mkdir -p "$(dirname "$f")"
  echo "this has no header" > "$f"

  local out; out="$(node "$CRUX_HOME/lib/task.mjs" summary --file "$f" 2>&1)"
  assert_contains "$out" "has no header" "a corrupt record is named"
  assert_exit 1 "and it is not read as an empty task" node "$CRUX_HOME/lib/task.mjs" summary --file "$f"
  assert_exit 1 "an invented status is not accepted" \
    node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to "almost-done"
}

test_hooks_install_hooks_the_task_context() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "task-context.sh" "install hooks the task hook"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "task-context" "and remove takes it off"
}

test_the_task_cycle_fits_in_few_calls() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"

  # Goal on opening and the plan at once: two calls, not four.
  bash "$CRUX_HOME/bin/workspace.sh" new p --repo "$root/app" --goal "Make the hover not cover the country" >/dev/null 2>&1
  ( cd "$root/app-ws-p" && bash "$CRUX_HOME/bin/task.sh" add "lift the country" "zoom on select" "screenshots" >/dev/null 2>&1 )

  local t; t="$(cat "$SB/tasks/proj/p.md")"
  assert_contains "$t" "Make the hover not cover the country" "the goal goes in when the workspace opens"
  assert_contains "$t" "- [ ] T3 screenshots" "and several steps go in one call"
}

test_workspace_list_from_inside_a_workspace_sees_the_repos_ones() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new one --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new two --repo "$root/app" >/dev/null 2>&1

  local out; out="$(cd "$root/app-ws-one" && bash "$CRUX_HOME/bin/workspace.sh" list 2>&1)"
  assert_contains "$out" "one" "from a workspace it sees itself"
  assert_contains "$out" "two" "and the others of the same repo"
  assert_not_contains "$out" "no workspaces in this repo" "without saying there is nothing"
}

test_closing_the_last_workspace_of_a_merged_task_archives_it() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new a --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new a-web --repo "$root/web" --task a >/dev/null 2>&1
  local f="$SB/tasks/proj/a.md"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm a 2>&1)"
  assert_contains "$out" "still in 1 more workspace" "with another live workspace, the task is not archived"
  assert_file "$f" "and stays in place"

  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm a-web 2>&1)"
  assert_contains "$out" "task 'a' archived" "closing the last workspace archives it"
  assert_no_file "$f" "it leaves the open list"
  local archived; archived="$(ls "$SB"/tasks/proj/done/*-a.md 2>/dev/null | head -1)"
  assert_file "$archived" "and it is dated in done/"
  assert_contains "$(cat "$archived")" "status: closed" "closed"

  out="$(bash "$CRUX_HOME/bin/task.sh" list --all 2>&1)"
  assert_not_contains "$out" "proj/a " "the open list no longer shows it"
  out="$(bash "$CRUX_HOME/bin/task.sh" list --done 2>&1)"
  assert_contains "$out" "-a" "and --done does"
}

test_an_unfinished_task_is_not_archived_when_its_workspace_closes() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$root/app" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm b 2>&1)"
  assert_contains "$out" "is still open (open)" "closing the workspace does not hide unfinished work"
  assert_contains "$out" "crux task archive --task proj/b" "and says how to archive it if it no longer goes on"
  assert_file "$SB/tasks/proj/b.md" "the record stays"

  out="$(bash "$CRUX_HOME/bin/task.sh" archive --task proj/b 2>&1)"
  assert_contains "$out" "task archived" "it can also be archived by hand"
  assert_no_file "$SB/tasks/proj/b.md" "and leaves the open ones"
}

test_gc_deletes_archived_tasks_that_have_expired() {
  sandbox >/dev/null
  local done_dir="$SB/tasks/proj/done"
  mkdir -p "$done_dir"
  printf -- '---\ntask: old\nstatus: closed\n---\n' > "$done_dir/2020-01-01-old.md"
  local recent; recent="$(date +%Y-%m-%d)-recent.md"
  printf -- '---\ntask: recent\nstatus: closed\n---\n' > "$done_dir/$recent"

  local out; out="$(env CRUX_TASKS_RETENTION_DAYS=180 bash "$CRUX_HOME/bin/workspace.sh" gc 2>&1)"
  assert_contains "$out" "2020-01-01-old" "it shows what expired"
  assert_file "$done_dir/2020-01-01-old.md" "without --yes it deletes nothing"

  env CRUX_TASKS_RETENTION_DAYS=180 bash "$CRUX_HOME/bin/workspace.sh" gc --yes >/dev/null 2>&1
  assert_no_file "$done_dir/2020-01-01-old.md" "with --yes it deletes what expired"
  assert_file "$done_dir/$recent" "and leaves the recent one"

  assert_exit 1 "a retention that is not a number is reported" \
    env CRUX_TASKS_RETENTION_DAYS=soon bash "$CRUX_HOME/bin/workspace.sh" gc
}

test_task_decisions_move_to_the_docs_repo_on_archive() {
  # The task record is local and gets archived: what was decided along the
  # way stayed there and the next session did not see it.
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  local docs="$root/proj-docs"
  mkdir -p "$docs/repos/app"; echo "# Notas" > "$docs/repos/app/notes.md"
  git -C "$docs" init -q; git -C "$docs" config user.email t@t; git -C "$docs" config user.name t
  git -C "$docs" add -A; git -C "$docs" commit -qm init
  bash "$CRUX_HOME/bin/workspace.sh" new dec --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-dec" out
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" note "Cache keys get a version prefix" \
    --why "changing the format broke existing keys" --where "src/cache.ts" \
    --learned "old keys expire in 24h, so no migration is needed" 2>&1)"
  assert_contains "$out" "decision noted" "with a why, it is a decision"
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" note "Skipped the retry, not needed yet" 2>&1)"
  assert_contains "$out" "--why" "without a why, it suggests adding one"

  local f="$SB/tasks/proj/dec.md"
  assert_contains "$(cat "$f")" "Cache keys get a version prefix · Why: changing the format broke existing keys · Where: src/cache.ts" \
    "the record keeps the decision on one line"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm dec 2>&1)"
  assert_contains "$out" "task decisions in proj-docs/repos/app/notes.md" "on archive it says so"

  local notes; notes="$(cat "$docs/repos/app/notes.md")"
  assert_contains "$notes" "## Cache keys get a version prefix," "the decision reaches the repo notes"
  assert_contains "$notes" "- **Why**: changing the format broke existing keys" "with its why"
  assert_contains "$notes" "- **Learned**: old keys expire in 24h" "and what was learned"
  assert_not_contains "$notes" "Skipped the retry" "the deviation without a why stays in the task"
  assert_contains "$(git -C "$docs" log -1 --format=%s)" "decisions from task dec" "and it is committed"
  assert_eq "" "$(git -C "$docs" status --porcelain)" "leaving nothing loose"
}

test_a_task_without_decisions_does_not_touch_the_docs_repo() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  local docs="$root/proj-docs"
  mkdir -p "$docs/repos/app"
  git -C "$docs" init -q; git -C "$docs" config user.email t@t; git -C "$docs" config user.name t
  git -C "$docs" add -A; git -C "$docs" commit -qm init
  bash "$CRUX_HOME/bin/workspace.sh" new none --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/none.md"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  bash "$CRUX_HOME/bin/workspace.sh" rm none >/dev/null 2>&1
  assert_no_file "$docs/repos/app/notes.md" "it does not create empty notes"
  assert_eq "init" "$(git -C "$docs" log -1 --format=%s)" "nor commits"
}

test_wait_records_who_and_retires_an_idle_workspace() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new domain --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/domain.md" out rc=0
  out="$(cd "$root/app-ws-domain" && bash "$CRUX_HOME/bin/task.sh" wait --on "Alex" --ask "Do we register the domain: yes or no?" --ref "email of October 3rd" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "wait finishes fine"
  assert_contains "$(cat "$f")" "waiting_on: Alex" "it notes who is awaited"
  assert_contains "$(cat "$f")" "waiting_ask: Do we register the domain: yes or no?" "and what was asked, even with a colon"
  assert_contains "$(cat "$f")" "waiting_ref: email of October 3rd" "and where"
  assert_contains "$(cat "$f")" "waiting_since: " "and since when"
  assert_no_file "$root/app-ws-domain/f.txt" "the workspace without work is retired"
  assert_eq "" "$(git -C "$root/app" branch --list ws/domain)" "and its empty branch too"
  assert_contains "$(cat "$f")" "retired: [app=ws/domain]" "the branch is noted as retired"
  assert_file "$f" "the task is not archived for lacking workspaces"
  local list; list="$(bash "$CRUX_HOME/bin/task.sh" list --all 2>&1)"
  assert_contains "$list" "proj/domain" "it stays in the list"
  assert_contains "$list" "waiting" "as a waiting task"
  assert_contains "$list" "to Alex since" "saying who it waits for"
}

test_wait_keeps_a_workspace_with_work_in_it() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new changes --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-changes" out
  echo y > "$ws/uncommitted.txt"
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" --ask "is this fine?" 2>&1)"
  assert_contains "$out" "uncommitted changes: it stays" "says why it does not retire it"
  assert_file "$ws/uncommitted.txt" "and does not lose the work"

  bash "$CRUX_HOME/bin/workspace.sh" new commits --repo "$root/app" >/dev/null 2>&1
  ws="$root/app-ws-commits"
  ( cd "$ws" && echo z > z.txt && git add z.txt && git commit -qm z )
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" --ask "is this fine?" 2>&1)"
  assert_contains "$out" "unmerged commit(s) in ws/commits: it stays" "a branch with its own commits is not touched"
  assert_file "$ws/z.txt" "nor its workspace"
}

test_wait_needs_who_and_what() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new none --repo "$root/app" >/dev/null 2>&1
  local out rc=0
  out="$(cd "$root/app-ws-none" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" 2>&1)" || rc=$?
  assert_eq 1 "$rc" "without the question it does not start waiting"
  assert_contains "$out" "usage: crux task wait" "and says how to use it"
  assert_not_contains "$(cat "$SB/tasks/proj/none.md")" "waiting_on" "nor writes anything halfway"
}

test_waiting_tasks_get_their_own_block_in_the_reminder() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new busy --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new idle --repo "$root/web" >/dev/null 2>&1
  ( cd "$root/web-ws-idle" && bash "$CRUX_HOME/bin/task.sh" wait --on "Alex" --ask "Data from the old database?" >/dev/null 2>&1 )
  local r; r="$(node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")"
  assert_contains "$r" "Waiting for an answer:" "those that wait go in their own block"
  assert_contains "$r" "proj/idle · to Alex, today: Data from the old database?" "with who, since when and what"
  assert_not_contains "$r" "worth a nudge" "without nudging too early"
  local antes after
  antes="$(printf '%s' "$r" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j.user.indexOf("proj/busy")))})')"
  after="$(printf '%s' "$r" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j.user.indexOf("Waiting for an answer")))})')"
  assert_eq 1 "$([[ "$antes" -ge 0 && "$antes" -lt "$after" ]] && echo 1 || echo 0)" "own work goes before what waits on someone else"
  sed -i 's/^waiting_since: .*/waiting_since: 2020-01-01/' "$SB/tasks/proj/idle.md"
  r="$(node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")"
  assert_contains "$r" "worth a nudge" "past the deadline it suggests nudging"
  r="$(CRUX_WAIT_NUDGE_DAYS=100000 node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")"
  assert_not_contains "$r" "worth a nudge" "and the deadline can be adjusted"
  local st; st="$(cd "$root/app" && bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$st" "waiting for an answer" "crux status gives them their section"
  assert_not_contains "$(printf '%s' "$st" | sed -n '/open tasks without a workspace/,/^$/p')" "proj/idle" "and does not count it as open without a workspace"
}

test_a_merged_task_that_waits_is_not_archived() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new merged --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/merged.md"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  node "$CRUX_HOME/lib/task.mjs" wait --file "$f" --on "Alex" --ask "shall we go on?" >/dev/null
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm merged 2>&1)"
  assert_contains "$out" "is waiting on Alex: not archiving" "rm does not archive a task that waits"
  assert_file "$f" "the record stays"
  assert_contains "$(node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")" "proj/merged" "and it stays in the reminder even though it is merged"
}

test_resume_reopens_a_retired_branch_and_stops_waiting() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  bash "$CRUX_HOME/bin/workspace.sh" new back --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/back.md"
  ( cd "$root/app-ws-back" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" --ask "yes?" >/dev/null 2>&1 )
  local out rc=0
  out="$(cd "$root/app" && bash "$CRUX_HOME/bin/workspace.sh" resume back 2>&1)" || rc=$?
  assert_eq 0 "$rc" "resume opens the task even though its branch was retired"
  assert_file "$root/app-ws-back/f.txt" "with a new workspace from the main one"
  assert_contains "$out" "no longer waits for an answer" "and stops waiting"
  assert_not_contains "$(cat "$f")" "waiting_on" "without a trace of the wait"
  assert_not_contains "$(cat "$f")" "retired:" "nor of the retired branch"
  rc=0; out="$(cd "$root/app-ws-back" && bash "$CRUX_HOME/bin/task.sh" unwait 2>&1)" || rc=$?
  assert_eq 0 "$rc" "unwait on a task that does not wait is not an error"
  assert_contains "$out" "was not waiting" "and says so"
}

test_a_record_with_spanish_headings_is_still_read() {
  sandbox >/dev/null
  local f="$SB/old.md"
  printf -- '---\ntask: old\nproject: proj\nstatus: open\nrepos: [app]\n---\n\n## Objetivo\n\nKeep it working.\n\n## Pasos\n\n- [ ] T1 first step\n\n## Siguiente paso\n\nfirst step\n\n## Desviaciones y decisiones\n\n' > "$f"

  local out; out="$(node "$CRUX_HOME/lib/task.mjs" summary --file "$f" --json)"
  assert_contains "$out" '"objective":"Keep it working."' "the old Objetivo heading is read as the objective"
  assert_contains "$out" '"next":"first step"' "and Siguiente paso as the next step"

  node "$CRUX_HOME/lib/task.mjs" note --file "$f" --text "kept" >/dev/null
  local body; body="$(cat "$f")"
  assert_contains "$body" "## Deviations and decisions" "the next write uses the English headings"
  assert_not_contains "$body" "## Desviaciones y decisiones" "without leaving the Spanish one behind"
  assert_contains "$body" "kept" "and keeps what it appended"
}
