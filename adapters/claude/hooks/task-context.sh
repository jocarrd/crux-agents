#!/usr/bin/env bash
# Claude Code hook (UserPromptSubmit).
#
# Inside a workspace, reminds where its task was left: status, steps and next
# step, with the path of the record. Once per session and per workspace.
#
# It exists because resuming depended on the conversation. A compaction, a
# restart or coming back the next day lost the list of steps and what was
# checked, and it had to be rebuilt. The instruction "read the record when
# resuming" competes for attention; a hook arrives on its own. See ADR-012.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook task-context "$@"
