#!/usr/bin/env bash
# Claude Code hook (UserPromptSubmit).
#
# Reminds about the cycle when about to work on the main branch of a managed
# repo. Once per session, and silent the rest of the time.
#
# It does not guess from the prompt text: the signal is the state —where you
# are and on which branch—, which is deterministic. Guessing intent from words
# ends up warning when it should not and staying silent when it should.
#
# It exists because we measured that describing it was not enough: the cycle
# skill was written, installed and had its description, and in 31 sessions it
# was invoked zero times. A description competes for attention; a hook arrives
# on its own.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook cycle-guard "$@"
