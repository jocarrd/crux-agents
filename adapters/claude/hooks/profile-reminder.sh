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

set -u
cat > /dev/null 2>&1 || true

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/lib/common.sh" ]] || exit 0
# shellcheck source=../../../lib/common.sh
source "$kernel/lib/common.sh"

dir="$(profile_dir 2>/dev/null)" || exit 0
reminder="$(profile_field "$dir" reminder 2>/dev/null)"
[[ -n "$reminder" ]] && printf '%s\n' "$reminder"
exit 0
