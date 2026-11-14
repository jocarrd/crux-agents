#!/usr/bin/env bash
# A workspace's commits travel as they are made: `crux hook post-commit`
# publishes the branch to a hidden ref in the background.

_publish_project() {
  local root; root="$(_tasks_project)"
  git init -q --bare -b main "$SB/remotes/app.git"
  git -C "$root/app" remote add origin "$SB/remotes/app.git"
  git -C "$root/app" push -q origin HEAD:main
  echo "$root"
}

_wait_for_ref() {
  local repo="$1" ref="$2" _
  for _ in $(seq 40); do
    git -C "$repo" rev-parse -q --verify "$ref" >/dev/null && return 0
    sleep 0.25
  done
  return 1
}

test_publish_a_workspace_commit_reaches_a_hidden_ref() {
  sandbox >/dev/null
  local root; root="$(_publish_project)"
  "$CRUX_HOME/bin/crux" workspace new pub --repo "$root/app" >/dev/null 2>&1
  _commit_in "$root/app-ws-pub" "published"
  ( cd "$root/app-ws-pub" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )

  _wait_for_ref "$SB/remotes/app.git" refs/crux/branches/here/ws/pub
  assert_eq "$(git -C "$SB/remotes/app.git" rev-parse -q --verify refs/crux/branches/here/ws/pub)" \
    "$(git -C "$root/app" rev-parse ws/pub)" "the remote has the commit under the machine's hidden ref"
  assert_exit 1 "and no branch" git -C "$SB/remotes/app.git" show-ref -q --verify refs/heads/ws/pub
}

test_publish_a_commit_outside_a_workspace_stays_here() {
  sandbox >/dev/null
  local root; root="$(_publish_project)"
  _commit_in "$root/app" "on main"
  ( cd "$root/app" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )

  sleep 1
  assert_eq "$(git -C "$SB/remotes/app.git" for-each-ref refs/crux)" "" "nothing of the main branch is published"
}

test_publish_the_commit_does_not_wait_for_a_slow_remote() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  git -C "$root/app" remote add origin "ssh://slow.invalid/app.git"
  "$CRUX_HOME/bin/crux" workspace new slow --repo "$root/app" >/dev/null 2>&1
  _commit_in "$root/app-ws-slow" "slow"

  local start end
  start=$(date +%s%N)
  ( cd "$root/app-ws-slow" && CRUX_TASK_SYNC=1 GIT_SSH_COMMAND="sleep 3; false" "$CRUX_HOME/bin/crux" hook post-commit )
  end=$(date +%s%N)
  assert_exit 0 "the hook returns well before the 3 s the remote takes" test $(((end - start) / 1000000)) -lt 500
}

test_publish_resume_does_not_choose_between_diverged_copies() {
  sandbox >/dev/null
  local root; root="$(_publish_project)"
  "$CRUX_HOME/bin/crux" workspace new div --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-div" base one two
  base="$(git -C "$ws" rev-parse HEAD)"
  _commit_in "$ws" "laptop"; one="$(git -C "$ws" rev-parse HEAD)"
  git -C "$ws" reset -q --hard "$base"
  _commit_in "$ws" "desktop"; two="$(git -C "$ws" rev-parse HEAD)"
  git -C "$root/app" push -q origin "$one:refs/crux/branches/laptop/ws/div" "$two:refs/crux/branches/desktop/ws/div"
  "$CRUX_HOME/bin/crux" workspace rm div >/dev/null 2>&1
  git -C "$root/app" branch -D ws/div >/dev/null

  local out; out="$(cd "$root/app" && "$CRUX_HOME/bin/crux" workspace resume div 2>&1)"
  assert_contains "$out" "diverged between machines" "it says the copies diverged"
  assert_contains "$out" "$one" "naming one"
  assert_contains "$out" "$two" "and the other"
  assert_exit 1 "and chooses neither" test -d "$ws"
}

test_publish_a_commit_made_offline_travels_with_the_next() {
  sandbox >/dev/null
  local root; root="$(_tasks_project)"
  local remote="$SB/remotes/app.git"
  git -C "$root/app" remote add origin "$remote"
  "$CRUX_HOME/bin/crux" workspace new off --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-off"
  _commit_in "$ws" "offline"
  ( cd "$ws" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )
  sleep 1
  assert_exit 1 "with the remote unreachable nothing is marked as published" \
    git -C "$root/app" rev-parse -q --verify refs/crux/published/ws/off

  git init -q --bare -b main "$remote"
  _commit_in "$ws" "online"
  ( cd "$ws" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )
  _wait_for_ref "$remote" refs/crux/branches/here/ws/off
  assert_eq "$(git -C "$remote" rev-parse -q --verify refs/crux/branches/here/ws/off)" "$(git -C "$ws" rev-parse HEAD)" \
    "the next commit carries both"
}

test_publish_closing_a_merged_workspace_deletes_its_hidden_refs() {
  sandbox >/dev/null
  local root; root="$(_publish_project)"
  "$CRUX_HOME/bin/crux" workspace new gone --repo "$root/app" >/dev/null 2>&1
  _commit_in "$root/app-ws-gone" "merged work"
  ( cd "$root/app-ws-gone" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )
  _wait_for_ref "$SB/remotes/app.git" refs/crux/branches/here/ws/gone
  local fake; fake="$(_gh_with_merged_proposal)"
  echo "9 $(git -C "$root/app" rev-parse ws/gone)" > "$SB/merged"

  PATH="$fake:$PATH" "$CRUX_HOME/bin/crux" workspace rm gone >/dev/null 2>&1
  assert_exit 1 "the remote no longer keeps the hidden ref" \
    git -C "$SB/remotes/app.git" rev-parse -q --verify refs/crux/branches/here/ws/gone
  assert_exit 1 "nor this machine its copy" git -C "$root/app" rev-parse -q --verify refs/crux/published/ws/gone
}

test_publish_arrival_installs_the_post_commit_a_repo_lacks() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron --repos "api")"
  local api="$CRUX_PROJECTS_DIR/omicron/api"
  git init -q "$api"
  (cd "$docs" && "$CRUX_HOME/bin/crux" hooks install >/dev/null 2>&1)
  assert_file "$api/.git/hooks/post-commit.crux" "hooks install puts the post-commit in the code repo"
  rm "$api/.git/hooks/post-commit.crux"

  local out; out="$(cd "$CRUX_PROJECTS_DIR" && "$CRUX_HOME/bin/crux" sync 2>&1)"
  assert_contains "$out" "git hooks brought up to date" "arriving notices a repo hooked by an older crux"
  assert_file "$api/.git/hooks/post-commit.crux" "and puts the missing hook back with nobody asking"
}

test_publish_arrival_repairs_hooks_whose_kernel_is_gone() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron --repos "api")"
  local api="$CRUX_PROJECTS_DIR/omicron/api"
  git init -q "$api"
  (cd "$docs" && "$CRUX_HOME/bin/crux" hooks install >/dev/null 2>&1)
  sed -i "s|^KERNEL=.*|KERNEL=\"$SB/deleted-worktree\"|" "$api/.git/hooks/commit-msg.crux"

  local out; out="$(cd "$CRUX_PROJECTS_DIR" && "$CRUX_HOME/bin/crux" sync 2>&1)"
  assert_contains "$out" "git hooks brought up to date" "arriving notices a hook that points at a kernel no longer there"
  assert_not_contains "$(cat "$api/.git/hooks/commit-msg.crux")" "deleted-worktree" "and points it back at one that is"
}

test_publish_forgetting_a_branch_keeps_one_whose_name_ends_like_it() {
  sandbox >/dev/null
  local root; root="$(_publish_project)"
  local app="$root/app"
  "$CRUX_HOME/bin/crux" workspace new pub --repo "$app" >/dev/null 2>&1
  _commit_in "$root/app-ws-pub" "workspace work"
  ( cd "$root/app-ws-pub" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )
  _wait_for_ref "$SB/remotes/app.git" refs/crux/branches/here/ws/pub
  git -C "$app" switch -q -c pub
  _commit_in "$app" "a plain branch called pub"
  git -C "$app" push -q -u origin pub 2>/dev/null
  git -C "$app" switch -q main
  git -C "$app" push -q origin --delete pub
  local fake; fake="$(_gh_with_merged_proposal)"
  echo "3 $(git -C "$app" rev-parse pub)" > "$SB/merged"

  (cd "$CRUX_PROJECTS_DIR" && PATH="$fake:$PATH" "$CRUX_HOME/bin/crux" sync >/dev/null 2>&1)
  assert_exit 1 "the merged branch pub is cleaned" git -C "$app" rev-parse -q --verify refs/heads/pub
  assert_exit 0 "and what ws/pub published stays on the remote" \
    git -C "$SB/remotes/app.git" rev-parse -q --verify refs/crux/branches/here/ws/pub
  assert_exit 0 "and here" git -C "$app" rev-parse -q --verify refs/crux/published/ws/pub
}

test_publish_a_clients_repo_receives_no_hidden_ref() {
  sandbox >/dev/null
  local root; root="$(_tasks_project client-repo)"
  git init -q --bare -b main "$SB/remotes/app.git"
  git -C "$root/app" remote add origin "$SB/remotes/app.git"
  git -C "$root/app" push -q origin HEAD:main
  "$CRUX_HOME/bin/crux" workspace new theirs --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-theirs"
  _commit_in "$ws" "work for the client"
  ( cd "$ws" && CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook post-commit )
  echo "halfway" >> "$ws/f.txt"
  printf '{"cwd":"%s"}' "$ws" | CRUX_TASK_SYNC=1 CRUX_MACHINE=here "$CRUX_HOME/bin/crux" hook wip-save

  sleep 1
  assert_eq "" "$(git -C "$SB/remotes/app.git" for-each-ref refs/crux)" \
    "neither the commit nor the uncommitted work leaves our tooling's name in the client's remote"
  local out; out="$(cd "$CRUX_PROJECTS_DIR" && CRUX_TASK_SYNC=1 "$CRUX_HOME/bin/crux" sync --leave 2>&1)"
  assert_contains "$out" "error proj/app-ws-theirs: 1 uncommitted file" "and leaving says the work stays here"
}
