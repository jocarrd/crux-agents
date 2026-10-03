#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash and file tools).
#
# Stops commands that destroy work irreversibly and the reading of private keys
# and credentials. With the agent permissions skipped, it is the only brake left
# between a wrong deduction and a `reset --hard`.
#
# It does not replace a person: if someone really wants it, they run it
# themselves with `! <command>` in the conversation, and then it is a decision.
# Adapted from the Gentle Shell guard policy.

set -u

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

verdict="$(printf '%s' "$input" | node -e '
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    let event;
    try { event = JSON.parse(raw); } catch { process.exit(0); }
    const tool = String(event.tool_name || "");
    const params = event.tool_input || {};

    // Private keys and credentials. Public ones (.pub) and .env files are left
    // out: the former are not secrets and the latter are moved by carry-env.
    const SECRET = [
      /(^|\/)\.ssh\/(?!.*\.pub$)(id_[^\/]*|[^\/]*_key|identity)$/,
      /\.(pem|p12|pfx)$/,
      /(^|\/)[^\/]*private[^\/]*\.key$/,
      /(^|\/)\.aws\/credentials$/,
      /(^|\/)\.config\/gh\/hosts\.ya?ml$/,
      /(^|\/)\.netrc$/,
    ];
    const isSecret = (p) => SECRET.some((rx) => rx.test(String(p).replace(/^~(?=\/)/, process.env.HOME || "~")));

    if (tool !== "Bash") {
      const path = params.file_path || params.notebook_path || params.path || "";
      if (path && isSecret(path)) out("secret", path);
      process.exit(0);
    }

    const command = String(params.command || "");
    // What is not executed does not count: comments, heredoc bodies (commit
    // messages go there) and quoted text, except what is passed to another
    // shell to execute.
    const runnable = command
      .replace(/<<-?\s*([\x27"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)/g, " ")
      .replace(/\b(bash|sh|zsh|eval)\s+(-c\s+)?(["\x27])([\s\S]*?)\3/g, " $4 ")
      .replace(/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/g, " \"\" ")
      .replace(/(^|\s)#[^\n]*/g, " ");

    const RULES = [
      [/\bgit\b[^;&|\n]*\breset\b[^;&|\n]*--hard\b/, "git reset --hard", "throws away uncommitted changes", "git stash push -u -m \"<reason>\", or a temporary commit"],
      [/\bgit\b[^;&|\n]*\bpush\b(?=[^;&|\n]*(\s--force(?!-with-lease)\b|\s-[A-Za-z]*f))/, "git push --force", "rewrites the remote history without checking what is there", "git push --force-with-lease"],
      [/\bgit\b[^;&|\n]*\bclean\b(?=[^;&|\n]*\s-[A-Za-z]*f)(?=[^;&|\n]*\s-[A-Za-z]*[dxX])/, "git clean -fd", "deletes untracked files, which git cannot recover", "git clean -n to see first what it would delete"],
      [/\bgit\b[^;&|\n]*\b(checkout\s+--|restore)\s+(\.|:\/)(?=\s|$)/, "discarding the whole tree", "throws away all uncommitted changes in the repo", "discard file by file, after looking at the diff"],
      [/\bgit\b[^;&|\n]*\bstash\s+clear\b/, "git stash clear", "the stash stack is shared between worktrees and sessions", "git stash drop <sha> of your own"],
      [/\brm\b(?=(?:\s+-{1,2}[A-Za-z-]+)*\s+-{0,2}[A-Za-z-]*[rR])[^;&|\n]*\s(\/|~|~\/|\$HOME|\$\{HOME\}|\$HOME\/|\.|\.\.|\*|\.\/\*)(?=[\s;&|]|$)/, "rm -r on /, ~, . or *", "takes a whole directory with it", "name the exact path you want to delete"],
      [/\bchmod\s+-R\s+0?777\b/, "chmod -R 777", "opens all permissions on a whole tree", "grant only the missing permission, to the file that needs it"],
      [/\bchown\s+-R\b/, "chown -R", "changes the owner of a whole tree", "change it on the specific path"],
      [/(^|[\s;&|(])(pkill|killall)\b/, "pkill / killall", "kills by name and takes processes that are not yours", "find the PID (pgrep -a <name>) and use kill <PID>"],
    ];
    for (const [rx, name, why, instead] of RULES) {
      if (rx.test(runnable)) out("command", name, why, instead);
    }

    // Reading a private key from the shell. Using it (ssh -i, sshCommand) does
    // not dump it into the conversation, so that is allowed.
    const READERS = /\b(cat|less|more|head|tail|base64|xxd|od|strings|bat|cp|scp|rsync)\b([^;&|\n]*)/g;
    for (const m of runnable.matchAll(READERS)) {
      const hit = m[2].split(/\s+/).find((t) => t && isSecret(t));
      if (hit) out("secret", hit);
    }
    process.exit(0);

    function out(...fields) {
      process.stdout.write(fields.join("\t"));
      process.exit(0);
    }
  });
' 2>/dev/null)"

[[ -n "$verdict" ]] || exit 0

IFS=$'\t' read -r kind name why instead <<<"$verdict"

if [[ "$kind" == "secret" ]]; then
  cat >&2 <<MSG
'$name' is a private key or a credential. Reading it leaves it in the
conversation and in its log.

If it must be used, use it without dumping it (ssh -i, gh auth). If it really
has to be seen, a person should open it.
MSG
else
  cat >&2 <<MSG
Stopped: $name $why.

Instead: $instead

If a person wants it as is, they run it themselves with '! <command>' in the
conversation.
MSG
fi
exit 2
