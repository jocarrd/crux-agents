#!/usr/bin/env bash
# Claude Code hook (UserPromptSubmit).
#
# A session left open and resumed hours later does not go through
# SessionStart: as far as Claude Code is concerned nothing has started. Here
# the gap since the last message is measured and, if it exceeds
# CRUX_TASKS_IDLE_HOURS (3 by default), the same is done as on opening: bring
# the machine up to date and show the open tasks, as a reminder and without
# pushing to resume them.

set -u

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/lib/task-sync.mjs" ]] || exit 0

entry="$(cat 2>/dev/null || true)"
data="$(printf '%s' "$entry" | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try { const j = JSON.parse(s); process.stdout.write(`${j.session_id || ""}\t${j.cwd || ""}`); } catch {}
  });' 2>/dev/null)"
IFS=$'\t' read -r session cwd <<< "$data"
[[ -n "$session" ]] || exit 0

status="${CRUX_STATE_DIR:-$HOME/.crux/state}/sessions"
( umask 077 && mkdir -p "$status" ) 2>/dev/null || exit 0
marker="$status/$(printf '%s' "$session" | tr -c 'A-Za-z0-9-' '_')"
find "$status" -type f -mtime +30 -delete 2>/dev/null || true

hours="${CRUX_TASKS_IDLE_HOURS:-3}"
[[ "$hours" =~ ^[0-9]+$ ]] || hours=3
stopped=0
# No marker means the first message: session start already took care of it.
if [[ -f "$marker" && -n "$(find "$marker" -mmin +"$((hours * 60))" 2>/dev/null)" ]]; then
  stopped=1
fi
: > "$marker"
[[ $stopped -eq 1 ]] || exit 0

synced="$(bash "$kernel/bin/sync.sh" --hook < /dev/null 2>/dev/null || true)"
reminder="$(node "$kernel/lib/task-sync.mjs" remind --cwd "${cwd:-$PWD}" 2>/dev/null || true)"
[[ -z "$synced" && -z "$reminder" ]] && exit 0

node -e '
  const [synced, rec, hours] = process.argv.slice(1);
  const r = rec ? JSON.parse(rec) : null;
  const intro = `You are back in this session after more than ${hours} h.`;
  const user = [intro, r?.user, synced].filter(Boolean).join("\n\n");
  const agent = [intro, synced, r?.agent].filter(Boolean).join("\n\n");
  process.stdout.write(JSON.stringify({
    systemMessage: user,
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: agent },
  }));
' "$synced" "$reminder" "$hours"
exit 0
