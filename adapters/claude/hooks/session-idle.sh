#!/usr/bin/env bash
# Claude Code hook (UserPromptSubmit).
#
# A session left open and resumed hours later does not go through
# SessionStart: as far as Claude Code is concerned nothing has started. Here
# the gap since the last message is measured and, if it exceeds
# CRUX_TASKS_IDLE_HOURS (3 by default), the same is done as on opening: bring
# the machine up to date and show the open tasks, as a reminder and without
# pushing to resume them.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook session-idle "$@"
