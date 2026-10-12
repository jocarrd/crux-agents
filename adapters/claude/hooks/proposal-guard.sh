#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash).
#
# Stops a `gh pr create` run by hand in a code repo managed by crux. The
# proposal is opened by `crux workspace finish`, which is what demands the gate
# receipt: opening it by hand pushes unchecked work through the only path
# nobody was watching. The pre-push only closes the main branch.
#
# It only acts where there is a contract (a docs repo with crux.json). In the
# kernel or in a repo without a docs repo, `finish` does not apply and the
# command is allowed.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook proposal-guard "$@"
