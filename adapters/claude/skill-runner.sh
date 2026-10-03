#!/usr/bin/env bash
# Claude adapter for `crux skill test`: answers the question that arrives on
# standard input following only the skill in $CRUX_SKILL_FILE.
#
# Isolated context on purpose: own system prompt, no MCP and no tools, and from
# a temporary directory so that no repo's hooks fire. With the normal context,
# the baseline varied by hundreds of tokens between calls and the closing hooks
# answered instead of the skill.
set -u
: "${CRUX_SKILL_FILE:?CRUX_SKILL_FILE is missing}"
cd "$(mktemp -d)" || exit 1
exec claude -p --model "${CRUX_SKILL_MODEL:-haiku}" \
  --system-prompt "Follow this skill to the letter. You execute nothing: you only answer what you would do.

$(cat "$CRUX_SKILL_FILE")" \
  --strict-mcp-config --tools ""
