#!/usr/bin/env bash
# What a workspace has not committed travels too: the turn-end hook saves it
# to a hidden ref of the machine, and resuming the workspace applies it.

_wip_workspace() {
  # _wip_workspace <name>: a workspace of proj/app with its remote; prints the root.
  local root; root="$(_publish_project)"
  "$CRUX_HOME/bin/crux" workspace new "$1" --repo "$root/app" >/dev/null 2>&1
  echo "$root"
}

_turn_ends() {
  # _turn_ends <dir> <machine> [env...]: the agent's turn ends in <dir>.
  local dir="$1" machine="$2"; shift 2
  printf '{"cwd":"%s"}' "$dir" | env CRUX_TASK_SYNC=1 CRUX_MACHINE="$machine" "$@" "$CRUX_HOME/bin/crux" hook wip-save
}

_wait_for_no_ref() {
  local repo="$1" ref="$2" _
  for _ in $(seq 40); do
    git -C "$repo" rev-parse -q --verify "$ref" >/dev/null || return 0
    sleep 0.25
  done
  return 1
}

test_wip_a_turn_end_saves_what_is_uncommitted() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace half)"
  local ws="$root/app-ws-half"
  echo "changed" >> "$ws/f.txt"
  echo "new" > "$ws/new.txt"
  echo "staged" > "$ws/staged.txt"
  git -C "$ws" add staged.txt
  local before; before="$(git -C "$ws" diff --cached --name-only)"

  _turn_ends "$ws" laptop
  _wait_for_ref "$SB/remotes/app.git" refs/crux/wip/laptop/ws/half
  local saved; saved="$(git -C "$SB/remotes/app.git" rev-parse refs/crux/wip/laptop/ws/half)"
  assert_eq "changed" "$(git -C "$ws" show "$saved:f.txt" | tail -1)" "the change to a tracked file is saved"
  assert_eq "new" "$(git -C "$ws" show "$saved:new.txt")" "and the file nobody added yet"
  assert_eq "$(git -C "$ws" rev-parse HEAD)" "$(git -C "$ws" rev-parse "$saved^")" "on top of the commit it was made on"
  assert_eq "$before" "$(git -C "$ws" diff --cached --name-only)" "and what was staged stays as it was"
  assert_exit 1 "no branch is created on the remote" git -C "$SB/remotes/app.git" show-ref -q --verify refs/heads/ws/half
}

test_wip_ignored_and_secret_looking_files_stay_here() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace keep)"
  local ws="$root/app-ws-keep"
  echo "build/" > "$ws/.gitignore"
  mkdir -p "$ws/build"
  echo "output" > "$ws/build/out.js"
  echo "TOKEN=1" > "$ws/.env"
  echo "work" > "$ws/work.txt"

  _turn_ends "$ws" laptop
  _wait_for_ref "$SB/remotes/app.git" refs/crux/wip/laptop/ws/keep
  local files; files="$(git -C "$ws" ls-tree -r --name-only refs/crux/wip-here/ws/keep)"
  assert_contains "$files" "work.txt" "the work travels"
  assert_not_contains "$files" "build/out.js" "what the repo ignores does not"
  assert_not_contains "$files" ".env" "nor a file that looks like a secret, even unignored"
}

test_wip_resume_on_the_other_machine_brings_it() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace move)"
  local ws="$root/app-ws-move"
  _commit_in "$ws" "committed"
  ( cd "$ws" && CRUX_TASK_SYNC=1 CRUX_MACHINE=laptop "$CRUX_HOME/bin/crux" hook post-commit )
  _wait_for_ref "$SB/remotes/app.git" refs/crux/branches/laptop/ws/move
  echo "halfway" >> "$ws/f.txt"
  printf 'binary\0\377\376' > "$ws/blob.bin"
  echo "gone" > "$ws/old.txt"; git -C "$ws" add old.txt; git -C "$ws" commit -qm "old"
  ( cd "$ws" && CRUX_TASK_SYNC=1 CRUX_MACHINE=laptop "$CRUX_HOME/bin/crux" hook post-commit )
  rm "$ws/old.txt"
  _turn_ends "$ws" laptop
  _wait_for_ref "$SB/remotes/app.git" refs/crux/wip/laptop/ws/move
  local blob; blob="$(sha256sum < "$ws/blob.bin")"
  # This machine forgets everything: what remains is on the remote.
  git -C "$ws" reset -q --hard && git -C "$ws" clean -fdq
  "$CRUX_HOME/bin/crux" workspace rm move >/dev/null 2>&1
  git -C "$root/app" branch -D ws/move >/dev/null 2>&1
  git -C "$root/app" for-each-ref --format='%(refname)' refs/crux | xargs -r -n1 git -C "$root/app" update-ref -d

  local out; out="$(cd "$root/app" && CRUX_MACHINE=desktop "$CRUX_HOME/bin/crux" workspace resume move 2>&1)"
  assert_contains "$out" "brought what laptop left uncommitted" "it says what it brought"
  assert_contains "$(cat "$ws/f.txt")" "halfway" "the half-made change is there"
  assert_eq "$blob" "$(sha256sum < "$ws/blob.bin")" "a binary file arrives intact"
  assert_no_file "$ws/old.txt" "a file deleted and not committed is deleted here too"
  assert_eq "" "$(git -C "$ws" diff --cached --name-only)" "and nothing is left staged"
}

test_wip_committing_it_withdraws_what_was_saved() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace done-now)"
  local ws="$root/app-ws-done-now"
  echo "x" >> "$ws/f.txt"
  _turn_ends "$ws" laptop
  _wait_for_ref "$SB/remotes/app.git" refs/crux/wip/laptop/ws/done-now
  git -C "$ws" commit -qam "all of it"

  _turn_ends "$ws" laptop
  _wait_for_no_ref "$SB/remotes/app.git" refs/crux/wip/laptop/ws/done-now
  assert_exit 1 "with nothing uncommitted, the saved work is withdrawn from the remote" \
    git -C "$SB/remotes/app.git" rev-parse -q --verify refs/crux/wip/laptop/ws/done-now
}

test_wip_a_public_repo_saves_nothing() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace open)"
  local ws="$root/app-ws-open"
  git -C "$root/app" remote set-url origin "https://github.com/acme/app.git"
  git -C "$root/app" config "url.$SB/remotes/app.git.insteadOf" "https://github.com/acme/app.git"
  mkdir -p "$SB/vis-bin"
  printf '#!/bin/sh\necho PUBLIC\n' > "$SB/vis-bin/gh"; chmod +x "$SB/vis-bin/gh"
  echo "x" >> "$ws/f.txt"

  _turn_ends "$ws" laptop PATH="$SB/vis-bin:$PATH"
  sleep 1
  assert_eq "" "$(git -C "$SB/remotes/app.git" for-each-ref refs/crux/wip)" \
    "in a public repo the uncommitted work is not published for anyone to read"
}

test_wip_leaving_counts_uncommitted_work_that_travelled() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace leave)"
  local ws="$root/app-ws-leave"
  _commit_in "$ws" "committed"
  ( cd "$ws" && CRUX_TASK_SYNC=1 CRUX_MACHINE=laptop "$CRUX_HOME/bin/crux" hook post-commit )
  _wait_for_ref "$SB/remotes/app.git" refs/crux/branches/laptop/ws/leave
  echo "halfway" >> "$ws/f.txt"

  local out; out="$(cd "$CRUX_PROJECTS_DIR" && CRUX_TASK_SYNC=1 CRUX_MACHINE=laptop "$CRUX_HOME/bin/crux" sync --leave 2>&1)"
  assert_contains "$out" "travelled as work in progress" "leaving saves it and says it travelled"
  assert_not_contains "$out" "error proj/app-ws-leave" "instead of blocking on it"
}

test_wip_a_turn_end_outside_a_workspace_saves_nothing() {
  sandbox >/dev/null
  local root; root="$(_publish_project)"
  echo "x" >> "$root/app/f.txt"

  _turn_ends "$root/app" laptop
  sleep 1
  assert_eq "" "$(git -C "$SB/remotes/app.git" for-each-ref refs/crux)" "the main checkout's changes are not published"
}

test_wip_halfway_through_a_merge_saves_nothing() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace clash)"
  local ws="$root/app-ws-clash"
  git -C "$ws" switch -q -c other
  echo "theirs" > "$ws/f.txt"; git -C "$ws" commit -qam theirs
  git -C "$ws" switch -q ws/clash
  echo "ours" > "$ws/f.txt"; git -C "$ws" commit -qam ours
  git -C "$ws" merge -q other >/dev/null 2>&1

  _turn_ends "$ws" laptop
  sleep 1
  assert_eq "" "$(git -C "$SB/remotes/app.git" for-each-ref refs/crux/wip)" "conflict markers do not travel as work"
}

test_wip_a_dependency_folder_nobody_ignored_is_not_carried() {
  sandbox >/dev/null
  local root; root="$(_wip_workspace deps)"
  local ws="$root/app-ws-deps"
  mkdir -p "$ws/node_modules/pkg"
  local i
  for i in $(seq 1001); do echo "$i" > "$ws/node_modules/pkg/$i.js"; done

  _turn_ends "$ws" laptop
  sleep 1
  assert_eq "" "$(git -C "$SB/remotes/app.git" for-each-ref refs/crux/wip)" "a thousand new files are not pushed as work"
}
