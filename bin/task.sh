#!/usr/bin/env bash
# crux task — the record of the task of the workspace you are in.
#
#   crux task                        status, steps and next step
#   crux task path                   where the record is
#   crux task goal "<text>"          the objective: what and why
#   crux task scope "<text>"         what is in and what stays out
#   crux task plan <file>            dumps an approved plan and marks it planned
#   crux task add "<step>" [...]     adds steps and returns their id (T1, T2…)
#   crux task done <Tn> ["evidence"] marks a step done with what proves it
#   crux task next "<text>"          the next thing to do
#   crux task note "<what>" [--why "…"] [--where "…"] [--learned "…"]
#                                    a deviation or a decision taken along the way;
#                                    with --why it is a decision, and when the task is
#                                    archived it goes to repos/<repo>/notes.md of the docs repo
#   crux task status <status> [--force]
#   crux task wait --on "<who>" --ask "<what>" [--ref "<where>"] [--keep]
#                                    the task waits on another person: notes it and removes
#                                    the workspaces and branches that no longer add anything
#   crux task unwait                 the answer arrived: the task is work again
#   crux task list [--all] [--done]  the open tasks, with their next step; --done, the archived ones
#   crux task archive                closes it and sets it aside in done/, dated
#
# Outside a workspace, --task <project>/<task> says which one.
#
# The record lives in ~/.crux/tasks/<project>/<task>.md: local state, next to
# the workspace registry, and outside the repos. Not the code one —in a
# client's it cannot go, and a task spanning several repos would be split— nor
# the documentation one, which is for what lasts. See ADR-012.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REGISTRY="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
TASKS="$(task_dir)"
ENGINE="$CRUX_HOME/lib/task.mjs"

op="${1:-show}"; [[ $# -gt 0 ]] && shift || true

# --task <project>/<task> overrides the workspace you are in.
CHOSEN=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) CHOSEN="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# Called inside $(...): an error on stdout would end up inside the variable,
# and the command would exit without saying why.
fail() { err "$*" >&2; exit 1; }

current_task_file() {
  if [[ -n "$CHOSEN" ]]; then
    [[ "$CHOSEN" == */* ]] || fail "--task goes as <project>/<task>"
    echo "$TASKS/$CHOSEN.md"
    return 0
  fi
  local here
  here="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || fail "you are not in a repo: use --task <project>/<task>, or 'crux task list'"
  local path_value
  path_value="$(task_file_for_path "$REGISTRY" "$here")" \
    || fail "you are not in a workspace with a task: 'crux workspace new <task>', or --task <project>/<task>"
  echo "$path_value"
}

engine() { node "$ENGINE" "$@"; }

# When going into waiting, a clean workspace and a branch with nothing of its
# own only take up room. They are removed; whatever has unpublished work stays
# and is reported.
retire_idle_workspaces() {
  local task_file="$1" task project
  task="$(awk -F': ' '/^task:/{print $2; exit}' "$task_file")"
  project="$(basename "$(dirname "$task_file")")"
  local entries
  entries="$(node -e '
    const fs = require("fs");
    let r = {};
    try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {
      if (fs.existsSync(process.argv[1])) { console.error("could not read " + process.argv[1]); process.exit(2); }
    }
    for (const [name, w] of Object.entries(r.workspaces || {}))
      if (w.project === process.argv[2] && w.task === process.argv[3]) console.log([name, w.repo, w.path, w.branch].join("\t"));
  ' "$REGISTRY" "$project" "$task")" || die "could not read the workspace registry $REGISTRY"
  [[ -n "$entries" ]] || { info "the task has no workspaces on this machine"; return 0; }

  local name repo path branch main ahead merged_pr
  while IFS=$'\t' read -r name repo path branch; do
    if [[ -d "$path" && -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      warn "$name has uncommitted changes: it stays"
      continue
    fi
    main="$(main_branch "$repo")"
    ahead="$(git -C "$repo" rev-list --count "$main..$branch" 2>/dev/null || echo 0)"
    merged_pr=""
    if [[ "$ahead" -gt 0 ]]; then
      merged_pr="$(cd "$repo" && gh pr list --head "$branch" --state merged --json number -q '.[0].number // ""' 2>/dev/null || true)"
      if [[ -z "$merged_pr" ]]; then
        warn "$name has $ahead unmerged commit(s) in $branch: it stays"
        continue
      fi
    fi
    if [[ -d "$path" ]]; then
      "$CRUX_HOME/bin/workspace.sh" rm "$name" --include-ignored >/dev/null 2>&1 \
        || { warn "could not remove workspace $name: crux workspace rm $name"; continue; }
    fi
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
    if [[ -n "$merged_pr" ]] && git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      git -C "$repo" push -q origin --delete "$branch" >/dev/null 2>&1 \
        || warn "could not delete remote branch $branch"
    fi
    engine retire --file "$task_file" --repo "$(basename "$repo")" --branch "$branch" --workspace "$name"
    ok "$name removed, and its branch $branch${merged_pr:+ (merged in #$merged_pr)}"
  done <<< "$entries"
}

case "$op" in
  show)
    f="$(current_task_file)"
    [[ -f "$f" ]] || die "the record $f does not exist"
    IFS=$'\x1f' read -r task status steps next_step < <(engine summary --file "$f")
    echo "task $task · $status${steps:+ · steps $steps}"
    [[ -n "$next_step" ]] && echo "next: $next_step" || info "no next step: crux task next \"...\""
    info "$f"
    ;;
  path) current_task_file ;;
  goal)  f="$(current_task_file)"; [[ -n "${1:-}" ]] || die "usage: crux task goal \"<text>\""; engine set --file "$f" --section Objective --text "$1"; ok "objective noted" ;;
  scope) f="$(current_task_file)"; [[ -n "${1:-}" ]] || die "usage: crux task scope \"<text>\""; engine set --file "$f" --section Scope --text "$1"; ok "scope noted" ;;
  plan)
    f="$(current_task_file)"
    [[ -f "${1:-}" ]] || die "usage: crux task plan <file with the approved plan>"
    engine set --file "$f" --section Plan --text "$(cat "$1")"
    engine status --file "$f" --to planned
    ok "plan dumped to the record"
    ;;
  add)
    # Several steps in one call: the plan comes out at once, and noting it one
    # by one was what added the most calls to the cycle.
    f="$(current_task_file)"; [[ -n "${1:-}" ]] || die "usage: crux task add \"<step>\" [\"<step>\"...]"
    for step in "$@"; do
      id="$(engine add --file "$f" --text "$step")"
      ok "$id $step"
    done
    ;;
  "done")
    f="$(current_task_file)"; [[ -n "${1:-}" ]] || die "usage: crux task done <Tn> [\"evidence\"]"
    engine "done" --file "$f" --id "$1" ${2:+--evidence "$2"}
    ok "$1 done"
    [[ -n "${2:-}" ]] || info "no evidence: a step marked without what proves it is a declaration"
    ;;
  next)  f="$(current_task_file)"; [[ -n "${1:-}" ]] || die "usage: crux task next \"<text>\""; engine set --file "$f" --section "Next step" --text "$1"; ok "next step noted" ;;
  note)
    f="$(current_task_file)"
    [[ -n "${1:-}" && "$1" != --* ]] || die "usage: crux task note \"<what>\" [--why \"…\"] [--where \"…\"] [--learned \"…\"]"
    what="$1"; shift
    extra=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --why|--where|--learned)
          [[ -n "${2:-}" && "$2" != --* ]] || die "$1 needs a text"
          extra+=("$1" "$2"); shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    engine note --file "$f" --text "$what" ${extra[@]+"${extra[@]}"}
    if [[ " ${extra[*]:-} " == *" --why "* ]]; then
      ok "decision noted: when the task is archived it goes to the repo notes in the docs repo"
    else
      ok "noted in deviations and decisions"
      info "if it is a decision that has to last, add its why: --why \"…\""
    fi
    ;;
  status)
    f="$(current_task_file)"; [[ -n "${1:-}" ]] || die "usage: crux task status <status> [--force]"
    engine status --file "$f" --to "$1" ${2:+"$2"}
    ok "status: $(awk -F': ' '/^status:/{print $2; exit}' "$f")"
    ;;
  wait)
    f="$(current_task_file)"
    [[ -f "$f" ]] || die "the record $f does not exist"
    on="" ask="" ref="" keep=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --on|--ask|--ref)
          [[ -n "${2:-}" && "$2" != --* ]] || die "$1 needs a text"
          case "$1" in --on) on="$2" ;; --ask) ask="$2" ;; --ref) ref="$2" ;; esac
          shift 2 ;;
        --keep) keep=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ -n "$on" && -n "$ask" ]] || die "usage: crux task wait --on \"<who>\" --ask \"<what>\" [--ref \"<where>\"] [--keep]"
    engine wait --file "$f" --on "$on" --ask "$ask" ${ref:+--ref "$ref"}
    ok "waiting on $on: $ask"
    if [[ $keep -eq 1 ]]; then
      info "workspaces and branches untouched (--keep)"
    else
      retire_idle_workspaces "$f"
    fi
    info "when the answer arrives: crux workspace resume $(awk -F': ' '/^task:/{print $2; exit}' "$f"), or crux task unwait"
    ;;
  unwait)
    f="$(current_task_file)"
    [[ -f "$f" ]] || die "the record $f does not exist"
    if [[ "$(engine unwait --file "$f")" == "cleared" ]]; then ok "the task no longer waits for an answer"; else info "the task was not waiting"; fi
    ;;
  archive)
    f="$(current_task_file)"
    [[ -f "$f" ]] || die "the record $f does not exist"
    promote_decisions "$f"
    target="$(engine archive --file "$f")"
    ok "task archived: $target"
    ;;
  list)
    all_flag=0 done_flag=0
    for a in "$@"; do
      case "$a" in --all) all_flag=1 ;; --done) done_flag=1 ;; esac
    done
    if [[ $done_flag -eq 1 ]]; then
      found_any=0
      for f in "$TASKS"/*/done/*.md; do
        [[ -f "$f" ]] || continue
        found_any=1
        printf '%-12s %s\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(basename "$f" .md)"
      done
      [[ $found_any -eq 1 ]] || echo "no archived tasks"
      exit 0
    fi
    [[ -d "$TASKS" ]] || { echo "no open tasks"; exit 0; }
    project=""
    if [[ $all_flag -eq 0 ]]; then
      here="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      [[ -n "$here" ]] && project="$(project_name_for "$here")"
    fi
    found_any=0
    for f in "$TASKS"/*/*.md; do
      [[ -f "$f" ]] || continue
      p="$(basename "$(dirname "$f")")"
      [[ -z "$project" || "$p" == "$project" ]] || continue
      IFS=$'\x1f' read -r task status steps next_step < <(engine summary --file "$f")
      [[ "$status" == "closed" ]] && continue
      found_any=1
      waiting="$(engine waiting --file "$f")"
      if [[ -n "$waiting" ]]; then
        IFS=$'\x1f' read -r on ask since _ <<< "$waiting"
        printf '%-28s %-12s %-6s %s\n' "$p/$task" "waiting" "$steps" "to $on since $since: ${ask:0:50}"
        continue
      fi
      printf '%-28s %-12s %-6s %s\n' "$p/$task" "$status" "$steps" "${next_step:0:70}"
    done
    [[ $found_any -eq 1 ]] || echo "no open tasks${project:+ in $project (all: crux task list --all)}"
    ;;
  -h|--help|help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" ;;
  *) die "unknown subcommand: $op — 'crux task --help'" ;;
esac
