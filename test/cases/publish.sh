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
