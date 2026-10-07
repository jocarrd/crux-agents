#!/usr/bin/env bash

# A repo out of production but kept. The contract says so, whatever the git
# provider allows; gh is a fake that records what it was asked.

_archivable() {
  # A project with two code repos on a GitHub template; leaves DOCS set.
  DOCS="$(new_project acme --repos api,web)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const c = JSON.parse(fs.readFileSync(f, "utf8"));
    c.remote = { url: "git@github.com:acme-org/{repo}.git" };
    fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");
  ' "$DOCS/crux.json"
  local repo
  for repo in api web; do
    mkdir -p "$(dirname "$DOCS")/$repo" && git init -q -b main "$(dirname "$DOCS")/$repo"
    git -C "$(dirname "$DOCS")/$repo" commit -q --allow-empty -m "chore: init"
  done
  mkdir -p "$SB/bin"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh-calls"\ncase "$1" in auth) exit 0 ;; api) echo false ;; esac\nexit 0\n' "$SB" > "$SB/bin/gh"
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

_contract() { node -e "const c=require(process.argv[1]); console.log(JSON.stringify($1))" "$DOCS/crux.json"; }

test_archive_takes_a_repo_out_of_production() {
  sandbox >/dev/null
  _archivable
  local out
  out="$(cd "$DOCS" && crux archive api --reason "Replaced by web" 2>&1)"

  assert_eq '["web"]' "$(_contract 'c.repos')" "it leaves repos"
  assert_contains "$(_contract 'c.archived.api')" '"reason":"Replaced by web"' "and is archived with its reason"
  assert_contains "$(_contract 'c.archived.api.since')" "$(date +%Y-%m-%d)" "and the day"
  assert_contains "$(cat "$DOCS/repos/api/README.md")" "Replaced by web" "its docs say so at the top"
  assert_contains "$(cat "$SB/gh-calls")" "repo archive acme-org/api --yes" "GitHub makes it read only"
  assert_exit 1 "its local clone refuses to push" \
    bash "$(dirname "$DOCS")/api/.git/hooks/pre-push"
  teardown
}

test_archive_asks_why() {
  sandbox >/dev/null
  _archivable
  assert_exit 1 "without a reason it does nothing" bash -c "cd '$DOCS' && bash '$CRUX_HOME/bin/archive.sh' api"
  assert_eq '["api","web"]' "$(_contract 'c.repos')" "and the contract is untouched"
  teardown
}

test_an_archived_repo_refuses_new_work() {
  sandbox >/dev/null
  _archivable
  export CRUX_REGISTRY="$SB/registry.json"
  (cd "$DOCS" && crux archive api --reason "Retired" >/dev/null 2>&1)
  local out rc=0
  out="$(cd "$(dirname "$DOCS")/api" && bash "$CRUX_HOME/bin/workspace.sh" new task 2>&1)" || rc=$?
  assert_eq "1" "$rc" "workspace new refuses"
  assert_contains "$out" "archived since" "and says since when"
  assert_no_file "$(dirname "$DOCS")/api-ws-task" "without creating anything"
  teardown
}

test_doctor_knows_archived_repos_and_checks_their_entry() {
  sandbox >/dev/null
  _archivable
  (cd "$DOCS" && crux archive api --reason "Retired" >/dev/null 2>&1)
  local out
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" 2>&1)"
  assert_not_contains "$out" "api/ is on disk and not declared" "its clone is not an undeclared repo"
  assert_not_contains "$out" "repos/api/ is not declared" "nor is its doc folder"
  assert_contains "$out" "1 archived" "it is counted apart"
  assert_contains "$out" "not on GitHub" "and doctor sees GitHub still has it writable"

  node -e '
    const fs = require("fs"); const f = process.argv[1]; const c = JSON.parse(fs.readFileSync(f, "utf8"));
    c.repos.push("api"); c.archived.web = { since: "ayer" };
    fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");' "$DOCS/crux.json"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" 2>&1)"
  assert_contains "$out" "archived or active, not both" "a repo cannot be both"
  assert_contains "$out" "since must be a date" "the date is checked"
  assert_contains "$out" "reason is missing" "and so is the reason"
  assert_exit 1 "and doctor fails" bash "$CRUX_HOME/bin/doctor.sh" "$DOCS"
  teardown
}

test_unarchive_brings_it_back() {
  sandbox >/dev/null
  _archivable
  (cd "$DOCS" && crux archive api --reason "Paused" >/dev/null 2>&1)
  (cd "$DOCS" && crux unarchive api >/dev/null 2>&1)
  assert_eq '["web","api"]' "$(_contract 'c.repos')" "it is active again"
  assert_eq 'undefined' "$(_contract 'c.archived')" "and nothing is left archived"
  assert_not_contains "$(cat "$DOCS/repos/api/README.md")" "Paused" "the notice goes away"
  assert_contains "$(cat "$SB/gh-calls")" "repo unarchive acme-org/api --yes" "and GitHub opens it again"
  assert_no_file "$(dirname "$DOCS")/api/.git/hooks/pre-push" "and the clone can push"
  teardown
}

test_docs_indexes_merge_by_union() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega)"
  assert_contains "$(cat "$docs/.gitattributes")" "decisions/index.md merge=union" "a new docs repo carries it"
  rm "$docs/.gitattributes"
  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1
  assert_file "$docs/.gitattributes" "and upgrade brings it to one that lacks it"
}
