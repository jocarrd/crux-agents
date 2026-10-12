#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash).
#
# Stops a command that is known to take minutes when it is launched in the
# foreground. The agent sat watching a test suite, a CI run or a build while
# work that did not depend on it waited; the preference was written in the
# person's profile and was not enough.
#
# In the background it passes. When nothing else is left to do and waiting is
# the decision, CRUX_WAIT=1 in front of the command says so.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook wait-guard "$@"
