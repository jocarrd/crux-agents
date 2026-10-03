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
