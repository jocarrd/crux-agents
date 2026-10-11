#!/usr/bin/env bash

# The person's profile (ADR-018): created, loaded into each agent, counted by
# memory and searched.

profile_here() {
  # profile_here [reminder] — a minimal profile in the sandbox, no remote.
  local dir="$CRUX_PROJECTS_DIR/agent-profile"
  mkdir -p "$dir/preferences" "$dir/about" "$dir/machines"
  {
    echo "---"
    [[ -n "${1:-}" ]] && echo "reminder: $1"
    echo "---"
    echo
    echo "# Profile"
    echo
    echo "Speak plainly. Index of preferences below."
  } > "$dir/PROFILE.md"
  echo "$dir"
}

claude_md() { echo "$CLAUDE_CONFIG_DIR/CLAUDE.md"; }

test_profile_init_creates_it_and_loads_it_into_claude() {
  sandbox >/dev/null
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf 'My own line\n' > "$(claude_md)"

  local out; out="$(bash "$CRUX_HOME/bin/profile.sh" init --no-remote 2>&1)"
  local dir="$CRUX_PROJECTS_DIR/agent-profile"
  assert_file "$dir/PROFILE.md" "creates the index"
  assert_file "$dir/README.md" "and says what goes where"
  assert_contains "$(git -C "$dir" log --oneline 2>&1)" "skeleton" "starts it as a repo with a first commit"
  assert_contains "$(cat "$(claude_md)")" "@$dir/PROFILE.md" "Claude imports the index"
  assert_eq "<!-- crux:profile:begin -->" "$(head -1 "$(claude_md)")" "the block goes at the top"
  assert_contains "$(cat "$(claude_md)")" "My own line" "what the person wrote stays"
  assert_not_contains "$out" "error" "without errors"
}

test_profile_link_is_idempotent_and_brings_the_machine_note() {
  sandbox >/dev/null
  local dir; dir="$(profile_here)"
  local host; host="$(hostname 2>/dev/null || uname -n)"
  printf -- '---\ntype: machine\n---\n\nThis laptop has little disk.\n' > "$dir/machines/$host.md"

  bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1
  bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1
  assert_eq "1" "$(grep -c 'crux:profile:begin' "$(claude_md)")" "linking twice leaves one block"
  assert_contains "$(cat "$(claude_md)")" "@$dir/machines/$host.md" "and imports this machine's note"
}

test_profile_link_copies_the_index_for_codex() {
  sandbox >/dev/null
  local dir; dir="$(profile_here "Be brief.")"
  mkdir -p "$CODEX_HOME_DIR"
  printf 'codex notes of my own\n' > "$CODEX_HOME_DIR/AGENTS.md"

  bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1
  local agents; agents="$(cat "$CODEX_HOME_DIR/AGENTS.md")"
  assert_contains "$agents" "Speak plainly" "Codex has no imports: it gets the index itself"
  assert_not_contains "$agents" "reminder:" "without the frontmatter"
  assert_contains "$agents" "codex notes of my own" "and what was there stays"
}

test_profile_reminder_is_the_persons_and_only_if_set() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/claude/hooks/profile-reminder.sh"
  assert_eq "" "$(echo '{}' | bash "$hook")" "silent without a profile"
  profile_here >/dev/null
  assert_eq "" "$(echo '{}' | bash "$hook")" "silent with a profile that sets no reminder"
  rm -rf "$CRUX_PROJECTS_DIR/agent-profile"
  profile_here "Reply in Spanish, short notes included." >/dev/null
  assert_eq "Reply in Spanish, short notes included." "$(echo '{}' | bash "$hook")" \
    "repeats exactly the person's text"
}

test_memory_sends_personal_memories_to_the_profile() {
  sandbox >/dev/null
  new_project alpha >/dev/null
  profile_here >/dev/null
  local scope dir
  scope="$(printf '%s' "$CRUX_PROJECTS_DIR/alpha" | tr '/.' '-')"
  dir="$CLAUDE_CONFIG_DIR/projects/$scope/memory"
  mkdir -p "$dir"
  printf -- '---\nname: prefers-spanish\ndescription: x\nmetadata:\n  type: feedback\n---\nbody\n' > "$dir/prefers-spanish.md"

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "personal, not in the profile" "with a profile, a preference is no longer local by design"
  assert_contains "$out" "agent-profile/preferences" "and says where it goes"
  assert_exit 1 "--check fails while it is not moved" bash "$CRUX_HOME/bin/memory.sh" --check

  rm "$dir/prefers-spanish.md"
  out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "no personal memory outside the profile" "once moved, it says so"
}

test_memory_search_looks_in_the_profile_and_the_docs() {
  sandbox >/dev/null
  local docs; docs="$(new_project alpha)"
  local dir; dir="$(profile_here)"
  echo "The watermark goes big on everything shareable." > "$dir/preferences/watermark.md"
  echo "Deploys go through the watermark service." > "$docs/operations/deploy-notes.md"

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" search watermark 2>&1)"
  assert_contains "$out" "agent-profile/preferences/watermark.md" "finds it in the profile"
  assert_contains "$out" "alpha-docs/operations/deploy-notes.md" "and in the docs repos"
}

test_memory_ignores_folders_that_are_someone_elses() {
  sandbox >/dev/null
  profile_here >/dev/null
  local other="$SB/home/Desktop/Novel" scope dir
  scope="$(printf '%s' "$other" | tr '/.' '-')"
  dir="$CLAUDE_CONFIG_DIR/projects/$scope/memory"
  mkdir -p "$dir" "$SB/home/.crux"
  printf -- '---\nname: novel\ndescription: x\nmetadata:\n  type: project\n---\nbody\n' > "$dir/novel.md"
  assert_exit 1 "without the setting, another person's memory counts as a leak" \
    env HOME="$SB/home" bash "$CRUX_HOME/bin/memory.sh" --check
  echo "CRUX_MEMORY_IGNORE=\"$other\"" > "$SB/home/.crux/config"
  assert_exit 0 "with it, it is left out" env HOME="$SB/home" bash "$CRUX_HOME/bin/memory.sh" --check
  assert_contains "$(env HOME="$SB/home" bash "$CRUX_HOME/bin/memory.sh" 2>&1)" "ignored by CRUX_MEMORY_IGNORE" \
    "and says how many it left out"
}

test_profile_link_without_profile_removes_the_block() {
  sandbox >/dev/null
  profile_here >/dev/null
  bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1
  rm -rf "$CRUX_PROJECTS_DIR/agent-profile"
  assert_exit 1 "linking without a profile says so" bash "$CRUX_HOME/bin/profile.sh" link
  assert_not_contains "$(cat "$(claude_md)")" "crux:profile:begin" "and leaves no import pointing to nothing"
}

test_profile_status_survives_folders_that_git_did_not_bring() {
  sandbox >/dev/null
  local dir="$CRUX_PROJECTS_DIR/agent-profile"
  mkdir -p "$dir"
  printf -- '---\n---\n# P\n' > "$dir/PROFILE.md"
  local out; out="$(bash "$CRUX_HOME/bin/profile.sh" 2>&1)"
  assert_contains "$out" "machines: 0" "a cloned profile without its empty folders is still reported"
  bash "$CRUX_HOME/bin/profile.sh" init --no-remote >/dev/null 2>&1
  rm -rf "$dir"
  bash "$CRUX_HOME/bin/profile.sh" init --no-remote >/dev/null 2>&1
  assert_file "$dir/machines/.gitkeep" "and init leaves its folders tracked so they travel"
}

test_profile_two_machines_adding_a_preference_do_not_clash() {
  sandbox >/dev/null
  mkdir -p "$CLAUDE_CONFIG_DIR"
  # The profile on a remote, cloned here and on the other machine.
  local seed="$SB/seed" other="$SB/other" here="$CRUX_PROJECTS_DIR/agent-profile"
  git init -q --bare -b main "$SB/profile.git"
  git clone -q "$SB/profile.git" "$seed" 2>/dev/null
  printf -- '---\n---\n# Profile\n\n## Preferences\n\n- [One](preferences/one.md) — one\n' > "$seed/PROFILE.md"
  git -C "$seed" add -A && git -C "$seed" commit -qm "profile" && git -C "$seed" push -q origin main
  git clone -q "$SB/profile.git" "$here" && git clone -q "$SB/profile.git" "$other"
  bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1

  # Each one saves a preference at the end of the same section.
  printf -- '- [There](preferences/there.md) — there\n' >> "$other/PROFILE.md"
  git -C "$other" commit -qam "pref: there" && git -C "$other" push -q origin main
  printf -- '- [Here](preferences/here.md) — here\n' >> "$here/PROFILE.md"
  git -C "$here" commit -qam "pref: here"

  assert_exit 0 "joining both does not stop on a conflict" git -C "$here" pull -q --rebase origin main
  assert_contains "$(cat "$here/PROFILE.md")" "[There]" "the line from the other machine stays"
  assert_contains "$(cat "$here/PROFILE.md")" "[Here]" "and so does this one"
  assert_eq "" "$(git -C "$here" status --porcelain)" "and the repo is not left dirty"
}

test_profile_works_with_a_remote_that_is_not_github() {
  # Without gh, or with a remote outside GitHub, the profile goes where the
  # CRUX_REMOTE template says, like the projects crux init creates.
  sandbox >/dev/null
  local remotes="$SB/remotes" cfg="$SB/crux-config"
  mkdir -p "$remotes" && git init -q --bare -b main "$remotes/agent-profile.git"
  echo "CRUX_REMOTE=\"$remotes/{repo}.git\"" > "$cfg"

  local out; out="$(CRUX_CONFIG="$cfg" bash "$CRUX_HOME/bin/profile.sh" init 2>&1)"
  assert_not_contains "$out" "error" "init does not ask for gh"
  assert_contains "$(git -C "$remotes/agent-profile.git" log --oneline main 2>&1)" "skeleton" \
    "the profile reaches the remote of the template"

  rm -rf "$CRUX_PROJECTS_DIR/agent-profile"
  out="$(CRUX_CONFIG="$cfg" bash "$CRUX_HOME/bin/profile.sh" clone 2>&1)"
  assert_file "$CRUX_PROJECTS_DIR/agent-profile/PROFILE.md" "clone brings it back from that remote"
}
