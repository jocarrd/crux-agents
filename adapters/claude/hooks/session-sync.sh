#!/usr/bin/env bash
# Claude Code hook (SessionStart).
#
# When a session is opened, resumed or cleared: brings the machine up to date
# with the remote —repos, contract projects, kernel and tasks— and shows the
# open tasks. On a compaction it stays quiet, because the session is halfway
# through some work.
#
# Tasks are shown as a reminder: the person sees them as is and decides. The
# agent is told they have already been seen and not to push them.
#
# It exists because when switching computers work started on the code from the
# last time that machine was used, with nothing to warn about it.

set -u

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/bin/sync.sh" ]] || exit 0

entry="$(cat 2>/dev/null || true)"
field() {
  printf '%s' "$entry" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d));
    process.stdin.on("end", () => {
      try { process.stdout.write(String(JSON.parse(s)[process.argv[1]] ?? "")); } catch {}
    });' "$1" 2>/dev/null
}
origin="$(field source)"
cwd="$(field cwd)"
session="$(field session_id)"
[[ "$origin" == "compact" ]] && exit 0

# The time of the session's last activity, for the hook that warns on returning
# to a session that had been idle for hours.
status="${CRUX_STATE_DIR:-$HOME/.crux/state}/sessions"
if [[ -n "$session" ]]; then
  ( umask 077 && mkdir -p "$status" ) 2>/dev/null && : > "$status/$(printf '%s' "$session" | tr -c 'A-Za-z0-9-' '_')"
fi

synced="$(bash "$kernel/bin/sync.sh" --hook < /dev/null 2>/dev/null || true)"
reminder="$(node "$kernel/lib/task-sync.mjs" remind --cwd "${cwd:-$PWD}" 2>/dev/null || true)"
[[ -z "$synced" && -z "$reminder" ]] && exit 0

node -e '
  const [synced, rec] = process.argv.slice(1);
  const r = rec ? JSON.parse(rec) : null;
  // With the Claude Code mod active, it draws the reminder as a panel; the
  // model still gets it the same. Without the mod (Codex, the web, the phone),
  // the person reads it here.
  const panel = process.env.CRUX_REMINDER_UI === "panel";
  const user = [panel ? null : r?.user, synced].filter(Boolean).join("\n\n");
  const agent = [synced, r?.agent].filter(Boolean).join("\n\n");
  process.stdout.write(JSON.stringify({
    ...(user ? { systemMessage: user } : {}),
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: agent },
  }));
' "$synced" "$reminder"
exit 0
