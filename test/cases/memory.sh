#!/usr/bin/env bash

# Writes an agent memory in the sandbox and prints its path.
#   memory <scope> <name> [type]   — with no type, leaves it undeclared
memory() {
  local scope_name="$1" name="$2" kind="${3:-}" dir
  dir="$CLAUDE_CONFIG_DIR/projects/$scope_name/memory"
  mkdir -p "$dir"
  {
    echo "---"
    echo "name: $name"
    echo "description: test memory"
    if [[ -n "$kind" ]]; then
      echo "metadata:"
      echo "  type: $kind"
    fi
    echo "---"
    echo
    echo "body"
  } > "$dir/$name.md"
  echo "$dir/$name.md"
}

# The scope an agent names a working directory with.
scope_of() { printf '%s' "$1" | tr '/.' '-'; }

test_memory_detects_unpromoted_project_ones() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  memory "$(scope_of "$CRUX_PROJECTS_DIR/alpha")" sales-lead project >/dev/null

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "sales-lead" "names the memory that is missing in git"
  assert_contains "$out" "alpha-docs" "says which docs repo it belongs to"
  assert_exit 1 "--check fails while any remain" \
    "$CRUX_HOME/bin/crux" memory --check
}

test_memory_leaves_local_what_belongs_to_the_person() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  local scope_name; scope_name="$(scope_of "$CRUX_PROJECTS_DIR/alpha")"
  memory "$scope_name" prefers-spanish user >/dev/null
  memory "$scope_name" no-narrative-comments feedback >/dev/null

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "nothing unpromoted" "user and feedback are not leaks"
  assert_contains "$out" "1 user" "counts them as local by design"
  assert_exit 0 "--check passes" "$CRUX_HOME/bin/crux" memory --check
}

test_memory_does_not_assume_missing_type() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  memory "$(scope_of "$CRUX_PROJECTS_DIR/alpha")" undeclared >/dev/null

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "no declared type" "reports the one that declares no type"
  assert_contains "$out" "undeclared" "and names it"
  assert_exit 0 "does not count it as a leak: it is not known whether it is one" \
    "$CRUX_HOME/bin/crux" memory --check
}

test_memory_stops_if_a_memory_cannot_be_read() {
  # Root reads any file, so there the check proves nothing.
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0

  sandbox >/dev/null
  new_project alpha >/dev/null
  local f; f="$(memory "$(scope_of "$CRUX_PROJECTS_DIR/alpha")" opaque project)"
  chmod 000 "$f"

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "cannot be read" "says so instead of counting it as zero"
  assert_contains "$out" "opaque" "and points at which one"
  assert_exit 1 "--check does not accept a read that failed either" \
    "$CRUX_HOME/bin/crux" memory --check

  chmod 644 "$f"
}

test_memory_assigns_to_most_specific_project() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  new_project alpha-beta >/dev/null
  memory "$(scope_of "$CRUX_PROJECTS_DIR/alpha-beta/api")" api-note project >/dev/null

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "alpha-beta-docs" "the longest project name wins"
  assert_not_contains "$out" " alpha-docs" "and the one that starts the same does not take it"
}

test_memory_without_project_says_where_it_comes_from() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  memory "$(scope_of "$SB/elsewhere")" loose-note reference >/dev/null

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "loose-note" "reports it all the same"
  assert_contains "$out" "scope" "and says which directory it came from"
  assert_not_contains "$out" "alpha-docs" "does not place it in a project by eye"
}

test_memory_brief_takes_two_lines_however_many() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  local scope_name; scope_name="$(scope_of "$CRUX_PROJECTS_DIR/alpha")"
  local i; for i in 1 2 3 4 5; do memory "$scope_name" "nota-$i" project >/dev/null; done

  local out; out="$("$CRUX_HOME/bin/crux" memory --brief 2>&1)"
  assert_eq "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the hook warning does not grow"
  assert_contains "$out" "+2" "says how many were left unnamed"
}

test_hooks_install_and_remove_memory_guard() {
  sandbox >/dev/null
  local docs; docs="$(new_project alpha)"
  echo '{}' > "$CLAUDE_SETTINGS"

  ( cd "$docs" && "$CRUX_HOME/bin/crux" hooks install >/dev/null 2>&1 )
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "memory-guard" \
    "install hooks the guard at session close"

  ( cd "$docs" && "$CRUX_HOME/bin/crux" hooks remove >/dev/null 2>&1 )
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "memory-guard" \
    "remove removes it"
}

test_guard_stays_silent_when_nothing_to_promote() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  memory "$(scope_of "$CRUX_PROJECTS_DIR/alpha")" prefers-spanish user >/dev/null

  # CRUX_HOME is already exported by the runner, which is how the real hook sees it.
  local out
  out="$(bash "$CRUX_HOME/adapters/claude/hooks/memory-guard.sh" 2>&1)"
  assert_eq "" "$out" "silent while there are no leaks"
}

test_memory_warns_if_no_projects_root() {
  sandbox >/dev/null
  memory "$(scope_of "$CRUX_PROJECTS_DIR/alpha")" note project >/dev/null
  rm -rf "$CRUX_PROJECTS_DIR"

  local out; out="$("$CRUX_HOME/bin/crux" memory 2>&1)"
  assert_contains "$out" "projects root does not exist" "does not silently write the destination off"
  assert_contains "$out" "note" "and keeps reporting the leak, which does not depend on that"
}

test_sandbox_isolates_agent_settings() {
  sandbox >/dev/null
  local docs; docs="$(new_project alpha)"
  ( cd "$docs" && "$CRUX_HOME/bin/crux" hooks install >/dev/null 2>&1 )

  assert_file "$CLAUDE_SETTINGS" "the hooks are installed inside the sandbox"
  assert_not_contains "$CLAUDE_SETTINGS" "$HOME/.claude" \
    "and not in the real settings of whoever runs the suite"
}
