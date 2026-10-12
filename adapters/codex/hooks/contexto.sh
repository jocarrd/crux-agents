#!/usr/bin/env bash
# Codex adapter for hooks that provide context as plain text.
#
#   contexto.sh <event> <hook> [args...]
#
# Claude Code takes as context whatever a UserPromptSubmit hook writes to
# stdout. Codex only guarantees it as JSON (hookSpecificOutput.additionalContext),
# so it is wrapped here. The hook does not change: it is the same script in both
# agents, and its exit code and stderr pass through as is.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook codex-context "$@"
