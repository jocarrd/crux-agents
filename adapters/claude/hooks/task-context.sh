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

set -u

entry="$(cat 2>/dev/null || true)"
silence() { exit 0; }

here="$(git rev-parse --show-toplevel 2>/dev/null)" || silence
[[ "$here" == *-ws-* ]] || silence

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/lib/common.sh" && -f "$kernel/lib/task.mjs" ]] || silence
# shellcheck source=../../../lib/common.sh
source "$kernel/lib/common.sh"

task_record="$(task_file_for_path "${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}" "$here" 2>/dev/null)" || silence
[[ -f "$task_record" ]] || silence

session="$(printf '%s' "$entry" | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try { process.stdout.write(String(JSON.parse(s).session_id || "")); } catch { }
  });
' 2>/dev/null || true)"
[[ -n "$session" ]] || session="$PPID"

# The marker goes to ~/.crux/state and not to /tmp: the name carried the repo
# path inside, that is the client and the task, in a directory readable by
# anyone on the machine and that nobody ever cleaned.
status="$HOME/.crux/state"
( umask 077 && mkdir -p "$status" ) 2>/dev/null || true
marker="$status/task-context-$(printf '%s' "$session-$here" | \
  cksum | tr -d ' ' | tr -c 'A-Za-z0-9' '_')"
find "$status" -name 'task-context-*' -type f -mtime +2 -delete 2>/dev/null || true
[[ -e "$marker" ]] && silence

IFS=$'\x1f' read -r task status steps next_step < <(node "$kernel/lib/task.mjs" summary --file "$task_record" 2>/dev/null) || silence
: > "$marker"

echo "Task '$task' · $status${steps:+ · steps $steps}${next_step:+ · next: $next_step}"
echo "Record: $task_record — read it before continuing; it is updated with 'crux task'."
