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

set -u

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

name="$(printf '%s' "$input" | node -e '
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    let event;
    try { event = JSON.parse(raw); } catch { process.exit(0); }
    if (String(event.tool_name || "") !== "Bash") process.exit(0);
    const params = event.tool_input || {};
    if (params.run_in_background === true) process.exit(0);
    const command = String(params.command || "");
    if (/(^|[\s;&|(])CRUX_WAIT=1\s/.test(command)) process.exit(0);
    // Heredoc bodies and quoted text are not executed.
    const runnable = command
      .replace(/<<-?\s*([\x27"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)/g, " ")
      .replace(/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/g, " \"\" ");
    const LONG = [
      [/(^|[\s;&|(\/])test\/run\.sh(?=\s*($|[;&|)<>]))/, "the whole test suite"],
      [/(^|[\s;&|(\/])test\/e2e\.sh\b/, "the end-to-end battery"],
      [/\bcrux\s+ship\s+run\b/, "the quality gate"],
      [/\bgh\s+(pr\s+checks|run\s+watch)\b[^;&|\n]*--watch|\bgh\s+run\s+watch\b/, "watching CI"],
      [/\buntil\b[\s\S]*?\bdo\b[\s\S]*?\bsleep\b/, "a loop that waits"],
      [/\bsleep\s+([1-9]\d{2,})\b/, "a long sleep"],
      [/\bdocker\s+(compose\s+)?build\b|\bdocker\s+buildx\s+build\b/, "an image build"],
      [/\bgradlew\b[^;&|\n]*\b(assemble|bundle|build)/, "an Android build"],
      [/\beas(-cli)?\s+build\b(?![^;&|\n]*--no-wait)/, "a cloud build that is waited for"],
    ];
    for (const [rx, what] of LONG) if (rx.test(runnable)) { process.stdout.write(what); break; }
  });
' 2>/dev/null)"

[[ -n "$name" ]] || exit 0

cat >&2 <<MSG
Stopped: $name takes minutes, and in the foreground everything else waits.

Run it in the background and carry on with what does not depend on it; you
are notified when it ends. If the next step really needs this result and
nothing else is left, say so and put CRUX_WAIT=1 in front of the command.
MSG
exit 2
