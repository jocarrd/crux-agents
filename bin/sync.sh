#!/usr/bin/env bash
# crux sync — work on two machines without either falling behind.
#
#   crux sync            on arrival: what is on this machine, up to date, and the kernel
#   crux sync --leave    on leaving: fails if something would stay only on this machine
#   crux sync --hook     the same as on arrival, silent except for news;
#                        it is what the session-start hook runs
#
# `bootstrap` sets up an empty machine and `clone` brings a project that is
# missing, but neither updates what is already there: on returning to a
# computer after a month, both said "all done" and left the month-old code.
# This covers the case of alternating, which is the everyday one.
#
# It works on what is already in the projects root. It does not bring projects
# that are missing: each machine has its own, and `crux clone` brings one. By
# hand it does say which ones exist on the remote and are not here.
#
# On arrival it only advances what can be advanced without deciding anything:
# a clean branch that is behind its remote. If there are uncommitted changes
# or the branches have diverged, it says so and touches nothing. It never
# merges or rewrites.
#
# Tasks travel too, in the crux/tasks branch of each docs repo (ADR-016).
#
# The person's profile (ADR-018) is one more repo in the root: it is brought up
# to date like the rest and loaded again into the agents, because Codex keeps a
# copy of its index that goes stale.
#
# What it does NOT sync, on purpose: credentials (see `carry-env`) and the
# agent's local memory, which is a draft: what is worth keeping goes to the
# profile or to a project's docs repo.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

MODE="arrive"
case "${1:-}" in
  "")      ;;
  --leave) MODE="leave" ;;
  --hook)  MODE="hook" ;;
  *) die "usage: crux sync [--leave|--hook]" ;;
esac

ROOT="$(projects_root)"
[[ -d "$ROOT" ]] || die "the projects root does not exist: $ROOT"

# On a freshly set-up machine, ssh asks for each host's fingerprint and git for
# user and password. With no terminal to answer, each repo waited until the
# timeout: better to fail at once and show up as unresponsive.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

# The repos in the root and those inside each project. Worktrees are returned
# separately: they share their main repo's fetch, so on arrival they are only
# advanced, under the same rule as any branch.
main_repos() {
  local d
  for d in "$ROOT"/*/ "$ROOT"/*/*/; do
    d="${d%/}"
    [[ -e "$d/.git" ]] || continue
    is_worktree "$d" && continue
    echo "$d"
  done
}

worktrees() {
  local d
  for d in "$ROOT"/*/ "$ROOT"/*/*/; do
    d="${d%/}"
    [[ -e "$d/.git" ]] || continue
    is_worktree "$d" && echo "$d"
  done
}

name_of() { local r="${1#"$ROOT"/}"; echo "$r"; }

# Reads repos from stdin and prints "x<TAB>repo" if its remote no longer exists
# and "?<TAB>repo" if it could not be known. Without a network nothing is
# claimed to be missing.
missing_remotes() {
  local repo
  while IFS= read -r repo; do
    [[ -n "$(git -C "$repo" remote)" ]] || continue
    echo "$repo"
  done | xargs -P 16 -I{} bash -c '
    r="$(git -C "$1" config "branch.$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null).remote" 2>/dev/null)"
    [ -n "$r" ] || r="$(git -C "$1" remote | grep -x origin || git -C "$1" remote | head -1)"
    output="$(LC_ALL=C timeout 20 git -C "$1" ls-remote -q "$r" 2>&1 >/dev/null)" && exit 0
    if printf "%s" "$output" | grep -qiE "repository not found|does not appear to be a git repository|repository .* does not exist"; then
      printf "x\t%s\n" "$1"
    else
      printf "?\t%s\n" "$1"
    fi' _ {}
}

# --- On leaving ------------------------------------------------------------------

# On leaving there is no previous fetch to draw on: each project goes to the
# remote, in parallel, because each trip over ssh costs seconds.
parallel_tasks() {
  node "$CRUX_HOME/lib/task-sync.mjs" projects 2>/dev/null \
    | xargs -P 8 -I{} node "$CRUX_HOME/lib/task-sync.mjs" sync --project {} 2>/dev/null \
    | node -e '
      let s = "";
      process.stdin.on("data", (d) => (s += d));
      process.stdin.on("end", () => {
        const all = s.split("\n").filter(Boolean).flatMap((l) => { try { return JSON.parse(l); } catch { return []; } });
        process.stdout.write(JSON.stringify(all));
      });'
}

sync_departure() {
  local stuck=0 warnings=0 repo name b up ahead dirty stash
  echo "what would stay only on this machine"
  echo

  while IFS= read -r repo; do
    name="$(name_of "$repo")"
    [[ -n "$(git -C "$repo" remote)" ]] || {
      warn "$name: no remote, everything it has lives only here"
      stuck=$((stuck + 1)); continue
    }

    dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$dirty" -gt 0 ]]; then
      err "$name: $(count "$dirty" "uncommitted file" "uncommitted files")"
      stuck=$((stuck + 1))
    fi

    # A commit made with a detached HEAD is in no branch, so the branch review
    # below does not see it. Each worktree has its own HEAD.
    if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null \
       && git -C "$repo" rev-parse -q --verify HEAD >/dev/null \
       && [[ -z "$(git -C "$repo" for-each-ref --contains HEAD refs/heads refs/remotes 2>/dev/null)" ]]; then
      err "$name: detached HEAD with commits that are in no branch — create one: git switch -c <branch>"
      stuck=$((stuck + 1))
    fi

    # Branches are looked at from the main repo and not from each worktree:
    # they share the references, and counting them twice would be noise.
    is_worktree "$repo" && continue

    while IFS=$'\t' read -r b up; do
      if [[ -z "$up" ]]; then
        # Untracked: it is only safe if some remote already contains it.
        if [[ -z "$(git -C "$repo" branch -r --contains "$b" 2>/dev/null)" ]]; then
          err "$name: branch $b is in no remote"
          stuck=$((stuck + 1))
        fi
      elif ! git -C "$repo" rev-parse -q --verify "$up" >/dev/null; then
        # It tracked a branch that no longer exists: almost always a proposal
        # merged with squash, whose commits do not appear in the main branch.
        warnings=$((warnings + 1))
      else
        ahead="$(git -C "$repo" rev-list --count "$up..$b" 2>/dev/null || echo 0)"
        if [[ "$ahead" -gt 0 ]]; then
          err "$name: $b has $(count "$ahead" commit commits) not pushed"
          stuck=$((stuck + 1))
        fi
      fi
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)%09%(upstream:short)' refs/heads)

    stash="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$stash" -gt 0 ]]; then
      warn "$name: $(count "$stash" stash stashes) — they do not travel; turn them into a branch if you want them there"
    fi
  done < <(main_repos; worktrees)

  # With the remote deleted, the local references still say everything is
  # pushed: git does not find out until it asks. It is the only check on
  # leaving that needs a network, and it runs in parallel.
  local vanished unchecked r
  vanished="$(main_repos | missing_remotes)"
  unchecked="$(printf '%s\n' "$vanished" | sed -n 's/^?\t//p')"
  vanished="$(printf '%s\n' "$vanished" | sed -n 's/^x\t//p')"
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    err "$(name_of "$r"): its remote no longer exists — what it has lives only here"
    stuck=$((stuck + 1))
  done <<< "$vanished"
  if [[ -n "$unchecked" ]]; then
    warn "could not check whether the remotes still exist for:"
    while IFS= read -r r; do info "$(name_of "$r")"; done <<< "$unchecked"
  fi

  # Tasks publish themselves when written, but a write without a network stays
  # pending. Here it is retried, and what still is not pushed does not arrive.
  local p line
  while IFS=$'\t' read -r p line; do
    [[ -n "$p" ]] || continue
    warn "$p: $line"
  done < <(parallel_tasks | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d));
    process.stdin.on("end", () => {
      for (const r of JSON.parse(s || "[]")) {
        if (r.status === "no-transport") console.log(`${r.project}\ttheir tasks have no docs repo to travel through: they stay on this machine`);
        if (r.status === "no-remote") console.log(`${r.project}\tits docs repo has no remote: the tasks stay on this machine`);
        if (r.status === "public") console.log(`${r.project}\tits repo is public: tasks are not published there and stay on this machine ("tasks": {"sync": true} in crux.json to force it)`);
      }
    });' 2>/dev/null)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    err "$p: unpublished tasks — the other machine will not see them"
    stuck=$((stuck + 1))
  done < <(node "$CRUX_HOME/lib/task-sync.mjs" pending 2>/dev/null)

  # What the agent learned about the person, still only in its local memory: on
  # the other machine it would start without it (ADR-018).
  local personal
  if profile_dir >/dev/null 2>&1 && ! bash "$CRUX_HOME/bin/memory.sh" --check >/dev/null 2>&1; then
    personal="$(bash "$CRUX_HOME/bin/memory.sh" --brief 2>&1 | head -1 | sed 's/^[^ ]* *//')"
    err "agent memory: ${personal:-there are memories that should be in git} — 'crux memory'"
    stuck=$((stuck + 1))
  fi

  echo
  if [[ $warnings -gt 0 ]]; then
    info "$(count "$warnings" "branch tracks" "branches track") a branch deleted from the remote (merged, almost surely): they do not block"
  fi
  if [[ $stuck -eq 0 ]]; then
    ok "nothing trapped: you can carry on on the other machine"
    return 0
  fi
  err "$(count "$stuck" "thing" "things") would not reach the other machine"
  info "push them, or consciously decide they stay here"
  return 1
}

# --- On arrival ---------------------------------------------------------------

# Fetches every remote in parallel: in series, with thirty repos, the
# session-start hook took long enough to notice every time.
fetch_all() {
  main_repos | xargs -P 16 -I{} bash -c '
    repo="$1"
    remote="$(git -C "$repo" config "branch.$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null).remote" 2>/dev/null)"
    [ -n "$remote" ] || remote="$(git -C "$repo" remote | grep -x origin || git -C "$repo" remote | head -1)"
    timeout 30 git -C "$repo" fetch -q --all --prune --tags >/dev/null 2>&1 && exit 0
    # With --all, one failing secondary remote is enough to fail everything.
    [ -n "$remote" ] && timeout 30 git -C "$repo" fetch -q --prune --tags "$remote" >/dev/null 2>&1 && exit 0
    echo "$repo"' _ {}
}

# Advances the current branch if it is behind and there is nothing to decide.
advance() {
  local repo="$1" name up behind ahead
  name="$(name_of "$repo")"
  up="$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" || return 0
  git -C "$repo" rev-parse -q --verify "$up" >/dev/null || return 0
  behind="$(git -C "$repo" rev-list --count "HEAD..$up" 2>/dev/null || echo 0)"
  [[ "$behind" -gt 0 ]] || return 0
  ahead="$(git -C "$repo" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)"

  if [[ "$ahead" -gt 0 ]]; then
    echo "diverged	$name: the local branch and $up have diverged ($ahead here, $behind there) — you decide how to join them"
  elif [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "dirty	$name: is $(count "$behind" commit commits) behind, but has uncommitted changes — I leave it alone"
  # In C: the message is compared, and git translates it to the system language.
  elif output="$(LC_ALL=C git -C "$repo" merge -q --ff-only "$up" 2>&1)"; then
    echo "ok	$name: $(count "$behind" "new commit" "new commits")"
  elif [[ "$output" == *"untracked working tree files would be overwritten"* ]]; then
    echo "dirty	$name: an untracked file here clashes with one that is arriving — move it and retry: $(printf '%s\n' "$output" | sed -n 's/^[[:space:]]\{1,\}//p' | head -3 | tr '\n' ' ')"
  else
    echo "failed	$name: could not advance to $up — $(printf '%s' "$output" | head -1)"
  fi
}

# The other local branches that are behind their remote: without this, on
# switching to main on the other machine work started on the old state, with
# sync saying everything was up to date. `fetch .` does not advance a branch in
# use in some worktree nor one that has diverged, which is exactly what is wanted.
advance_the_rest() {
  local repo="$1" name current b up behind
  name="$(name_of "$repo")"
  current="$(git -C "$repo" symbolic-ref -q HEAD 2>/dev/null || true)"
  while IFS=$'\t' read -r b up; do
    [[ -n "$up" && "$b" != "$current" ]] || continue
    git -C "$repo" rev-parse -q --verify "$up" >/dev/null || continue
    behind="$(git -C "$repo" rev-list --count "$b..$up" 2>/dev/null || echo 0)"
    [[ "$behind" -gt 0 ]] || continue
    [[ "$(git -C "$repo" rev-list --count "$up..$b" 2>/dev/null || echo 1)" -eq 0 ]] || continue
    git -C "$repo" fetch -q . "$up:$b" >/dev/null 2>&1 \
      && echo "ok	$name: ${b#refs/heads/}, $(count "$behind" "new commit" "new commits")"
  done < <(git -C "$repo" for-each-ref --format='%(refname)%09%(upstream)' refs/heads)
}

# Repos that the contract of a project on this machine declares and that are
# not on disk: they show up when they were added from the other. They belong to
# the same project.
fetch_new_repos() {
  local p docs repo missing reason
  for docs in "$ROOT"/*/*-docs; do
    [[ -f "$docs/crux.json" ]] || continue
    p="$(basename "$(dirname "$docs")")"
    if ! reason="$(valid_json "$docs/crux.json")"; then
      echo "failed	$p: crux.json unreadable, I do not know which repos it declares — $reason"
      continue
    fi
    missing=0
    while IFS= read -r repo; do
      valid_name "$repo" 2>/dev/null || continue
      [[ -e "$ROOT/$p/$repo/.git" ]] || missing=1
    done < <(json_get "$docs/crux.json" repos 2>/dev/null || true)
    [[ $missing -eq 1 ]] || continue
    if bash "$CRUX_HOME/bin/clone.sh" "$p" --parent "$ROOT" >/dev/null 2>&1; then
      echo "new	$p: missing repos, brought in"
    else
      echo "failed	$p: it lacks repos and I could not bring them — 'crux clone $p'"
    fi
  done
}

# The kernel is updated from its clone, and only to a published version: the
# main branch's VERSION may be ahead of the latest tag.
kernel_up_to_date() {
  local clone="$ROOT/crux" new_one current
  [[ -f "$clone/install.sh" && -f "$clone/VERSION" ]] || return 0
  new_one="$(tr -d '[:space:]' < "$clone/VERSION")"
  current="$(crux_version)"
  is_semver "$new_one" || return 0
  version_greater_than "$new_one" "$current" || return 0
  git -C "$clone" rev-parse -q --verify "refs/tags/v$new_one" >/dev/null || return 0
  [[ "${CRUX_SYNC_NO_INSTALL:-0}" == "1" ]] && { echo "kernel	crux $new_one available (installation disabled)"; return 0; }
  # In dev mode the kernel already is the clone: reinstalling would switch it to release.
  grep -qE '^CRUX_MODE="?dev' "${CRUX_CONFIG:-$HOME/.crux/config}" 2>/dev/null && return 0

  # This process exports its own CRUX_HOME; inherited, the new hooks would point at the old kernel.
  if ( cd "$HOME" && bash "$clone/install.sh" ) >/dev/null 2>&1 \
     && ( cd "$HOME" && CRUX_HOME="$HOME/.crux/kernel/$new_one" \
          bash "$HOME/.crux/kernel/$new_one/bin/hooks.sh" install ) >/dev/null 2>&1; then
    echo "kernel	crux $current → $new_one, with its hooks"
  else
    echo "failed	kernel: could not install crux $new_one — run '$clone/install.sh' by hand"
  fi
}

# Tasks travel in the crux/tasks branch of each project's docs repo: those from
# the other machine are pulled and what stayed pending here is published.
tasks_up_to_date() {
  local output rc=0
  output="$(node "$CRUX_HOME/lib/task-sync.mjs" sync --all --fetched 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "failed	tasks: $(printf '%s' "$output" | head -1)"
    return
  fi
  printf '%s' "$output" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d));
    process.stdin.on("end", () => {
      const n = (k, one, many) => (k === 1 ? `1 ${one}` : `${k} ${many}`);
      for (const r of JSON.parse(s || "[]")) {
        for (const c of r.closed || []) console.log(`tasks\t${c}`);
        for (const a of r.warnings || []) console.log(`warning\t${a}`);
        if (r.status === "ok") {
          if (r.pulled) console.log(`tasks\t${r.project}: ${n(r.pulled, "task pulled", "tasks pulled")}`);
        } else if (r.status === "rejected") {
          console.log(`warning\t${r.project}: the tasks could not be published, retrying next time`);
        } else if (r.status === "failed") {
          console.log(`failed\t${r.project}: tasks — ${r.reason}`);
        }
      }
    });'
}

# The profile is reloaded into the agents after advancing it. Without a profile
# here it is not looked for on the remote in the hook, which runs every session:
# on a manual sync it is said if one exists.
profile_up_to_date() {
  if profile_dir >/dev/null 2>&1; then
    bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1 \
      || echo "failed	profile: could not load it into the agents — 'crux profile link'"
    return 0
  fi
  # Gone since the last time: the agents stop importing it.
  grep -qF "crux:profile:begin" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md" 2>/dev/null \
    && bash "$CRUX_HOME/bin/profile.sh" link >/dev/null 2>&1
  [[ "$MODE" == "hook" ]] && return 0
  command -v gh >/dev/null 2>&1 || return 0
  local owner; owner="$(default_owner)"
  [[ -n "$owner" ]] && gh repo view "$owner/$(profile_repo_name)" >/dev/null 2>&1 \
    && echo "warning	the profile $owner/$(profile_repo_name) is not on this machine — 'crux profile clone'"
  return 0
}

# Projects on the remote that this machine does not have. Only by hand: it asks
# the remote once per candidate, too slow for every session start.
missing_projects() {
  [[ "$MODE" == "arrive" ]] || return 0
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || return 0
  local o p seen=" "
  while IFS= read -r o; do
    while IFS= read -r p; do
      [[ -n "$p" && "$seen" != *" $p "* ]] || continue
      seen+="$p "
      [[ -d "$ROOT/$p/$p-docs" ]] && continue
      echo "notice	$p is on the remote ($o) and not on this machine — 'crux clone $p' if you need it"
    done < <(projects_with_contract "$o")
  done < <(search_owners)
}

# A workspace whose task was archived, here or on the other machine: left
# there it looks like work in progress. Only by hand, where advice is read.
closed_workspaces() {
  [[ "$MODE" == "arrive" ]] || return 0
  local wt base task project dir
  dir="$(task_dir)"
  while IFS= read -r wt; do
    base="$(basename "$wt")"
    [[ "$base" == *-ws-* ]] || continue
    task="${base##*-ws-}"
    project="$(project_name_for "$wt")"
    [[ -f "$dir/$project/$task.md" ]] && continue
    compgen -G "$dir/$project/done/*-$task.md" >/dev/null || continue
    echo "notice	$(name_of "$wt"): its task is archived — 'crux workspace rm $task' once nothing in it is pending"
  done < <(worktrees)
}

# A task edited on both machines keeps the most recent version and saves the
# other alongside. That is decided in a background publish nobody reads, so
# the copy is named here until someone reviews it.
task_conflicts() {
  [[ "$MODE" == "arrive" ]] || return 0
  local f dir
  dir="$(task_dir)"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    echo "notice	task changed on both machines: ${f#"$dir"/} holds the version that lost — merge what is missing and delete it"
  done < <(find "$dir" -mindepth 2 -maxdepth 2 -name '*.conflicto-*.md' 2>/dev/null | sort)
}

# A project materialized with an old kernel misses the checks and templates
# released since: a project thirty minors behind went unnoticed.
# Only by hand, and only when the minor differs: patches do not change what is
# materialized.
behind_projects() {
  [[ "$MODE" == "arrive" ]] || return 0
  local docs pinned current p
  current="$(crux_version)"
  for docs in "$ROOT"/*/*-docs; do
    [[ -f "$docs/crux.json" ]] || continue
    pinned="$(json_get "$docs/crux.json" crux 2>/dev/null)" || continue
    is_semver "$pinned" || continue
    [[ "${pinned%.*}" == "${current%.*}" ]] && continue
    version_greater_than "$current" "$pinned" || continue
    p="$(basename "$(dirname "$docs")")"
    echo "notice	$p is materialized with crux $pinned and the kernel is $current — 'crux upgrade' in $(basename "$docs")"
  done
}

sync_arrival() {
  local offline lines repo
  offline="$(fetch_all)"
  lines=""
  while IFS= read -r repo; do
    lines+="$(advance "$repo")"$'\n'
    lines+="$(advance_the_rest "$repo")"$'\n'
  done < <(main_repos)
  # A task resumed on the other machine moves its branch on there: left
  # behind here, the next commit diverges and it only shows on pushing.
  while IFS= read -r repo; do
    lines+="$(advance "$repo")"$'\n'
  done < <(worktrees)
  lines+="$(fetch_new_repos)"$'\n'
  lines+="$(kernel_up_to_date)"$'\n'
  lines+="$(tasks_up_to_date)"$'\n'
  lines+="$(profile_up_to_date)"$'\n'
  lines+="$(missing_projects)"$'\n'
  lines+="$(closed_workspaces)"$'\n'
  lines+="$(task_conflicts)"$'\n'
  lines+="$(behind_projects)"$'\n'
  lines="$(printf '%s' "$lines" | sed '/^$/d')"

  local n_offline=0
  [[ -n "$offline" ]] && n_offline="$(printf '%s\n' "$offline" | wc -l | tr -d ' ')"

  if [[ "$MODE" == "hook" ]]; then
    # In the hook, what is printed enters the agent's context: only what
    # changed or asks for a decision, and nothing if everything was up to date.
    # A repo whose remote was deleted never answers, and repeating it every
    # session is noise: here only counts that none answers, which is being
    # offline.
    local total offline_hook=0
    total="$(main_repos | wc -l | tr -d ' ')"
    [[ $n_offline -gt 0 && $n_offline -eq $total ]] && offline_hook=1
    [[ -z "$lines" && $offline_hook -eq 0 ]] && return 0
    echo "crux sync, at session start:"
    [[ -n "$lines" ]] && printf '%s\n' "$lines" | cut -f2- | sed 's/^/  /'
    [[ $offline_hook -eq 1 ]] && echo "  offline: no remote answered, the repos may not be up to date"
    return 0
  fi

  echo "up to date with the remote — $ROOT"
  echo
  if [[ -z "$lines" ]]; then
    ok "nothing new: this machine was already up to date"
  else
    while IFS=$'\t' read -r kind text; do
      case "$kind" in
        ok|new|kernel|tasks) ok "$text" ;;
        diverged|dirty|warning)  warn "$text" ;;
        notice)          info "$text" ;;
        *)               err "$text" ;;
      esac
    done <<< "$lines"
  fi
  if [[ $n_offline -gt 0 ]]; then
    echo
    warn "no answer from the remote (offline, or the remote no longer exists):"
    printf '%s\n' "$offline" | while IFS= read -r r; do info "$(name_of "$r")"; done
  fi
  # Diverged and dirty ask for a decision: it exits with an error so a script
  # chaining it does not carry on as if everything were up to date.
  printf '%s\n' "$lines" | grep -qE '^(diverged|dirty|failed|warning)' && return 1
  return 0
}

# --- Hook: once in a while, not every session -------------------------------
#
# Several sessions open at once would launch the same fetch round in parallel.
# With a ten-minute marker, the first one syncs and the rest do not.

status="${CRUX_STATE_DIR:-$HOME/.crux/state}"
( umask 077 && mkdir -p "$status" ) 2>/dev/null || true

# Two arrivals at once —a session's hook and a manual `crux sync`— trampled
# git's index: one advanced and the other said it could not. mkdir is atomic
# and exists everywhere, unlike flock.
lock="$status/sync.lock"
take_lock() {
  local wait_s=0
  while ! mkdir "$lock" 2>/dev/null; do
    # A lock older than ten minutes belongs to a process that died.
    if [[ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
      rmdir "$lock" 2>/dev/null; continue
    fi
    [[ "$MODE" == "hook" ]] && return 1
    [[ $wait_s -eq 0 ]] && info "another sync is running, waiting for it to finish"
    wait_s=1; sleep 1
  done
  trap 'rmdir "$lock" 2>/dev/null' EXIT
}

if [[ "$MODE" == "hook" ]]; then
  # By hand and in a terminal, reading stdin would wait for a Ctrl-D.
  [[ -t 0 ]] || cat >/dev/null 2>&1 || true
  marker="$status/sync-last"
  if [[ -f "$marker" ]] && [[ -n "$(find "$marker" -mmin -"${CRUX_SYNC_EVERY_MIN:-10}" 2>/dev/null)" ]]; then
    exit 0
  fi
  take_lock || exit 0
  : > "$marker"
  sync_arrival
  exit 0
fi

if [[ "$MODE" == "leave" ]]; then
  sync_departure
  exit $?
fi

take_lock
sync_arrival
exit $?
