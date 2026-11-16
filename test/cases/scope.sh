#!/usr/bin/env bash

# Work scopes (ADR-025): one person, several isolated contexts on one machine.

# two_scopes — the person's own scope and one for a company, each with its
# root. Prints nothing; leaves OWN and ACME pointing at the roots.
two_scopes() {
  OWN="$SB/Own"; ACME="$SB/Acme"
  mkdir -p "$OWN" "$ACME" "$CRUX_SCOPES_DIR/own" "$CRUX_SCOPES_DIR/acme"
  printf 'ROOT="%s"\nPRIMARY="true"\nREMOTE="git@github.com:me/{repo}.git"\n' "$OWN" \
    > "$CRUX_SCOPES_DIR/own/config"
  printf 'ROOT="%s"\nREMOTE="git@github.com:acme/{repo}.git"\nOWNERS="acme"\nGIT_EMAIL="me@acme.test"\n' "$ACME" \
    > "$CRUX_SCOPES_DIR/acme/config"
}

session_start() {
  # session_start <session id> <cwd>: what the session-start hook answers.
  printf '{"session_id":"%s","cwd":"%s","source":"startup"}' "$1" "$2" |
    (cd "$2" 2>/dev/null || cd "$SB" || exit; bash "$CRUX_HOME/adapters/claude/hooks/session-sync.sh")
}

test_without_scopes_nothing_changes() {
  sandbox >/dev/null
  local out; out="$(crux scope 2>&1)"
  assert_contains "$out" "no scopes declared" "a machine without scopes says it has one root"
  assert_eq "$CRUX_PROJECTS_DIR" "$(crux __fn projects_root)" "and the root is the one it always was"
  assert_exit 0 "crux scope check passes" crux scope check
}

test_each_folder_belongs_to_its_scope() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web/api" "$OWN/alpha"
  assert_eq "acme" "$(crux scope of "$ACME/web/api")" "a folder deep in a root is of that scope"
  assert_eq "own" "$(crux scope of "$OWN/alpha")" "and the other root is of the other"
  assert_eq "acme" "$(crux scope of "$ACME/web/not-yet-created.txt")" "a file still to be written is where its folder is"
  assert_exit 1 "a folder outside every root is of none" crux scope of "$SB"
  assert_eq "$ACME" "$(in_dir "$ACME/web" "$CRUX_HOME/bin/crux" __fn projects_root)" \
    "the projects root of a command is its scope's"
  assert_eq "$OWN" "$(in_dir "$SB" "$CRUX_HOME/bin/crux" __fn projects_root)" \
    "and outside every root, the person's own"
}

test_a_sibling_folder_with_the_same_prefix_is_not_inside() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$SB/Acme-old/x"
  assert_exit 1 "Acme-old is not inside Acme" crux scope of "$SB/Acme-old/x"
}

test_a_worktree_made_outside_every_root_keeps_its_scope() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web"
  git init -q "$ACME/web/api"
  git -C "$ACME/web/api" commit -q --allow-empty -m init
  git -C "$ACME/web/api" worktree add -q "$SB/elsewhere/api-wt" -b wt 2>/dev/null
  assert_eq "acme" "$(crux scope of "$SB/elsewhere/api-wt")" "a worktree is of the scope its repo lives in"
}

test_scopes_that_contradict_each_other_stop_every_command() {
  sandbox >/dev/null
  two_scopes
  # A root inside another: no folder could say which scope it belongs to.
  printf 'ROOT="%s"\n' "$OWN/inner" > "$CRUX_SCOPES_DIR/acme/config"
  local out rc=0; out="$(crux status 2>&1)" || rc=$?
  assert_eq 1 "$rc" "status refuses to run"
  assert_contains "$out" "overlap" "and says the roots overlap"
  assert_exit 1 "scope check fails" crux scope check

  two_scopes
  printf 'ENFORCE="guadr"\n' >> "$CRUX_SCOPES_DIR/acme/config"
  out="$(crux scope check 2>&1)"
  assert_contains "$out" "is not guard or sandbox" "a typo is named, never read as the default"

  two_scopes
  printf 'PRIMARY="true"\n' >> "$CRUX_SCOPES_DIR/acme/config"
  assert_contains "$(crux scope check 2>&1)" "only one scope can be primary" "two primaries are refused"
}

test_one_owner_in_two_scopes_is_refused() {
  sandbox >/dev/null
  two_scopes
  printf 'OWNERS="acme"\n' >> "$CRUX_SCOPES_DIR/own/config"
  assert_contains "$(crux scope check 2>&1)" "owner 'acme' is in two scopes" "bootstrap could not tell where to put it"
}

test_init_creates_the_project_in_its_scope_with_its_remote() {
  sandbox >/dev/null
  two_scopes
  in_dir "$ACME" "$CRUX_HOME/bin/crux" init web --no-remote >/dev/null 2>&1
  assert_file "$ACME/web/web-docs/crux.json" "the project goes to the scope's root"
  assert_contains "$(cat "$ACME/web/web-docs/crux.json")" "git@github.com:acme/{repo}.git" \
    "with the scope's remote, not the person's"
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init alpha --no-remote >/dev/null 2>&1
  assert_contains "$(cat "$OWN/alpha/alpha-docs/crux.json")" "git@github.com:me/{repo}.git" \
    "and the person's own scope keeps theirs"
}

test_tasks_of_each_scope_live_apart() {
  sandbox >/dev/null
  two_scopes
  in_dir "$ACME" "$CRUX_HOME/bin/crux" init web --no-remote >/dev/null 2>&1
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init web --no-remote >/dev/null 2>&1
  in_dir "$ACME/web" "$CRUX_HOME/bin/crux" task new web/login --goal "acme login" >/dev/null 2>&1
  in_dir "$OWN/web" "$CRUX_HOME/bin/crux" task new web/blog --goal "own blog" >/dev/null 2>&1
  assert_file "$CRUX_SCOPES_DIR/acme/tasks/web/login.md" "a task of a company project lives in its scope"
  assert_no_file "$CRUX_SCOPES_DIR/acme/tasks/web/blog.md" \
    "and a project with the same name elsewhere does not land there"
  local machine; machine="$(dirname "$CRUX_REGISTRY")/tasks"
  assert_file "$machine/web/blog.md" "the person's own scope keeps the machine's tasks folder"
}

test_a_session_opened_in_a_root_is_pinned_there() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web"
  local out; out="$(session_start s1 "$ACME/web")"
  assert_contains "$out" "scope 'acme'" "the agent is told its scope"
  assert_contains "$out" "new session" "and that another scope needs another session"
  assert_eq "acme" "$(cat "$CRUX_STATE_DIR/scope-pins/s1")" "the pin is written"
  # Reopened from another root, the same session keeps its scope.
  out="$(session_start s1 "$OWN")"
  assert_contains "$out" "scope 'acme'" "a pin never moves"
  assert_not_contains "$out" "scope 'own'" "not even when the session reopens elsewhere"
}

test_a_session_outside_every_root_starts_at_the_front_desk() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web" "$OWN/alpha" "$SB/desk"
  local out; out="$(session_start s2 "$SB/desk")"
  assert_contains "$out" "front desk" "it is in no scope yet"
  assert_contains "$out" "acme: web" "the map gives each scope's projects"
  assert_contains "$out" "own (the person's own): alpha" "by name only"
  assert_no_file "$CRUX_STATE_DIR/scope-pins/s2" "and nothing is pinned"
}

test_unpinned_sessions_can_go_straight_to_a_scope() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$SB/desk"
  local out; out="$(CRUX_UNPINNED_SESSIONS=own session_start s3 "$SB/desk")"
  assert_contains "$out" "scope 'own'" "the person can skip the front desk"
}

test_the_person_sees_every_task_and_the_agent_only_its_scope() {
  sandbox >/dev/null
  two_scopes
  in_dir "$ACME" "$CRUX_HOME/bin/crux" init web --no-remote >/dev/null 2>&1
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init alpha --no-remote >/dev/null 2>&1
  in_dir "$ACME/web" "$CRUX_HOME/bin/crux" task new web/login --goal "send the contract to the client" >/dev/null 2>&1
  in_dir "$OWN/alpha" "$CRUX_HOME/bin/crux" task new alpha/salary --goal "negotiate my salary" >/dev/null 2>&1

  local out user agent
  out="$(session_start s4 "$ACME/web")"
  user="$(printf '%s' "$out" | "$CRUX_BIN" __fn json_get /dev/stdin systemMessage 2>/dev/null || printf '%s' "$out")"
  agent="$(printf '%s' "$out" | "$CRUX_BIN" __fn json_get /dev/stdin hookSpecificOutput.additionalContext 2>/dev/null || printf '%s' "$out")"
  assert_contains "$user" "web/login" "the person sees the company task"
  assert_contains "$user" "alpha/salary" "and their own, from any session"
  assert_contains "$agent" "web/login" "the agent in the company scope gets its task"
  assert_not_contains "$agent" "salary" "and nothing of the person's own"

  out="$(session_start s5 "$SB")"
  agent="$(printf '%s' "$out" | "$CRUX_BIN" __fn json_get /dev/stdin hookSpecificOutput.additionalContext 2>/dev/null || printf '%s' "$out")"
  assert_contains "$agent" "own · alpha/salary" "at the front desk the agent gets the names with their scope"
  assert_not_contains "$agent" "negotiate" "but none of their text"
}

test_the_profile_is_the_persons_wherever_the_command_runs() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$OWN/agent-profile" "$ACME/web"
  printf -- '---\n---\n\n# Profile\n' > "$OWN/agent-profile/PROFILE.md"
  local out; out="$(in_dir "$ACME/web" "$CRUX_HOME/bin/crux" profile 2>&1)"
  assert_contains "$out" "$OWN/agent-profile" "it is found in the primary root, even from another scope"
}

test_scope_open_says_how_to_open_a_session_there() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web" "$SB/desk"
  local out; out="$(in_dir "$SB/desk" "$CRUX_HOME/bin/crux" scope open --project web --prompt "fix the login" 2>&1)"
  assert_contains "$out" "cd '$ACME/web' && claude 'fix the login'" "it finds the project's scope on its own"
  out="$(crux scope enter --project web 2>&1)"
  assert_contains "$out" "scope 'acme'" "enter gives the scope's context"
  assert_contains "$(crux scope open --project nope 2>&1)" "no scope has a project 'nope'" "an unknown project is said"
}

test_each_scope_loads_only_what_it_may_see_of_the_profile() {
  sandbox >/dev/null
  two_scopes
  local dir="$OWN/agent-profile"
  mkdir -p "$dir/preferences" "$dir/about"
  printf -- '---\n---\n\n# Profile\n\n- [Short answers](preferences/short.md) — how to reply\n- [Job search](about/jobs.md) — interviews going on\n- [Rates](preferences/rates.md) — what I charge\n' > "$dir/PROFILE.md"
  printf -- '---\nname: short\n---\nShort answers.\n' > "$dir/preferences/short.md"
  printf -- '---\nname: jobs\n---\nInterviewing.\n' > "$dir/about/jobs.md"
  printf -- '---\nname: rates\nvisibility: private\n---\n100 an hour.\n' > "$dir/preferences/rates.md"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf 'My own line\n' > "$CLAUDE_CONFIG_DIR/CLAUDE.md"

  crux profile link >/dev/null 2>&1
  local shared; shared="$(cat "$CRUX_STATE_DIR/person/shared.md")"
  assert_contains "$shared" "Short answers" "how the person works is shared"
  assert_not_contains "$shared" "Job search" "who they are (about/) is not"
  assert_not_contains "$shared" "Rates" "nor a note marked private"
  assert_not_contains "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" "PROFILE.md" "the global file imports none of it"
  assert_contains "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" "My own line" "and keeps what the person wrote"
  # A root's file reaches every project under it, an isolated client's too:
  # every root imports the shared part, and the full index comes with the
  # session's context where scope and project allow it.
  assert_contains "$(cat "$OWN/CLAUDE.md")" "@$CRUX_STATE_DIR/person/shared.md" "the person's own root imports the shared part"
  assert_contains "$(cat "$ACME/CLAUDE.md")" "@$CRUX_STATE_DIR/person/shared.md" "and so does a company root"
  assert_not_contains "$(cat "$ACME/CLAUDE.md")" "PROFILE.md" "never the full index"
  mkdir -p "$OWN/alpha" "$ACME/web"
  assert_contains "$(session_start s-own "$OWN/alpha")" "Job search" "a session of the person's own gets the full index"
  assert_not_contains "$(session_start s-acme "$ACME/web")" "Job search" "a company one does not"

  mkdir -p "$SB/desk"
  local out; out="$(session_start s6 "$SB/desk")"
  assert_contains "$out" "Short answers" "the front desk gets the shared part"
  assert_not_contains "$out" "Job search" "and nothing private"
}

# --- The wall (scope-guard) ---------------------------------------------------

guard() {
  # guard <session> <cwd> <tool> <tool_input json> — prints stderr, returns the exit code.
  local input
  input="$(printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3" "$4")"
  # Only the hook's reason, on stderr: stdout is dropped and stderr takes its place.
  # shellcheck disable=SC2069
  printf '%s' "$input" | (cd "$2" 2>/dev/null || cd "$SB" || exit; bash "$CRUX_HOME/adapters/claude/hooks/scope-guard.sh" 2>&1 >/dev/null)
}

assert_stops() {
  # assert_stops <description> <fragment of the reason> <guard args...>
  local desc="$1" frag="$2"; shift 2
  local out rc=0; out="$(guard "$@")" || rc=$?
  assert_eq 2 "$rc" "$desc (stopped)"
  [[ -n "$frag" ]] && assert_contains "$out" "$frag" "$desc (says why)"
}

assert_lets() {
  local desc="$1"; shift
  local out rc=0; out="$(guard "$@")" || rc=$?
  assert_eq 0 "$rc" "$desc${out:+ — $out}"
}

wall_setup() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web/api" "$OWN/alpha" "$SB/desk" "$SB/keys/own"
  printf 'secret\n' > "$OWN/alpha/.env"
  printf 'k\n' > "$SB/keys/own/id_deploy"
  printf 'SECRETS="%s"\nOWNERS="me"\n' "$SB/keys/own" >> "$CRUX_SCOPES_DIR/own/config"
  printf 'MCP_DENY="mcp__gmail__*"\n' >> "$CRUX_SCOPES_DIR/acme/config"
  session_start in-acme "$ACME/web" >/dev/null
}

test_the_wall_without_scopes_lets_everything_through() {
  sandbox >/dev/null
  mkdir -p "$SB/a"
  assert_lets "no scopes, no wall" s0 "$SB" Read "{\"file_path\":\"$SB/a/x\"}"
}

test_the_wall_stops_every_way_into_another_scope() {
  wall_setup
  local s=in-acme c="$ACME/web"
  assert_lets "its own scope is open" $s "$c" Read "{\"file_path\":\"$ACME/web/api/x\"}"
  assert_stops "Read into another scope" "belongs to scope 'own'" $s "$c" Read "{\"file_path\":\"$OWN/alpha/.env\"}"
  assert_stops "Write into another scope" "new session" $s "$c" Write "{\"file_path\":\"$OWN/alpha/new.txt\",\"content\":\"x\"}"
  assert_stops "Edit into another scope" "" $s "$c" Edit "{\"file_path\":\"$OWN/alpha/.env\"}"
  assert_stops "Grep over another scope" "" $s "$c" Grep "{\"pattern\":\"x\",\"path\":\"$OWN\"}"
  assert_stops "cat in the shell" "" $s "$c" Bash "{\"command\":\"cat $OWN/alpha/.env\"}"
  assert_stops "a quoted path" "" $s "$c" Bash "{\"command\":\"cat \\\"$OWN/alpha/.env\\\"\"}"
  assert_stops "a relative path" "" $s "$c" Bash "{\"command\":\"cat ../../Own/alpha/.env\"}"
  assert_stops "a cd first" "" $s "$c" Bash "{\"command\":\"cd ../.. && cat Own/alpha/.env\"}"
  assert_stops "a copy out of it" "" $s "$c" Bash "{\"command\":\"cp $OWN/alpha/.env /tmp/x\"}"
  local rc=0
  HOME="$SB" guard $s "$c" Bash '{"command":"cat ~/Own/alpha/.env"}' >/dev/null || rc=$?
  assert_eq 2 "$rc" "a path through ~ (stopped)"
  rc=0; HOME="$SB" guard $s "$c" Bash '{"command":"cat $HOME/Own/alpha/.env"}' >/dev/null || rc=$?
  assert_eq 2 "$rc" "a path through \$HOME (stopped)"
  ln -s "$OWN/alpha" "$ACME/web/sneaky"
  assert_stops "a symlink from inside" "" $s "$c" Read "{\"file_path\":\"$ACME/web/sneaky/.env\"}"
  assert_stops "a secret the other scope declares" "" $s "$c" Read "{\"file_path\":\"$SB/keys/own/id_deploy\"}"
  assert_stops "a repo of the other scope's owner" "owner of scope 'own'" $s "$c" Bash '{"command":"git clone git@github.com:me/blog.git"}'
  assert_stops "gh on the other owner" "" $s "$c" Bash '{"command":"gh pr list -R me/blog"}'
  assert_lets "its own owner is fine" $s "$c" Bash '{"command":"gh pr list -R acme/web"}'
  assert_stops "a connector the scope denies" "not used in scope 'acme'" $s "$c" mcp__gmail__send_message '{}'
  assert_lets "and one it does not" $s "$c" mcp__figma__get_screenshot '{}'
}

test_the_wall_cannot_be_moved_from_inside() {
  wall_setup
  local s=in-acme c="$ACME/web"
  assert_stops "rewriting its own pin" "holds up the scope wall" $s "$c" Write "{\"file_path\":\"$CRUX_STATE_DIR/scope-pins/in-acme\",\"content\":\"own\"}"
  assert_stops "editing a scope's config" "" $s "$c" Bash "{\"command\":\"echo ROOT=/ > $CRUX_SCOPES_DIR/acme/config\"}"
  assert_stops "CRUX_SCOPE on a command" "decides which scope" $s "$c" Bash '{"command":"CRUX_SCOPE=own crux status"}'
  assert_stops "exporting it" "" $s "$c" Bash '{"command":"export CRUX_SCOPES_DIR=/tmp/none"}'
  assert_stops "entering another scope" "and this line enters" $s "$c" Bash '{"command":"crux scope enter own"}'
  assert_stops "asking for every scope's tasks" "for the person" $s "$c" Bash '{"command":"crux task list --all"}'
  assert_eq "acme" "$(cat "$CRUX_STATE_DIR/scope-pins/in-acme")" "and the pin is still where it was"
}

test_the_front_desk_enters_one_scope_and_stays() {
  wall_setup
  local s=desk c="$SB/desk"
  session_start $s "$c" >/dev/null
  assert_lets "outside every root, nothing to stop" $s "$c" Bash '{"command":"ls /tmp"}'
  assert_stops "touching a scope from the desk" "crux scope enter acme" $s "$c" Read "{\"file_path\":\"$ACME/web/api/x\"}"
  assert_no_file "$CRUX_STATE_DIR/scope-pins/desk" "nothing is pinned by being stopped"
  assert_lets "entering it" $s "$c" Bash '{"command":"crux scope enter acme"}'
  assert_eq "acme" "$(cat "$CRUX_STATE_DIR/scope-pins/desk")" "pins the session"
  assert_lets "then the scope is open" $s "$c" Read "{\"file_path\":\"$ACME/web/api/x\"}"
  assert_stops "and the other one closed" "" $s "$c" Read "{\"file_path\":\"$OWN/alpha/.env\"}"
  assert_stops "for good" "and this line enters" $s "$c" Bash '{"command":"crux scope enter own"}'
  assert_stops "a command over two scopes from the desk" "" desk2 "$c" Bash "{\"command\":\"diff $ACME/web/x $OWN/alpha/x\"}"
}

test_an_isolated_project_is_walled_inside_its_own_scope() {
  wall_setup
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init client --no-remote --profile client-repo >/dev/null 2>&1
  mkdir -p "$OWN/client/app"
  local out; out="$(session_start in-client "$OWN/client/app")"
  assert_eq "own/client" "$(cat "$CRUX_STATE_DIR/scope-pins/in-client")" "a client's project pins the session to itself"
  assert_contains "$out" "isolated project 'client'" "and says so"
  assert_lets "its own folder is open" in-client "$OWN/client/app" Read "{\"file_path\":\"$OWN/client/app/x\"}"
  assert_stops "another project of the same scope is not" "isolated project 'client'" in-client "$OWN/client/app" Read "{\"file_path\":\"$OWN/alpha/.env\"}"
  session_start in-alpha "$OWN/alpha" >/dev/null
  assert_stops "and from the rest of the scope it is closed" "isolated project 'client'" in-alpha "$OWN/alpha" Read "{\"file_path\":\"$OWN/client/app/x\"}"
  assert_lets "while the scope's other projects stay open" in-alpha "$OWN/alpha" Read "{\"file_path\":\"$OWN/alpha/.env\"}"
}

test_private_notes_of_the_profile_stay_where_the_full_profile_applies() {
  wall_setup
  local dir="$OWN/agent-profile"
  mkdir -p "$dir/preferences" "$dir/about"
  printf -- '---\n---\n\n# Profile\n\n- [Short](preferences/short.md)\n- [Jobs](about/jobs.md)\n' > "$dir/PROFILE.md"
  printf 'Short answers.\n' > "$dir/preferences/short.md"
  printf 'Interviewing.\n' > "$dir/about/jobs.md"
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init client --no-remote --profile client-repo >/dev/null 2>&1
  mkdir -p "$OWN/client/app"

  assert_lets "a shared note from another scope" in-acme "$ACME/web" Read "{\"file_path\":\"$dir/preferences/short.md\"}"
  assert_stops "a private one" "private to" in-acme "$ACME/web" Read "{\"file_path\":\"$dir/about/jobs.md\"}"
  session_start in-client "$OWN/client/app" >/dev/null
  assert_stops "nor from a client's project of the person's own scope" "private to" in-client "$OWN/client/app" Read "{\"file_path\":\"$dir/about/jobs.md\"}"
  local out; out="$(session_start in-alpha "$OWN/alpha")"
  assert_contains "$out" "about/jobs.md" "the person's own projects get the full index"
  assert_lets "and may read every note" in-alpha "$OWN/alpha" Read "{\"file_path\":\"$dir/about/jobs.md\"}"
  out="$(session_start in-client2 "$OWN/client/app")"
  assert_not_contains "$out" "about/jobs.md" "a client's project does not get it"
}

test_other_sessions_conversations_stay_in_their_scope() {
  wall_setup
  local enc; enc="$(printf '%s' "$OWN" | tr '/.' '--')"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$enc" "$CLAUDE_CONFIG_DIR/projects/-desk"
  printf '{}\n' > "$CLAUDE_CONFIG_DIR/projects/$enc/old.jsonl"
  printf '{}\n' > "$CLAUDE_CONFIG_DIR/projects/-desk/in-acme.jsonl"
  printf '{}\n' > "$CLAUDE_CONFIG_DIR/projects/-desk/someone.jsonl"
  assert_stops "a transcript of the other scope's root" "" in-acme "$ACME/web" Read "{\"file_path\":\"$CLAUDE_CONFIG_DIR/projects/$enc/old.jsonl\"}"
  assert_lets "its own transcript" in-acme "$ACME/web" Read "{\"file_path\":\"$CLAUDE_CONFIG_DIR/projects/-desk/in-acme.jsonl\"}"
  assert_stops "a front-desk session it cannot place" "other sessions" desk3 "$SB/desk" Read "{\"file_path\":\"$CLAUDE_CONFIG_DIR/projects/-desk/someone.jsonl\"}"
}

test_a_worktree_outside_every_root_is_walled_with_its_scope() {
  wall_setup
  git init -q "$ACME/web/api"
  git -C "$ACME/web/api" commit -q --allow-empty -m init
  git -C "$ACME/web/api" worktree add -q "$SB/elsewhere/api-wt" -b wt 2>/dev/null
  session_start in-own "$OWN/alpha" >/dev/null
  assert_stops "from another scope it is closed" "scope 'acme'" in-own "$OWN/alpha" Read "{\"file_path\":\"$SB/elsewhere/api-wt/x\"}"
  assert_lets "from its own it is open" in-acme "$ACME/web" Read "{\"file_path\":\"$SB/elsewhere/api-wt/x\"}"
}

test_scopes_that_cannot_be_read_stop_every_tool_call() {
  wall_setup
  printf 'ENFORCE="nope"\n' >> "$CRUX_SCOPES_DIR/acme/config"
  assert_stops "it fails closed" "cannot be read" in-acme "$ACME/web" Read "{\"file_path\":\"$ACME/web/x\"}"
}

test_a_session_already_open_in_a_root_is_pinned_by_its_first_tool_call() {
  wall_setup
  assert_lets "its own scope" old-session "$OWN/alpha" Read "{\"file_path\":\"$OWN/alpha/.env\"}"
  assert_eq "own" "$(cat "$CRUX_STATE_DIR/scope-pins/old-session")" "it is pinned where it stands"
  assert_stops "and walled from then on" "" old-session "$OWN/alpha" Read "{\"file_path\":\"$ACME/web/x\"}"
}

# --- Applying the scopes to the machine -----------------------------------------

test_each_scope_commits_with_its_own_identity() {
  sandbox >/dev/null
  two_scopes
  git init -q "$ACME/api"; git init -q "$OWN/blog"
  local gc="$SB/gitconfig"; printf '[core]\n\tautocrlf = false\n' > "$gc"
  GIT_CONFIG_GLOBAL="$gc" crux scope apply >/dev/null 2>&1
  GIT_CONFIG_GLOBAL="$gc" crux scope apply >/dev/null 2>&1
  assert_eq "1" "$(grep -c 'crux:scopes:begin' "$gc")" "applying twice leaves one block"
  assert_contains "$(cat "$gc")" "autocrlf" "and what the person had stays"
  assert_eq "me@acme.test" "$(GIT_CONFIG_GLOBAL="$gc" git -C "$ACME/api" config user.email)" \
    "a repo of the company scope commits with its email"
  assert_eq "" "$(GIT_CONFIG_GLOBAL="$gc" git -C "$OWN/blog" config user.email)" \
    "and one of the person's own scope does not get it"
}

test_a_scope_key_is_offered_only_from_inside_the_scope() {
  needs ssh || return 0
  sandbox >/dev/null
  two_scopes
  mkdir -p "$SB/.ssh/acme" "$ACME/api" "$OWN/blog"
  printf 'k\n' > "$SB/.ssh/acme/git.acme.test"
  local cfg="$SB/.ssh/config"
  printf 'Host *\n  ServerAliveInterval 60\n' > "$cfg"
  HOME="$SB" CRUX_SSH_CONFIG="$cfg" crux scope apply >/dev/null 2>&1
  assert_contains "$(head -1 "$cfg")" "crux:scopes:begin" "the block goes before any Host *"
  local from_acme from_own
  from_acme="$(cd "$ACME/api" && HOME="$SB" ssh -G -F "$cfg" git.acme.test 2>/dev/null | grep -i '^identityfile')"
  from_own="$(cd "$OWN/blog" && HOME="$SB" ssh -G -F "$cfg" git.acme.test 2>/dev/null | grep -i '^identityfile')"
  # ssh -G prints the IdentityFile before expanding %h.
  assert_contains "$from_acme" "/.ssh/acme/%h" "from the company scope its key is offered"
  assert_not_contains "$from_own" "/.ssh/acme/" "from any other folder it is not"
}

test_a_sandboxed_scope_writes_the_agents_sandbox_into_its_repos() {
  sandbox >/dev/null
  two_scopes
  printf 'ENFORCE="sandbox"\nSECRETS="%s"\n' "$SB/keys/acme" >> "$CRUX_SCOPES_DIR/acme/config"
  mkdir -p "$ACME/web"; git init -q "$ACME/web/api"; git init -q "$OWN/blog"
  crux scope apply >/dev/null 2>&1
  local f="$ACME/web/api/.claude/settings.local.json"
  assert_file "$f" "the repo gets the agent's local settings"
  assert_eq "true" "$(json_get "$f" sandbox.enabled)" "with the sandbox on"
  assert_eq "false" "$(json_get "$f" sandbox.allowUnsandboxedCommands)" "and no way around it"
  assert_contains "$(json_get "$f" sandbox.filesystem.denyRead)" "$OWN" "the other scope's root out of reach"
  assert_not_contains "$(json_get "$f" sandbox.filesystem.denyRead)" "$SB/keys/acme" "its own secrets are not denied to it"
  assert_contains "$(git -C "$ACME/web/api" status --porcelain --ignored)" "!! .claude/" "and the file is excluded from git"
  assert_no_file "$OWN/blog/.claude/settings.local.json" "a scope on the guard alone gets nothing written"
}

test_a_project_moves_to_another_scope_with_its_tasks() {
  sandbox >/dev/null
  two_scopes
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init shop --no-remote >/dev/null 2>&1
  in_dir "$OWN/shop" "$CRUX_HOME/bin/crux" task new shop/checkout --goal "x" >/dev/null 2>&1
  local machine; machine="$(dirname "$CRUX_REGISTRY")/tasks"
  assert_file "$machine/shop/checkout.md" "the task starts in the person's own scope"
  mkdir -p "$OWN/shop-ws-old"
  assert_contains "$(crux scope move shop acme 2>&1)" "has workspaces open" "refused while a workspace is open"
  rmdir "$OWN/shop-ws-old"
  crux scope move shop acme >/dev/null 2>&1
  assert_file "$ACME/shop/shop-docs/crux.json" "the project is now in the other root"
  assert_no_file "$OWN/shop" "and nothing is left behind"
  assert_file "$CRUX_SCOPES_DIR/acme/tasks/shop/checkout.md" "its tasks went with it"
  assert_eq "acme" "$(crux scope of "$ACME/shop")" "and it belongs to the new scope"
}

test_sync_goes_through_every_scope() {
  sandbox >/dev/null
  two_scopes
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init alpha --no-remote >/dev/null 2>&1
  in_dir "$ACME" "$CRUX_HOME/bin/crux" init web --no-remote >/dev/null 2>&1
  local out; out="$(in_dir "$OWN" "$CRUX_HOME/bin/crux" sync 2>&1)"
  assert_contains "$out" "$OWN" "the scope it runs from"
  assert_contains "$out" "$ACME" "and every other one"
}

test_what_is_only_written_about_does_not_move_the_wall() {
  wall_setup
  local s=desk4 c="$SB/desk"
  assert_lets "an echo that names the command" $s "$c" Bash '{"command":"echo \"run crux scope enter own to start\""}'
  assert_no_file "$CRUX_STATE_DIR/scope-pins/desk4" "pins nothing"
  assert_lets "entering with the name quoted" $s "$c" Bash '{"command":"crux scope enter \"acme\""}'
  assert_eq "acme" "$(cat "$CRUX_STATE_DIR/scope-pins/desk4")" "still pins"
  assert_lets "a commit message that names a variable" in-acme "$ACME/web" Bash "{\"command\":\"git commit -m \\\"docs: explain CRUX_SCOPE=own\\\"\"}"
  assert_stops "a quoted remote of another scope is still a remote" "owner of scope 'own'" in-acme "$ACME/web" Bash '{"command":"git clone \"https://github.com/me/blog\""}'
  assert_stops "a Glob pattern over another scope" "" in-acme "$ACME/web" Glob "{\"pattern\":\"$OWN/**/*.env\"}"
}

test_scope_check_finds_what_lives_in_the_wrong_scope() {
  sandbox >/dev/null
  two_scopes
  printf 'GIT_EMAIL="me@own.test"\nOWNERS="me"\n' >> "$CRUX_SCOPES_DIR/own/config"
  mkdir -p "$OWN/shop"
  git init -q "$OWN/shop/api"
  git -C "$OWN/shop/api" remote add origin git@github.com:acme/api.git
  local out rc=0; out="$(crux scope check 2>&1)" || rc=$?
  assert_eq 1 "$rc" "a repo of the person's scope pushing to the company's owner fails the check"
  assert_contains "$out" "crux scope move shop acme" "and says how to fix it"
  git -C "$OWN/shop/api" remote set-url origin git@github.com:me/api.git
  git init -q "$ACME/web"
  GIT_AUTHOR_EMAIL=me@own.test git -C "$ACME/web" commit -q --allow-empty -m "x"
  rc=0; out="$(crux scope check 2>&1)" || rc=$?
  assert_eq 0 "$rc" "commits with the wrong email do not fail it"
  assert_contains "$out" "the email of scope 'own'" "but they are named"
}

test_each_scope_has_its_browser_profile_and_the_others_are_closed() {
  wall_setup
  mkdir -p "$SB/chrome/Own" "$SB/chrome/Acme"
  printf 'BROWSER_PROFILE="%s"\n' "$SB/chrome/Own" >> "$CRUX_SCOPES_DIR/own/config"
  printf 'BROWSER_PROFILE="%s"\n' "$SB/chrome/Acme" >> "$CRUX_SCOPES_DIR/acme/config"
  assert_eq "$SB/chrome/Acme" "$(in_dir "$ACME/web" "$CRUX_HOME/bin/crux" __fn scope_browser_profile)" \
    "the browser skill gets its scope's profile"
  assert_stops "copying another scope's profile" "scope 'own'" in-acme "$ACME/web" Bash "{\"command\":\"cp -R $SB/chrome/Own /tmp/cdp\"}"
  assert_lets "copying its own" in-acme "$ACME/web" Bash "{\"command\":\"cp -R $SB/chrome/Acme /tmp/cdp\"}"
  printf 'BROWSER_PROFILE="%s"\n' "$SB/chrome/Own" >> "$CRUX_SCOPES_DIR/acme/config"
  assert_contains "$(crux scope check 2>&1)" "share one browser profile" "two scopes cannot share one"
}

test_a_session_entered_from_the_front_desk_runs_crux_inside_its_scope() {
  wall_setup
  local s=desk5 c="$SB/desk"
  session_start $s "$c" >/dev/null
  guard $s "$c" Bash '{"command":"crux scope enter acme"}' >/dev/null
  assert_stops "a task created from the desk folder" "Run it from inside: \`cd $ACME" $s "$c" Bash '{"command":"crux task new web/login"}'
  assert_lets "from inside its root" $s "$c" Bash "{\"command\":\"cd $ACME/web && crux task new web/login\"}"
  assert_lets "commands that do not depend on the folder" $s "$c" Bash '{"command":"crux scope show"}'
}

# --- What the independent review found (each line is one way through) ----------

test_the_review_bypasses_are_closed() {
  wall_setup
  local s=in-acme c="$ACME/web"
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init client --no-remote --profile client-repo >/dev/null 2>&1
  mkdir -p "$OWN/client/app" "$OWN/agent-profile/about" "$OWN/agent-profile/preferences"
  printf -- '---\n---\n- [Jobs](about/jobs.md)\n' > "$OWN/agent-profile/PROFILE.md"
  printf 'Interviewing.\n' > "$OWN/agent-profile/about/jobs.md"
  printf 'Short answers.\n' > "$OWN/agent-profile/preferences/short.md"
  assert_stops "1: entering its own scope does not open the rest of the line" "" $s "$c" Bash "{\"command\":\"crux scope enter acme; cat $OWN/alpha/.env\"}"
  assert_stops "2: walking there with bare cds" "" $s "$c" Bash '{"command":"cd .. && cd .. && cd Own && grep -r secret ."}'
  assert_stops "2: a search with no path from a foreign folder" "" $s "$OWN/alpha" Grep '{"pattern":"secret"}'
  assert_stops "3: a recursive read of a folder that holds another scope" "reading it whole" $s "$c" Bash "{\"command\":\"grep -r token $SB\"}"
  assert_lets "3: a plain listing of it is not a tree read" $s "$c" Bash "{\"command\":\"ls $SB\"}"
  assert_stops "4: the whole transcripts folder" "" $s "$c" Bash "{\"command\":\"grep -r secret $CLAUDE_CONFIG_DIR/projects\"}"
  session_start in-client "$OWN/client/app" >/dev/null
  assert_stops "6: an isolated project reading its scope's root whole" "reading it whole" in-client "$OWN/client/app" Bash "{\"command\":\"grep -r . $OWN\"}"
  assert_stops "7: a private part of the profile that is not a note" "" $s "$c" Bash "{\"command\":\"grep -r . $OWN/agent-profile/about\"}"
  assert_stops "7: the full index is private too" "" $s "$c" Read "{\"file_path\":\"$OWN/agent-profile/PROFILE.md\"}"
  assert_stops "7: the profile is not written from another scope" "not written from" $s "$c" Write "{\"file_path\":\"$OWN/agent-profile/preferences/new.md\",\"content\":\"x\"}"
  assert_stops "8: moving a project between scopes is the person's" "the person runs it themselves" $s "$c" Bash '{"command":"crux scope move alpha acme"}'
  assert_stops "8: reading another scope's declaration" "is not this session's" $s "$c" Bash '{"command":"crux scope show own"}'
  assert_stops "8: entering another scope through a path to crux" "and this line enters" $s "$c" Bash '{"command":"/usr/local/bin/crux scope enter own"}'
  assert_stops "8: or through env" "and this line enters" $s "$c" Bash '{"command":"env crux scope enter own"}'
  assert_stops "8: or through env named by its path" "and this line enters" $s "$c" Bash '{"command":"/usr/bin/env crux scope enter own"}'
  assert_stops "9: the variable set inside quotes" "decides which scope" $s "$c" Bash '{"command":"env \"CRUX_SCOPE=own\" crux task list"}'
  assert_stops "10: gh with the owner as a bare argument" "owner of scope 'own'" $s "$c" Bash '{"command":"gh repo list me"}'
  assert_stops "10: gh api with the owner in the path" "" $s "$c" Bash '{"command":"gh api repos/me/blog/contents/x"}'
  assert_stops "11: a connector with a path into another scope" "" $s "$c" mcp__fs__read_file "{\"path\":\"$OWN/alpha/.env\"}"
}

test_review_findings_outside_the_wall() {
  sandbox >/dev/null
  two_scopes
  mkdir -p "$ACME/web" "$OWN/web"
  assert_contains "$(crux scope open --project web 2>&1)" "is in several scopes" "14: a project name in two scopes is said, not guessed"
  printf 'SECRETS="keys/acme"\n' >> "$CRUX_SCOPES_DIR/acme/config"
  assert_contains "$(crux scope check 2>&1)" "must be an absolute path" "18: a relative secret is refused"
  two_scopes
  printf 'ENFORCE="sandbox"\nGH_CONFIG_DIR="%s/gh dir"\n' "$SB" >> "$CRUX_SCOPES_DIR/acme/config"
  mkdir -p "$ACME/web"; git init -q "$ACME/web/api"
  local gc="$SB/gitconfig"; : > "$gc"
  GIT_CONFIG_GLOBAL="$gc" crux scope apply >/dev/null 2>&1
  assert_contains "$(cat "$CRUX_SCOPES_DIR/acme/gitconfig")" "GH_CONFIG_DIR='$SB/gh dir'" "16: a gh folder with a space is quoted"
  assert_contains "$(json_get "$ACME/web/api/.claude/settings.local.json" sandbox.filesystem.denyRead)" "/projects" "17: the sandbox also denies the transcripts"
  printf 'ROOT="%s"\nREMOTE="git@github.com:acme/{repo}.git"\n' "$ACME" > "$CRUX_SCOPES_DIR/acme/config"
  GIT_CONFIG_GLOBAL="$gc" crux scope apply >/dev/null 2>&1
  assert_eq "" "$(json_get "$ACME/web/api/.claude/settings.local.json" sandbox 2>/dev/null)" "15: going back to the guard takes the sandbox out"
  rm -rf "$CRUX_SCOPES_DIR"
  GIT_CONFIG_GLOBAL="$gc" CRUX_PROJECTS_DIR="$SB" crux scope apply >/dev/null 2>&1
  assert_not_contains "$(cat "$gc")" "crux:scopes" "15: without scopes the git block is gone"
  two_scopes
  assert_contains "$(CRUX_UNPINNED_SESSIONS=nope crux status 2>&1)" "no scope 'nope'" "20: an unknown scope name stops the command"
}

test_an_isolated_project_session_gets_only_its_tasks() {
  wall_setup
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init client --no-remote --profile client-repo >/dev/null 2>&1
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init alpha2 --no-remote >/dev/null 2>&1
  mkdir -p "$OWN/client/app"
  in_dir "$OWN/alpha2" "$CRUX_HOME/bin/crux" task new alpha2/secret-plan --goal "x" >/dev/null 2>&1
  local out agent; out="$(session_start in-client9 "$OWN/client/app")"
  agent="$(printf '%s' "$out" | "$CRUX_BIN" __fn json_get /dev/stdin hookSpecificOutput.additionalContext 2>/dev/null)"
  assert_not_contains "$agent" "secret-plan" "13: the rest of its scope's tasks stay out"
}

test_the_second_review_is_closed_too() {
  wall_setup
  local s=in-acme c="$ACME/web"
  mkdir -p "$OWN/agent-profile/preferences"
  printf -- '---\n---\n' > "$OWN/agent-profile/PROFILE.md"
  printf 'Short answers.\n' > "$OWN/agent-profile/preferences/short.md"
  assert_stops "1: entering another scope behind nice -n" "and this line enters" $s "$c" Bash '{"command":"nice -n 10 crux scope enter own"}'
  assert_stops "1: behind sudo -u" "" $s "$c" Bash '{"command":"sudo -u root crux scope enter own"}'
  assert_stops "1: inside bash -c" "" $s "$c" Bash "{\"command\":\"bash -c 'crux scope enter own'\"}"
  assert_stops "9: a variable set inside bash -c" "decides which scope" $s "$c" Bash "{\"command\":\"bash -c 'CRUX_SCOPE=own crux task list'\"}"
  assert_lets "2: reading a shared note of the profile from the shell" $s "$c" Bash "{\"command\":\"cat $OWN/agent-profile/preferences/short.md\"}"
  assert_stops "2: but not writing it" "not written from" $s "$c" Bash "{\"command\":\"echo x > $OWN/agent-profile/preferences/short.md\"}"
  assert_lets "4: a commit message that names another scope's path" $s "$c" Bash "{\"command\":\"git commit -m \\\"docs: mention $OWN/alpha\\\"\"}"
  assert_stops "3: a shell glob across scopes" "" $s "$c" Bash "{\"command\":\"cat $SB/*/alpha/.env\"}"
  assert_stops "10: the API host with another scope's owner" "owner of scope 'own'" $s "$c" Bash '{"command":"curl https://api.github.com/repos/me/blog/contents/x"}'
  assert_lets "10: an owner that only starts the same" $s "$c" Bash '{"command":"gh api repos/meteo/x"}'
}

test_apply_without_scopes_leaves_files_that_never_had_the_block_alone() {
  sandbox >/dev/null
  local gc="$SB/gitconfig"; printf '[user]\n\tname = me\n' > "$gc"
  local before; before="$(cksum < "$gc")"
  GIT_CONFIG_GLOBAL="$gc" crux scope apply >/dev/null 2>&1
  GIT_CONFIG_GLOBAL="$gc" crux scope apply >/dev/null 2>&1
  assert_eq "$before" "$(cksum < "$gc")" "5: byte for byte as it was"
}

test_the_final_audit_is_closed() {
  wall_setup
  local s=in-acme c="$ACME/web"
  assert_stops "1: removing the folder that holds the pins" "holds up the scope wall" $s "$c" Bash "{\"command\":\"rm -rf $CRUX_STATE_DIR\"}"
  assert_stops "1: moving the scopes away" "holds up the scope wall" $s "$c" Bash "{\"command\":\"mv $CRUX_SCOPES_DIR $SB/elsewhere\"}"
  assert_stops "2: writing the guard's own script" "holds up the scope wall" $s "$c" Write "{\"file_path\":\"$CRUX_HOME/adapters/claude/hooks/scope-guard.sh\",\"content\":\"exit 0\"}"
  assert_stops "2: writing the repo's agent settings" "holds up the scope wall" $s "$c" Write "{\"file_path\":\"$ACME/web/.claude/settings.local.json\",\"content\":\"{}\"}"
  assert_lets "2: reading crux's own files is fine" $s "$c" Read "{\"file_path\":\"$CRUX_HOME/STANDARD.md\"}"
  assert_stops "4: a tree that holds another scope's secret" "reading it whole" $s "$c" Bash "{\"command\":\"tar czf /tmp/k.tgz $SB/keys\"}"
  assert_stops "bash -lc" "" $s "$c" Bash "{\"command\":\"bash -lc 'cat $OWN/alpha/.env'\"}"
  assert_stops "eval" "" $s "$c" Bash "{\"command\":\"eval cat $OWN/alpha/.env\"}"
  assert_stops "an assignment that names a path" "" $s "$c" Bash "{\"command\":\"F=$OWN/alpha/.env cat \\\"\$F\\\"\"}"
  assert_stops "a redirection of stderr" "" $s "$c" Bash "{\"command\":\"echo x 2>$OWN/alpha/f\"}"
  assert_lets "FS1: a tree read of an own folder from an unrelated cwd" $s "$HOME" Bash "{\"command\":\"rg token $ACME/web\"}"
  assert_lets "FS5: a commit message that cites another scope's repo" $s "$c" Bash '{"command":"git commit -m \"port from github.com/me/x\""}'
  mkdir -p "$CRUX_SCOPES_DIR/acme/tasks/web"; printf 'x\n' > "$CRUX_SCOPES_DIR/acme/tasks/web/t.md"
  assert_lets "FS6: the scope's own tasks are readable" $s "$c" Read "{\"file_path\":\"$CRUX_SCOPES_DIR/acme/tasks/web/t.md\"}"
}

test_a_stopped_call_pins_nothing() {
  wall_setup
  local s=desk7 c="$SB/desk"
  assert_stops "entering and crossing on one line" "" $s "$c" Bash "{\"command\":\"crux scope enter acme; cat $OWN/alpha/.env\"}"
  assert_no_file "$CRUX_STATE_DIR/scope-pins/desk7" "the session is left where it was"
}

test_a_pinned_session_whose_scopes_are_gone_is_stopped() {
  wall_setup
  rm -rf "$CRUX_SCOPES_DIR"
  assert_stops "it fails closed" "scopes are gone" in-acme "$ACME/web" Read "{\"file_path\":\"$ACME/web/x\"}"
}

test_a_broken_contract_isolates_its_project() {
  wall_setup
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init client --no-remote >/dev/null 2>&1
  printf '{ broken <<<<<<< HEAD\n' > "$OWN/client/client-docs/crux.json"
  session_start in-own2 "$OWN/alpha" >/dev/null
  assert_stops "a half-merged contract fails closed" "isolated project 'client'" in-own2 "$OWN/alpha" Read "{\"file_path\":\"$OWN/client/x\"}"
}

test_one_scope_has_no_front_desk() {
  sandbox >/dev/null
  mkdir -p "$SB/Only/p" "$CRUX_SCOPES_DIR/only" "$SB/desk"
  printf 'ROOT="%s"\n' "$SB/Only" > "$CRUX_SCOPES_DIR/only/config"
  assert_lets "a session outside the root works in the only scope" single "$SB/desk" Read "{\"file_path\":\"$SB/Only/p/x\"}"
  assert_lets "and searches its home without the stores in the way" single "$SB/desk" Bash "{\"command\":\"grep -r hook $CLAUDE_CONFIG_DIR\"}"
}

test_the_third_audit_is_closed() {
  wall_setup
  local s=in-acme c="$ACME/web"
  mkdir -p "$ACME/web/pkg"; printf '{}\n' > "$ACME/web/pkg/package.json"
  assert_stops "1: &> into the pins" "holds up the scope wall" $s "$c" Bash "{\"command\":\"echo own &> $CRUX_STATE_DIR/scope-pins/in-acme\"}"
  assert_stops "1: >| into another scope" "" $s "$c" Bash "{\"command\":\"echo x >| $OWN/alpha/f\"}"
  assert_stops "1: >& into another scope" "" $s "$c" Bash "{\"command\":\"echo x >&$OWN/alpha/f\"}"
  assert_stops "1: running a script of another scope by its path" "" $s "$c" Bash "{\"command\":\"$OWN/alpha/run.sh\"}"
  assert_stops "2: a bare folder name from its parent" "" $s "$SB" Bash '{"command":"tar czf ./o.tgz Own"}'
  assert_stops "3: moving the folder that holds another root" "" $s "$c" Bash "{\"command\":\"mv $SB $SB-moved\"}"
  assert_stops "4: a line piped into a shell" "" $s "$c" Bash "{\"command\":\"echo 'cat $OWN/alpha/.env' | sh\"}"
  assert_stops "4: a heredoc fed to a shell" "" $s "$c" Bash "{\"command\":\"sh <<'EOF'\\ncat $OWN/alpha/.env\\nEOF\"}"
  assert_stops "4: command substitution" "" $s "$c" Bash "{\"command\":\"cat \\\"\$(echo $OWN/alpha/.env)\\\"\"}"
  assert_stops "4: xargs" "" $s "$c" Bash "{\"command\":\"echo $OWN/alpha/.env | xargs cat\"}"
  assert_stops "5: searching the whole profile from another scope" "person's own scope" $s "$c" Bash '{"command":"crux memory search salary"}'
  assert_stops "5: the machine-wide sync from another scope" "" $s "$c" Bash '{"command":"crux sync"}'
  assert_stops "6: a symlink to another scope" "" $s "$c" Bash "{\"command\":\"ln -s $OWN web/l\"}"
  assert_stops "6: a relative symlink resolved from its folder" "" $s "$c" Bash '{"command":"ln -s ../../Own web/l"}'
  assert_stops "7: braces" "" $s "$c" Bash "{\"command\":\"cat $SB/{Own,Acme}/alpha/.env\"}"
  assert_lets "a glob of the own folder" $s "$c" Bash '{"command":"ls */package.json"}'
  assert_lets "an ordinary command in the own folder" $s "$c" Bash '{"command":"pnpm install && pnpm test 2>&1 | tail -5"}'
  assert_stops "front desk: a folder-bound crux command" "enter one first" desk8 "$SB/desk" Bash '{"command":"crux task show web/login"}'
}

test_the_last_review_is_closed() {
  wall_setup
  local s=in-acme c="$ACME/web"
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init cliente --no-remote --profile client-repo >/dev/null 2>&1
  in_dir "$OWN" "$CRUX_HOME/bin/crux" init other --no-remote >/dev/null 2>&1
  mkdir -p "$OWN/cliente/app"
  in_dir "$OWN/other" "$CRUX_HOME/bin/crux" task new other/plan --goal "x" >/dev/null 2>&1
  local machine; machine="$(dirname "$CRUX_REGISTRY")/tasks"
  assert_stops "1: reading another scope's config" "" $s "$c" Bash "{\"command\":\"cat $CRUX_SCOPES_DIR/own/config\"}"
  assert_stops "1: a glob over every scope's tasks" "" $s "$c" Bash "{\"command\":\"cat $CRUX_SCOPES_DIR/*/tasks/*/*.md\"}"
  session_start in-cliente "$OWN/cliente/app" >/dev/null
  assert_stops "2: an isolated project reading its neighbour's tasks" "" in-cliente "$OWN/cliente/app" Read "{\"file_path\":\"$machine/other/plan.md\"}"
  assert_stops "3: cd with an option" "" $s "$c" Bash '{"command":"cd -P .. && cd .. && cat Own/alpha/.env"}'
  assert_stops "3: pushd" "" $s "$c" Bash '{"command":"pushd .. && pushd .. && cat Own/alpha/.env"}'
  assert_stops "3: a folder through a variable" "cannot follow" $s "$c" Bash '{"command":"cd $SOMEWHERE && cat alpha/.env"}'
  assert_stops "4: the pins through a shell, by text" "" $s "$c" Bash "{\"command\":\"echo 'echo own > $CRUX_STATE_DIR/scope-pins/in-acme' | sh\"}"
  assert_stops "4: quotes inside the path" "" $s "$c" Bash "{\"command\":\"echo 'cat \\\"$SB\\\"/Own/alpha/.env' | sh\"}"
  assert_lets "7: a commit message in a heredoc that cites another root" $s "$c" Bash "{\"command\":\"git commit -m \\\"\$(cat <<'EOF'\\nfix: see $OWN/alpha\\nEOF\\n)\\\"\"}"
  assert_lets "7: the repo's versioned agent settings are project content" $s "$c" Write "{\"file_path\":\"$ACME/web/.claude/settings.json\",\"content\":\"{}\"}"
  session_start in-own3 "$OWN" >/dev/null
  assert_lets "7: copying a file into a root that holds an isolated project" in-own3 "$OWN" Bash '{"command":"cp /tmp/f.pdf ."}'
  assert_lets "9: gh with a label that is another scope's owner" $s "$c" Bash '{"command":"gh pr create --label me --title x"}'
  assert_stops "9: gh repo list of another scope's owner" "" $s "$c" Bash '{"command":"gh repo list me"}'
}

test_the_front_desk_can_note_in_the_profile() {
  wall_setup
  local dir="$OWN/agent-profile"
  mkdir -p "$dir/preferences" "$dir/about"; git init -q "$dir"
  printf -- '---\n---\n- [Jobs](about/jobs.md)\n' > "$dir/PROFILE.md"
  printf 'Interviewing.\n' > "$dir/about/jobs.md"
  session_start desk9 "$SB/desk" >/dev/null
  assert_lets "5: writing a note from the desk" desk9 "$SB/desk" Write "{\"file_path\":\"$dir/preferences/new.md\",\"content\":\"x\"}"
  assert_lets "5: adding its line to the index" desk9 "$SB/desk" Bash "{\"command\":\"echo '- [New](preferences/new.md)' >> $dir/PROFILE.md\"}"
  assert_lets "5: committing it" desk9 "$SB/desk" Bash "{\"command\":\"cd $dir && git add -A && git commit -qm x\"}"
  assert_stops "5: but not reading a private note" "private to" desk9 "$SB/desk" Read "{\"file_path\":\"$dir/about/jobs.md\"}"
  local enc; enc="$(printf '%s' "$SB/desk" | tr -c 'A-Za-z0-9' '-')"
  assert_lets "7: the session's own automatic memory" desk9 "$SB/desk" Write "{\"file_path\":\"$CLAUDE_CONFIG_DIR/projects/$enc/memory/x.md\",\"content\":\"x\"}"
}
