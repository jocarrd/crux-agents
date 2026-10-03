#!/usr/bin/env bash
# crux review — gathers the material for reviewing a proposal.
#
#   crux review [--base <branch>] [--repo <dir>]
#
# It does not review: it prepares. `/review-pr` does the review with this in
# front of it, so it does not depend on someone remembering to gather the diff,
# the proposal and the checks.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="$PWD"; BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

REPO="$(cd "$REPO" && git rev-parse --show-toplevel 2>/dev/null)" || die "not a git repo: $REPO"
cd "$REPO" || die "cannot enter $REPO"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if [[ -z "$BASE" ]]; then
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/##')"
  [[ -n "$BASE" ]] || for c in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null && { BASE="$c"; break; }
  done
fi
[[ -n "$BASE" ]] || die "cannot find the base branch — pass it with --base"

[[ "$(git rev-parse "$BRANCH")" != "$(git rev-parse "$BASE" 2>/dev/null)" ]] \
  || die "$BRANCH is at the same commit as $BASE: there is nothing to review"

name="$(basename "$REPO")"
is_worktree "$REPO" && name="$(basename "$(main_repo "$REPO")")"
echo "review of $BRANCH over $BASE — $name"
echo

# --- 1. What is proposed -------------------------------------------------------

section_head() { echo; echo "${C_DIM}── $* ${C_OFF}"; }

section_head "commits"
git log --oneline "$BASE..$BRANCH" | sed 's/^/      /'

section_head "files"
git diff --stat "$BASE...$BRANCH" | sed 's/^/      /'

dirty="$(git status --porcelain | head -5)"
[[ -n "$dirty" ]] && { warn "there are uncommitted changes: they are not part of the proposal"; echo "$dirty" | sed 's/^/      /'; }

# --- 2. The proposal and its checks ------------------------------------

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  pr="$(gh pr view "$BRANCH" --json number,title,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null || true)"
  if [[ -n "$pr" ]]; then
    section_head "proposal"
    node -e '
      const d = JSON.parse(process.argv[1]);
      console.log(`      #${d.number} ${d.title}`);
      console.log(`      ${d.mergeable} · ${d.mergeStateStatus}`);
      const checks = d.statusCheckRollup || [];
      if (!checks.length) {
        console.log("      no automatic checks — nothing blocking it is not the same as verified");
      } else {
        for (const c of checks) {
          console.log(`      ${(c.conclusion || c.state || "?").toLowerCase().padEnd(10)} ${c.name || c.context}`);
        }
      }
    ' "$pr"
  else
    info "no open proposal for $BRANCH"
  fi
fi

# --- 3. Objective signals ----------------------------------------------------
#
# They are not verdicts: they are the places to look first. Each one has shown
# up in a real review as the finding nobody saw.

section_head "signals"

has_signal=0
signal() { has_signal=1; warn "$*"; }

files="$(git diff --name-only "$BASE...$BRANCH")"
code="$(echo "$files" | grep -vE '\.(md|txt|json|ya?ml|lock)$|^docs/' || true)"
tests="$(echo "$files" | grep -iE '(^|/)(test|tests|spec|__tests__)/|\.(test|spec)\.[a-z]+$' || true)"

[[ -n "$code" && -z "$tests" ]] && signal "touches code and touches no test"

# A console.log in a test is its way of reporting, not unfinished work.
code_paths=()
while IFS= read -r r; do [[ -n "$r" ]] && code_paths+=("$r"); done < <(
  echo "$code" | grep -ivE '(^|/)(test|tests|spec|__tests__)/|\.(test|spec)\.[a-z]+$' || true)
added="$(git diff "$BASE...$BRANCH" -- ${code_paths[@]+"${code_paths[@]}"} 2>/dev/null \
  | grep '^+' | grep -v '^+++' || true)"

markers="$(echo "$added" | grep -owE 'TODO|FIXME|XXX|HACK|console\.log|debugger|binding\.pry' \
  | sort -u | tr '\n' ' ' || true)"
[[ -n "${markers// /}" ]] && signal "adds unfinished-work markers: ${markers% }"

secrets="$(echo "$added" | grep -oiE '(api[_-]?key|secret|token|password|passwd)["'"'"']?\s*[:=]\s*["'"'"'][^"'"'"']{8,}' | head -3 || true)"
[[ -n "$secrets" ]] && signal "there seem to be credentials in the diff — check it first"

deps="$(echo "$files" | grep -iE 'package\.json|.*\.lock$|requirements.*\.txt|pyproject\.toml|go\.mod|Cargo\.toml|Gemfile' || true)"
[[ -n "$deps" ]] && signal "changes dependencies: $(echo "$deps" | tr '\n' ' ')"

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  n="$(wc -l < "$f")"
  [[ "$n" -gt 700 ]] && signal "$f ends up at $n lines"
done <<< "$files"

large="$(git diff --numstat "$BASE...$BRANCH" | awk '$1 + $2 > 400 {print $3" ("$1"+/"$2"-)"}' || true)"
[[ -n "$large" ]] && signal "large changes to review in one sitting: $(echo "$large" | tr '\n' ' ')"

[[ $has_signal -eq 0 ]] && ok "no automatic signal"

# --- 4. Risk and specialists ---------------------------------------------
#
# Which specialist reviewers the proposal deserves and who merges it. The diff
# decides, not the mood of the moment: by eye everything looks low risk.

section_head "risk and specialists"
scope="$(bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" "$BASE" 2>&1)" \
  || die "could not classify the proposal: $scope"
echo "$scope" | grep -v '^base:' | sed 's/^/      /'

# --- 5. The diff -------------------------------------------------------------

section_head "the diff, to read in full"
echo "      git diff $BASE...$BRANCH"

echo
info "this is the material, not the review: the review is /review-pr"
exit 0
