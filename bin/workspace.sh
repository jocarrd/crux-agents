#!/usr/bin/env bash
# crux workspace — isolated workspaces to work in parallel.
#
#   crux workspace new <name> [--repo <dir>] [--base <branch>] [--branch <branch>] [--task <task>] [--goal "<text>"] [--force]
#   crux workspace list
#   crux workspace resume <task> [--project <p>]   resumes it here from the remote
#   crux workspace adopt <path> [--task <task>]    registers a hand-made worktree
#   crux workspace heal [--quiet]                  removes entries with no folder or branch
#   crux workspace finish <name> [--title "..."]
#   crux workspace merge <name> [--yes]
#   crux workspace rm <name> [--include-ignored]
#   crux workspace gc [--yes] [--include-disk]
#   crux workspace prune [--yes]
#
# A git worktree isolates files, but not the runtime: two agents on the same
# repo still fight over the port, the database and the .env. This shares out
# those resources too, with a registry so two workspaces do not take the same
# slot.
#
# The worktree is created as a sibling of the original repo, not in a separate
# directory: that is what makes the relative context pointers
# (../<project>-docs/) keep resolving inside the isolated workspace.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
# Brings in REGISTRY, LOCK and the lock. It goes after common.sh, whose die and
# warn it uses.
source "$CRUX_HOME/lib/registry.sh"

RESERVED=""
WORKTREE_DONE=0

on_exit() {
  trap - EXIT
  if [[ -n "$RESERVED" ]]; then
    # With the worktree already on disk the entry stays: that is what allows
    # removing it with 'workspace rm' instead of by hand.
    if [[ $WORKTREE_DONE -eq 1 ]]; then
      warn "workspace '$RESERVED' half-done — remove it with: crux workspace rm $RESERVED"
    else
      remove_from_registry "$RESERVED"
    fi
    RESERVED=""
  fi
  unlock
}
trap on_exit EXIT
trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM

# The lock is released by the system when the process dies, so a hard Ctrl-C
# or an OOM do not leave the registry blocked. Where there is no flock —macOS—
# a mkdir with the pid inside is used, which does need to recognise a dead
# owner.

# --- The project's workspace configuration ----------------------------------
#
# It comes from the "workspace" section of crux.json. Without it the defaults
# are used, which only share out ports.

load_config() {
  # load_config <docs-repo> <repo-name>
  #
  # A multi-repo project does not have a single set of variables: the front,
  # the backend and the panel need different things. The per-repo section is
  # overlaid on the common one.
  local docs="$1" repo="$2"
  PORT_BASE=3000; PORTS_PER_SLOT=10; ENV_FILE=""; ENV_TEMPLATE="{}"
  SETUP_CMD=""; TEARDOWN_CMD=""; INSTALL_DEPS="true"
  local cfg="$docs/crux.json"
  [[ -f "$cfg" ]] || return 0
  local reason
  reason="$(valid_json "$cfg")" || die "the contract of $(basename "$docs") is unreadable — $reason"

  eval "$(node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    const w = (JSON.parse(fs.readFileSync(file, "utf8")).workspace) || {};
    const r = (w.repos || {})[repo] || {};
    const env = { ...(w.env || {}), ...(r.env || {}) };
    const q = (v) => `'"'"'${String(v).replace(/'"'"'/g, `'"'"'\\'"'"''"'"'`)}'"'"'`;
    console.log(`PORT_BASE=${Number(w.portBase) || 3000}`);
    console.log(`PORTS_PER_SLOT=${Number(w.portsPerSlot) || 10}`);
    console.log(`ENV_FILE=${q(r.envFile || w.envFile || "")}`);
    console.log(`ENV_TEMPLATE=${q(JSON.stringify(env))}`);
    console.log(`SETUP_CMD=${q(r.setup || w.setup || "")}`);
    console.log(`TEARDOWN_CMD=${q(r.teardown || w.teardown || "")}`);
    const inst = r.install !== undefined ? r.install : w.install;
    console.log(`INSTALL_DEPS=${q(inst === false ? "false" : "true")}`);
  ' "$cfg" "$repo" 2>/dev/null)"
}

substitute() {
  # substitute <text> — applies {{SLOT}}, {{PORTn}}, {{NAME}}, {{BRANCH}}
  node -e '
    const [text, slot, port0, name, branch] = process.argv.slice(1);
    let v = text.replace(/\{\{SLOT\}\}/g, slot)
                .replace(/\{\{NAME\}\}/g, name)
                .replace(/\{\{BRANCH\}\}/g, branch);
    process.stdout.write(v.replace(/\{\{PORT(\d+)\}\}/g, (_, i) => String(Number(port0) + Number(i))));
  ' "$1" "$SLOT" "$PORT0" "$WS_NAME" "$WS_BRANCH"
}

cmd_new() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "usage: crux workspace new <name> [--repo <dir>] [--base <branch>] [--branch <branch>]"
  valid_name "$name" \
    || die "invalid workspace name: '$name' — letters, numbers, dot, hyphen and underscore, no slashes or '..'"

  local repo="$PWD" base="" requested_branch="" FORCE=0 task="" goal=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --goal) goal="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --branch) requested_branch="$2"; shift 2 ;;
      --force) FORCE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  repo="$(cd "$repo" && git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not a git repo: $repo"
  local repo_name; repo_name="$(basename "$repo")"
  local parent; parent="$(dirname "$repo")"
  local path="$parent/${repo_name}-ws-${name}"
  # A task touching several repos opens a workspace in each with the same
  # --task: all of them write to the same record.
  task="${task:-$name}"
  valid_name "$task" || die "invalid task name: '$task'"
  local project; project="$(project_name_for "$repo")"
  local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
  local profile=""
  [[ -n "$docs" && -f "$docs/crux.json" ]] &&
    profile="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"

  # The workspace name is local; the branch name is published. In a client's
  # repo `ws/<whatever>` shows our naming and, if the name is in another
  # language, that too. That is why the profile decides the pattern and the
  # branch can be set separately.
  local pattern branch
  pattern="$(profile_get "$profile" "$docs" branch.pattern "ws/{{name}}")"
  branch="${requested_branch:-${pattern//\{\{name\}\}/$name}}"

  [[ -e "$path" ]] && die "$path already exists"

  # If another workspace is already working on this repo, say so: it is the
  # sign that there is another live session and that it is worth splitting by
  # surface.
  others="$(node -e '
    const fs = require("fs");
    try {
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const m = Object.entries(r.workspaces || {}).filter(([, w]) => w.repo === process.argv[2]);
      process.stdout.write(m.map(([n, w]) => `${n} (${w.branch})`).join(", "));
    } catch {}
  ' "$REGISTRY" "$repo" 2>/dev/null || true)"
  [[ -n "$others" ]] && warn "there is already open work on $repo_name: $others"

  # `pointers.write: false` says the standard's documentation is not written in
  # the code repo; it does not say you cannot work in it. A local branch is not
  # documentation, and in a client repo developing is precisely the job:
  # blocking it prevented the task without protecting anything. A warning says
  # where the documentation goes and carries on. What does go out to the client
  # is `finish`, which pushes the branch and opens the proposal: that is where
  # to look.
  if [[ -n "$profile" ]]; then
    local writes
    writes="$(profile_get "$profile" "$docs" pointers.write true)"
    if [[ "$writes" != "true" && $FORCE -eq 0 ]]; then
      warn "profile $profile: the branch and the worktree are local and yours, but the"
      warn "documentation of $repo_name goes to $(basename "$docs"), not to the client's repo"
      # The branch does end up published in their repository when the change is proposed.
      if [[ -z "$requested_branch" ]]; then
        warn "and the branch '$branch' will be seen in their repository, with our naming"
        info "to choose it: crux workspace new $name --branch fix/<something-in-english>"
      fi
    fi
  fi

  load_config "$docs" "$repo_name"

  cmd_heal --quiet

  registry_init
  with_lock

  # The registry is indexed by workspace name, so two repos with the same name
  # trampled each other: the first one's entry disappeared, its worktree stayed
  # alive but invisible, its ports were shared out again, and a later gc
  # deleted it from disk for "not knowing it". cmd_adopt already checked this;
  # cmd_new did not.
  local taken
  taken="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = (r.workspaces || {})[process.argv[2]];
    process.stdout.write(w ? w.path : "");
  ' "$REGISTRY" "$name")" || taken=""
  if [[ -n "$taken" ]]; then
    unlock
    err "there is already a workspace called $name in the registry"
    info "it is at $taken"
    info "use another name, or remove it with: crux workspace rm $name"
    exit 1
  fi

  # The lowest slot with its range free: each project starts from its own base,
  # and two different slots of two projects gave the same port range.
  local slot
  slot="$(node -e '
    const fs = require("fs");
    const [file, base, perSlot] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    const ws = Object.values(r.workspaces);
    const takenSlots = new Set(ws.map((w) => w.slot));
    const ranges = ws.map((w) => w.ports).filter(Array.isArray);
    const isFree = (s) => {
      if (takenSlots.has(s)) return false;
      const since = Number(base) + s * Number(perSlot);
      const until = since + Number(perSlot) - 1;
      return !ranges.some(([a, b]) => since <= b && a <= until);
    };
    let s = 0;
    while (!isFree(s)) {
      if (++s > 9999) { process.stderr.write("no free port range left\n"); process.exit(1); }
    }
    process.stdout.write(String(s));
  ' "$REGISTRY" "$PORT_BASE" "$PORTS_PER_SLOT")" || die "could not allocate a slot"

  SLOT="$slot"; PORT0=$((PORT_BASE + slot * PORTS_PER_SLOT))
  WS_NAME="$name"; WS_BRANCH="$branch"

  # Once the slot is reserved, the lock is released: installing and running the
  # setup takes minutes, and with the registry held the second workspace did
  # not start.
  write_workspace "$name" "$slot" "$repo" "$path" "$branch" "$PORT0" "$PORTS_PER_SLOT" "$task" "$project"
  RESERVED="$name"
  unlock

  # If a specific base was requested and it fails, it stops: the fallback path
  # created the branch from HEAD without saying so, and hours were worked on
  # the wrong base. The 2>/dev/null of the first attempt also threw away the
  # reason.
  if [[ -n "$base" ]]; then
    git -C "$repo" show-ref --verify --quiet "refs/heads/$base" ||
      git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$base" ||
      die "the base $base does not exist in $repo"
    git -C "$repo" worktree add -b "$branch" "$path" "$base" >/dev/null \
      || die "could not create the worktree from $base"
  else
    git -C "$repo" worktree add "$path" "$branch" >/dev/null 2>&1 \
      || git -C "$repo" worktree add -b "$branch" "$path" >/dev/null \
      || die "could not create the worktree"
  fi

  WORKTREE_DONE=1
  ok "worktree $path (branch $branch)"

  local task_record_file result
  task_record_file="$(task_dir)/$project/$task.md"
  if result="$(node "$CRUX_HOME/lib/task.mjs" ensure --file "$task_record_file" \
      --task "$task" --project "$project" --repo "$repo_name" --workspace "$name" 2>&1)"; then
    [[ "$result" == joined ]] && ok "joins the already open task '$task'" || ok "task '$task' registered"
    node "$CRUX_HOME/lib/task.mjs" branch --file "$task_record_file" --repo "$repo_name" --branch "$branch" \
      >/dev/null 2>&1 || warn "could not note the branch in the task: without it, another machine will not know how to resume it"
    local task_language
    task_language="$(commit_language "$profile" "$docs")"
    info "write it in '$task_language': the proposal description comes from it"
    [[ -z "$goal" ]] || node "$CRUX_HOME/lib/task.mjs" set --file "$task_record_file" \
      --section Objective --text "$goal" >/dev/null 2>&1 || warn "could not note the objective"
  else
    warn "could not write the task record: $result"
  fi

  # The gate marker is local state. It goes to the common directory's exclude,
  # which is the one git honours from a worktree, and so it does not touch the
  # versioned .gitignore —which in someone else's repo cannot be touched.
  local common; common="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null || echo "")"
  if [[ -n "$common" ]]; then
    mkdir -p "$common/info"
    local to_ignore
    for to_ignore in .crux-ship .crux-visual ${ENV_FILE:+"$ENV_FILE"}; do
      grep -qxF "$to_ignore" "$common/info/exclude" 2>/dev/null \
        || echo "$to_ignore" >> "$common/info/exclude"
    done
  fi

  # An unversioned file does not travel with `git worktree add`: without this,
  # the client profile's local pointer stayed in the original repo.
  if [[ -n "$docs" && "$(profile_get "$profile" "$docs" pointers.local false)" == "true" ]]; then
    local rc_pointer=0
    write_local_pointer "$path" "$(basename "$docs")" || rc_pointer=$?
    if [[ $rc_pointer -eq 0 ]]; then
      ok "$LOCAL_POINTER points to $(basename "$docs") (excluded from git)"
    fi
  fi

  if [[ -n "$ENV_FILE" ]]; then
    # It starts from the main checkout's file: it is ignored by git, so the
    # worktree never gets it, and writing only the template's variables left a
    # workspace without the keys the app needs to start (a 404 at login). The
    # template wins where both define a variable: ports and databases are per
    # slot.
    local env_report
    env_report="$(node -e '
      const fs = require("fs");
      const [file, base, example, tmplRaw, slot, port0, name, branch] = process.argv.slice(1);
      const subst = (v) => String(v)
        .replace(/\{\{SLOT\}\}/g, slot).replace(/\{\{NAME\}\}/g, name)
        .replace(/\{\{BRANCH\}\}/g, branch)
        .replace(/\{\{PORT(\d+)\}\}/g, (_, i) => String(Number(port0) + Number(i)));
      const keyOf = (l) => (l.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/) || [])[1];
      const tmpl = Object.fromEntries(Object.entries(JSON.parse(tmplRaw)).map(([k, v]) => [k, subst(v)]));
      const lines = fs.existsSync(base) ? fs.readFileSync(base, "utf8").split("\n") : [];
      const seen = new Set();
      const out = lines.map((l) => {
        const k = keyOf(l);
        if (!k) return l;
        seen.add(k);
        return k in tmpl ? `${k}=${tmpl[k]}` : l;
      });
      while (out.length && out[out.length - 1] === "") out.pop();
      for (const [k, v] of Object.entries(tmpl)) if (!seen.has(k)) out.push(`${k}=${v}`);
      fs.writeFileSync(file, out.join("\n") + "\n", { mode: 0o600 });
      const have = new Set(out.map(keyOf).filter(Boolean));
      const missing = fs.existsSync(example)
        ? [...new Set(fs.readFileSync(example, "utf8").split("\n").map(keyOf).filter(Boolean))].filter((k) => !have.has(k))
        : [];
      process.stdout.write(`${lines.length ? "copied" : "fresh"}\t${missing.join(" ")}`);
    ' "$path/$ENV_FILE" "$repo/$ENV_FILE" "$path/.env.example" "$ENV_TEMPLATE" "$slot" "$PORT0" "$name" "$branch")"
    if [[ "${env_report%%$'\t'*}" == "copied" ]]; then
      ok "$ENV_FILE from $repo_name's, with slot $slot (ports from $PORT0)"
    else
      ok "$ENV_FILE with slot $slot (ports from $PORT0)"
    fi
    local missing_keys="${env_report#*$'\t'}"
    [[ -n "$missing_keys" ]] &&
      warn "$ENV_FILE lacks what .env.example asks for: $missing_keys"
  else
    info "no workspace configuration for $repo_name: only the port range is reserved"
  fi

  # A worktree shares the history but not ignored files, so it is born without
  # dependencies installed. Without this, the first command run in the
  # workspace fails with an error that does not say what is wrong.
  if [[ "$INSTALL_DEPS" != "false" ]]; then
    local install=""
    if   [[ -f "$path/pnpm-lock.yaml" ]];   then install="pnpm install --prefer-offline"
    elif [[ -f "$path/package-lock.json" ]]; then install="npm ci --prefer-offline"
    elif [[ -f "$path/yarn.lock" ]];        then install="yarn install"
    elif [[ -f "$path/bun.lockb" ]];        then install="bun install"
    elif [[ -f "$path/uv.lock" ]];          then install="uv sync"
    elif [[ -f "$path/poetry.lock" ]];      then install="poetry install"
    elif [[ -f "$path/requirements.txt" ]]; then install="pip install -r requirements.txt"
    elif [[ -f "$path/go.mod" ]];           then install="go mod download"
    elif [[ -f "$path/Cargo.toml" ]];       then install="cargo fetch"
    fi
    if [[ -n "$install" ]]; then
      if ( cd "$path" && eval "$install" >/dev/null 2>&1 ); then
        ok "dependencies installed (${install%% *})"
      else
        warn "could not install the dependencies: do it with '$install'"
      fi
    fi
  fi

  if [[ -n "$SETUP_CMD" ]]; then
    local cmd; cmd="$(substitute "$SETUP_CMD")"
    if ( cd "$path" && eval "$cmd" ); then
      ok "setup executed"
    else
      warn "the setup failed — the workspace exists, but check its resources"
    fi
  fi

  RESERVED=""

  echo
  ok "workspace '$name' ready"
  info "slot $slot · ports $PORT0-$((PORT0 + PORTS_PER_SLOT - 1))"
  info "cd $path"
}

cmd_finish() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "usage: crux workspace finish <name> [--title \"...\"] [--skip-gate]"

  local title="" SKIP_GATE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --skip-gate) SKIP_GATE=1; shift ;;
      --sin-puerta) die "--sin-puerta is now called --skip-gate" ;;
      *) die "unknown option: $1" ;;
    esac
  done

  registry_init
  local data
  data="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.branch, w.repo].join("\n"));
  ' "$REGISTRY" "$name")" || die "the workspace '$name' does not exist"

  local path branch repo
  path="$(echo "$data" | sed -n 1p)"
  branch="$(echo "$data" | sed -n 2p)"
  repo="$(echo "$data" | sed -n 3p)"
  [[ -d "$path" ]] || die "the workspace '$name' is no longer on disk"

  # Nothing leaves a workspace uncommitted: what stays out of git does not
  # reach review, and that is the point of working this way.
  local pending
  pending="$(git -C "$path" status --porcelain | grep -vE ' \.crux-(ship|visual)$' || true)"
  if [[ -n "$pending" ]]; then
    err "uncommitted changes remain in $path"
    echo "$pending" | sed 's/^/      /'
    exit 1
  fi

  # What is not yet in any remote: it is what goes into the proposal.
  local commits
  commits="$(git -C "$path" log --oneline "$branch" --not --remotes 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${commits:-0}" -gt 0 ]] || commits=0
  [[ "$commits" -eq 0 ]] && die "there is nothing to propose in $branch"

  # The quality gate records the commit it verified. Without it, a code
  # proposal that nobody has reviewed would be opened, and review would depend
  # on someone remembering.
  # The receipt says what was run and with what result. A bare sha only said
  # that someone wrote it, which is not the same: the gate is earned, not
  # declared. The shortcut exists, but it has to be asked for and it shows.
  local head
  head="$(git -C "$path" rev-parse HEAD)"
  if [[ $SKIP_GATE -eq 1 ]]; then
    warn "proposal opened WITHOUT passing the quality gate, at explicit request"
  else
    local receipt="$path/.crux-ship" sealed="" commands=0 failures=0
    if [[ -f "$receipt" ]]; then
      sealed="$(awk '/^sealed /{print $2}' "$receipt" | tail -1)"
      commands="$(receipt_commands "$receipt")"
      failures="$(receipt_failures "$receipt")"
    fi
    if [[ ! -f "$receipt" ]]; then
      err "this commit has not passed the quality gate"
      info "pass it: crux ship run -- <command>, then crux ship seal"
      info "if skipping it is really needed: --skip-gate"
      exit 1
    fi
    if [[ "${commands:-0}" -eq 0 ]]; then
      err "the gate receipt records not a single command run"
      info "a bare sha does not prove anything was verified: crux ship run -- <command>"
      exit 1
    fi
    if [[ "${failures:-0}" -gt 0 ]]; then
      err "the receipt records $(count "$failures" check checks) in red"
      receipt_failed "$receipt" | sed 's/^/      /'
      exit 1
    fi
    if [[ "$sealed" != "$head" ]]; then
      err "this commit has not passed the quality gate"
      [[ -n "$sealed" ]] && info "the receipt is for ${sealed:0:8}, and HEAD is ${head:0:8}"
      info "pass it again and close with: crux ship seal"
      exit 1
    fi
    local kernel_receipt
    kernel_receipt="$(receipt_kernel "$receipt")"
    if [[ -z "$kernel_receipt" ]]; then
      err "the receipt does not say which crux version sealed it"
      info "seal it again: crux ship seal"
      exit 1
    fi
    if [[ "$kernel_receipt" != "$(crux_version)" ]]; then
      err "the receipt was sealed with crux $kernel_receipt and now $(crux_version) is running"
      info "the gate rules may have changed: pass it again"
      exit 1
    fi
    ok "gate passed on ${head:0:8} with $(count "$commands" check checks) (crux $kernel_receipt)"
  fi

  # This is where context is lost: the proposal goes out and the session that
  # knew why each thing was done ends. If the record has not a single step, the
  # task is left with a one-line objective and nothing else, and what was
  # measured or discarded along the way is recovered by nobody. It goes before
  # pushing, which is when it can still be noted. It warns and carries on: the
  # one who decides whether the task deserved a record is whoever did it, not
  # the kernel.
  local task_record_file
  task_record_file="$(task_file_for_path "$REGISTRY" "$path" 2>/dev/null || echo "")"
  if [[ -n "$task_record_file" && -f "$task_record_file" ]]; then
    local task_steps
    task_steps="$(node "$CRUX_HOME/lib/task.mjs" summary --file "$task_record_file" 2>/dev/null |
      cut -d$'\x1f' -f3)"
    if [[ -z "$task_steps" ]]; then
      warn "the task is closed without a single step noted"
      info "only the objective is left in $task_record_file"
      info "what you measured and what you discarded along the way is recovered by nobody"
      info "note it now: crux task add \"<step>\" · crux task note \"<decision>\" --why \"<why>\""
    fi
  fi

  # A branch that clashes with the main one goes out as a proposal that cannot
  # be merged, and the gate was passed against a base that no longer exists.
  # It is checked before pushing, with the latest from the remote; offline, it
  # carries on as before.
  local remote_main
  remote_main="$(main_branch "$path")"
  if git -C "$path" fetch -q origin "$remote_main" 2>/dev/null &&
     git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$remote_main"; then
    local clashes behind
    if ! clashes="$(git -C "$path" merge-tree --write-tree --name-only --no-messages \
        HEAD "origin/$remote_main" 2>/dev/null)"; then
      err "the branch clashes with origin/$remote_main"
      printf '%s\n' "$clashes" | tail -n +2 | sed 's/^/      /'
      info "rebase and pass the gate again: git rebase origin/$remote_main"
      exit 1
    fi
    behind="$(git -C "$path" rev-list --count "HEAD..origin/$remote_main" 2>/dev/null || echo 0)"
    [[ "${behind:-0}" -gt 0 ]] &&
      warn "origin/$remote_main has $(count "$behind" "commit" "commits") that this branch lacks; they do not clash"
  fi

  # The base branch comes from the contract, the remote or the local one, in
  # that order. It used to fall back to origin/main when there was no
  # origin/HEAD, and in a repo with another main branch the range below fails
  # with 128: with set -e the script dies here, with the branch already pushed
  # and the proposal not opened.
  local branch_ref base
  branch_ref="$(main_branch "$path")"
  if git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$branch_ref"; then
    base="origin/$branch_ref"
  else
    base="$branch_ref"
  fi

  # A proposal of more than 400 written lines is not reviewed well in one
  # sitting. It warns and carries on: splitting it is up to whoever made it, and
  # some changes cannot be split. Generated files do not count, because nobody
  # reads them line by line.
  local written_lines
  written_lines="$(git -C "$path" diff --numstat "$base...$branch" 2>/dev/null | awk '
    $1 == "-" { next }
    $3 ~ /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|go\.sum)$/ { next }
    $3 ~ /(^|\/)(dist|build|vendor|generated|__snapshots__)\// || $3 ~ /\.(min\.(js|css)|snap)$/ { next }
    { n += $1 + $2 } END { print n + 0 }')"
  if [[ "${written_lines:-0}" -gt 400 ]]; then
    warn "the proposal has $written_lines written lines: over 400, what can be reviewed well at once"
    info "if it can be split into units that work on their own, split it into chained proposals"
    info "if not, say in the description why it goes whole"
  fi

  # Nothing forces presenting the plan before writing code, and blocking it
  # would be worse: a typo does not need one. But a change this size with no
  # plan in the record is precisely the one nobody could stop in time.
  if [[ "${written_lines:-0}" -gt 100 && -n "$task_record_file" && -f "$task_record_file" ]]; then
    local plan_lines
    plan_lines="$(awk '/^## /{on = ($0 == "## Plan"); next} on && NF && !/^<!--.*-->$/' "$task_record_file" | wc -l | tr -d ' ')"
    if [[ "$plan_lines" -eq 0 ]]; then
      warn "$written_lines written lines and the task has no plan"
      info "if it was approved in the conversation, save it: crux task plan <file>"
    fi
  fi

  # If the task says what changes and why, the description comes from there;
  # if not, from the commits, as always. An empty record does not improve the
  # proposal.
  local body="" language docs_fin profile_fin=""

  docs_fin="$(find_docs_repo "$path" 2>/dev/null || echo "")"
  [[ -n "$docs_fin" && -f "$docs_fin/crux.json" ]] &&
    profile_fin="$(json_get "$docs_fin/crux.json" profile 2>/dev/null || echo "")"
  # The description goes in the language of what is published in the repo, the
  # same as the commits. The task is written in that language because the text
  # comes from it.
  language="$(commit_language "$profile_fin" "$docs_fin")"
  if [[ -n "$task_record_file" && -f "$task_record_file" ]]; then
    body="$(node "$CRUX_HOME/lib/task.mjs" body --file "$task_record_file" --lang "$language" \
      --commits "$(git -C "$path" log --format='- %s' "$base..$branch")" 2>/dev/null || true)"
  fi
  # If the gate was skipped, the proposal says so. The default body used to
  # claim "gate passed" even with --skip-gate: false evidence misleads more
  # than missing evidence.
  local changes gate_line
  if [[ "$language" == "es" ]]; then
    changes="Cambios"
    if [[ $SKIP_GATE -eq 1 ]]; then gate_line="Abierta SIN pasar la puerta de calidad, a petición explícita."
    else gate_line="Puerta de calidad pasada sobre ${head:0:8}."; fi
  else
    changes="Changes"
    if [[ $SKIP_GATE -eq 1 ]]; then gate_line="Opened WITHOUT passing the quality gate, at explicit request."
    else gate_line="Quality gate passed on ${head:0:8}."; fi
  fi
  if [[ -z "$body" ]]; then
    body="$(printf '%s:\n\n%s\n\n---\n%s\n' "$changes" \
      "$(git -C "$path" log --format='- %s' "$base..$branch")" "$gate_line")"
  elif [[ $SKIP_GATE -eq 1 ]]; then
    body="$(printf '%s\n\n---\n%s\n' "$body" "$gate_line")"
  fi

  # The visual review a person approved goes into the proposal if it is for the
  # commit being proposed. If it is not, it says so and carries on: old
  # screenshots are not published as if they were current, but they do not block.
  if [[ -f "$path/.crux-visual" ]]; then
    local visual="" rc_visual=0
    visual="$(cd "$path" && bash "$CRUX_HOME/bin/visual.sh" section --publish --lang "$language" 2>&1)" || rc_visual=$?
    if [[ $rc_visual -eq 0 ]]; then
      body="$(printf '%s\n\n%s' "$body" "$visual")"
      ok "visual review added to the proposal"
    else
      warn "the visual review does not go into the proposal"
      printf '%s\n' "$visual" | sed 's/^/      /'
    fi
  fi

  # The body goes through the same filter as ship body before anything leaves.
  # It existed and nobody called it: it depended on the agent remembering, and
  # what is published outside cannot depend on that. It goes before the push so
  # that a body with a credential inside does not even push the branch.
  local body_tmp
  body_tmp="$(mktemp "${TMPDIR:-/tmp}/crux-body.XXXXXX")"
  printf '%s\n' "$body" > "$body_tmp"
  if ! ( cd "$path" && bash "$CRUX_HOME/bin/ship.sh" body "$body_tmp" >/dev/null 2>&1 ); then
    err "the proposal body does not pass the filter"
    ( cd "$path" && bash "$CRUX_HOME/bin/ship.sh" body "$body_tmp" 2>&1 | sed 's/^/      /' ) || true
    info "it comes from the task record: $task_record_file"
    rm -f "$body_tmp"
    exit 1
  fi
  rm -f "$body_tmp"

  git -C "$path" push -q -u origin "$branch" || die "could not push $branch"
  ok "$branch pushed ($(count "$commits" commit commits))"

  local url_pr=""
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    # Against the base branch, not against --remotes: by the time the title is
    # computed the branch is already pushed, so --remotes would exclude it
    # entirely and the title would come out empty.
    local first_one
    first_one="$(git -C "$path" log --format='%s' "$base..$branch" | tail -1)"
    [[ -n "$first_one" ]] || first_one="$(git -C "$path" log -1 --format=%s "$branch")"
    # The title is what the squash leaves in the main branch's history. With
    # several commits, the first one rarely sums them up.
    if [[ -z "$title" && "$commits" -gt 1 ]]; then
      warn "the title comes from the first of $commits commits: \"$first_one\""
      info "if it does not sum them up: gh pr edit --title \"...\", or next time finish --title \"...\""
    fi
    # gh's error is kept instead of thrown away: without it, an already open
    # proposal, a mandatory template or a missing permission gave the same
    # message as not having gh installed.
    local gh_err
    gh_err="$(mktemp "${TMPDIR:-/tmp}/crux-gh.XXXXXX")"
    url_pr="$(cd "$path" && gh pr create \
      --title "${title:-$first_one}" \
      --body "$body" 2>"$gh_err" || true)"
    if [[ -z "$url_pr" && -s "$gh_err" ]]; then
      warn "gh could not open the proposal"
      head -3 "$gh_err" | sed 's/^/      /'
    fi
    rm -f "$gh_err"
  fi

  if [[ -n "$url_pr" ]]; then
    ok "proposal opened: $url_pr"
    if [[ -n "$task_record_file" && -f "$task_record_file" ]]; then
      node "$CRUX_HOME/lib/task.mjs" meta --file "$task_record_file" --key pr --value "$url_pr" >/dev/null 2>&1 || true
      node "$CRUX_HOME/lib/task.mjs" status --file "$task_record_file" --to proposed >/dev/null 2>&1 || true
    fi
  else
    info "open the proposal on your provider from the branch $branch"
  fi

  echo
  info "review it before asking for human review: /review-pr"
  info "once it is merged: crux workspace rm $name"
}

cmd_merge() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "usage: crux workspace merge <name> [--yes]"

  local confirmed=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) confirmed=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
    || die "an authenticated gh is needed to query and merge the proposal"

  registry_init
  local data path branch
  data="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.branch].join("\n"));
  ' "$REGISTRY" "$name")" || die "the workspace '$name' does not exist"
  path="$(echo "$data" | sed -n 1p)"
  branch="$(echo "$data" | sed -n 2p)"
  [[ -d "$path" ]] || die "the workspace '$name' is no longer on disk"

  local status
  status="$(cd "$path" && gh pr view --json number,title,url,mergeable,reviewDecision,statusCheckRollup 2>/dev/null)" \
    || die "there is no open proposal for $branch — run 'crux workspace finish $name'"

  # All the signals are listed before deciding: a proposal can have green
  # checks and be in conflict, or the other way round.
  eval "$(node -e '
    const d = JSON.parse(process.argv[1]);
    const checks = d.statusCheckRollup || [];
    const failing = checks.filter((c) => ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT"].includes(c.conclusion));
    const running = checks.filter((c) => c.status && c.status !== "COMPLETED");
    // Single quotes, as in load_config: inside double quotes bash still expands
    // $(...), and these values come from gh, that is from the title anyone can
    // give the proposal.
    const q = (v) => `'"'"'${String(v).replace(/'"'"'/g, `'"'"'\\'"'"''"'"'`)}'"'"'`;
    console.log(`PR_NUM=${d.number}`);
    console.log(`PR_URL=${q(d.url)}`);
    console.log(`PR_TITLE=${q(d.title)}`);
    console.log(`PR_MERGEABLE=${q(d.mergeable)}`);
    console.log(`PR_REVIEW=${q(d.reviewDecision || "no review required")}`);
    console.log(`PR_CHECKS_TOTAL=${checks.length}`);
    console.log(`PR_CHECKS_FAILING=${failing.length}`);
    console.log(`PR_CHECKS_RUNNING=${running.length}`);
    console.log(`PR_FAILING_NAMES=${q(failing.map((c) => c.name || c.context).join(", "))}`);
  ' "$status")"

  echo "proposal #$PR_NUM · $PR_TITLE"
  echo "$PR_URL"
  echo

  local blocked=0
  local no_ci=0
  if [[ "$PR_CHECKS_TOTAL" -eq 0 ]]; then
    warn "no automatic checks: the only validation is the one you passed locally"
    no_ci=1
  elif [[ "$PR_CHECKS_RUNNING" -gt 0 ]]; then
    warn "$PR_CHECKS_RUNNING checks still running"
    blocked=1
  elif [[ "$PR_CHECKS_FAILING" -gt 0 ]]; then
    err "$PR_CHECKS_FAILING checks failing: $PR_FAILING_NAMES"
    blocked=1
  else
    ok "$PR_CHECKS_TOTAL checks green"
  fi

  case "$PR_MERGEABLE" in
    MERGEABLE) ok "no conflicts" ;;
    CONFLICTING) err "there are conflicts to resolve"; blocked=1 ;;
    *) warn "unknown merge state: $PR_MERGEABLE" ;;
  esac

  [[ "$PR_REVIEW" == "CHANGES_REQUESTED" ]] && { err "changes were requested in the review"; blocked=1; }

  echo
  if [[ $blocked -eq 1 ]]; then
    err "not merging: there is something to resolve first"
    exit 1
  fi

  if [[ $confirmed -eq 0 ]]; then
    [[ $no_ci -eq 1 ]] && ok "nothing blocks the merge, but there is no automatic safety net behind it" \
                        || ok "all green"
    info "to merge it: crux workspace merge $name --yes"
    exit 0
  fi

  # Without --delete-branch: gh tries to switch to the base branch to delete the
  # local one, and from a worktree that fails because the base is already used
  # by another. The remote branch is deleted separately.
  ( cd "$path" && gh pr merge --squash ) || true

  # The exit code is not trusted: the failure may come from the cleanup after
  # the merge is already done, and reporting an error then would be lying.
  local merged
  merged="$(cd "$path" && gh pr view --json mergedAt -q '.mergedAt // ""' 2>/dev/null)"
  [[ -n "$merged" ]] || die "proposal #$PR_NUM was not merged"
  ok "proposal #$PR_NUM merged"
  local task_record_file
  task_record_file="$(task_file_for_path "$REGISTRY" "$path" 2>/dev/null || echo "")"
  [[ -n "$task_record_file" && -f "$task_record_file" ]] &&
    node "$CRUX_HOME/lib/task.mjs" status --file "$task_record_file" --to merged >/dev/null 2>&1 || true

  git -C "$path" push -q origin --delete "$branch" 2>/dev/null \
    && ok "remote branch deleted" \
    || info "the remote branch is still there: delete it from your provider if you want"

  echo
  # Once merged, the workspace has nothing left to do. Leaving it alive by
  # default was what piled up finished workspaces for weeks. rm refuses only if
  # something is uncommitted, and then it stays and says so.
  if [[ "$(preference CRUX_MERGE_CLOSE_WORKSPACE true)" == "true" ]]; then
    ( cmd_rm "$name" ) || warn "the workspace is still alive: close it with 'crux workspace rm $name' when it is clean"
  else
    info "the workspace is still alive (CRUX_MERGE_CLOSE_WORKSPACE=false): 'crux workspace rm $name'"
  fi
}

cmd_list() {
  local all_flag=0
  [[ "${1:-}" == "--all" ]] && all_flag=1
  registry_init
  local here=""
  [[ $all_flag -eq 0 ]] && here="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const here = process.argv[2];
    let rows = Object.entries(r.workspaces);
    const total = rows.length;
    // From inside a workspace, "this repo" is the repo it hangs from, not the
    // worktree path: otherwise the list said there was nothing right when
    // resuming, which is when it is looked at.
    const own = rows.find(([, w]) => w.path === here);
    const repo = own ? own[1].repo : here;
    if (here) rows = rows.filter(([, w]) => w.repo === repo);
    if (!rows.length) {
      console.log(total ? `no workspaces in this repo (${total} in others: crux workspace list --all)`
                        : "no active workspaces");
      process.exit(0);
    }
    const since = (p) => {
      try {
        const days = Math.floor((Date.now() - fs.statSync(p).mtimeMs) / 86400000);
        return days < 1 ? "today" : days === 1 ? "yesterday" : `${days} days ago`;
      } catch { return ""; }
    };
    // What matters on returning to a workspace is where it was left: the status
    // and next step of its task, not just the slot.
    const task = (w) => {
      if (!w.task || !w.project) return "";
      try {
        const t = fs.readFileSync(`${process.argv[3]}/${w.project}/${w.task}.md`, "utf8");
        const status = (t.match(/^status: (.*)$/m) || [])[1] || "";
        const next = ((t.split(/^## (?:Next step|Siguiente paso)$/m)[1] || "").split(/^## /m)[0] || "")
          .replace(/<!--[\s\S]*?-->/g, "").trim().split("\n")[0];
        const pending = (t.match(/^- \[ \] (T\d+ .*)$/m) || [])[1] || "";
        return `${status}${(next || pending) ? " · " + (next || pending).slice(0, 60) : ""}`;
      } catch { return ""; }
    };
    for (const [name, w] of rows) {
      const alive = fs.existsSync(w.path);
      const tail = alive ? since(w.path) : "no worktree — remove it with: crux workspace gc";
      console.log(`${name.padEnd(16)} slot ${String(w.slot).padStart(2)}  ports ${w.ports[0]}-${w.ports[1]}  ${tail.padEnd(14)}  ${w.path}`);
      const t = task(w);
      if (t) console.log(`${"".padEnd(16)} task ${w.task}: ${t}`);
    }
  ' "$REGISTRY" "$here" "$(task_dir)"
}

# Hooks are tested before a release by installing them from a kernel
# workspace. On closing it they would point to a deleted folder and fail on
# every message, command and agent shutdown: if the repo is the kernel, they
# are reinstalled from the main checkout and those that only existed in the
# workspace are removed.
repoint_hooks() {
  local workspace="$1" main_repo="$2" settings="$3"
  if [[ ! -f "$main_repo/bin/hooks.sh" || ! -d "$main_repo/adapters" ]] ||
    ! ( cd "$main_repo" && CRUX_HOME="$main_repo" CLAUDE_SETTINGS="$settings" \
          bash "$main_repo/bin/hooks.sh" install >/dev/null 2>&1 ); then
    warn "the agent hooks point to this workspace: they will break when it is deleted"
    info "reinstall them from the main repo: crux hooks install"
    return 0
  fi

  local removed
  removed="$(node -e '
    const fs = require("fs");
    const [file, prefix] = process.argv.slice(1);
    const settings = JSON.parse(fs.readFileSync(file, "utf8"));
    let removed = 0;
    for (const [event, groups] of Object.entries(settings.hooks || {})) {
      for (const group of groups) {
        const kept = (group.hooks || []).filter((h) => !(h.command || "").includes(prefix));
        removed += (group.hooks || []).length - kept.length;
        group.hooks = kept;
      }
      settings.hooks[event] = groups.filter((g) => g.hooks.length);
    }
    fs.writeFileSync(file, JSON.stringify(settings, null, 2) + "\n");
    process.stdout.write(String(removed));
  ' "$settings" "$workspace/")"

  ok "agent hooks returned to the main checkout: $main_repo"
  [[ "$removed" == "0" ]] || info "removed $removed that only existed in the workspace"
}

cmd_rm() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "usage: crux workspace rm <name> [--include-ignored]"
  local include_ignored=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-ignored) include_ignored=1; shift ;;
      --con-ignorados) die "--con-ignorados is now called --include-ignored" ;;
      *) die "unknown option: $1" ;;
    esac
  done

  registry_init
  with_lock

  local path repo branch
  path="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.repo, w.branch, w.project || "", w.task || ""].join("\n"));
  ' "$REGISTRY" "$name")" || die "the workspace '$name' does not exist"

  repo="$(echo "$path" | sed -n 2p)"
  branch="$(echo "$path" | sed -n 3p)"
  local project_rm task_rm
  project_rm="$(echo "$path" | sed -n 4p)"
  task_rm="$(echo "$path" | sed -n 5p)"
  path="$(echo "$path" | sed -n 1p)"
  unlock

  if [[ -d "$path" ]]; then
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      die "$path has uncommitted changes — resolve them before deleting it"
    fi
    # Installing the hooks from inside a workspace leaves them pointing at it,
    # and on closing it they cease to exist with nothing saying so until the
    # next session.
    local settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
    if [[ -f "$settings" ]] && grep -qF "$path/" "$settings"; then
      repoint_hooks "$path" "$repo" "$settings"
    fi

    SLOT="$(node -e '
      const fs = require("fs");
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(r.workspaces[process.argv[2]].slot));
    ' "$REGISTRY" "$name")"
    PORT0=0; WS_NAME="$name"; WS_BRANCH="$branch"
    local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
    load_config "$docs" "$(basename "$repo")"

    # After load_config: ENV_FILE comes from the contract, and crux itself writes
    # that file, so it does not count as work that is lost.
    if [[ $include_ignored -eq 0 && -n "$(ignored_files "$path" "${ENV_FILE:-}")" ]]; then
      err "$path has ignored files that would be lost on removal"
      ignored_files "$path" "${ENV_FILE:-}" | sed 's/^/      /' | head -10
      info "take them out of there, or remove it anyway: crux workspace rm $name --include-ignored"
      exit 1
    fi

    if [[ -n "$TEARDOWN_CMD" ]]; then
      ( cd "$path" && eval "$(substitute "$TEARDOWN_CMD")" ) \
        && ok "teardown executed" \
        || warn "the teardown failed — check whether resources of slot $SLOT were left behind"
    fi
    if git -C "$repo" worktree remove "$path" 2>/dev/null \
       || git -C "$repo" worktree remove --force "$path" 2>/dev/null; then
      ok "worktree removed"
    else
      # git stops recognising it if someone deleted its record some other way.
      # The directory still occupies the slot, so it is removed anyway.
      rm -rf "$path"
      git -C "$repo" worktree prune 2>/dev/null || true
      ok "directory removed (git no longer had it as a worktree)"
    fi
  fi

  with_lock
  if remove_from_registry "$name"; then
    unlock
    ok "slot released"
  else
    unlock
    err "the worktree is gone, but its entry is still in the registry"
    info "the slot and ports stay reserved until it is removed"
    info "check the permissions of $REGISTRY and retry: crux workspace heal"
    exit 1
  fi

  [[ -n "$task_rm" && -n "$project_rm" ]] && archive_if_finished "$project_rm" "$task_rm"

  # Only if it is merged: a branch with work that is nowhere else is not
  # deleted because of a preference.
  # Here crux created the branch for this workspace, so `--merged` does say
  # what it seems to: its commits are in the main branch. What does not work as
  # proof is for an arbitrary branch of the repo, which is what prune is about.
  if [[ "$(preference CRUX_RM_DELETE_BRANCH false)" == "true" ]] &&
     git -C "$repo" branch --merged "$(main_branch "$repo")" 2>/dev/null |
       sed 's/^[ *]*//' | grep -qxF -- "$branch" &&
     [[ -n "$(git -C "$repo" log --oneline "$(main_branch "$repo")".."$branch" 2>/dev/null ||
              git -C "$repo" log --oneline -1 "$branch" 2>/dev/null)" ]]; then
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 \
      && ok "branch $branch deleted (CRUX_RM_DELETE_BRANCH)" \
      || info "the branch $branch still exists"
  else
    info "the branch $branch still exists; delete it if you no longer need it"
  fi
}

# A task archives itself when its last workspace closes and it is already
# merged. If it is still open, it stays: a workspace can be closed to resume
# the task from another, and archiving unfinished work would hide it.
archive_if_finished() {
  local project="$1" task="$2" task_record status others target
  task_record="$(task_dir)/$project/$task.md"
  [[ -f "$task_record" ]] || return 0
  others="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const n = Object.values(r.workspaces || {}).filter((w) => w.project === process.argv[2] && w.task === process.argv[3]).length;
    process.stdout.write(String(n));
  ' "$REGISTRY" "$project" "$task")"
  if [[ "${others:-0}" -gt 0 ]]; then
    info "the task '$task' is still in $others more workspace(s)"
    return 0
  fi
  status="$(awk -F': ' '/^status:/{print $2; exit}' "$task_record")"
  # Merged but waiting for an answer: it stays alive until it arrives.
  local waiting_on
  waiting_on="$(awk -F': ' '/^waiting_on:/{print $2; exit}' "$task_record")"
  if [[ -n "$waiting_on" ]]; then
    info "the task '$task' is waiting on $waiting_on: not archiving"
    return 0
  fi
  case "$status" in
    merged|deployed)
      promote_decisions "$task_record"
      if target="$(node "$CRUX_HOME/lib/task.mjs" archive --file "$task_record" 2>&1)"; then
        ok "task '$task' archived"
      else
        warn "could not archive the task: $target"
      fi
      ;;
    closed) ;;
    *)
      info "the task '$task' is still open ($status)"
      info "if it is no longer going: crux task archive --task $project/$task"
      ;;
  esac
}

# A branch merged by squash does not appear in `git branch --merged`: its
# commit never enters the main branch. Asking the proposal is the only reliable
# thing in a flow that merges that way.
branches_with_merged_pr() {
  # The branches that really had a merged proposal, in a single call. Before,
  # `git branch --merged` was used as a shortcut, and that is true for any
  # branch pointing at an ancestor of the main branch: a freshly created one
  # with not a single commit of its own, or a long-lived one such as develop or
  # staging right after its release lands. They were deleted, here and on the
  # remote, saying "its proposal already merged" without ever having asked.
  local repo="$1" slug
  slug="$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || return 1
  [[ -n "$slug" ]] || return 1
  gh pr list --repo "$slug" --state merged --limit 200 --json headRefName \
     -q '.[].headRefName' 2>/dev/null
}

# The registry repairs itself. An entry whose folder no longer exists and whose
# branch does not either holds nothing: someone removed the worktree on their
# own —a `git worktree remove` to free disk— and the registry did not find out.
# 41 piled up that way. If the branch is still alive, there may be work: it
# warns and leaves it.
cmd_heal() {
  local quiet=0
  [[ "${1:-}" == "--quiet" ]] && quiet=1
  [[ -f "$REGISTRY" ]] || return 0
  local n repo branch path project task retired=0
  while IFS=$'\t' read -r n repo branch path project task; do
    [[ -n "$n" ]] || continue
    if [[ -d "$repo" ]] && git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1; then
      [[ $quiet -eq 1 ]] || warn "'$n' has no folder, but its branch $branch is still alive: not removing"
      continue
    fi
    with_lock 50
    remove_from_registry "$n"
    unlock
    retired=$((retired + 1))
    [[ $quiet -eq 1 ]] || ok "'$n' removed from the registry: no folder, no branch"
    [[ -n "$task" && -n "$project" ]] && archive_if_finished "$project" "$task" >/dev/null
  done < <(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      if (fs.existsSync(w.path)) continue;
      console.log([n, w.repo, w.branch, w.path, w.project || "", w.task || ""].join("\t"));
    }
  ' "$REGISTRY")
  if [[ $quiet -eq 1 ]]; then
    [[ $retired -gt 0 ]] && info "registry repaired: $retired workspace(s) with no folder or branch removed"
  elif [[ $retired -eq 0 ]]; then
    ok "the registry is up to date"
  fi
  return 0
}

# A hand-made worktree does not exist for crux: it appears in no list and
# nothing protects it, and `gc --include-disk` would treat it as garbage. It
# happened with one that had work pending review.
cmd_adopt() {
  local path_value="${1:-}"; shift || true
  [[ -n "$path_value" ]] || die "usage: crux workspace adopt <path> [--task <task>]"
  local task=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -d "$path_value" ]] || die "$path_value does not exist"
  path_value="$(cd "$path_value" && pwd)"
  is_worktree "$path_value" || die "$path_value is not a git worktree"
  local base; base="$(basename "$path_value")"
  [[ "$base" == *-ws-* ]] || die "the name does not follow the pattern <repo>-ws-<name>: $base"
  local name="${base#*-ws-}" repo branch
  repo="$(main_repo "$path_value")"
  branch="$(git -C "$path_value" rev-parse --abbrev-ref HEAD)"
  valid_name "$name" || die "invalid workspace name: '$name'"
  task="${task:-$name}"
  local project; project="$(project_name_for "$repo")"

  registry_init
  with_lock
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const [, , name, path] = process.argv.slice(1);
    if (r.workspaces[name]) { console.error(`there is already a workspace called ${name}`); process.exit(2); }
    if (Object.values(r.workspaces).some((w) => w.path === path)) { console.error("that worktree is already registered"); process.exit(2); }
  ' "$REGISTRY" x "$name" "$path_value" || { unlock; exit 1; }

  local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
  load_config "$docs" "$(basename "$repo")"
  local slot
  slot="$(node -e '
    const fs = require("fs");
    const [file, base, perSlot] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    const ws = Object.values(r.workspaces);
    const takenSlots = new Set(ws.map((w) => w.slot));
    const ranges = ws.map((w) => w.ports).filter(Array.isArray);
    const isFree = (s) => {
      if (takenSlots.has(s)) return false;
      const since = Number(base) + s * Number(perSlot);
      return !ranges.some(([a, b]) => since <= b && a <= since + Number(perSlot) - 1);
    };
    let s = 0; while (!isFree(s)) s++;
    process.stdout.write(String(s));
  ' "$REGISTRY" "$PORT_BASE" "$PORTS_PER_SLOT")"
  local port0=$((PORT_BASE + slot * PORTS_PER_SLOT))
  write_workspace "$name" "$slot" "$repo" "$path_value" "$branch" "$port0" "$PORTS_PER_SLOT" "$task" "$project"
  unlock

  local task_record_file result
  task_record_file="$(task_dir)/$project/$task.md"
  result="$(node "$CRUX_HOME/lib/task.mjs" ensure --file "$task_record_file" \
    --task "$task" --project "$project" --repo "$(basename "$repo")" --workspace "$name" 2>&1)" \
    || warn "could not write the task record: $result"
  ok "'$name' adopted ($branch, slot $slot)"
  info "task '$task': $task_record_file"
}

# The registry and the disk drift apart in both directions: an entry whose
# worktree someone deleted by hand, and a worktree that never made it into the
# registry. `prune` looks at branches; this looks at workspaces.
cmd_gc() {
  local confirmed=0 include_disk=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) confirmed=1; shift ;;
      --include-disk) include_disk=1; shift ;;
      --con-disco) die "--con-disco is now called --include-disk" ;;
      *) die "unknown option: $1" ;;
    esac
  done

  registry_init
  local root; root="$(projects_root)"

  local without_worktree=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && without_worktree+=("$n")
  done < <(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      if (!fs.existsSync(w.path)) console.log(n);
    }
  ' "$REGISTRY")

  local registered; registered="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(Object.values(r.workspaces || {}).map((w) => w.path).join("\n"));
  ' "$REGISTRY")"

  local unregistered=() d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\n' "$registered" | grep -qxF "$d" && continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    is_worktree "$d" || continue
    unregistered+=("$d")
  done < <(find "$root" -maxdepth 2 -type d -name '*-ws-*' 2>/dev/null | sort)

  expire_tasks "$confirmed"

  if [[ ${#without_worktree[@]} -eq 0 && ${#unregistered[@]} -eq 0 ]]; then
    ok "registry and disk agree"
    return 0
  fi

  if [[ ${#without_worktree[@]} -gt 0 ]]; then
    echo "registry entries with no worktree on disk (${#without_worktree[@]}):"
    printf '      %s\n' "${without_worktree[@]}"
    echo
  fi
  if [[ ${#unregistered[@]} -gt 0 ]]; then
    echo "worktrees on disk that the registry does not know (${#unregistered[@]}):"
    local w
    for w in "${unregistered[@]}"; do
      printf '      %s%s\n' "$(basename "$w")" "$(clean_workspace "$w" || echo "  (with work inside)")"
    done
    echo
  fi

  if [[ $confirmed -eq 0 ]]; then
    info "to remove the orphan entries: crux workspace gc --yes"
    [[ ${#unregistered[@]} -gt 0 ]] \
      && info "and the worktrees, if they are clean: crux workspace gc --yes --include-disk"
    return 0
  fi

  local n
  for n in ${without_worktree[@]+"${without_worktree[@]}"}; do
    with_lock 50
    remove_from_registry "$n"
    unlock
    ok "$n removed from the registry"
  done

  [[ $include_disk -eq 1 ]] || {
    [[ ${#unregistered[@]} -gt 0 ]] && info "the disk is not touched without --include-disk"
    return 0
  }

  local w repo
  for w in ${unregistered[@]+"${unregistered[@]}"}; do
    if ! clean_workspace "$w"; then
      warn "$(basename "$w") has unpushed work: it stays"
      continue
    fi
    repo="$(main_repo "$w")"
    if git -C "$repo" worktree remove "$w" 2>/dev/null; then
      ok "$(basename "$w") removed from disk"
    else
      warn "could not remove $(basename "$w"): do it with 'git worktree remove'"
    fi
  done
}

# Archived tasks expire. What had to last already went out: the description is
# in the proposal and the decisions in the docs repo. The date is in the file
# name, not in the modification time, which changes with any copy.
expire_tasks() {
  local confirmed="$1" days cutoff f date old_items=()
  days="${CRUX_TASKS_RETENTION_DAYS:-$(preference CRUX_TASKS_RETENTION_DAYS 180)}"
  [[ "$days" =~ ^[0-9]+$ ]] || die "CRUX_TASKS_RETENTION_DAYS has to be a number of days: '$days'"
  cutoff="$(node -e 'const d = new Date(Date.now() - Number(process.argv[1]) * 86400000); process.stdout.write(d.toISOString().slice(0, 10))' "$days")"
  for f in "$(task_dir)"/*/done/*.md; do
    [[ -f "$f" ]] || continue
    date="$(basename "$f" | cut -c1-10)"
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ "$date" < "$cutoff" ]] && old_items+=("$f")
  done
  [[ ${#old_items[@]} -gt 0 ]] || return 0
  echo "tasks archived more than $days days ago (${#old_items[@]}):"
  for f in "${old_items[@]}"; do printf '      %s/%s\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(basename "$f" .md)"; done
  if [[ "$confirmed" -eq 1 ]]; then
    # Noted as removed, or the other machine's replica would bring them back.
    # With their creation date, which is read before deleting them.
    for f in "${old_items[@]}"; do
      printf 'done/%s %s\n' "$(basename "$f")" "$(sed -n 's/^created: //p' "$f" | head -1)" \
        >> "$(dirname "$(dirname "$f")")/.removed"
    done
    rm -f "${old_items[@]}"
    ok "${#old_items[@]} expired tasks deleted"
  else
    info "to delete them: crux workspace gc --yes"
  fi
  echo
}

# A worktree is removed only if nothing is lost: neither uncommitted changes
# nor the workspace's own commits that are in no remote. Against the main
# branch and not against HEAD: in a repo with no remote, HEAD --not --remotes
# is every commit of the project and it would never come out clean.
ignored_files() {
  # ignored_files <dir> [file crux regenerates]
  #
  # What a plain git status does not show and is deleted anyway when the
  # worktree is removed: the workspace's database and whatever was left by hand
  # live there. What an install can restore, the gate receipt, the local
  # pointer and the environment file crux itself writes are left out. The
  # regenerable folders, at any depth: a monorepo or a server/ has its own.
  local own="${2:-}"
  git -C "$1" status --porcelain --ignored=matching 2>/dev/null |
    grep -E '^!! ' |
    grep -vE '^!! (\.crux-ship|\.crux-visual|CLAUDE\.local\.md$)' |
    grep -vE '^!! (.*/)?(node_modules|\.next|dist|build|target|\.venv|__pycache__|\.turbo|\.nx|\.pnpm-store|coverage)/' |
    { [[ -n "$own" ]] && grep -vxF "!! $own" || cat; } || true
}

clean_workspace() {
  local w="$1"
  [[ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ]] || return 1
  [[ -z "$(ignored_files "$w" "${ENV_FILE:-}")" ]] || return 1
  local base standalone_items
  base="$(main_branch "$w")"
  standalone_items="$(git -C "$w" log --oneline "$base..HEAD" --not --remotes 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${standalone_items:-0}" -eq 0 ]]
}

cmd_prune() {
  local confirmed=0
  [[ "${1:-}" == "--yes" ]] && confirmed=1

  local repo; repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "this runs inside a repo"
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
    || die "an authenticated gh is needed to know which proposals were merged"

  local main_name; main_name="$(main_branch "$repo")"
  local merged_list
  merged_list="$(branches_with_merged_pr "$repo")" \
    || die "could not ask gh which proposals were merged"

  local integrated=()
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != "$main_name" ]] || continue
    # No long-lived branches: even if their proposal was merged, deleting them
    # breaks the flow of whoever uses them.
    case "$b" in
      develop|development|staging|stage|next|production|prod|release|release/*|hotfix/*) continue ;;
    esac
    printf '%s\n' "$merged_list" | grep -qxF -- "$b" && integrated+=("$b")
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin |
           sed 's|^origin/||' | sort -u)

  if [[ ${#integrated[@]} -eq 0 ]]; then
    ok "there are no merged branches to clean"
    return 0
  fi

  echo "branches with their proposal already merged (${#integrated[@]}):"
  printf '      %s\n' "${integrated[@]}"
  echo
  if [[ $confirmed -eq 0 ]]; then
    info "to delete them, here and on the remote: crux workspace prune --yes"
    return 0
  fi

  local cleaned=0
  local in_use; in_use="$(git -C "$repo" worktree list --porcelain | sed -n 's/^branch refs\/heads\///p')"
  for b in "${integrated[@]}"; do
    if echo "$in_use" | grep -qx "$b"; then
      info "$b is used by a worktree: it stays"
      continue
    fi
    # With set -e, a failing deletion —the branch only existed locally, or is
    # no longer on the remote— would take the rest of the pass down with it.
    local was_removed=0
    git -C "$repo" branch -D "$b" >/dev/null 2>&1 && was_removed=1
    git -C "$repo" push -q origin --delete "$b" >/dev/null 2>&1 && was_removed=1
    [[ $was_removed -eq 1 ]] && cleaned=$((cleaned + 1))
  done
  ok "$cleaned of ${#integrated[@]} branches cleaned"
}

# Resume on this machine a task started on another. The record already arrived
# with `crux sync`; here a workspace is opened, in each repo it declares, on the
# same branch brought from the remote, and the workspace joins the task instead
# of starting an empty one. Nothing is decided that the record does not say.
cmd_resume() {
  local task="${1:-}" project=""
  shift || true
  [[ -n "$task" ]] || die "usage: crux workspace resume <task> [--project <project>]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) project="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  valid_name "$task" || die "invalid task name: '$task'"

  local candidates=() f
  for f in "$(task_dir)"/*/"$task".md; do
    [[ -f "$f" ]] || continue
    [[ -z "$project" || "$(basename "$(dirname "$f")")" == "$project" ]] && candidates+=("$f")
  done
  if [[ ${#candidates[@]} -eq 0 ]]; then
    err "there is no open task '$task' on this machine"
    info "if it was opened on another, pull the tasks first: crux sync"
    exit 1
  fi
  if [[ ${#candidates[@]} -gt 1 ]]; then
    err "there is a task '$task' in several projects:"
    for f in "${candidates[@]}"; do info "$(basename "$(dirname "$f")")"; done
    die "choose with --project <project>"
  fi
  local task_record="${candidates[0]}"
  project="$(basename "$(dirname "$task_record")")"

  local data
  data="$(node "$CRUX_HOME/lib/task.mjs" places --file "$task_record" 2>&1)" \
    || die "could not read the record $task_record: $data"
  [[ -n "$data" ]] || die "the task '$task' declares no repo: open it with crux workspace new"

  local root repo_name branch_ref ws_name dir_repo n_repos done_count=0
  root="$(projects_root)"
  n_repos="$(printf '%s\n' "$data" | wc -l | tr -d ' ')"
  while IFS=$'\t' read -r repo_name branch_ref ws_name; do
    dir_repo="$root/$project/$repo_name"
    [[ -d "$dir_repo/.git" ]] || dir_repo="$root/$repo_name"
    if [[ ! -d "$dir_repo/.git" ]]; then
      err "$repo_name is not on this machine"
      info "bring it with: crux clone $project"
      continue
    fi
    [[ -n "$ws_name" ]] || { [[ "$n_repos" -gt 1 ]] && ws_name="$task-$repo_name" || ws_name="$task"; }
    # A task registered before the branch was noted: the pattern one.
    [[ -n "$branch_ref" ]] || branch_ref="ws/$ws_name"

    local already
    already="$(node -e '
      const fs = require("fs");
      try {
        const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const w = (r.workspaces || {})[process.argv[2]];
        if (w && fs.existsSync(w.path)) process.stdout.write(w.path);
      } catch {}
    ' "$REGISTRY" "$ws_name")"
    if [[ -n "$already" ]]; then
      ok "$repo_name: the workspace is already here — $already"
      done_count=$((done_count + 1)); continue
    fi

    git -C "$dir_repo" fetch -q origin "+refs/heads/$branch_ref:refs/remotes/origin/$branch_ref" 2>/dev/null || true
    # A branch retired when going into waiting is not missing: a new one is
    # opened from the main branch, because what it had was already merged.
    local retired_branch
    retired_branch="$(node "$CRUX_HOME/lib/task.mjs" retired --file "$task_record" | awk -F'\t' -v r="$repo_name" '$1 == r {print $2; exit}')"
    if [[ -n "$retired_branch" ]]; then
      branch_ref="$retired_branch"
      if ( cmd_new "$ws_name" --repo "$dir_repo" --branch "$branch_ref" --base "$(main_branch "$dir_repo")" --task "$task" ); then
        node "$CRUX_HOME/lib/task.mjs" reopen --file "$task_record" --repo "$repo_name"
        done_count=$((done_count + 1))
      fi
      continue
    fi
    if ! git -C "$dir_repo" show-ref --verify --quiet "refs/heads/$branch_ref" \
       && ! git -C "$dir_repo" show-ref --verify --quiet "refs/remotes/origin/$branch_ref"; then
      err "$repo_name: the branch $branch_ref is neither here nor on the remote"
      info "on the other machine: crux sync --leave tells you what is left to push"
      continue
    fi
    ( cmd_new "$ws_name" --repo "$dir_repo" --branch "$branch_ref" --task "$task" ) && done_count=$((done_count + 1))
  done <<< "$data"

  [[ $done_count -gt 0 ]] || exit 1
  # Resuming it means the answer arrived: it stops waiting.
  if [[ "$(node "$CRUX_HOME/lib/task.mjs" unwait --file "$task_record")" == "cleared" ]]; then
    ok "the task no longer waits for an answer"
  fi
  echo
  local summary
  summary="$(node "$CRUX_HOME/lib/task.mjs" summary --file "$task_record" 2>/dev/null || true)"
  IFS=$'\x1f' read -r _ status steps next_step <<< "$summary"
  ok "task '$task' resumed · $status${steps:+ · steps $steps}"
  [[ -n "$next_step" ]] && info "next: $next_step"
  info "record: $task_record"
}

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

for arg in "$@"; do
  [[ "$arg" == "--help" || "$arg" == "-h" ]] && { usage; exit 0; }
done

case "${1:-}" in
  new)  shift; cmd_new "$@" ;;
  list) shift; cmd_heal --quiet; cmd_list "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  adopt) shift; cmd_adopt "$@" ;;
  heal) shift; cmd_heal "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  merge)  shift; cmd_merge "$@" ;;
  rm)   shift; cmd_rm "$@" ;;
  gc)   shift; cmd_gc "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  help) usage ;;
  *) usage >&2; die "usage: crux workspace {new|list|resume|adopt|finish|merge|rm|gc|heal|prune}" ;;
esac
