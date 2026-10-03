#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash).
#
# Stops a `git worktree remove` or an `rm -r` on a workspace that crux has
# registered, and says what to use instead.
#
# It exists because of what we measured: sessions that freed disk with
# `git worktree remove --force` and `git branch -D` left 41 entries in the
# registry pointing to folders that no longer existed. `crux workspace rm`
# removes the entry, archives the task if it was finished and refuses if
# uncommitted work remains; the shortcut does none of that. See ADR-013.

set -u

entry="$(cat 2>/dev/null || true)"
[[ -n "$entry" ]] || exit 0

task_record="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
[[ -f "$task_record" ]] || exit 0

result="$(printf '%s' "$entry" | node -e '
  const fs = require("fs");
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    let cmd = "";
    try { cmd = String(JSON.parse(s).tool_input?.command || ""); } catch { process.exit(0); }
    // What follows a hash sign is a comment, not a command. Without this the
    // guard fired on text that merely mentioned the words.
    const runnable = cmd.replace(/(^|\s)#[^\n]*/g, " ");

    // The ways of taking a directory out, not only the canonical one:
    // rm -rf, rm --recursive, rm -f -r, and find ... -delete.
    const DESTROYS = [
      /\bworktree\s+remove\b/,
      /\brm\b(?=(?:\s+-{1,2}[A-Za-z-]+)*\s+-{0,2}[A-Za-z-]*[rR])/,
      /\brm\b(?=[^\n]*--recursive)/,
      /\bfind\b(?=[^\n]*\s-delete\b)/,
      /\bfind\b(?=[^\n]*-exec\s+rm\b)/,
    ];
    const hits = DESTROYS.map((rx) => runnable.search(rx)).filter((i) => i >= 0);
    if (!hits.length) process.exit(0);
    const since = Math.min(...hits);
    // Only what comes AFTER the destructive command counts: mentioning the path
    // before, in a cd or an echo, is not deleting it.
    const tail = runnable.slice(since);

    // A wildcard (web-ws-*, project/*) deletes the workspaces that match it even
    // if their name does not appear written out.
    const byWildcard = (text, filePath) => {
      for (const t of text.split(/[\s;&|]+/)) {
        const clean = t.replace(/^["'"'"']|["'"'"']$/g, "").replace(/\/+$/, "");
        if (!/[*?[]/.test(clean)) continue;
        const rx = new RegExp("^" + clean.split("").map((c) =>
          c === "*" ? "[^/]*" : c === "?" ? "[^/]" : c.replace(/[.+^${}()|\\]/g, "\\$&")).join("") + "$");
        const base = filePath.split("/").pop();
        if (clean.startsWith("/") ? rx.test(filePath) : rx.test(base) || rx.test(filePath)) return true;
      }
      return false;
    };

    let r;
    try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const end = `(?=[\\s"'"'"';&|]|/?$|/[\\s"'"'"';&|])`;
      const base = w.path.split("/").pop();
      const byPath = new RegExp(esc(w.path) + end);
      const byName = new RegExp(`(^|[\\s/"'"'"'])${esc(base)}` + end);
      if (byPath.test(tail) || byName.test(tail) || byWildcard(tail, w.path)) {
        process.stdout.write(n);
        process.exit(0);
      }
    }
  });
' "$task_record" 2>/dev/null)"

[[ -n "$result" ]] || exit 0

cat >&2 <<MSG
'$result' is a workspace registered in crux. Removing it by hand leaves its
entry in the registry and its task open.

  crux workspace rm $result

It does the same, removes the entry, archives the task if it is already merged
and refuses if anything is left uncommitted.
MSG
exit 2
