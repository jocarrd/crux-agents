#!/usr/bin/env bash
# crux status — what is open right now, across all projects.
#
#   crux status            the projects, their workspaces and the unpublished work
#   crux status --check    also runs each project's doctor; exits 1 if anything fails
#
# `doctor` answers for one project. This answers for the morning: where the
# work was left, which workspaces are still alive and what is pushed nowhere.
# No network: what cannot be known locally is not asked.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
source "$CRUX_HOME/lib/registry.sh"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

ROOT="$(projects_root)"

echo "projects in $ROOT"
echo

projects=0
PROBLEMS=0
for docs in "$ROOT"/*/*-docs; do
  [[ -f "$docs/crux.json" ]] || continue
  projects=$((projects + 1))
  name="$(basename "$(dirname "$docs")")"

  if ! reason="$(valid_json "$docs/crux.json")"; then
    printf '  %-14s %s\n' "$name" "unreadable contract — $reason"
    info "fix it or see what is wrong: crux doctor $docs"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  version="$(json_get "$docs/crux.json" crux 2>/dev/null || echo "?")"
  repos="$(json_get "$docs/crux.json" repos 2>/dev/null | wc -l | tr -d ' ')"

  status=""
  if [[ $CHECK -eq 1 ]]; then
    output="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" || PROBLEMS=$((PROBLEMS + 1))
    status="$(echo "$output" | tail -1)"
    [[ "$status" == conformant* || "$status" == conforme* ]] && status="conformant"
  fi
  printf '  %-14s crux %-8s %s repos%s\n' "$name" "$version" "$repos" "${status:+  ·  $status}"
done
[[ $projects -eq 0 ]] && info "none under that root ('install.sh --projects-dir' if it is not yours)"

echo
echo "workspaces"
echo
bash "$CRUX_HOME/bin/workspace.sh" heal --quiet 2>/dev/null | sed 's/^/  /' || true
if [[ -f "$REGISTRY" ]]; then
  if [[ -z "$(registry_entries)" ]]; then
    echo "  none"
  else
    # The columns fit the longest name: a fixed width pushed the long ones out
    # of line.
    entries="$(registry_entries)"
    name_w="$(cut -f1 <<<"$entries" | awk '{ if (length > w) w = length } END { print w }')"
    branch_w="$(cut -f3 <<<"$entries" | awk '{ if (length > w) w = length } END { print w }')"
    while IFS=$'\t' read -r n path_value branch slot; do
      alive=""; [[ -d "$path_value" ]] || alive="  (no worktree)"
      printf "  %-${name_w}s  %-${branch_w}s  slot %s%s\n" "$n" "$branch" "$slot" "$alive"
    done <<<"$entries"
  fi

  # A workspace whose branch is no longer on the remote is almost always merged
  # work that nobody closed. No network: what git already knows of the remote
  # is looked at.
  registry_entries | while IFS=$'\t' read -r n path branch _slot; do
    [[ -d "$path" ]] || continue
    tracking="$(git -C "$path" for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null || true)"
    if [[ "$tracking" == *gone* ]]; then
      warn "'$n': its branch is no longer on the remote, probably merged — close it with 'crux workspace rm $n'"
    fi
  done

  # A worktree crux does not know about appears in no list and nothing protects it.
  registered="$(registry_paths)"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\n' "$registered" | grep -qxF "$d" && continue
    is_worktree "$d" || continue
    warn "$(basename "$d") is a worktree crux does not know about — register it: crux workspace adopt $d"
  done < <(find "$ROOT" -maxdepth 2 -type d -name '*-ws-*' 2>/dev/null | sort)

  # A proposal opened from a branch without a receipt is the shortcut taken
  # behind the back: legitimate if a person asked for it, but it has to be
  # visible. Without this, going around the gate left no trace anywhere.
  # One call per repository and all of them at once: one per workspace, one
  # after the other, was 0.6 s each and almost all of what status took.
  # No associative arrays: macOS ships bash 3.2.
  if command -v gh >/dev/null; then
    prs_dir="$(mktemp -d "${TMPDIR:-/tmp}/crux-status.XXXXXX")"
    while IFS=$'\t' read -r n path branch _slot; do
      [[ -d "$path" ]] || continue
      origin="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
      [[ -n "$origin" ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$n" "$path" "$branch" \
        "$(echo "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
    done < <(registry_entries) > "$prs_dir/workspaces"
    for slug in $(cut -f4 "$prs_dir/workspaces" | sort -u); do
      gh pr list --repo "$slug" --state open --limit 200 --json number,headRefName \
        --jq '.[] | "\(.headRefName)\t\(.number)"' > "$prs_dir/${slug//\//__}" 2>/dev/null &
    done
    wait

    while IFS=$'\t' read -r n path branch slug; do
      open_pr="$(awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' "$prs_dir/${slug//\//__}" 2>/dev/null)"
      [[ -n "$open_pr" ]] || continue
      receipt="$path/.crux-ship"
      head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
      sealed=""
      [[ -f "$receipt" ]] && sealed="$(awk '/^sealed /{print $2}' "$receipt" | tail -1)"
      if [[ "$sealed" != "$head" ]]; then
        warn "$slug#$open_pr ($n) is open and its branch has no gate receipt"
      fi
    done < "$prs_dir/workspaces"
    rm -rf "$prs_dir"
  fi
else
  echo "  none"
fi

# Open tasks with no workspace on this machine: started on another, or whose
# workspace was closed before finishing them. They are resumed with
# `workspace resume`.
without_workspace="$(node -e '
  const fs = require("fs");
  const tasks = JSON.parse(process.argv[1] || "[]");
  let liveSet = new Set();
  try {
    const r = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    liveSet = new Set(Object.entries(r.workspaces || {}).filter(([, w]) => fs.existsSync(w.path)).map(([n]) => n));
  } catch {}
  for (const t of tasks) {
    if (t.waiting) continue;
    if (t.workspaces.some((e) => liveSet.has(e))) continue;
    console.log(`${t.project}/${t.task}\t${t.status}\t${t.next || ""}`);
  }
' "$(node "$CRUX_HOME/lib/task-sync.mjs" open 2>/dev/null)" "$REGISTRY" 2>/dev/null)"
if [[ -n "$without_workspace" ]]; then
  echo
  echo "open tasks with no workspace on this machine"
  echo
  while IFS=$'\t' read -r t status next_step; do
    printf '  %-34s %-12s %s\n' "$t" "$status" "${next_step:0:60}"
  done <<< "$without_workspace"
  info "resume them with: crux workspace resume <task>"
fi

# Those waiting on another person: not pending work of ours, but they cannot
# be lost sight of. Once the deadline passes a nudge is suggested.
waiting_tasks="$(node -e '
  const tasks = JSON.parse(process.argv[1] || "[]");
  const nudge = Number(process.env.CRUX_WAIT_NUDGE_DAYS) > 0 ? Number(process.env.CRUX_WAIT_NUDGE_DAYS) : 7;
  for (const t of tasks) {
    if (!t.waiting) continue;
    const since = Date.parse(t.waiting.since);
    const days = Number.isNaN(since) ? null : Math.max(0, Math.floor((Date.now() - since) / 86400000));
    const age = days === null ? "" : days === 0 ? "today" : days === 1 ? "yesterday" : `${days} days ago`;
    console.log([`${t.project}/${t.task}`, t.waiting.on, age, t.waiting.ask, days !== null && days >= nudge ? "1" : "", t.waiting.ref].join("\t"));
  }
' "$(node "$CRUX_HOME/lib/task-sync.mjs" open 2>/dev/null)")"
if [[ -n "$waiting_tasks" ]]; then
  echo
  echo "waiting for an answer"
  echo
  while IFS=$'\t' read -r task on age ask nudge ref; do
    printf '  %-34s to %s, %s\n' "$task" "$on" "$age"
    printf '  %-34s %s\n' "" "${ask:0:70}"
    [[ -n "$ref" ]] && printf '  %-34s %s\n' "" "$ref"
    [[ -n "$nudge" ]] && warn "$task is past its deadline: worth a nudge"
  done <<< "$waiting_tasks"
  info "when the answer arrives: crux workspace resume <task>"
fi

echo
echo "unpublished work"
echo

pending=0
for repo in "$ROOT"/*/*/; do
  repo="${repo%/}"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || continue
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || continue
  is_worktree "$repo" && continue

  name="$(basename "$(dirname "$repo")")/$(basename "$repo")"
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  unpushed=0
  if git -C "$repo" rev-parse '@{u}' >/dev/null 2>&1; then
    unpushed="$(git -C "$repo" log --oneline '@{u}..' 2>/dev/null | wc -l | tr -d ' ')"
  else
    unpushed="$(git -C "$repo" log --oneline "$(main_branch "$repo")..$branch" 2>/dev/null | wc -l | tr -d ' ')"
  fi

  [[ "$dirty" -eq 0 && "$unpushed" -eq 0 ]] && continue
  pending=$((pending + 1))
  detail=""
  [[ "$unpushed" -gt 0 ]] && detail="$(count "$unpushed" commit commits) not pushed"
  [[ "$dirty" -gt 0 ]] && detail="${detail:+$detail, }$(count "$dirty" "file touched" "files touched")"
  printf '  %-34s %-22s %s\n' "$name" "$branch" "$detail"
done
if [[ $pending -eq 0 ]]; then
  echo "  nothing: everything is pushed"
fi

# --check exists to hook it to something automatic: it has to be able to fail.
[[ $CHECK -eq 1 && $PROBLEMS -gt 0 ]] && exit 1
exit 0
