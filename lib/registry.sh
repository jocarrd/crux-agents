#!/usr/bin/env bash
# The workspace registry: where each worktree lives, which branch it carries
# and which port range it has reserved.
#
# It used to live inside bin/workspace.sh, so the others re-read it by hand
# with their own node: status.sh in three blocks and the worktree-guard hook in
# another. Changing the schema meant remembering all of them.
#
# Requires CRUX_HOME and lib/common.sh loaded. It sets no `set` options, for
# the same reason as common.sh: overriding the options of whoever loads you
# kills them silently.

REGISTRY="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
LOCK="$(dirname "$REGISTRY")/.workspaces.lock"
FLOCK="$(command -v flock 2>/dev/null || true)"
# BusyBox ships a flock without -w, and calling it with -w fails at once: crux
# read that as a held registry. Without -w the directory lock below is enough.
if [[ -n "$FLOCK" ]] && ! "$FLOCK" -w 0 /dev/null true 2>/dev/null; then FLOCK=""; fi
MY_LOCK=0

registry_init() {
  # 077: the registry holds the paths, branches and tasks of all projects at
  # once, including those of different clients. With the usual umask it was
  # readable by anyone on the machine.
  ( umask 077 && mkdir -p "$(dirname "$REGISTRY")" )
  [[ -f "$REGISTRY" ]] || ( umask 077 && echo '{"workspaces":{}}' > "$REGISTRY" )
  chmod 600 "$REGISTRY" 2>/dev/null || true
}

remove_from_registry() {
  # Returns 1 if it could not. It used to return 0 whatever happened, and the
  # caller has already deleted the worktree from disk: the entry stayed alive
  # pointing at a path that no longer exists, the slot reserved forever and an
  # "ok slot released" that was a lie.
  local own=0 rc=0
  if [[ $MY_LOCK -eq 0 ]]; then with_lock 50 && own=1; fi
  node -e '
    const fs = require("fs");
    const [file, name] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    delete r.workspaces[name];
    // To a temp file and rename: a kill halfway left the registry truncated,
    // and with it truncated the deletion guard opens and status lists zero.
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(r, null, 2) + "\n", { mode: 0o600 });
    fs.renameSync(tmp, file);
  ' "$REGISTRY" "$1" || { warn "could not remove '$1' from the registry"; rc=1; }
  [[ $own -eq 1 ]] && unlock
  return $rc
}

with_lock() {
  local cap="${1:-300}" seconds=$(( (${1:-300} + 9) / 10 ))
  mkdir -p "$(dirname "$REGISTRY")"

  # The directory lock is the only one both paths understand: flock locks a
  # separate file, and a process with a trimmed PATH —a hook, a cron— does not
  # find it and took its own. They were two different locks over the same
  # registry, and two processes were verified to get in at once. This one is
  # always taken; flock stays on top because it waits without spinning.
  if [[ -n "$FLOCK" ]]; then
    exec 9>"$LOCK.flock"
    "$FLOCK" -w "$seconds" 9 \
      || die "the registry has been held by another crux for ${seconds}s"
  fi

  local tries=0 owner
  until mkdir "$LOCK" 2>/dev/null; do
    owner=""
    if [[ -r "$LOCK/pid" ]]; then owner="$(cat "$LOCK/pid" || true)"; fi
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      if mv "$LOCK" "$LOCK.$$" 2>/dev/null; then
        rm -rf "$LOCK.$$"
        warn "removed the lock of process $owner, which no longer exists"
      fi
      continue
    fi
    tries=$((tries + 1))
    if [[ $tries -gt $cap ]]; then
      [[ -n "$owner" ]] \
        && die "the registry has been held for ${seconds}s by process $owner, which is still alive" \
        || die "lock with no owner at $LOCK: remove it if no crux is running"
    fi
    sleep 0.1
  done
  echo $$ > "$LOCK/pid"
  MY_LOCK=1
}

unlock() {
  [[ $MY_LOCK -eq 1 ]] || return 0
  # Both, in the reverse order they were taken. Without the `|| true` the
  # function returns 1 when there is no flock, and whoever calls it chained
  # with && stops there.
  rm -rf "$LOCK" 2>/dev/null || true
  [[ -n "$FLOCK" ]] && exec 9>&- || true
  MY_LOCK=0
  return 0
}

write_workspace() {
  node -e '
    const fs = require("fs");
    const [file, name, slot, repo, path, branch, port0, perSlot, task, project] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    r.workspaces[name] = {
      slot: Number(slot), repo, path, branch,
      ports: [Number(port0), Number(port0) + Number(perSlot) - 1],
      task, project,
    };
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(r, null, 2) + "\n", { mode: 0o600 });
    fs.renameSync(tmp, file);
  ' "$REGISTRY" "$@"
}

registry_entries() {
  # One line per workspace: name, path, branch and slot, tab-separated.
  # Whoever only reads does not take the lock: the file is written in one go.
  [[ -f "$REGISTRY" ]] || return 0
  node -e '
    const fs = require("fs");
    let r;
    // An unreadable registry is not an empty one: staying silent opened the
    // deletion guard and made status list zero workspaces without saying so.
    try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stderr.write("unreadable registry: " + e.message + "\n"); process.exit(1); }
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      process.stdout.write([n, w.path, w.branch, w.slot].join("\t") + "\n");
    }
  ' "$REGISTRY"
}

registry_paths() {
  # Only the paths, one per line, to check whether a directory is registered.
  registry_entries | cut -f2
}
