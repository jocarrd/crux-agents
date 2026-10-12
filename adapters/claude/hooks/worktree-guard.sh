#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash).
#
# Stops a `git worktree remove` or an `rm -r` on a workspace that crux has
# registered, and says what to use instead.
#
# It exists because of what we measured: sessions that freed disk with
# `git worktree remove --force` and `git branch -D` left 41 entries in the
# registry pointing to folders that no longer existed. `crux workspace rm`
# removes the entry, archives the task if it was finished and refuses if
# uncommitted work remains; the shortcut does none of that. See ADR-013.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook worktree-guard "$@"
