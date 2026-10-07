#!/usr/bin/env bash

# What doctor checks inside your own code repos: the documentation lives in the
# docs repo and the example env file lists what the code reads. In a client's
# repo none of it applies.

_code_repo() {
  # _code_repo <docs> <repo> — a versioned code repo next to the docs repo
  local dir; dir="$(dirname "$1")/$2"
  mkdir -p "$dir/src" && git init -q -b main "$dir"
  echo "export const url = process.env.API_URL" > "$dir/src/index.js"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}

_commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "chore: change"; }

test_doctor_asks_for_the_env_example_the_code_needs() {
  sandbox >/dev/null
  local docs repo out
  docs="$(new_project kappa --repos api)"
  repo="$(_code_repo "$docs" api)"

  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "api reads environment variables and has no .env.example (API_URL)" \
    "names the repo and the variable"

  printf 'OTHER=\n' > "$repo/.env.example" && _commit_all "$repo"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "api/.env.example lacks what the code reads: API_URL" \
    "an example that does not list it is not enough"

  printf 'OTHER=\nAPI_URL=\n' > "$repo/.env.example" && _commit_all "$repo"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "API_URL" "with the name listed it says nothing"
  assert_contains "$out" "environment listed in its example" "and passes the section"
  teardown
}

test_doctor_sends_documentation_in_a_code_repo_to_the_docs_repo() {
  sandbox >/dev/null
  local docs repo out
  docs="$(new_project lambda --repos web)"
  repo="$(_code_repo "$docs" web)"
  printf 'API_URL=\n' > "$repo/.env.example"
  mkdir -p "$repo/docs" && echo "# setup" > "$repo/docs/setup.md"
  echo "# notes" > "$repo/NOTES.md"
  seq 1 80 > "$repo/README.md"
  _commit_all "$repo"

  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "web holds documentation (" "sees documentation in the code repo"
  assert_contains "$out" "docs/" "the folder"
  assert_contains "$out" "NOTES.md" "and the loose file"
  assert_contains "$out" "web/README.md has 80 lines" "and the README that grew"
  teardown
}

test_doctor_leaves_a_clients_code_repo_alone() {
  sandbox >/dev/null
  local docs repo out
  docs="$(new_project mu --repos vendor --profile client-repo)"
  repo="$(_code_repo "$docs" vendor)"
  mkdir -p "$repo/docs" && echo "# theirs" > "$repo/docs/guide.md" && _commit_all "$repo"

  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "holds documentation" "their documentation is theirs"
  assert_not_contains "$out" ".env.example" "and so is their environment"
  teardown
}
