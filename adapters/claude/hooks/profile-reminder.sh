#!/usr/bin/env bash
# Agent hook (UserPromptSubmit), Claude Code and Codex.
#
# Repeats on every message the reminder the person wrote in their profile
# (`reminder:` in the frontmatter of PROFILE.md). The kernel brings no text of
# its own: it is the person's setting, in their words and their language, and
# without one this hook says nothing.
#
# It exists because a rule loaded at the start of the session was not enough.
# The case that forced it was the language: almost everything the agent reads
# while it works —instructions, skills, command output, the other hooks— is in
# English, and the short notes it wrote between tools caught the language of
# the last thing it had read. A reminder that arrives right when it is about to
# write is what holds. See ADR-018.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook profile-reminder "$@"
