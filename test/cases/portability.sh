#!/usr/bin/env bash

# Cases for the portability frictions seen when bringing projects to a new
# machine and when creating one in an organization. Generic names on purpose:
# the kernel names no real projects, not even in the tests.

crux_fn() {
  # crux_fn <function> <args...> — runs one library function in isolation.
  local fn="$1"; shift
  "$CRUX_BIN" __fn "$fn" "$@"
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

  local out; out="$("$CRUX_HOME/bin/crux" doctor "$docs" 2>&1)"
  assert_not_contains "$out" "nobody links to operations/runbook" \
    "a freshly created project does not carry the orphan runbook warning"
}

test_with_timeout_works_without_the_timeout_command() {
  # macOS has neither 'timeout' nor 'gtimeout', and the exit codes callers rely
  # on must hold without them: 124 when time runs out, the command's otherwise.
  sandbox >/dev/null
  local bin="$SB/no-timeout-bin" tool
  mkdir -p "$bin"
  for tool in bash sleep; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  local rc
  rc=0; env PATH="$bin" "$CRUX_BIN" __fn with_timeout 1 sleep 5 || rc=$?
  assert_eq "124" "$rc" "a command that runs over its time ends with 124"
  rc=0; env PATH="$bin" "$CRUX_BIN" __fn with_timeout 5 bash -c "exit 3" || rc=$?
  assert_eq "3" "$rc" "a command that finishes in time keeps its exit code"
}

test_registry_lock_works_with_a_flock_without_wait() {
  # BusyBox's flock has no -w. The registry has to fall back to its directory
  # lock instead of reporting that another crux holds it.
  sandbox >/dev/null
  local bin="$SB/busybox-bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase "$1" in -w) echo "unrecognized option: w" >&2; exit 1;; esac\nexit 0\n' > "$bin/flock"
  chmod +x "$bin/flock"
  local out rc=0
  out="$(env PATH="$bin:$PATH" CRUX_REGISTRY="$SB/workspaces.json" "$CRUX_BIN" __fn with_lock 10 2>&1)" || rc=$?
  assert_eq "0" "$rc" "taking the registry lock does not fail"
  assert_contains "$out" "locked" "the lock is taken through the directory"
}
