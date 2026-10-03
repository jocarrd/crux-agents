#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash).
#
# Stops a `gh pr create` run by hand in a code repo managed by crux. The
# proposal is opened by `crux workspace finish`, which is what demands the gate
# receipt: opening it by hand pushes unchecked work through the only path
# nobody was watching. The pre-push only closes the main branch.
#
# It only acts where there is a contract (a docs repo with crux.json). In the
# kernel or in a repo without a docs repo, `finish` does not apply and the
# command is allowed.

set -u

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

parsed="$(printf '%s' "$input" | node -e '
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    let event;
    try { event = JSON.parse(raw); } catch { process.exit(0); }
    const command = String(event.tool_input?.command || "");
    // Same as the destructive guard: what is not executed does not count.
    const runnable = command
      .replace(/<<-?\s*([\x27"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)/g, " ")
      .replace(/\b(bash|sh|zsh|eval)\s+(-c\s+)?(["\x27])([\s\S]*?)\3/g, " $4 ")
      .replace(/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/g, " \"\" ")
      .replace(/(^|\s)#[^\n]*/g, " ");
    if (!/\bgh\b[^;&|\n]*\bpr\s+(create|new)\b/.test(runnable)) process.exit(0);
    // If the command first enters another folder, that is the one that counts.
    const cd = runnable.match(/(?:^|[;&|]\s*)cd\s+(\S+)\s*&&[^;&|\n]*\bgh\b[^;&|\n]*\bpr\s+(create|new)\b/);
    process.stdout.write(cd ? cd[1] : String(event.cwd || process.cwd()));
  });
' 2>/dev/null)"

[[ -n "$parsed" ]] || exit 0
target="${parsed/#\~/$HOME}"
[[ -d "$target" ]] || exit 0

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)}"
# shellcheck source=../../../lib/common.sh
source "$CRUX_HOME/lib/common.sh" 2>/dev/null || exit 0

toplevel="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || exit 0
docs="$(find_docs_repo "$toplevel" 2>/dev/null)" || exit 0
[[ -n "$docs" && "$docs" != "$toplevel" ]] || exit 0

base="$(basename "$toplevel")"
if [[ "$base" == *-ws-* ]]; then
  next="  crux workspace finish ${base##*-ws-}"
else
  # Outside a workspace there is no finish that applies: the work has to go
  # through one first.
  next="  crux workspace new <task>      and work there; then
  crux workspace finish <task>"
fi

cat >&2 <<MSG
Stopped: in this project the proposal is opened by crux, not by hand with gh pr create.

$next

finish pushes the branch and opens the proposal, but first it demands the
quality gate receipt (crux ship run and crux ship seal). Opening it by hand
skips that.

If a person wants it as is, they run it themselves with '! <command>' in the
conversation.
MSG
exit 2
