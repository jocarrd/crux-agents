#!/usr/bin/env bash

# Cases for the portability frictions seen when bringing projects to a new
# machine and when creating one in an organization. Generic names on purpose:
# the kernel names no real projects, not even in the tests.

crux_fn() {
  # crux_fn <function> <args...> — runs a lib/common.sh function in isolation.
  local fn="$1"; shift
  bash -c 'source "$1/lib/common.sh"; "$2" "${@:3}"' _ "$CRUX_HOME" "$fn" "$@"
}

test_normalize_git_url_equates_ssh_and_https() {
  # Declaring ssh in the contract and cloning with gh (which leaves https) must
  # not look like a misalignment: it is the same repo. And the owner is
  # case-insensitive.
  local ssh https
  ssh="$(crux_fn normalize_git_url "git@github.com:Acme-Org/foo.git")"
  https="$(crux_fn normalize_git_url "https://github.com/acme-org/foo.git")"
  assert_eq "$https" "$ssh" \
    "ssh and https of the same repo normalize the same, even if the case differs"

  local other_one
  other_one="$(crux_fn normalize_git_url "git@github.com:acme-org/bar.git")"
  assert_not_contains "$ssh" "$other_one" \
    "two different repos do not normalize to the same value"
}

test_owner_from_template_extracts_the_owner() {
  assert_eq "Acme-Org" \
    "$(crux_fn owner_from_template 'git@github.com:Acme-Org/{repo}.git')" \
    "the owner comes out of the ssh template"
  assert_eq "acme-org" \
    "$(crux_fn owner_from_template 'https://github.com/acme-org/{repo}.git')" \
    "the owner comes out of the https template"
  assert_eq "" \
    "$(crux_fn owner_from_template 'git@gitlab.com:acme-org/{repo}.git')" \
    "outside github no owner is guessed: gh is left with its default account"
}

test_init_leaves_no_orphan_runbook() {
  sandbox >/dev/null
  local docs; docs="$(new_project beta)"

  assert_file "$docs/operations/runbooks/README.md" \
    "the template brings operations/runbooks/ as an index, not a loose runbook"
  assert_no_file "$docs/operations/runbook.md" \
    "a runbook.md that nobody links to is no longer materialized"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "nobody links to operations/runbook" \
    "a freshly created project does not carry the orphan runbook warning"
}
