#!/usr/bin/env bash

# `crux bootstrap` is what runs on a machine where there is nothing. Here a
# fake `gh` is put in front of it, because what has to be checked is not that
# GitHub answers: it is what it considers a project and what it does with the
# list.

_ready_machine() {
  # The minimum the machine doctor demands, inside the sandbox.
  export CRUX_CONFIG="$SB/crux-config"
  cat > "$CRUX_CONFIG" <<EOF
CRUX_REMOTE="git@github.com:jocarrd/{repo}.git"
EOF
  mkdir -p "$CLAUDE_SKILLS_DIR/some-skill"
}

_fake_gh() {
  # $1 = list of repos separated by spaces
  # $2 = those that have a contract, separated by spaces
  mkdir -p "$SB/bin"
  cat > "$SB/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  auth) exit 0 ;;
  repo) printf '%s\n' $1 ; exit 0 ;;
  api)
    case "\$2" in
      user) echo jocarrd; exit 0 ;;
      *)
        for c in $2; do
          [[ "\$2" == *"/\$c-docs/"* ]] && exit 0
        done
        exit 1 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

test_bootstrap_takes_as_project_only_what_carries_a_contract() {
  sandbox >/dev/null
  _ready_machine
  # three repos end in -docs, but only two carry crux.json. The third is
  # documentation of something that is not a project of the standard.
  _fake_gh "alpha-docs beta-docs notes-docs otro-repo" "alpha beta"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run 2>&1)"

  assert_contains "$out" "alpha" "takes the one that carries a contract"
  assert_contains "$out" "beta" "takes the other one that carries a contract"
  assert_contains "$out" "notes-docs has no contract" "drops the one that does not carry it and says why"
  assert_not_contains "$out" "otro-repo" "a repo that does not end in -docs is not even looked at"
  teardown
}

test_bootstrap_only_filters() {
  sandbox >/dev/null
  _ready_machine
  _fake_gh "alpha-docs beta-docs" "alpha beta"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --only beta --dry-run 2>&1)"

  assert_contains "$out" "beta" "fetches the one asked for"
  assert_not_contains "$out" "would fetch 2" "and only that one"
  teardown
}

test_bootstrap_dry_run_clones_nothing() {
  sandbox >/dev/null
  _ready_machine
  _fake_gh "alpha-docs" "alpha"

  crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run >/dev/null 2>&1
  assert_no_file "$CRUX_PROJECTS_DIR/alpha" "--dry-run does not touch the disk"
  teardown
}

test_bootstrap_stops_if_machine_not_ready() {
  sandbox >/dev/null
  # Without a machine config: cloning twenty repos to discover afterwards that
  # something is missing is the worst way to find out, so it does not even
  # start.
  export CRUX_CONFIG="$SB/does-not-exist"
  mkdir -p "$CLAUDE_SKILLS_DIR/some-skill"
  _fake_gh "alpha-docs" "alpha"

  assert_exit 1 "does not go on with a half-ready machine" \
    crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run
  teardown
}

test_bootstrap_says_which_repos_are_left_out() {
  sandbox >/dev/null
  _ready_machine
  # Two loose repos that belong to no project. It does not fetch them, but
  # keeping quiet about it would be worse: you leave believing everything is
  # there.
  _fake_gh "alpha-docs loose-one loose-two" "alpha"
  mkdir -p "$CRUX_PROJECTS_DIR/alpha/alpha-docs"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" 2>&1)"

  assert_contains "$out" "loose-one" "names the repo that is left out"
  assert_contains "$out" "loose-two" "and the other one"
  teardown
}

_fake_gh_with_profile() {
  # The account has a project and the profile; `gh repo clone` clones a local remote.
  git init -q --bare -b main "$SB/agent-profile.git"
  git clone -q "$SB/agent-profile.git" "$SB/profile-seed" 2>/dev/null
  printf -- '---\nreminder: "Answer briefly."\n---\n# Profile\n' > "$SB/profile-seed/PROFILE.md"
  git -C "$SB/profile-seed" add -A && git -C "$SB/profile-seed" commit -q -m "profile"
  git -C "$SB/profile-seed" push -q origin main
  mkdir -p "$SB/bin"
  cat > "$SB/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth "*) exit 0 ;;
  "repo list") printf '%s\n' alpha-docs agent-profile ; exit 0 ;;
  "repo view") exit 0 ;;
  "repo clone") git clone -q "$SB/agent-profile.git" "\$4"; exit \$? ;;
  "api user") echo jocarrd; exit 0 ;;
  "api "*) [[ "\$2" == *"/alpha-docs/"* ]] && exit 0; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

test_bootstrap_dry_run_announces_the_profile_without_bringing_it() {
  sandbox >/dev/null
  _ready_machine
  _fake_gh_with_profile

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run 2>&1)"

  assert_contains "$out" "would clone the profile jocarrd/agent-profile" "it says it would bring the profile"
  assert_no_file "$CRUX_PROJECTS_DIR/agent-profile/PROFILE.md" "and does not bring it"
  teardown
}

test_bootstrap_brings_the_profile_and_loads_it() {
  sandbox >/dev/null
  _ready_machine
  _fake_gh_with_profile

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --only alpha 2>&1)"

  assert_file "$CRUX_PROJECTS_DIR/agent-profile/PROFILE.md" "it clones the profile"
  assert_contains "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md" 2>/dev/null)" "@$CRUX_PROJECTS_DIR/agent-profile/PROFILE.md" \
    "and Claude loads it"
  assert_not_contains "$(printf '%s' "$out" | grep -A1 'belong to no project')" "agent-profile" \
    "the profile is not listed as a loose repo"
  teardown
}

test_bootstrap_finds_projects_in_the_organisations_too() {
  sandbox >/dev/null
  _ready_machine
  # The docs repo of a team project lives in its organisation, not in the
  # personal account: searching only there left those projects behind.
  mkdir -p "$SB/bin"
  cat > "$SB/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth "*) exit 0 ;;
  "repo list")
    case "$3" in
      jocarrd)  printf '%s\n' alpha-docs ;;
      team-org) printf '%s\n' teamproj-docs alpha-docs ;;
    esac; exit 0 ;;
  "api user") echo jocarrd; exit 0 ;;
  "api user/memberships/orgs") echo team-org; exit 0 ;;
  "api repos/"*) [[ "$2" == */alpha-docs/* || "$2" == team-org/teamproj-docs/* || "$2" == repos/team-org/teamproj-docs/* ]] && exit 0; exit 1 ;;
esac
exit 0
GH
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"

  local out
  out="$(crux bootstrap --parent "$CRUX_PROJECTS_DIR" --dry-run 2>&1)"

  assert_contains "$out" "teamproj (team-org)" "finds the project of the organisation and says whose it is"
  assert_contains "$out" "would fetch 2 projects" "together with the personal one"
  assert_contains "$out" "only the first one comes" "a name repeated in two owners is not fetched twice"
  teardown
}

test_template_for_owner_keeps_the_shape() {
  sandbox >/dev/null
  _ready_machine
  local got
  got="$("$CRUX_BIN" __fn template_for_owner team-org)"
  assert_contains "$got" "git@github.com:team-org/{repo}.git" "same template, other owner"
  printf 'CRUX_REMOTE="https://github.com/jocarrd/{repo}.git"\n' > "$CRUX_CONFIG"
  got="$("$CRUX_BIN" __fn template_for_owner team-org)"
  assert_contains "$got" "https://github.com/team-org/{repo}.git" "https stays https"
  teardown
}

test_bootstrap_only_does_not_call_the_rest_loose() {
  sandbox >/dev/null
  _ready_machine
  _fake_gh "alpha-docs beta-docs loose-one" "alpha beta"
  mkdir -p "$CRUX_PROJECTS_DIR/alpha/alpha-docs" "$CRUX_PROJECTS_DIR/loose-one"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --only alpha 2>&1)"
  assert_not_contains "$out" "beta-docs" "a project left out by --only is not a loose repo"

  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_not_contains "$out" "loose-one" "a repo cloned straight under the root is already here"
  teardown
}

test_bootstrap_brings_the_open_tasks_of_the_other_machine() {
  sandbox >/dev/null
  _ready_machine
  local docs; docs="$(new_project alpha)"
  git init -q --bare -b main "$SB/remotes/alpha-docs.git"
  git -C "$docs" remote add origin "$SB/remotes/alpha-docs.git"
  git -C "$docs" push -q origin HEAD:main 2>/dev/null
  local record="$SB/A/tasks/alpha/t1.md"
  CRUX_TASKS_DIR="$SB/A/tasks" crux __task ensure --file "$record" --task t1 --project alpha --repo app \
    --workspace t1 >/dev/null
  CRUX_TASKS_DIR="$SB/A/tasks" crux __task set --file "$record" --section "Next step" --text "finish the import" >/dev/null
  CRUX_TASKS_DIR="$SB/A/tasks" crux __task-sync sync --all >/dev/null 2>&1
  assert_contains "$(git -C "$SB/remotes/alpha-docs.git" branch)" "crux/tasks" "the first machine published it"

  cat > "$CRUX_CONFIG" <<CONF
CRUX_REMOTE="$SB/remotes/{repo}.git"
CONF
  _fake_gh "alpha-docs" "alpha"
  CRUX_TASKS_DIR="$SB/B/tasks" CRUX_STATE_DIR="$SB/B/state" CRUX_REGISTRY="$SB/B/registry.json" \
    crux bootstrap --owner jocarrd --parent "$SB/B/P" --only alpha >/dev/null 2>&1

  assert_file "$SB/B/P/alpha/alpha-docs/crux.json" "the project arrives"
  assert_contains "$(cat "$SB/B/tasks/alpha/t1.md" 2>/dev/null)" "finish the import" \
    "and so does the task left open on the other machine"
  teardown
}
