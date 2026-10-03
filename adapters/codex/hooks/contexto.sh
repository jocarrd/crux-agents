#!/usr/bin/env bash
# Codex adapter for hooks that provide context as plain text.
#
#   contexto.sh <event> <hook> [args...]
#
# Claude Code takes as context whatever a UserPromptSubmit hook writes to
# stdout. Codex only guarantees it as JSON (hookSpecificOutput.additionalContext),
# so it is wrapped here. The hook does not change: it is the same script in both
# agents, and its exit code and stderr pass through as is.

set -u
event="$1"; hook="$2"; shift 2

output="$(bash "$hook" "$@")"
rc=$?
if [[ $rc -ne 0 ]]; then
  [[ -n "$output" ]] && printf '%s\n' "$output"
  exit "$rc"
fi
[[ -n "$output" ]] || exit 0

# If the hook already speaks JSON, it is respected.
if printf '%s' "$output" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))' 2>/dev/null; then
  printf '%s\n' "$output"
  exit 0
fi
node -e '
  const [eventName, text] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: eventName, additionalContext: text } }) + "\n");
' "$event" "$output"
