#!/usr/bin/env bash

test_init_creates_a_conformant_structure() {
  sandbox >/dev/null
  local docs; docs="$(new_project alpha --repos "api,web")"

  for f in README.md AGENTS.md crux.json decisions/README.md decisions/index.md repos/README.md; do
    assert_file "$docs/$f" "mandatory structure"
  done
  assert_symlink "$docs/CLAUDE.md" "AGENTS.md" "CLAUDE.md links to AGENTS.md"
  assert_file "$docs/repos/api/README.md" "folder of the declared repo"
  assert_file "$docs/.gitignore" "gitignore materialized"

  assert_not_contains "$(cat "$docs/README.md")" "{{" "placeholders substituted"
  assert_not_contains "$(cat "$docs/AGENTS.md")" "{{" "placeholders substituted"

  assert_exit 0 "doctor passes on a freshly created project" \
    bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_init_is_deterministic() {
  sandbox >/dev/null
  local a b
  a="$(new_project one --repos "api")"
  b="$(new_project two --repos "api")"

  local diff_out
  diff_out="$(diff \
    <(cd "$a" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sort) \
    <(cd "$b" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sort) 2>&1)"
  assert_eq "" "$diff_out" "two inits produce the same file tree"
}

test_init_rejects_invalid_names() {
  sandbox >/dev/null
  assert_exit 1 "rejects CamelCase" \
    bash "$CRUX_HOME/bin/init.sh" MyProject --no-remote --parent "$CRUX_PROJECTS_DIR"
  assert_exit 1 "rejects a nonexistent profile" \
    bash "$CRUX_HOME/bin/init.sh" beta --no-remote --parent "$CRUX_PROJECTS_DIR" --profile invented
}

test_doctor_fails_without_a_contract() {
  sandbox >/dev/null
  local docs; docs="$(new_project gamma)"
  rm "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "crux.json is missing" "reports the missing contract"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detects_a_declared_repo_without_a_doc_folder() {
  sandbox >/dev/null
  local docs; docs="$(new_project delta --repos "api")"
  rm -rf "$docs/repos/api"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "declared repo without a doc folder" "detects the missing folder"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# The auditable part of §7: if the code moved after the documentation, doctor
# says so. It is what lets you see afterwards whether the gate was skipped.
test_doctor_measures_drift_between_code_and_documentation() {
  sandbox >/dev/null
  local docs; docs="$(new_project drift --repos "api")"
  local repo; repo="$(dirname "$docs")/api"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'x\n' > "$repo/a.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "after the docs"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "code ↔ doc drift" "warns about the drift"
  assert_contains "$out" "api" "and says which repo"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# The negative: with no code repo having moved, it does not invent drift.
test_doctor_does_not_invent_drift_when_there_is_none() {
  sandbox >/dev/null
  local docs; docs="$(new_project nodrift)"
  git -C "$docs" add -A
  # No `|| true`: a commit that cannot be made is reported, not hidden.
  git -C "$docs" commit -qm "documentation up to date" >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "documentation up to date with the code" "says so in the positive"
  assert_not_contains "$out" "code ↔ doc drift" "and raises no warning"
}

test_doctor_detects_an_undeclared_folder() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon --repos "api")"
  mkdir -p "$docs/repos/ghost"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "is not declared in crux.json" "detects the orphan folder"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# Cloning a repo into the project and forgetting to register it is the real
# case: the other checks go from what is declared to what is on disk, so this
# one passed as conformant.
# upgrade, link and add-repo already stopped with the parser's reason. The one
# that diagnoses was the only one left, inventing errors about what is there.
test_doctor_says_when_the_contract_is_not_valid_json() {
  sandbox >/dev/null
  local docs; docs="$(new_project broken --repos "api")"
  printf '{ "crux": "0.15.0", "project": ' > "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "is not valid JSON" "says what is really going on"
  assert_not_contains "$out" "missing required field" "and does not blame fields that are there"
  assert_not_contains "$out" "is not declared" "nor invent undeclared repos"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detects_an_undeclared_repo_on_disk() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/web"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "web/ is on disk and not declared" "detects it"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# A workspace is a worktree sibling of the repo: warning about it would turn
# the check into noise every time one is opened.
test_doctor_does_not_mistake_a_workspace_for_an_undeclared_repo() {
  sandbox >/dev/null
  local docs; docs="$(new_project sigma --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/api"
  ( cd "$root/api" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  git -C "$root/api" worktree add -q --detach "$root/api-ws-task" 2>/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "api-ws-task/ is on disk" "does not warn about the worktree"

  git -C "$root/api" worktree remove --force "$root/api-ws-task" 2>/dev/null
}

test_doctor_detects_a_diverging_claude_md() {
  sandbox >/dev/null
  local docs; docs="$(new_project zeta)"
  rm "$docs/CLAUDE.md"
  echo "manual copy" > "$docs/CLAUDE.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "not a symlink" "detects the two sources that diverge"
}

test_doctor_detects_broken_markdown_links() {
  sandbox >/dev/null
  local docs; docs="$(new_project eta)"
  echo "See [this](./does-not-exist.md)." >> "$docs/README.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "broken markdown links" "detects the broken link"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detects_a_skill_without_frontmatter() {
  sandbox >/dev/null
  local docs; docs="$(new_project theta)"
  mkdir -p "$docs/.claude/skills/project/broken"
  echo "# no frontmatter" > "$docs/.claude/skills/project/broken/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "skill without frontmatter" "detects the malformed skill"
}

test_client_profile_does_not_write_in_the_foreign_repo() {
  sandbox >/dev/null
  local docs; docs="$(new_project client --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client/vendor"
  mkdir -p "$vendor"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_no_file "$vendor/AGENTS.md" "link creates no pointers with a client profile"
  assert_no_file "$vendor/CLAUDE.md" "link creates no pointers with a client profile"
  assert_eq "0" "$(ls -A "$vendor" | wc -l)" "the client's repo is left untouched"
}

test_client_profile_detects_an_intrusion() {
  sandbox >/dev/null
  local docs; docs="$(new_project client2 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client2/vendor"
  mkdir -p "$vendor"
  echo "x" > "$vendor/AGENTS.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "should not exist" "detects the write into someone else's code"
  assert_exit 1 "the intrusion is an error, not a warning" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# The foreign repo may bring its own AGENTS.md, versioned by the client. It is
# not our intrusion and the profile forbids touching it: doctor cannot ask for
# something we did not write to be deleted.
test_client_profile_respects_the_clients_agents() {
  sandbox >/dev/null
  local docs; docs="$(new_project client3 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client3/vendor"
  mkdir -p "$vendor"
  echo "# client instructions" > "$vendor/AGENTS.md"
  git -C "$vendor" init -q
  git -C "$vendor" add AGENTS.md
  git -C "$vendor" -c user.email=t@t -c user.name=t commit -qm "docs: add agents"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "should not exist" "the client's AGENTS.md is not an intrusion"
  assert_contains "$out" "belongs to the client" "reports it as respected"
  assert_exit 0 "doctor passes with the client's file" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# But a pointer of ours is one, even if someone committed it into the foreign
# repo: the managed block gives it away.
test_client_profile_detects_the_committed_pointer() {
  sandbox >/dev/null
  local docs; docs="$(new_project client4 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client4/vendor"
  mkdir -p "$vendor"
  printf '<!-- crux:begin -->\n@../client4-docs/AGENTS.md\n' > "$vendor/AGENTS.md"
  git -C "$vendor" init -q
  git -C "$vendor" add AGENTS.md
  git -C "$vendor" -c user.email=t@t -c user.name=t commit -qm "docs: add pointer"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "should not exist" "the managed block gives the pointer away"
  assert_exit 1 "still an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# With nothing the agent loads on its own, working in the client's repo does not
# lead to the docs repo. The local pointer solves it without versioning anything
# in their repository.
new_client_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  echo x > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "chore: init"
}

test_client_profile_writes_the_local_pointer_outside_git() {
  sandbox >/dev/null
  local docs; docs="$(new_project client5 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client5/vendor"
  new_client_repo "$vendor"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_file "$vendor/CLAUDE.local.md" "link writes the local pointer"
  assert_contains "$(cat "$vendor/CLAUDE.local.md")" "@../client5-docs/CLAUDE.md" "the import points to the docs repo"
  assert_eq "" "$(git -C "$vendor" status --porcelain)" "it does not show up in git status"
  assert_no_file "$vendor/AGENTS.md" "and still writes no versioned pointers"
  assert_no_file "$vendor/CLAUDE.md" "nor CLAUDE.md"
  assert_eq "" "$(tail -c1 "$vendor/CLAUDE.local.md")" "ends in a newline"
  local long_one; long_one="$(awk 'length > 80' "$vendor/CLAUDE.local.md")"
  assert_eq "" "$long_one" "no line goes over 80, so no formatter splits it"
}

test_client_profile_doctor_requires_the_local_pointer() {
  sandbox >/dev/null
  local docs; docs="$(new_project client6 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client6/vendor"
  new_client_repo "$vendor"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "has no CLAUDE.local.md" "detects the missing local pointer"
  assert_exit 1 "and it is an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_exit 0 "with the pointer written doctor passes" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_client_profile_doctor_detects_the_unexcluded_pointer() {
  sandbox >/dev/null
  local docs; docs="$(new_project client7 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client7/vendor"
  new_client_repo "$vendor"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  sed -i '/CLAUDE.local.md/d' "$vendor/.git/info/exclude"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "is not excluded from git" "detects that it could be committed"
  assert_exit 1 "and it is an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_client_profile_respects_the_clients_own_claude_local() {
  sandbox >/dev/null
  local docs; docs="$(new_project client8 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/client8/vendor"
  new_client_repo "$vendor"
  echo "# the client's" > "$vendor/CLAUDE.local.md"
  git -C "$vendor" add CLAUDE.local.md
  git -C "$vendor" -c user.email=t@t -c user.name=t commit -qm "docs: add local"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_eq "# the client's" "$(cat "$vendor/CLAUDE.local.md")" "does not overwrite the client's versioned file"
  assert_exit 0 "and doctor respects it" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_link_creates_pointers_with_the_import() {
  sandbox >/dev/null
  local docs; docs="$(new_project iota --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/iota/api"
  mkdir -p "$repo"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_file "$repo/AGENTS.md" "AGENTS.md generated"
  assert_file "$repo/CLAUDE.md" "CLAUDE.md generated"
  assert_contains "$(cat "$repo/CLAUDE.md")" "@../iota-docs/CLAUDE.md" "the import points to the docs repo"
  assert_not_contains "$(cat "$repo/AGENTS.md")" "{{" "placeholders substituted"
}

test_link_is_idempotent() {
  sandbox >/dev/null
  local docs; docs="$(new_project kappa --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/kappa/api"
  mkdir -p "$repo"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  echo "the repo's own context" >> "$repo/AGENTS.md"
  local before; before="$(cat "$repo/AGENTS.md")"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_eq "$before" "$(cat "$repo/AGENTS.md")" "does not overwrite what the repo already had"
}

test_link_does_not_overwrite_a_pointer_that_predates_the_block() {
  sandbox >/dev/null
  local docs; docs="$(new_project lambda --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/lambda/api"
  mkdir -p "$repo"
  printf '# api\n\nOwn context written by hand.\n' > "$repo/CLAUDE.md"

  local out; out="$(bash "$CRUX_HOME/bin/link.sh" "$docs" 2>&1)"
  assert_contains "$out" "predate the managed block" "warns instead of overwriting"
  assert_contains "$(cat "$repo/CLAUDE.md")" "Own context written by hand" \
    "does not touch the file unless asked"

  bash "$CRUX_HOME/bin/link.sh" "$docs" --refresh >/dev/null 2>&1
  local now; now="$(cat "$repo/CLAUDE.md")"
  assert_contains "$now" "crux:begin" "with --refresh it inserts the block"
  assert_contains "$now" "Own context written by hand" "and keeps what was there"
}

test_link_updates_the_block_without_touching_what_surrounds_it() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/omega/api"
  mkdir -p "$repo"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  printf '\n## Repo notes\n\nSomething that only matters here.\n' >> "$repo/CLAUDE.md"
  # Simulates the kernel changing the template
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("## How we work here", "## How we used to work"));
  ' "$repo/CLAUDE.md"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  local now; now="$(cat "$repo/CLAUDE.md")"
  assert_contains "$now" "## How we work here" "the block goes back to the template"
  assert_contains "$now" "Something that only matters here" "what is outside the block survives"
}

test_adopt_registers_an_existing_docs_repo() {
  sandbox >/dev/null
  local docs="$CRUX_PROJECTS_DIR/legacy/legacy-docs"
  mkdir -p "$docs/repos/service" "$docs/decisions" "$docs/operations" "$CRUX_PROJECTS_DIR/legacy/service"
  : > "$docs/README.md"; : > "$docs/AGENTS.md"
  ln -s AGENTS.md "$docs/CLAUDE.md"
  : > "$docs/decisions/README.md"; : > "$docs/decisions/index.md"
  : > "$docs/repos/README.md"; : > "$docs/repos/service/README.md"

  bash "$CRUX_HOME/bin/adopt.sh" "$docs" >/dev/null 2>&1

  assert_file "$docs/crux.json" "writes the contract"
  local cfg; cfg="$(cat "$docs/crux.json")"
  assert_contains "$cfg" '"project": "legacy"' "deduces the project from the folder name"
  assert_contains "$cfg" '"service"' "declares the repos that already had docs"
  assert_contains "$cfg" '"operations"' "declares the active sections"
}

# The case above builds the whole structure by hand, so it never saw what
# someone adopting a pre-kernel project runs into: a list of errors.
test_adopt_says_how_to_restore_what_is_missing() {
  sandbox >/dev/null
  local docs="$CRUX_PROJECTS_DIR/bare/bare-docs"
  mkdir -p "$docs"

  local out; out="$(bash "$CRUX_HOME/bin/adopt.sh" "$docs" 2>&1)"
  assert_contains "$out" "missing AGENTS.md" "doctor says what is missing"
  assert_contains "$out" "crux upgrade" "and adopt says what to restore it with"
}

test_adopt_does_not_overwrite_an_already_adopted_project() {
  sandbox >/dev/null
  local docs; docs="$(new_project mu)"
  assert_exit 1 "refuses to re-adopt" bash "$CRUX_HOME/bin/adopt.sh" "$docs"
}

test_upgrade_updates_the_declared_version() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu)"
  node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    o.crux = "0.0.1";
    fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2));
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "the kernel is" "doctor warns about the version gap"

  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1
  assert_contains "$(cat "$docs/crux.json")" "\"crux\": \"$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")\"" \
    "upgrade aligns the version"
}

test_upgrade_restores_missing_pieces_without_overwriting_content() {
  sandbox >/dev/null
  local docs; docs="$(new_project xi)"
  echo "the project's own content" > "$docs/README.md"
  rm "$docs/decisions/README.md"

  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" --force >/dev/null 2>&1 || true
  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1

  assert_file "$docs/decisions/README.md" "restores the piece that was missing"
}

test_json_get_returns_the_whole_array() {
  sandbox >/dev/null
  local f="$SB/x.json"
  echo '{"repos": ["one", "two", "three"]}' > "$f"

  local count
  count="$(bash -c 'source "$1/lib/common.sh"; json_get "$2" repos' _ "$CRUX_HOME" "$f" | wc -l)"
  assert_eq "3" "$count" "the last element of the array is not lost"
}

test_skills_are_materialized_for_both_agents() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron)"
  mkdir -p "$docs/.claude/skills/project/do-something"
  cat > "$docs/.claude/skills/project/do-something/SKILL.md" <<'EOF'
---
name: do-something
description: Test procedure.
---
# do something
EOF

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_symlink "$CLAUDE_SKILLS_DIR/do-something" \
    "$docs/.claude/skills/project/do-something" "Claude gets the link to the skill"
  assert_file "$CODEX_PROMPTS_DIR/do-something.md" "Codex gets its stub"
  assert_contains "$(cat "$CODEX_PROMPTS_DIR/do-something.md")" \
    "$docs/.claude/skills/project/do-something/SKILL.md" "the stub points to the source, it does not duplicate it"
}

test_no_kernel_skill_names_an_agents_tools() {
  local hits
  # Markdown only: the rule is that the PROCEDURE is not tied to an agent.
  # Scripts are left out because "cursor" is also a CSS property, and a script
  # that reads getComputedStyle().cursor is not naming any editor.
  hits="$(grep -rliE '\b(claude code|codex|cursor)\b' \
    --include='*.md' "$CRUX_HOME/skills" 2>/dev/null | wc -l)"
  assert_eq "0" "$hits" "the kernel skills are not tied to a specific agent"
}

test_kernel_names_no_concrete_projects() {
  local hits
  hits="$(grep -rliE 'acme|demo-co|client|weather-app' \
    "$CRUX_HOME/skills" "$CRUX_HOME/templates" "$CRUX_HOME/profiles" \
    "$CRUX_HOME/bin" "$CRUX_HOME/lib" 2>/dev/null | wc -l)"
  assert_eq "0" "$hits" "the kernel is free of project names"
}

test_add_repo_registers_everything_at_once() {
  sandbox >/dev/null
  local docs; docs="$(new_project pi --repos "api")"
  mkdir -p "$CRUX_PROJECTS_DIR/pi/worker"

  bash "$CRUX_HOME/bin/add-repo.sh" worker --description "Processes the queue." "$docs" >/dev/null 2>&1

  assert_file "$docs/repos/worker/README.md" "creates the documentation folder"
  assert_contains "$(cat "$docs/crux.json")" '"worker"' "declares the repo in the contract"
  assert_contains "$(cat "$docs/repos/README.md")" "worker" "registers it in the index"
  assert_contains "$(cat "$docs/repos/worker/README.md")" "Processes the queue." "uses the given description"
  assert_file "$CRUX_PROJECTS_DIR/pi/worker/AGENTS.md" "generates the repo's pointers"
  assert_exit 0 "the project stays conformant" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_adopt_does_not_invent_empty_repos_and_keeps_the_remotes() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/old"
  mkdir -p "$root/old-docs"
  git -C "$root/old-docs" init -q
  echo "# by hand" > "$root/old-docs/README.md"

  bash "$CRUX_HOME/bin/adopt.sh" "$root/old-docs" >/dev/null 2>&1 || true
  local cfg="$root/old-docs/crux.json"
  assert_exit 0 "the contract is valid JSON" node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$cfg"
  assert_eq "0" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).repos.length)' "$cfg")" \
    "with no repos, the list is empty and not a blank name"

  # A repo with a doc folder and an origin, with no remote in the docs repo.
  rm "$cfg"
  mkdir -p "$root/old-docs/repos/service" "$root/service"
  git -C "$root/service" init -q
  git -C "$root/service" remote add origin "git@example.com:someone/service.git"
  bash "$CRUX_HOME/bin/adopt.sh" "$root/old-docs" >/dev/null 2>&1 || true
  assert_contains "$(cat "$cfg")" "someone/service.git" "keeps the repo's remote even if the docs repo has none"
}

test_add_repo_takes_the_remote_from_origin() {
  sandbox >/dev/null
  local docs; docs="$(new_project tau --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/tau/worker"
  git init -q "$repo"
  git -C "$repo" remote add origin "git@example.com:another-account/worker.git"

  bash "$CRUX_HOME/bin/add-repo.sh" worker "$docs" >/dev/null 2>&1

  # Without this, clone would not know where to fetch the newly added repo from.
  assert_contains "$(cat "$docs/crux.json")" "another-account/worker.git" "records the remote it already has"
  assert_eq "git@example.com:another-account/worker.git" \
    "$(source "$CRUX_HOME/lib/common.sh"; remote_url "$docs/crux.json" worker)" \
    "and clone knows how to compose it"
}

test_add_repo_rejects_duplicates() {
  sandbox >/dev/null
  local docs; docs="$(new_project rho --repos "api")"
  assert_exit 1 "does not re-declare an existing repo" \
    bash "$CRUX_HOME/bin/add-repo.sh" api "$docs"
}

test_no_command_hides_a_file_it_cannot_read() {
  # Silencing the read of a file that has to be there turns its absence into an
  # empty value, and the empty value is later reported as something else:
  # missing fields, lists with no elements, a consumer that does not exist.
  local findings="" f
  for f in "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/lib/*.sh "$CRUX_HOME/install.sh" \
           "$CRUX_HOME"/adapters/*/*.sh; do
    [[ -f "$f" ]] || continue
    # Input redirection or cat on a path, with the error hidden. The shell
    # resolves the redirection before the command, so the command's 2>/dev/null
    # does not even cover it: the error shows on screen anyway.
    local suspicions
    suspicions="$(grep -nE '(<|cat) +"?\$[A-Za-z_{][^|;]*" *2>/dev/null' "$f" || true)"
    [[ -n "$suspicions" ]] && findings="$findings $(basename "$f")"
  done
  assert_eq "" "$findings" "no command reads a file while hiding the error"
}

test_the_library_does_not_override_shell_options() {
  # A `set -e` inside the library silently kills whoever loads it with other
  # options. It happened twice: in the suite and in doctor.
  local out
  out="$(bash -c '
    set +e
    source "$1/lib/common.sh"
    false
    echo SURVIVES
  ' _ "$CRUX_HOME" 2>&1)"
  assert_contains "$out" "SURVIVES" "loading the library does not enable set -e"

  assert_eq "0" "$(grep -c '^set -' "$CRUX_HOME/lib/common.sh")" \
    "the library sets no shell options"
}

test_doctor_detects_duplicate_adrs() {
  sandbox >/dev/null
  local docs; docs="$(new_project sigma)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: First
- **Status**: Accepted

### ADR-001: Another session picked the same number
- **Status**: Accepted
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "duplicate ADR" "detects the numbering collision"
  assert_exit 1 "it is an error, not a warning" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# The fixtures of this case and of the next one are Spanish on purpose: the
# project declares "es", and an English description would raise the language
# warning instead of the one being checked.
test_doctor_detects_a_description_that_does_not_activate() {
  sandbox >/dev/null
  local docs; docs="$(new_project tau)"
  mkdir -p "$docs/.claude/skills/project/mute"
  printf -- '---\nname: mute\ndescription: Ayuda con los despliegues del sistema.\n---\n\n# mute\n\nUsa esto cuando quieras.\n' \
    > "$docs/.claude/skills/project/mute/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "does not say when to use it" "detects the mute description"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"

  # The "Usa esto" in the body must not count: if more is read, this detects nothing.
  mkdir -p "$docs/.claude/skills/project/good"
  printf -- '---\nname: good\ndescription: Hace algo concreto. Usa cuando pase X.\n---\n\n# good\n' \
    > "$docs/.claude/skills/project/good/SKILL.md"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "'good'" "does not flag a description that does trigger"
}

test_doctor_detects_pointers_that_predate_the_block() {
  sandbox >/dev/null
  local docs; docs="$(new_project upsilon --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/upsilon/api"
  mkdir -p "$repo"
  printf '# api\n\nOld pointer.\n' > "$repo/CLAUDE.md"
  printf '# api\n\nOld pointer.\n' > "$repo/AGENTS.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "predates the managed block" "warns about the outdated pointers"
}

test_the_index_description_reaches_the_repo_pointer() {
  sandbox >/dev/null
  local docs; docs="$(new_project psi --repos "web,api")"
  mkdir -p "$CRUX_PROJECTS_DIR/psi/web" "$CRUX_PROJECTS_DIR/psi/api"

  assert_contains "$(cat "$docs/repos/README.md")" '`web/`' "init fills in the index table"

  # Editing the index is what a human does; the pointer must follow it.
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8")
      .replace("| `web/` | `psi/web` | What this repo does, in one line |",
               "| `web/` | `psi/web` | Public front end in Next |"));
  ' "$docs/repos/README.md"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_contains "$(head -1 "$CRUX_PROJECTS_DIR/psi/web/CLAUDE.md")" "Public front end in Next" \
    "the pointer picks up the index description"
  assert_not_contains "$(head -1 "$CRUX_PROJECTS_DIR/psi/api/CLAUDE.md")" "Public front end" \
    "each repo gets its own, not its neighbour's"
}

test_a_new_project_is_born_knowing_workspace_exists() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron2)"
  local cfg; cfg="$(cat "$docs/crux.json")"
  assert_contains "$cfg" '"workspace"' "the contract includes the section"
  assert_contains "$cfg" '"portBase"' "with the default values in sight"
}

test_doctor_detects_a_description_in_another_language() {
  sandbox >/dev/null
  local docs; docs="$(new_project chi)"
  mkdir -p "$docs/.claude/skills/project/mixed"
  printf -- '---\nname: mixed\ndescription: Purge the cache when the CDN is serving stale content after a deploy that changed the static assets.\n---\n\n# mixed\n' \
    > "$docs/.claude/skills/project/mixed/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "seems to be in English" "detects the description in another language"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_the_contract_declares_the_language() {
  sandbox >/dev/null
  local docs; docs="$(new_project phi)"
  assert_contains "$(cat "$docs/crux.json")" '"language": "es"' "Spanish by default"

  local other_one; other_one="$(new_project phi2 --language en)"
  assert_contains "$(cat "$other_one/crux.json")" '"language": "en"' "another can be declared"
}

test_link_keeps_the_kernel_catalog_in_the_index() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega2)"

  assert_contains "$(cat "$docs/AGENTS.md")" "crux:skills" "the index is born with the slot"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  local idx; idx="$(cat "$docs/AGENTS.md")"
  assert_contains "$idx" "\`end-session\`" "fills it with the kernel skills"
  assert_contains "$idx" "\`ship\`" "with all of them, not a hand-written list"

  # Regenerating does not duplicate: it is what happens when the block is badly substituted.
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_eq "1" "$(grep -c '^<!-- crux:skills -->$' "$docs/AGENTS.md")" "the opening marker is still unique"
}

test_clone_does_not_guess_where_to_fetch_things_from() {
  sandbox >/dev/null
  # With no template or default value, it stops instead of assuming a provider.
  local out
  out="$(HOME="$SB/home-no-config" bash "$CRUX_HOME/bin/clone.sh" x --parent "$SB/empty" 2>&1)"
  assert_contains "$out" "I do not know where to fetch" "without a remote it does not invent a URL"

  # With the docs repo present but no contract, it does not know what else to clone either.
  local withDocs="$SB/with-docs"
  mkdir -p "$withDocs/x/x-docs"; git init -q "$withDocs/x/x-docs"
  out="$(bash "$CRUX_HOME/bin/clone.sh" x --parent "$withDocs" 2>&1)"
  assert_contains "$out" "no crux.json" "without a contract it does not know which repos the project brings"
}

test_the_remote_allows_a_per_repo_override() {
  sandbox >/dev/null
  local cfg="$SB/crux.json"
  cat > "$cfg" <<'JSON'
{"remote":{"url":"git@github.com:mine/{repo}.git",
           "repos":{"foreign":"https://other-host.com/team/foreign.git"}}}
JSON

  local own foreign
  own="$(bash -c 'source "$1/lib/common.sh"; remote_url "$2" own' _ "$CRUX_HOME" "$cfg")"
  foreign="$(bash -c 'source "$1/lib/common.sh"; remote_url "$2" foreign' _ "$CRUX_HOME" "$cfg")"

  assert_eq "git@github.com:mine/own.git" "$own" "yours comes from the template"
  assert_eq "https://other-host.com/team/foreign.git" "$foreign" "someone else's, from its override"
}

test_the_remote_is_also_composed_with_the_shortcut() {
  sandbox >/dev/null
  local cfg="$SB/shortcut.json"
  printf '{"remote":{"host":"gitlab.company.com","owner":"team/sub","protocol":"ssh"}}\n' > "$cfg"
  local url
  url="$(bash -c 'source "$1/lib/common.sh"; remote_url "$2" api' _ "$CRUX_HOME" "$cfg")"
  assert_eq "git@gitlab.company.com:team/sub/api.git" "$url" "the shortcut composes the URL"
}

test_the_deduction_is_not_confused_by_repeated_names() {
  sandbox >/dev/null
  local repo="$SB/demo"
  mkdir -p "$repo"; git init -q "$repo"
  # The owner is named the same as the repo: substituting every occurrence
  # would produce "git@host:{repo}/{repo}.git", which is useless for any other repo.
  git -C "$repo" remote add origin "git@host.com:demo/demo.git"

  local tmpl
  tmpl="$(bash -c 'source "$1/lib/common.sh"; remote_from_git "$2"' _ "$CRUX_HOME" "$repo")"
  assert_eq "git@host.com:demo/{repo}.git" "$tmpl" "it only substitutes the last occurrence"
}

test_doctor_warns_if_the_declared_remote_is_not_the_real_one() {
  sandbox >/dev/null
  local docs; docs="$(new_project rho2 --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/rho2/api"
  mkdir -p "$repo"; git init -q "$repo"
  git -C "$repo" remote add origin "git@wherever.com:other/api.git"

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8"));
    o.remote = { url: "git@github.com:mine/{repo}.git" };
    fs.writeFileSync(f, JSON.stringify(o, null, 2));
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "the contract says" "detects the divergence between contract and origin"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_init_does_not_assume_where_to_push_the_repo() {
  sandbox >/dev/null
  local out
  out="$(HOME="$SB/clean" bash "$CRUX_HOME/bin/init.sh" sigma2 --parent "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_contains "$out" "I do not know where to push" "without --remote it does not pick a provider for you"

  # With a remote that is not GitHub: leaves the repo ready and says what is missing.
  out="$(HOME="$SB/clean" bash "$CRUX_HOME/bin/init.sh" sigma3 --parent "$CRUX_PROJECTS_DIR" \
    --remote 'git@gitlab.company.com:team/{repo}.git' 2>&1)"
  assert_contains "$out" "does not exist yet" "warns that it has to be created on the provider"

  local docs="$CRUX_PROJECTS_DIR/sigma3/sigma3-docs"
  assert_eq "git@gitlab.company.com:team/sigma3-docs.git" \
    "$(git -C "$docs" remote get-url origin)" "and leaves origin configured"
  assert_contains "$(cat "$docs/crux.json")" "gitlab.company.com" "the contract declares the remote"
}

test_init_states_the_visibility_when_it_cannot_apply_it() {
  sandbox >/dev/null
  local out
  out="$(HOME="$SB/clean2" bash "$CRUX_HOME/bin/init.sh" tau2 --parent "$CRUX_PROJECTS_DIR" \
    --remote 'git@gitlab.company.com:team/{repo}.git' --visibility private 2>&1)"

  # Outside GitHub a person creates the repo: if crux does not say so, it gets
  # created public by accident, with internal documentation inside.
  assert_contains "$out" "as **private**" "says which visibility to create it with"
  assert_contains "$out" "crux cannot apply visibility" "and warns that it does not control it"

  assert_contains "$(cat "$CRUX_PROJECTS_DIR/tau2/tau2-docs/crux.json")" '"visibility": "private"' \
    "the contract keeps the intended visibility, so it can be verified later"
}

test_the_kernel_documents_its_own_context() {
  assert_file "$CRUX_HOME/AGENTS.md" "the kernel has context for whoever comes to touch it"
  assert_symlink "$CRUX_HOME/CLAUDE.md" "AGENTS.md" "and a single file, not two that diverge"

  # AGENTS.md cites by name the tests that guard its hard rules. If someone
  # renames one, the documentation starts lying without anyone noticing.
  local cited missing_items=0
  cited="$(grep -oE 'test_[a-z_]+' "$CRUX_HOME/AGENTS.md" | sort -u)"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    grep -rq "^$t()" "$CRUX_HOME/test/cases/" || { missing_items=$((missing_items + 1)); echo "      missing: $t"; }
  done <<< "$cited"
  assert_eq "0" "$missing_items" "the tests that AGENTS.md cites exist"
}

test_link_does_not_fight_the_repos_formatter() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu2 --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/nu2/api"
  mkdir -p "$repo"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  # Simulates what a formatter does: aligning the table columns.
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8")
      .replace(/\| Moment \| What to invoke \|/, "| Moment                      | What to invoke |"));
  ' "$repo/CLAUDE.md"
  local formatted; formatted="$(cat "$repo/CLAUDE.md")"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_eq "$formatted" "$(cat "$repo/CLAUDE.md")" \
    "does not revert the formatting: otherwise link and the formatter fight endlessly"
}

test_the_projects_root_is_not_assumed() {
  sandbox >/dev/null
  # A kernel installed at a path that is not ~/Proyectos: its parent is the root.
  local root="$SB/dev"
  mkdir -p "$root/crux"
  cp -r "$CRUX_HOME/lib" "$CRUX_HOME/VERSION" "$root/crux/"

  local inferred
  inferred="$(env -u CRUX_PROJECTS_DIR CRUX_HOME="$root/crux" HOME="$SB/empty" \
    bash -c 'source "$1/lib/common.sh"; projects_root' _ "$root/crux")"
  assert_eq "$root" "$inferred" "the root comes from where the kernel lives"

  # What is declared wins over what is deduced.
  mkdir -p "$SB/other/.crux"
  printf 'CRUX_PROJECTS_DIR="/wherever"\n' > "$SB/other/.crux/config"
  inferred="$(env -u CRUX_PROJECTS_DIR CRUX_HOME="$root/crux" HOME="$SB/other" \
    bash -c 'source "$1/lib/common.sh"; projects_root' _ "$root/crux")"
  assert_eq "/wherever" "$inferred" "what is declared in the config rules"
}

test_the_drift_hook_works_outside_the_usual_path() {
  sandbox >/dev/null
  local root="$SB/workspace"
  local repo="$root/proj/api"
  mkdir -p "$repo/src" "$root/proj/proj-docs/repos/api"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'export const x = 1\n' > "$repo/src/util.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["api"],"sections":[]}\n' \
    > "$root/proj/proj-docs/crux.json"
  # The documentation mentions the file, and the file is modified uncommitted.
  printf 'The helper lives in `src/util.ts`.\n' > "$root/proj/proj-docs/repos/api/README.md"
  printf 'export const x = 2\n' > "$repo/src/util.ts"

  local out
  out="$(cd "$repo" && echo '{"session_id":"odd"}' | env HOME="$SB/home" CRUX_PROJECTS_DIR="$root" \
    bash "$CRUX_HOME/adapters/claude/hooks/doc-sync.sh" 2>&1)"
  assert_contains "$out" "DOCUMENTATION GATE" "warns even if the root is not the usual one"
  assert_contains "$out" "src/util.ts" "and says which file triggers it"
}

# The gate is worth it if it stops the close. A warning that is printed and lets
# you close is what there already was, and it is what failed.
test_the_documentation_gate_blocks_the_close_once() {
  sandbox >/dev/null
  local root="$SB/workspace"
  local repo="$root/proj/api"
  mkdir -p "$repo" "$root/proj/proj-docs/repos/api"
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["api"],"sections":[]}\n' \
    > "$root/proj/proj-docs/crux.json"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'x\n' > "$repo/a.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf 'y\n' > "$repo/a.txt"

  local hook="$CRUX_HOME/adapters/claude/hooks/doc-sync.sh"

  assert_exit 2 "blocks the close when the session moved things" \
    bash -c "cd '$repo' && echo '{\"session_id\":\"s1\"}' | env HOME='$SB/home' CRUX_PROJECTS_DIR='$root' bash '$hook' >/dev/null 2>&1"

  # Second pass of the same session: it was already asked, let it close.
  assert_exit 0 "does not block again in the same session" \
    bash -c "cd '$repo' && echo '{\"session_id\":\"s1\"}' | env HOME='$SB/home' CRUX_PROJECTS_DIR='$root' bash '$hook' >/dev/null 2>&1"

  # And it never blocks the turn that already comes from a blocked Stop: that is a loop.
  assert_exit 0 "does not chain itself" \
    bash -c "cd '$repo' && echo '{\"session_id\":\"s2\",\"stop_hook_active\":true}' | env HOME='$SB/home2' CRUX_PROJECTS_DIR='$root' bash '$hook' >/dev/null 2>&1"
}

# And the negative: in a project where nothing moved, stay quiet. Asking in
# empty sessions is the fastest way for someone to uninstall it.
test_the_documentation_gate_stays_quiet_if_nothing_moved() {
  sandbox >/dev/null
  local root="$SB/workspace"
  local repo="$root/proj/api"
  mkdir -p "$repo" "$root/proj/proj-docs/repos/api"
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["api"],"sections":[]}\n' \
    > "$root/proj/proj-docs/crux.json"

  local old="2020-01-01T00:00:00"
  local d
  for d in "$repo" "$root/proj/proj-docs"; do
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'x\n' > "$d/a.txt"
    git -C "$d" add -A
    env GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -C "$d" commit -qm init
  done

  local out
  out="$(cd "$repo" && echo '{"session_id":"quiet"}' | env HOME="$SB/home" CRUX_PROJECTS_DIR="$root" \
    bash "$CRUX_HOME/adapters/claude/hooks/doc-sync.sh" 2>&1)"
  assert_eq "" "$out" "in a quiet project it says nothing"
}

test_the_inventory_tools_respect_the_root() {
  sandbox >/dev/null
  local root="$SB/my-things"
  mkdir -p "$root/one/one-docs/.claude/skills/project/something"
  printf '{"crux":"0.1.0","project":"one","profile":"multi-repo","repos":[],"sections":[]}\n' \
    > "$root/one/one-docs/crux.json"
  printf -- '---\nname: something\ndescription: Does something. Use when it is time.\n---\n# something\n' \
    > "$root/one/one-docs/.claude/skills/project/something/SKILL.md"

  local out
  out="$(CRUX_PROJECTS_DIR="$root" node "$CRUX_HOME/skills/skill-audit/scripts/audit.mjs" 2>&1)"
  assert_contains "$out" "in 1 projects" "finds the project outside the usual path"
}

test_every_command_is_documented() {
  # Adding a command and forgetting to document it already happened with `clone`,
  # and nobody noticed until it was looked for by hand.
  local missing_items=0
  for f in "$CRUX_HOME"/bin/*.sh; do
    local cmd; cmd="$(basename "$f" .sh)"
    # Those that are not subcommands of the dispatcher
    case "$cmd" in machine|release) continue ;; esac

    grep -q "  $cmd)" "$CRUX_HOME/bin/crux" || { echo "      $cmd is not in the dispatcher"; missing_items=$((missing_items+1)); }
    grep -q "crux $cmd" "$CRUX_HOME/bin/crux" || { echo "      $cmd is not in the help"; missing_items=$((missing_items+1)); }
    grep -q "crux $cmd" "$CRUX_HOME/README.md" || { echo "      $cmd is not in the README"; missing_items=$((missing_items+1)); }
    grep -q "crux $cmd" "$CRUX_HOME/STANDARD.md" || { echo "      $cmd is not in STANDARD.md"; missing_items=$((missing_items+1)); }
  done
  assert_eq "0" "$missing_items" "every command is in the dispatcher, the help, the README and the standard"
}

test_every_kernel_skill_is_in_the_catalog() {
  local missing_items=0
  for d in "$CRUX_HOME"/skills/*/; do
    local n; n="$(basename "$d")"
    grep -q "\`$n\`" "$CRUX_HOME/STANDARD.md" || { echo "      $n is not in the catalog"; missing_items=$((missing_items+1)); }
  done
  assert_eq "0" "$missing_items" "the standard's catalog covers every kernel skill"
}

test_release_requires_the_version_to_come_by_proposal() {
  sandbox >/dev/null
  local out

  # release runs from the kernel repository, so the case goes there explicitly.
  out="$(cd "$CRUX_HOME" && bash "$CRUX_HOME/bin/release.sh" one.two 2>&1)"
  assert_contains "$out" "must be semver" "requires semver"

  # The version number is bumped in VERSION by proposal; release only tags.
  # If VERSION does not match, that proposal is missing.
  out="$(cd "$CRUX_HOME" && bash "$CRUX_HOME/bin/release.sh" 99.0.0 2>&1)"
  assert_contains "$out" "bump it to 99.0.0 by proposal" "does not commit the version on its own"
}

test_release_publishes_the_notes_it_generates() {
  local src; src="$(cat "$CRUX_HOME/bin/release.sh")"
  assert_contains "$src" "gh release create" "the notes do not stay in the tag"
  assert_contains "$src" "gh not authenticated" "and without gh it says so instead of failing"
}

test_release_verifies_whoever_consumes_the_kernel() {
  sandbox >/dev/null
  # A consumer that has stopped meeting the standard: the release has to stop,
  # which is what sets it apart from a `git tag`.
  local root="$SB/consumers"
  local docs="$root/broken/broken-docs"
  mkdir -p "$docs"
  printf '{"crux":"0.1.0","project":"broken","profile":"multi-repo","repos":["missing"],"sections":[]}\n' \
    > "$docs/crux.json"

  local out
  out="$(cd "$CRUX_HOME" && CRUX_PROJECTS_DIR="$root" bash "$CRUX_HOME/bin/release.sh" 99.0.0 2>&1)"
  assert_contains "$out" "stops meeting the standard" "detects the broken consumer"
  assert_contains "$out" "not publishing" "and stops"
  assert_exit 1 "exits with an error" \
    env CRUX_PROJECTS_DIR="$root" bash -c 'cd "$CRUX_HOME" && exec bash bin/release.sh 99.0.0'
}

test_kernel_references_no_skills_that_do_not_exist() {
  # An announced but missing skill does not fail: it is invoked, nothing
  # happens and the procedure is taken as done. That silence is the problem.
  local broken=""
  local ref
  while IFS= read -r ref; do
    [[ -d "$CRUX_HOME/skills/$ref" ]] || broken+="$ref "
  done < <(grep -rhoE '`/[a-z][a-z0-9-]+`' \
             "$CRUX_HOME/skills" "$CRUX_HOME"/*.md 2>/dev/null \
           | tr -d '`/' | sort -u)

  assert_eq "" "$broken" "every skill referenced in the kernel exists"
}

# The Spanish messages in this case are fixtures on purpose: the hook has to
# reject them.
test_the_hook_rejects_a_spanish_commit_message() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/git/commit-msg.sh"
  local f="$SB/MSG"

  # From this repo's real history, written before anyone checked anything.
  echo "fix(workspace): el titulo de la propuesta sale del primer commit" > "$f"
  assert_exit 1 "rejects a message in Spanish" bash "$hook" "$f"

  echo "fix(workspace): take the proposal title from the first commit" > "$f"
  assert_exit 0 "lets the same message through in English" bash "$hook" "$f"

  # A short Spanish subject has a single function word; the verb it starts with
  # is the second hint.
  echo "feat: añade el login" > "$f"
  assert_exit 1 "rejects a short subject in Spanish" bash "$hook" "$f"

  # One hint is not enough: a proper noun does not turn the message into
  # Spanish, and a hook that gets it wrong is disabled within a week.
  echo "feat(stations): add Los Angeles network ids" > "$f"
  assert_exit 0 "a Spanish proper noun does not trigger the rejection" bash "$hook" "$f"
  echo "fix(tz): correct Los Angeles offset" > "$f"
  assert_exit 0 "nor a place name with an article" bash "$hook" "$f"

  # What goes in backticks is code, not language.
  printf 'refactor: rename `esta_lista` and `el_valor` helpers\n' > "$f"
  assert_exit 0 "identifiers in backticks do not count" bash "$hook" "$f"

  # Paths and URLs are addresses, not language: /es/ is a route.
  printf 'feat(i18n): locale routing\n\nSpanish will go under /es/ and never serve English on an /es/ URL.\nSee https://example.com/es/la/guia.\n' > "$f"
  assert_exit 0 "paths and URLs do not count" bash "$hook" "$f"

  # Comment lines belong to git.
  printf 'chore: bump deps\n\n# Por favor escribe el mensaje para tu commit\n' > "$f"
  assert_exit 0 "neither do git's comments" bash "$hook" "$f"

  echo "feat: la puerta se gradua segun lo que toca el diff" > "$f"
  local out; out="$(bash "$hook" "$f" 2>&1)"
  assert_contains "$out" "no-verify" "and says how to skip it when it is really needed"
  assert_contains "$out" "hints:" "and shows why it was rejected"
}

test_the_hook_strips_the_tools_signature() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/git/commit-msg.sh"
  local f="$SB/MSG"

  # The agent adds it because its own environment asks it to: the written rule
  # competes with a live instruction and loses, so it deletes itself.
  printf 'feat: add the why we measure column\n\nExplains each indicator.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01ABC\n' > "$f"
  assert_exit 0 "does not reject the commit for carrying a signature" bash "$hook" "$f"
  assert_not_contains "$(cat "$f")" "Co-Authored-By" "strips the co-author trailer"
  assert_not_contains "$(cat "$f")" "Claude-Session" "and the session link"
  assert_contains "$(cat "$f")" "Explains each indicator." "without touching the body"

  # The other form of the signature: the "generated with" footer and its emoji.
  printf 'fix: correct the partner logo\n\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$f"
  bash "$hook" "$f" >/dev/null 2>&1
  assert_not_contains "$(cat "$f")" "Claude Code" "strips the generated-with footer"
  assert_contains "$(cat "$f")" "fix: correct the partner logo" "and leaves the subject"

  # A human co-author is real information about the repo and is not touched.
  printf 'feat: add the reviewed copy\n\nCo-Authored-By: A Reviewer <reviewer@example.org>\n' > "$f"
  bash "$hook" "$f" >/dev/null 2>&1
  assert_contains "$(cat "$f")" "reviewer@example.org" "respects a human co-author"
}

test_init_scaffolds_the_gate_block() {
  sandbox >/dev/null
  local docs; docs="$(new_project gate --repos "app")"
  # A new project used to be born without quality, so `ship gate` was useless
  # until someone knew the field existed.
  assert_contains "$(cat "$docs/crux.json")" '"quality"' "the new contract brings the gate block"
  assert_contains "$(cat "$docs/crux.json")" '"gate"' "with the slot to declare the commands"
}

test_the_machine_detects_that_there_are_no_hooks() {
  sandbox >/dev/null
  local empty="$SB/empty-settings.json"; echo '{}' > "$empty"
  # A broken hook was visible; none at all was not. And that is the case of a new machine.
  local out; out="$(CLAUDE_SETTINGS="$empty" bash "$CRUX_HOME/bin/machine.sh" 2>&1 || true)"
  assert_contains "$out" "no crux hook installed" "warns about a machine with no hooks"

  out="$(CLAUDE_SETTINGS="$SB/does-not-exist.json" bash "$CRUX_HOME/bin/machine.sh" 2>&1 || true)"
  assert_contains "$out" "no hook is installed" "and about one with no settings at all"
}

test_code_repos_also_protect_their_main_branch() {
  # The kernel and the docs repo were protected, and not the code repos, which
  # is where almost all the work happens.
  local src; src="$(cat "$CRUX_HOME/bin/hooks.sh")"
  assert_contains "$src" 'install_pre_push "$root/$repo"' "pre-push in the code repos too"
}

test_bringing_a_project_in_leaves_its_hooks_in_place() {
  # A new machine is set up with bootstrap or by cloning project by project. By
  # both routes it ended up without a single hook, and without them nothing is automatic.
  assert_contains "$(cat "$CRUX_HOME/bin/bootstrap.sh")" "hooks.sh\" install" \
    "bootstrap hooks up each project it brings"
  assert_contains "$(cat "$CRUX_HOME/bin/clone.sh")" "hooks.sh\" install" \
    "and clone those of the project it clones"
}

# It wrote the folder outside the docs repo and doctor took the contract as good.
test_add_repo_rejects_a_name_that_escapes_the_folder() {
  sandbox >/dev/null
  local docs; docs="$(new_project traversal --repos "api")"

  for bad_one in "../outside" "../../far" "with space" "sub/dir" ".hidden" "/abs"; do
    assert_exit 1 "rejects '$bad_one'" bash "$CRUX_HOME/bin/add-repo.sh" "$bad_one" "$docs"
  done

  assert_no_file "$(dirname "$docs")/outside" "creates nothing outside the docs repo"
  assert_eq "api" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).repos.join(","))' "$docs/crux.json")" \
    "the contract is left intact"

  assert_exit 0 "and still accepts a valid name" \
    bash "$CRUX_HOME/bin/add-repo.sh" "web-front" --description "x" "$docs"
  # There are real repos in CamelCase: the validation is against harm, not style.
  assert_exit 0 "accepts CamelCase" \
    bash "$CRUX_HOME/bin/add-repo.sh" "MyApp" --description "x" "$docs"
}

test_add_repo_escapes_the_pipes_in_the_description() {
  sandbox >/dev/null
  local docs; docs="$(new_project pipes)"
  bash "$CRUX_HOME/bin/add-repo.sh" web --description "front | back" "$docs" >/dev/null 2>&1

  local row; row="$(grep '^| `web/`' "$docs/repos/README.md")"
  assert_contains "$row" '\|' "the pipe is escaped"
  local columns; columns="$(sed 's/\\|//g' <<< "$row" | awk -F'|' '{print NF-2}')"
  assert_eq "3" "$columns" "the row keeps three columns"
}

# "${declared[@]:-}" with the array empty expands to one empty element.
test_doctor_does_not_invent_a_repo_when_there_is_none() {
  sandbox >/dev/null
  local docs; docs="$(new_project norepos)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.repos = [];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "/ has no AGENTS.md" "does not warn about a repo that does not exist"
  assert_contains "$out" "repos: 0 declared" "and counts zero"
  assert_exit 0 "no errors" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_does_not_warn_about_a_patch_difference() {
  sandbox >/dev/null
  local docs; docs="$(new_project alpatch)"
  local kernel; kernel="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  local other_patch="${kernel%.*}.99"
  [[ "$other_patch" == "$kernel" ]] && other_patch="${kernel%.*}.98"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = process.argv[2];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json" "$other_patch"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "crux upgrade" "one patch of difference does not send you to upgrade"
  assert_not_contains "$out" "is ahead of the kernel" "nor in the opposite direction"
}

test_doctor_warns_about_a_series_jump() {
  sandbox >/dev/null
  local docs; docs="$(new_project ofseries)"
  local kernel; kernel="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = process.argv[2];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json" "${kernel%%.*}.0.0"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "crux upgrade" "a minor behind does get a warning"
}

# The machine with the old kernel downgraded the project's contract without warning.
test_upgrade_does_not_downgrade_the_contract_of_a_newer_project() {
  sandbox >/dev/null
  local docs; docs="$(new_project ahead)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = "99.0.0";
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/upgrade.sh" "$docs" 2>&1)"
  assert_contains "$out" "update the kernel" "says what to do instead of downgrading"
  assert_exit 1 "and does not take it as good" bash "$CRUX_HOME/bin/upgrade.sh" "$docs"
  assert_eq "99.0.0" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).crux)' "$docs/crux.json")" \
    "the contract is not touched"

  local warning; warning="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$warning" "ahead of the kernel" "and doctor does not push toward a downgrade"
}

# A dry-run that exits with an error breaks any chained or CI use.
test_upgrade_in_dry_run_does_not_report_failure() {
  sandbox >/dev/null
  local docs; docs="$(new_project dry)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = "0.0.1";
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  assert_exit 0 "dry-run with pending work exits clean" \
    bash "$CRUX_HOME/bin/upgrade.sh" "$docs" --dry-run
  assert_eq "0.0.1" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).crux)' "$docs/crux.json")" \
    "and writes nothing"
}

# A template without a managed block was reported as written without touching anything.
test_render_managed_tells_apart_a_template_without_a_block() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local dir="$SB/rm"; mkdir -p "$dir"
  printf 'template without a block\n' > "$dir/tpl.md"
  printf '<!-- crux:begin -->\nold\n<!-- crux:end -->\n' > "$dir/dst.md"

  local rc=0
  render_managed "$dir/tpl.md" "$dir/dst.md" || rc=$?
  assert_eq "4" "$rc" "returns its own code, not the updated one"
  assert_contains "$(cat "$dir/dst.md")" "old" "and the destination is left intact"
}

# Without a repo it cannot be claimed that the remote matches the contract.
test_doctor_detects_a_docs_repo_outside_git() {
  sandbox >/dev/null
  local docs; docs="$(new_project nogit)"
  rm -rf "$docs/.git"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "is not in git" "reports it"
  assert_not_contains "$out" "remote consistent with the contract" "and does not claim what it cannot know"
  assert_exit 1 "it is an error, not a warning" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# A contract without a 'crux' field leaves "?", and sort -V put it above everything.
test_version_comparison_ignores_what_is_not_semver() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"

  assert_exit 1 "'?' is not greater than a version" version_greater_than "?" "0.6.0"
  assert_exit 1 "nor 'unknown'" version_greater_than "unknown" "0.6.0"
  assert_exit 0 "0.10.0 is greater than 0.9.0" version_greater_than "0.10.0" "0.9.0"
  assert_exit 1 "and 0.9.0 is not greater than 0.10.0" version_greater_than "0.9.0" "0.10.0"
}

# Without the closing line, the frontmatter is not valid YAML and the skill does not activate.
test_doctor_detects_unclosed_frontmatter() {
  sandbox >/dev/null
  local docs; docs="$(new_project frontmatter)"
  mkdir -p "$docs/.claude/skills/project/broken"
  printf -- '---\nname: broken\ndescription: use when something happens\n\n# body\n' \
    > "$docs/.claude/skills/project/broken/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "unclosed frontmatter" "detects it"
  assert_exit 1 "and it is an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# clone ended in a conditional, so it exited with 1 after having gone well.
test_commands_do_not_end_in_a_conditional() {
  sandbox >/dev/null
  local bad_items=""
  for f in "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/lib/*.sh "$CRUX_HOME/install.sh"; do
    local last; last="$(grep -vE '^\s*(#|$)' "$f" | tail -1)"
    [[ "$last" == *"]]"*"&&"* || "$last" == *"]"*"&&"* ]] && bad_items+=" $(basename "$f")"
  done
  assert_eq "" "$bad_items" "no command leaves its exit code in the hands of its last condition"
}

# The same escape as in add-repo, through init's door.
test_init_rejects_a_repo_that_escapes_the_folder() {
  sandbox >/dev/null
  assert_exit 1 "rejects the repo with a path" \
    bash "$CRUX_HOME/bin/init.sh" leak --no-remote --parent "$CRUX_PROJECTS_DIR" --repos "../../ESCAPE,ok"
  assert_no_file "$CRUX_PROJECTS_DIR/ESCAPE" "creates nothing outside"
  assert_no_file "$CRUX_PROJECTS_DIR/leak/ESCAPE" "nor inside the project"
}

# Installing from a worktree left ~/.claude/skills pointing at a directory that
# disappears when it is closed, and with it every skill on the machine.
test_a_worktree_is_told_apart_from_its_main_repo() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local repo="$SB/repo"
  mkdir -p "$repo" && git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$repo" worktree add -q --detach "$SB/wt" >/dev/null 2>&1

  assert_exit 1 "the main repo is not a worktree" is_worktree "$repo"
  assert_exit 0 "the worktree is one" is_worktree "$SB/wt"
  assert_eq "$repo" "$(main_repo "$SB/wt")" "and it knows what it hangs from"

  assert_contains "$(cat "$CRUX_HOME/install.sh")" "is_worktree" "install.sh checks it before touching anything"
}

# The cycle breaks silently if the step exists in the skill but the command that
# opens the proposal does not mention it: nobody invokes it.
test_the_cycle_leads_to_reviewing_the_proposal() {
  sandbox >/dev/null
  local skill="$CRUX_HOME/skills/review-pr/SKILL.md"
  assert_file "$skill" "the skill exists"
  assert_contains "$(head -1 "$skill")" "---" "with frontmatter"
  assert_contains "$(cat "$skill")" "name: review-pr" "and its name"

  assert_contains "$(cat "$CRUX_HOME/skills/flow/SKILL.md")" "/review-pr" "the cycle chains it"
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "/review-pr" "and finish reminds you of it"
}

test_review_gathers_the_proposals_material() {
  sandbox >/dev/null
  local repo="$SB/project"
  mkdir -p "$repo/src" && git -C "$repo" init -q -b main
  echo "one" > "$repo/src/app.sh"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "init"

  git -C "$repo" checkout -q -b ws/task
  printf 'two\nconsole.log("x")\n# TODO: finish\n' >> "$repo/src/app.sh"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "feat: something"

  local out; out="$(bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main 2>&1)"
  assert_contains "$out" "ws/task" "says which branch it reviews"
  assert_contains "$out" "src/app.sh" "and which files it touches"
  assert_contains "$out" "touches no test" "warns that there are no tests"
  assert_contains "$out" "unfinished-work markers" "and about what was left half done"
  assert_exit 0 "finishes clean" bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main
}

test_review_does_not_invent_a_review_without_changes() {
  sandbox >/dev/null
  local repo="$SB/empty"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"

  local out; out="$(bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main 2>&1)"
  assert_contains "$out" "nothing to review" "says so instead of printing an empty section"
  assert_exit 1 "and exits with an error" bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main
}

test_the_docs_repo_is_born_on_main() {
  sandbox >/dev/null
  local docs; docs="$(new_project branch)"
  assert_eq "main" "$(git -C "$docs" rev-parse --abbrev-ref HEAD)" "the branch does not depend on the machine"
}

# If the hook watches a branch that does not exist, it blocks nothing and nobody notices.
test_the_hook_protects_the_branch_the_project_declares() {
  sandbox >/dev/null
  local docs; docs="$(new_project inherited --branch master)"
  assert_eq "master" "$(git -C "$docs" rev-parse --abbrev-ref HEAD)" "the repo is born on the declared one"

  local app; app="$(dirname "$docs")/app"
  mkdir -p "$app"; git -C "$app" init -q -b master
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.repos = ["app"];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  ( cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )
  local hook="$app/.git/hooks/pre-push"
  assert_contains "$(cat "$hook")" "refs/heads/master" "the code repo's hook watches that one"
  assert_not_contains "$(cat "$hook")" "refs/heads/main" "not one that does not exist"
}

test_the_docs_repo_is_pushed_directly() {
  # The profile rule says the documentation is pushed when done. Closing its
  # main branch only taught people to use --no-verify.
  sandbox >/dev/null
  local docs; docs="$(new_project direct)"
  mkdir -p "$docs/.git/hooks"
  printf '#!/usr/bin/env bash\n# Installed by crux hooks install.\nexit 1\n' > "$docs/.git/hooks/pre-push"
  local out; out="$(cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" install 2>&1)"
  assert_no_file "$docs/.git/hooks/pre-push" "install removes the pre-push crux put there"
  assert_contains "$out" "pre-push removed" "and says so"
  assert_file "$docs/.git/hooks/pre-commit" "doctor's pre-commit stays"

  printf '#!/usr/bin/env bash\n# mine\nexit 0\n' > "$docs/.git/hooks/pre-push"
  ( cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )
  assert_file "$docs/.git/hooks/pre-push" "a pre-push that is not crux's is not touched"
}

# A project that predates the field declares nothing: what the repo uses rules.
test_without_a_declared_branch_the_real_one_is_used() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local docs; docs="$(new_project undeclared)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); delete o.branch;
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"
  git -C "$docs" branch -m main trunk

  assert_eq "trunk" "$(main_branch "$docs")" "falls back to the repo's real branch"
}

# The mark the gate leaves blocked the cycle's own next command.
test_the_gate_mark_does_not_block_the_proposal() {
  sandbox >/dev/null
  local repo="$SB/app"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"

  bash "$CRUX_HOME/bin/workspace.sh" new task --repo "$repo" >/dev/null 2>&1
  local ws="$SB/app-ws-task"
  assert_file "$ws/../app/.git/info/exclude" "the exclude exists"
  printf 'abc\n' > "$ws/.crux-ship"
  assert_eq "" "$(git -C "$ws" status --porcelain)" "the mark does not dirty the state"
}

test_the_contract_declares_the_main_branch() {
  sandbox >/dev/null
  local docs; docs="$(new_project declared --branch trunk)"
  assert_eq "trunk" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).branch)' "$docs/crux.json")" \
    "it is written in the contract"
  assert_eq "trunk" "$(git -C "$docs" rev-parse --abbrev-ref HEAD)" "and it is the repo's"
}

# From a worktree, the current branch is the working one: taking it for the main
# one leaves the hook blocking exactly the branch that has to be pushed.
test_the_main_branch_is_not_the_worktrees() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local repo="$SB/app"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$repo" worktree add -q -b ws/task "$SB/app-ws-task" >/dev/null 2>&1

  assert_eq "main" "$(main_branch "$SB/app-ws-task")" "resolves the trunk, not the working one"
}

test_the_users_preferences_are_read_from_their_config() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  mkdir -p "$SB/home/.crux"
  printf 'CRUX_RM_DELETE_BRANCH=true\nCRUX_MERGE_CLOSE_WORKSPACE="true"\n' > "$SB/home/.crux/config"

  assert_eq "true" "$(HOME=$SB/home preference CRUX_RM_DELETE_BRANCH false)" "reads the preference"
  assert_eq "true" "$(HOME=$SB/home preference CRUX_MERGE_CLOSE_WORKSPACE false)" "and strips the quotes"
  assert_eq "false" "$(HOME=$SB/home preference CRUX_NOT_DECLARED false)" "and respects the default"
}

# A branch with work that is not integrated is not deleted because of a preference.
test_the_branch_is_only_deleted_if_it_is_integrated() {
  sandbox >/dev/null
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "branch --merged" "rm checks integration before deleting"
}

# adopt writes the current version onto a repo with no structure: if upgrade
# exits before looking, the command that was meant to complete it completes nothing.
test_upgrade_completes_an_adopted_project() {
  sandbox >/dev/null
  local docs="$CRUX_PROJECTS_DIR/inherited/inherited-docs"
  mkdir -p "$docs" && git -C "$docs" init -q -b main
  echo "# inherited" > "$docs/README.md"
  git -C "$docs" add -A
  git -C "$docs" -c user.email=t@t -c user.name=t commit -qm "docs: init"
  ( cd "$docs" && bash "$CRUX_HOME/bin/adopt.sh" . >/dev/null 2>&1 )

  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1
  for f in AGENTS.md decisions/README.md decisions/index.md repos/README.md; do
    assert_file "$docs/$f" "upgrade restores $f"
  done
  assert_symlink "$docs/CLAUDE.md" "AGENTS.md" "and the symlink that is not a template"
}

# The kernel is installed on any machine, and macOS ships bash 3.2 as standard.
test_the_kernel_does_not_use_bash_4() {
  sandbox >/dev/null
  local uses=""
  for f in "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/bin/crux "$CRUX_HOME"/lib/*.sh \
           "$CRUX_HOME/install.sh" "$CRUX_HOME"/test/*.sh "$CRUX_HOME"/adapters/*/*.sh; do
    [[ -f "$f" ]] || continue
    # Not anchored to the start of the line: bash 4's lowercase expansion
    # appears inside a pipeline or a [[ ]], and with the anchor the two there
    # were went unnoticed. Comments are stripped before looking, because this
    # very note names them.
    sed 's/#.*$//' "$f" |
      grep -qE '(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]|declare -A|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^)\}' \
      && uses+=" $(basename "$f")"
  done
  assert_eq "" "$uses" "no script depends on bash 4"
}

# A wrongly deduced root breaks nothing visibly: it makes `crux release` find
# no consumers and publish saying there is nothing to verify. The rest of the
# install tests pass --projects-dir, so none of them looked at the deduction.
test_install_deduces_the_root_from_the_clone_not_the_kernels_directory() {
  sandbox >/dev/null
  local matches="$SB/home-root"; mkdir -p "$matches"
  # The clone lives at <root>/crux, as on a real machine.
  local root="$SB/projects-root"; local kernel="$root/crux"
  mkdir -p "$kernel"
  ( cd "$CRUX_HOME" && tar cf - bin lib skills templates profiles adapters VERSION install.sh ) \
    | ( cd "$kernel" && tar xf - )

  env HOME="$matches" bash "$kernel/install.sh" >/dev/null 2>&1

  assert_contains "$(cat "$matches/.crux/config")" "CRUX_PROJECTS_DIR=\"$root\"" \
    "the root is the clone's directory, not the kernels' one"
}

# Keeping the root fixes the new case but not the machine that already has the
# bad value written, which is exactly the one suffering the failure.
test_install_fixes_the_root_inherited_from_the_kernels_directory() {
  sandbox >/dev/null
  local matches="$SB/home-root3"; mkdir -p "$matches/.crux"
  printf 'CRUX_PROJECTS_DIR="%s"\n' "$matches/.crux/kernel" > "$matches/.crux/config"

  local root="$SB/projects-inherited"; local kernel="$root/crux"
  mkdir -p "$kernel"
  ( cd "$CRUX_HOME" && tar cf - bin lib skills templates profiles adapters VERSION install.sh ) \
    | ( cd "$kernel" && tar xf - )

  env HOME="$matches" bash "$kernel/install.sh" >/dev/null 2>&1

  assert_contains "$(cat "$matches/.crux/config")" "CRUX_PROJECTS_DIR=\"$root\"" \
    "the root inherited from the kernels' directory is discarded and deduced again"
}

test_install_does_not_overwrite_an_already_declared_root() {
  sandbox >/dev/null
  local matches="$SB/home-root2"; mkdir -p "$matches"
  env HOME="$matches" bash "$CRUX_HOME/install.sh" --projects-dir "$matches/chosen" >/dev/null 2>&1
  # Reinstall without the flag: what was declared once must still be there.
  env HOME="$matches" bash "$CRUX_HOME/install.sh" >/dev/null 2>&1

  assert_contains "$(cat "$matches/.crux/config")" "CRUX_PROJECTS_DIR=\"$matches/chosen\"" \
    "the declared root survives the reinstall"
}

# Linked to the working copy, projects use whatever is in it at any moment: a
# half-finished branch changes their behavior without touching them.
test_install_leaves_one_copy_per_version() {
  sandbox >/dev/null
  local matches="$SB/home"; mkdir -p "$matches"
  env HOME="$matches" bash "$CRUX_HOME/install.sh" --projects-dir "$matches/projects" >/dev/null 2>&1

  local version; version="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  assert_file "$matches/.crux/kernel/$version/bin/crux" "the version's copy exists"
  assert_contains "$(readlink "$matches/.local/bin/crux")" ".crux/kernel/$version" "the command points to the copy"
  assert_contains "$(readlink "$CLAUDE_SKILLS_DIR/ship")" ".crux/kernel/$version" "and so do the skills"
  assert_contains "$(cat "$matches/.crux/config")" 'CRUX_MODE="release"' "the mode is recorded"
}

test_install_dev_links_to_the_working_copy() {
  sandbox >/dev/null
  local matches="$SB/home2"; mkdir -p "$matches"
  # A copy outside git: in dev the installer rejects a worktree, and the suite
  # runs from one when the kernel is being developed.
  local kernel="$SB/kernel"
  mkdir -p "$kernel"
  ( cd "$CRUX_HOME" && tar cf - bin lib skills templates profiles adapters VERSION install.sh ) \
    | ( cd "$kernel" && tar xf - )

  env HOME="$matches" bash "$kernel/install.sh" --dev --projects-dir "$matches/projects" >/dev/null 2>&1

  assert_eq "$kernel/bin/crux" "$(readlink "$matches/.local/bin/crux")" "the command points to the repo"
  assert_contains "$(cat "$matches/.crux/config")" 'CRUX_MODE="dev"' "and the mode says so"
}

test_install_dev_rejects_a_worktree() {
  sandbox >/dev/null
  local wt="$SB/kernel-wt"
  git -C "$CRUX_HOME" worktree add -q --detach "$wt" 2>/dev/null || return 0
  cp "$CRUX_HOME/install.sh" "$wt/install.sh"

  local matches="$SB/home3"; mkdir -p "$matches"
  local out; out="$(env HOME="$matches" bash "$wt/install.sh" --dev --projects-dir "$matches/p" 2>&1)"
  assert_contains "$out" "kernel worktree" "detects it"
  assert_no_file "$matches/.local/bin/crux" "and installs nothing"

  git -C "$CRUX_HOME" worktree remove --force "$wt" 2>/dev/null
}

# With the kernel installed as a copy, CRUX_HOME is not a repo: publishing from
# there failed with "not a git repository" instead of saying what to do.
test_release_runs_from_the_kernel_repo() {
  sandbox >/dev/null
  local outside="$SB/outside"; mkdir -p "$outside"
  local out; out="$( cd "$outside" && bash "$CRUX_HOME/bin/release.sh" 9.9.9 2>&1 )"
  assert_contains "$out" "from the kernel repository" "says where it has to be run"
}

test_status_gathers_projects_workspaces_and_what_is_not_pushed() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local docs; docs="$(new_project lookout --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/api"
  git -C "$root/api" config user.email t@t
  git -C "$root/api" config user.name t
  git -C "$root/api" commit -q --allow-empty -m init
  git -C "$root/api" commit -q --allow-empty -m "feat: not pushed"
  echo loose > "$root/api/pending.txt"

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "lookout" "lists the project"
  assert_contains "$out" "1 repos" "and how many repos it declares"
  assert_contains "$out" "lookout/api" "points out the repo with pending work"
  assert_contains "$out" "1 file touched" "and what it has pending, singular if it is one"
}

test_status_does_not_mistake_a_workspace_for_lost_work() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local docs; docs="$(new_project workspaces --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/api"
  git -C "$root/api" config user.email t@t
  git -C "$root/api" config user.name t
  git -C "$root/api" commit -q --allow-empty -m init
  bash "$CRUX_HOME/bin/workspace.sh" new task --repo "$root/api" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "ws/task" "the workspace shows up as a workspace"
  assert_not_contains "$out" "api-ws-task " "and its worktree is not counted as a repo with pending work"
}

test_release_does_not_publish_with_an_old_installed_copy() {
  sandbox >/dev/null
  local matches="$SB/home-release"; mkdir -p "$matches/.crux"
  local old="$SB/old-kernel"; mkdir -p "$old"
  echo "0.0.1" > "$old/VERSION"
  echo "CRUX_HOME=\"$old\"" > "$matches/.crux/config"

  local out; out="$(cd "$CRUX_HOME" && HOME="$matches" bash "$CRUX_HOME/bin/release.sh" 99.0.0 2>&1)"
  assert_contains "$out" "the installed kernel is 0.0.1" "warns that it would publish with the old publisher"
  assert_contains "$out" "install.sh" "and says how to align it"
}

test_doctor_rejects_an_adr_status_that_does_not_exist() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: A decision with an invented status

- **Date**: 2026-01-01
- **Status**: Almost accepted
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "unrecognized Status" "names the invalid status"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_requires_superseded_to_say_by_whom() {
  sandbox >/dev/null
  local docs; docs="$(new_project zeta)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: A superseded decision that does not say by whom

- **Date**: 2026-01-01
- **Status**: Superseded
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "the chain breaks there" "explains why it matters"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detects_a_reference_to_an_adr_that_is_not_there() {
  sandbox >/dev/null
  local docs; docs="$(new_project eta)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: Points to one that does not exist

- **Date**: 2026-01-01
- **Status**: Superseded by ADR-099
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "and it is not there" "detects the broken reference"
  assert_exit 1 "exits with an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_accepts_the_seven_states_of_the_vocabulary() {
  sandbox >/dev/null
  local docs; docs="$(new_project theta)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: The one that replaces

- **Date**: 2026-01-01
- **Status**: Accepted
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter

### ADR-002: Inherited from the client's code

- **Date**: 2026-01-01
- **Status**: Inherited
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter

### ADR-003: Not decided yet

- **Date**: 2026-01-01
- **Status**: Open
- **Context**: does not matter
- **Decision**: none
- **Consequences**: does not matter

### ADR-004: In force with one part changed

- **Date**: 2026-01-01
- **Status**: Amended by ADR-001
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter

### ADR-005: Superseded by two at once

- **Date**: 2026-01-01
- **Status**: Superseded by ADR-001, ADR-004
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter

### ADR-006: Withdrawn without a replacement

- **Date**: 2026-01-01
- **Status**: Deprecated
- **Context**: does not matter
- **Decision**: does not matter
- **Consequences**: does not matter
ADR

  assert_exit 0 "the full vocabulary passes" \
    bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_warns_about_a_doc_that_nobody_links() {
  sandbox >/dev/null
  local docs; docs="$(new_project iota)"
  mkdir -p "$docs/operations"
  echo "# Something nobody mentions" > "$docs/operations/lost.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "nobody links to operations/lost.md" "names the orphan document"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_sees_the_repo_that_only_exists_on_the_remote() {
  sandbox >/dev/null
  local docs; docs="$(new_project kappa --repos "api")"
  git -C "$docs" remote add origin "https://github.com/someone/kappa-docs.git" 2>/dev/null || \
    git -C "$docs" remote set-url origin "https://github.com/someone/kappa-docs.git"

  # A project repo that nobody cloned on this machine is invisible to the loop
  # that walks the disk: that is how one spent 185 days outside the contract.
  local fake="$SB/bin"; mkdir -p "$fake"
  cat > "$fake/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo list") printf 'kappa-docs\nkappa-forgotten\napi\nother-thing\n' ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$fake/gh"

  local out
  out="$(PATH="$fake:$PATH" bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_contains "$out" "kappa-forgotten is on the remote" "names the repo that only lives on the remote"
  assert_not_contains "$out" "other-thing is on the remote" "the rest of the account is none of its business"
  assert_not_contains "$out" "kappa-docs is on the remote" "the docs repo itself is not reported"
  assert_exit 0 "it is a warning, not an error" env PATH="$fake:$PATH" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_warns_about_credentials_in_the_documentation() {
  sandbox >/dev/null
  local docs; docs="$(new_project lambda)"
  mkdir -p "$docs/operations"
  cat > "$docs/operations/access.md" <<'DOC'
# Access

Log in with:

```
admin@example.test
Xk7pQm2ZrT9wLb4V
```

Deploy token: `ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
DOC

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_contains "$out" "possible loose password" "sees the password inside the block"
  assert_contains "$out" "GitHub token" "sees the token by its format"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_does_not_mistake_configuration_for_credentials() {
  sandbox >/dev/null
  local docs; docs="$(new_project mu)"
  mkdir -p "$docs/operations"
  cat > "$docs/operations/service.md" <<'DOC'
# Service

```
Restart=always
RestartSec=10
EnvironmentFile=/opt/service/.env
```

```
postgres://user:devpass@127.0.0.1:5432/database
```

```
The example password is changeme-dev
```
DOC

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_not_contains "$out" "credential in the documentation" "syntax and examples are not secrets"
}

test_merge_does_not_touch_another_repositorys_proposal() {
  sandbox >/dev/null
  local repo="$SB/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "https://github.com/someone/project-a.git"

  # gh resolves the repository from the directory: a correct number in the wrong
  # place merges another project's work without asking.
  local fake="$SB/bin"; mkdir -p "$fake"
  cat > "$fake/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view") exit 1 ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$fake/gh"

  local out rc=0
  out="$(cd "$repo" && PATH="$fake:$PATH" bash "$CRUX_HOME/bin/merge.sh" 7 2>&1)" || rc=$?

  assert_contains "$out" "does not exist in someone/project-a" "says which repository it looked in"
  assert_eq "1" "$rc" "stops instead of merging blindly"
}

test_merge_requires_a_number() {
  sandbox >/dev/null
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/merge.sh" any-branch 2>&1)" || rc=$?
  assert_contains "$out" "integer" "rejects what is not a number"
  assert_eq "1" "$rc" "exits with an error"
}

test_doctor_warns_about_the_runbook_unverified_for_half_a_year() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu)"
  mkdir -p "$docs/operations"
  printf '# Restart the service\n\n> Last verified: 2020-01-15\n\nSteps.\n' \
    > "$docs/operations/old.md"
  printf '# Purge the cache\n\n> Last verified: %s\n\nSteps.\n' "$(date +%%F)" \
    > "$docs/operations/recent.md"
  # The label the kernel used to write is still read.
  printf '# Rotate the keys\n\n> Última verificación: 2020-01-15\n\nSteps.\n' \
    > "$docs/operations/legacy.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_contains "$out" "operations/old.md unverified" "names the one that expired"
  assert_contains "$out" "operations/legacy.md unverified" "also when it carries the old label"
  assert_not_contains "$out" "operations/recent.md unverified" "the recently checked one does not bother"
  assert_exit 0 "it is a warning, not an error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_status_tells_an_unreadable_contract_from_an_absent_one() {
  sandbox >/dev/null
  local docs; docs="$(new_project s)"
  # Truncated halfway: it is neither absent nor readable.
  printf '{\n  "crux": "0.36.0",\n  "project": "s",\n  "profile": "mul' > "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "unreadable" "a broken contract is reported, not counted as zero repos"
  assert_not_contains "$out" "0 repos" "zero looked like data and was not"

  assert_exit 1 "and --check exits 1, like memory's" bash "$CRUX_HOME/bin/status.sh" --check
}

test_a_users_own_profile_survives_the_kernel() {
  sandbox >/dev/null
  local matches="$SB/home"; mkdir -p "$matches/.crux/profiles"
  # A whole profile of the user's, which the kernel does not ship.
  printf '{"name":"solo","description":"mine","pointers":{"write":false},"rules":["mine"]}\n' \
    > "$matches/.crux/profiles/solo.json"

  local docs="$CRUX_PROJECTS_DIR/mp/mp-docs"
  env HOME="$matches" bash "$CRUX_HOME/bin/init.sh" mp --no-remote \
    --parent "$CRUX_PROJECTS_DIR" --profile solo >/dev/null 2>&1
  assert_file "$docs/crux.json" "init accepts a profile that only exists in ~/.crux/profiles"

  local out; out="$(env HOME="$matches" bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "unknown profile" "and doctor recognizes it"
  assert_contains "$out" "profile solo" "by its name"
}

test_the_project_can_overlay_a_profile_field() {
  sandbox >/dev/null
  local docs; docs="$(new_project sp)"
  # The project does not redefine the whole profile: it changes one field.
  printf '{"pointers":{"write":false}}\n' > "$docs/profile.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "profile multi-repo" "it is still its profile"
  # multi-repo writes pointers; with the overlay, it does not.
  mkdir -p "$(dirname "$docs")/app" && git -C "$(dirname "$docs")/app" init -q
  printf '# someone else'"'"'s\n' > "$(dirname "$docs")/app/AGENTS.md"
  git -C "$(dirname "$docs")/app" add -A
  git -C "$(dirname "$docs")/app" commit -qm init
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8")); j.repos = ["app"];
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$docs/crux.json"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "belongs to the client" "the overlaid field rules over the kernel's"
}

test_a_nonexistent_directory_does_not_hang_the_commands() {
  sandbox >/dev/null
  # find_docs_repo left the path empty and dirname "" returns "." forever.
  local out
  out="$(timeout 10 bash "$CRUX_HOME/bin/doctor.sh" "$SB/does-not-exist" 2>&1)"
  local rc=$?
  assert_eq "yes" "$([[ $rc -ne 124 ]] && echo yes || echo no)" "doctor does not hang"
  assert_contains "$out" "no docs repo found" "and says it finds nothing there"

  out="$(timeout 10 bash "$CRUX_HOME/bin/link.sh" "$SB/does-not-exist" 2>&1)"
  rc=$?
  assert_eq "yes" "$([[ $rc -ne 124 ]] && echo yes || echo no)" "neither does link"
}

test_the_profile_rules_are_written_and_verified() {
  sandbox >/dev/null
  local docs; docs="$(new_project rp)"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  local agents; agents="$(cat "$docs/AGENTS.md")"
  assert_contains "$agents" "crux:begin profile" "link writes the profile rules block"
  assert_contains "$agents" "A repo's specific documentation lives in" \
    "with the rules the profile declares, not copied by hand"
  assert_contains "$agents" "checks they are written here" "and says what doctor checks: that they are there, not that they are followed"
  assert_eq "1" "$(grep -c "^- A repo's specific documentation lives in" "$docs/AGENTS.md")" \
    "each rule on its own line, as a list item"
  assert_eq "1" "$(grep -c '^<!-- crux:end -->$' "$docs/AGENTS.md")" "and the end marker on its own line"
  assert_contains "$agents" $'automatic checks.\n\n- ' "with a blank line before the list"

  # If someone deletes them, doctor says so instead of staying quiet.
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace(/<!-- crux:begin profile[\s\S]*?crux:end -->/, ""));
  ' "$docs/AGENTS.md"
  assert_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "profile rules are not in AGENTS.md" \
    "doctor warns when the block is not there"
}

test_link_in_a_docs_repo_workspace_writes_to_the_workspace() {
  # The contract is still read from the main checkout, but what link writes
  # into the docs repo belongs to the tree it was run from: it used to land in
  # the main checkout and leave the workspace with nothing to propose.
  sandbox >/dev/null
  local docs; docs="$(new_project wsdocs)"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  git -C "$docs" add -A >/dev/null 2>&1; git -C "$docs" commit -qm linked >/dev/null 2>&1
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace(/<!-- crux:begin profile[\s\S]*?crux:end -->/, "<!-- crux:begin profile -->old<!-- crux:end -->"));
  ' "$docs/AGENTS.md"
  git -C "$docs" commit -qam "stale block"
  local ws; ws="$(dirname "$docs")/wsdocs-docs-ws-relink"
  git -C "$docs" worktree add -q -b ws/relink "$ws" 2>/dev/null

  ( cd "$ws" && bash "$CRUX_HOME/bin/link.sh" >/dev/null 2>&1 )
  assert_contains "$(cat "$ws/AGENTS.md")" "Rules of the" "the workspace gets the block"
  assert_eq "" "$(git -C "$docs" status --porcelain)" "and the main checkout is left alone"
}

# The block used to be marked `perfil`: projects written before the translation
# carry it, and both doctor and link must still recognize it.
test_the_old_profile_block_marker_is_still_recognized() {
  sandbox >/dev/null
  local docs; docs="$(new_project rpold)"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  sed -i 's/crux:begin profile/crux:begin perfil/' "$docs/AGENTS.md"

  assert_not_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "profile rules are not in AGENTS.md" \
    "doctor accepts the old marker"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_eq "1" "$(grep -cE 'crux:begin (perfil|profile)' "$docs/AGENTS.md")" \
    "link updates the block in place instead of adding a second one"
}

test_a_crux_json_in_the_code_repo_is_not_the_contract() {
  # Whoever sends a proposal can add a crux.json at the root. If it won, it
  # would decide the branch the hook watches and the gate commands.
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/impersonated"
  mkdir -p "$root/app" "$root/impersonated-docs"
  git -C "$root/app" init -q
  printf '{"crux":"0.1.0","project":"impersonated","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/impersonated-docs/crux.json"
  printf '{"crux":"0.1.0","project":"bad","profile":"multi-repo","branch":"theirs","sections":[]}\n' \
    > "$root/app/crux.json"

  source "$CRUX_HOME/lib/common.sh"
  local found; found="$(find_docs_repo "$root/app")"
  assert_eq "$root/impersonated-docs" "$found" "the docs repo rules, not the code repo's crux.json"
  assert_eq "main" "$(main_branch "$root/app")" "and the main branch does not come from the impersonated contract"
}

test_install_does_not_accept_a_version_that_is_a_path() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  assert_exit 1 "a version with traversal does not pass" is_semver "../../something"
  assert_exit 1 "nor an empty one" is_semver ""
  assert_exit 0 "and a normal one does" is_semver "1.2.3"
  assert_contains "$(cat "$CRUX_HOME/install.sh")" 'is_semver "$INSTALLED_VERSION"' \
    "install.sh checks it before composing the path it deletes"
}

test_upgrade_does_not_open_with_a_version_it_cannot_compare() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  assert_exit 1 "0.28 is not semver" is_semver "0.28"
  assert_exit 1 "neither is unknown" is_semver "unknown"
  local up; up="$(cat "$CRUX_HOME/bin/upgrade.sh")"
  assert_contains "$up" 'is_semver "$TO"' "upgrade checks the kernel's"
  assert_contains "$up" 'is_semver "$FROM"' "and the contract's"
}

test_the_commands_the_kernel_cites_exist() {
  # A message or a skill can only send you to run something that exists: if it
  # names an invented option, it leaves whoever follows it in a dead end.
  local bad_items="" ref sub fl script
  while IFS= read -r ref; do
    sub="$(awk '{print $2}' <<<"$ref")"
    script="$(grep -E "^[[:space:]]+$sub\)" "$CRUX_HOME/bin/crux" | grep -oE 'bin/[a-z.-]+' | head -1)"
    if [[ -z "$script" ]]; then
      [[ "$sub" == "version" ]] || bad_items+="$ref (the subcommand does not exist)"$'\n'
      continue
    fi
    for fl in $(grep -oE -- '--[a-z-]+' <<<"$ref"); do
      grep -qF -- "$fl" "$CRUX_HOME/$script" "$CRUX_HOME"/lib/* 2>/dev/null \
        || bad_items+="$ref ($fl is not in $script)"$'\n'
    done
  done < <(
    # What is quoted in code quotes or carries some option counts as a
    # command; prose ("crux does not know…") does not.
    local sources=("$CRUX_HOME/bin" "$CRUX_HOME/lib" "$CRUX_HOME/skills" "$CRUX_HOME/adapters"
      "$CRUX_HOME/templates" "$CRUX_HOME/STANDARD.md" "$CRUX_HOME/README.md" "$CRUX_HOME/GUIA.md")
    { grep -rhoE '`crux [a-z]+(-[a-z]+)*( [a-z<>_"-]+)*( --[a-z]+(-[a-z]+)*)*' "${sources[@]}" 2>/dev/null | tr -d '`'
      grep -rhoE 'crux [a-z]+(-[a-z]+)*( [a-z<>_-]+)*( --[a-z]+(-[a-z]+)*)+' "${sources[@]}" 2>/dev/null
    } | sort -u)
  assert_eq "" "$bad_items" "every cited command exists, with its options"
}

# The Spanish option names in the pattern below are the ones the kernel used to
# have: they may only remain as the message that gives the new name.
test_crux_options_are_in_english() {
  local hits old_items
  hits="$(grep -rhE -- '^[[:space:]]+--(sin|con|todo|todos|solo|forzar|nuevo|borrar)(-[a-z]+)*\)' "$CRUX_HOME/bin" \
    | grep -vc 'is now called' || true)"
  old_items="$(grep -rhE -- '^[[:space:]]+--[a-z-]+\) die ".* is now called' "$CRUX_HOME/bin" | wc -l | tr -d ' ')"
  assert_eq "0" "$hits" "no crux option is in Spanish"
  assert_eq "3" "$old_items" "the three old ones only remain to say their new name"
}

test_install_moves_the_hooks_of_the_previous_kernel() {
  sandbox >/dev/null
  local matches="$SB/home-hooks"; mkdir -p "$matches/.claude"
  local old="$matches/.crux/kernel/0.0.1/adapters/claude/hooks/session-sync.sh"
  printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"%s"},{"type":"command","command":"/opt/other.sh"}]}]}}' \
    "$old" > "$matches/.claude/settings.json"

  env HOME="$matches" CLAUDE_SETTINGS="$matches/.claude/settings.json" bash "$CRUX_HOME/install.sh" >/dev/null 2>&1

  local version; version="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  local settings; settings="$(cat "$matches/.claude/settings.json")"
  assert_contains "$settings" "$matches/.crux/kernel/$version/adapters/claude/hooks/session-sync.sh" \
    "the hook moves to the newly installed version"
  assert_not_contains "$settings" "kernel/0.0.1/" "and none is left on the previous one"
  assert_contains "$settings" "/opt/other.sh" "hooks that are not crux's are not touched"
}

test_install_moves_the_claude_plugin_of_the_previous_kernel() {
  sandbox >/dev/null
  local matches="$SB/home-plugin"; mkdir -p "$matches/.claude"
  printf '{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/opt/other:%s"}}' "$matches/.crux/kernel/0.0.1/adapters/claude/plugin" > "$matches/.claude/settings.json"

  env HOME="$matches" CLAUDE_SETTINGS="$matches/.claude/settings.json" bash "$CRUX_HOME/install.sh" >/dev/null 2>&1

  local version; version="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  local settings; settings="$(cat "$matches/.claude/settings.json")"
  assert_contains "$settings" "/opt/other:$matches/.crux/kernel/$version/adapters/claude/plugin" \
    "the plugin moves to the installed version and the others stay where they were"
}

test_hooks_install_loads_the_plugin_only_in_claude() {
  sandbox >/dev/null
  printf '{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/opt/other"}}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "/opt/other:$CRUX_HOME/adapters/claude/plugin" \
    "install adds the Claude plugin next to the ones that were already there"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_eq 1 "$(grep -o 'adapters/claude/plugin' "$CLAUDE_SETTINGS" | wc -l | tr -d ' ')" "reinstalling does not duplicate it"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  local settings; settings="$(cat "$CLAUDE_SETTINGS")"
  assert_not_contains "$settings" "adapters/claude/plugin" "remove takes it out"
  assert_contains "$settings" "/opt/other" "and leaves the plugins that are not crux's"
}

test_the_claude_plugin_passes_its_own_tests() {
  # The mod's tests are run by Claude Code: without it on the machine there is nothing to run them with.
  command -v claude >/dev/null 2>&1 || { echo "  (no claude on the PATH: skipped)"; return 0; }
  local out rc=0
  out="$(claude plugin validate "$CRUX_HOME/adapters/claude/plugin" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "the mod's manifest and module validate"
  rc=0
  out="$(cd "$CRUX_HOME/adapters/claude/plugin" && claude plugin test 2>&1)" || rc=$?
  assert_eq 0 "$rc" "the mod's tests pass"
  assert_contains "$out" " 0 fail" "with none failing"
}

test_hooks_install_registers_the_hooks_in_codex() {
  sandbox >/dev/null
  local f="$CODEX_HOME_DIR/hooks.json"
  mkdir -p "$CODEX_HOME_DIR"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/mine.sh"}]}]}}' > "$f"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  local h; h="$(cat "$f")"
  assert_contains "$h" "$CRUX_HOME/adapters/claude/hooks/session-sync.sh" "Codex gets the reminder when a session opens"
  assert_contains "$h" "adapters/codex/hooks/contexto.sh" "the context hooks go through the JSON wrapper"
  assert_contains "$h" "destructive-guard.sh" "and the guards"
  assert_not_contains "$h" "memory-guard" "not the memory one, which checks Claude's"
  assert_contains "$h" "/opt/mine.sh" "the user's own hooks stay"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_eq 1 "$(grep -o 'session-sync.sh' "$f" | wc -l | tr -d ' ')" "reinstalling does not duplicate them"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  h="$(cat "$f")"
  assert_not_contains "$h" "session-sync" "remove takes them out"
  assert_contains "$h" "/opt/mine.sh" "and leaves the user's own"
}

test_hooks_install_does_not_create_codex_if_it_is_not_there() {
  sandbox >/dev/null
  rm -rf "$CODEX_HOME_DIR"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_eq "no" "$([[ -e "$CODEX_HOME_DIR/hooks.json" ]] && echo yes || echo no)" "without Codex on the machine nothing is written"
}

test_the_codex_wrapper_gives_the_context_as_json() {
  sandbox >/dev/null
  local ctx="$CRUX_HOME/adapters/codex/hooks/contexto.sh" h="$SB/hook.sh" out rc
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "Task x · open"\n' > "$h"
  out="$(echo '{}' | bash "$ctx" UserPromptSubmit "$h")"
  assert_eq '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Task x · open"}}' "$out" "the text goes into additionalContext"
  printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$h"
  assert_eq "" "$(echo '{}' | bash "$ctx" UserPromptSubmit "$h")" "with no output it says nothing"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "no" >&2\nexit 2\n' > "$h"
  rc=0; out="$(echo '{}' | bash "$ctx" UserPromptSubmit "$h" 2>&1)" || rc=$?
  assert_eq 2 "$rc" "a block is still a block"
  assert_contains "$out" "no" "with its reason"
}

test_install_moves_the_codex_hooks_of_the_previous_kernel() {
  sandbox >/dev/null
  local matches="$SB/home-codex"; mkdir -p "$matches/.codex"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}' "$matches/.crux/kernel/0.0.1/adapters/claude/hooks/session-sync.sh" > "$matches/.codex/hooks.json"
  env HOME="$matches" CODEX_HOME_DIR="$matches/.codex" bash "$CRUX_HOME/install.sh" >/dev/null 2>&1
  local version; version="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  assert_contains "$(cat "$matches/.codex/hooks.json")" "$matches/.crux/kernel/$version/adapters/claude/hooks/session-sync.sh" "Codex's hooks move to the installed version"
}
