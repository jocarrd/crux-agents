#!/usr/bin/env bash
# Two-machine battery: one person, two computers, one project.
#
#   test/two-machines.sh
#
# e2e walks the cycle on one machine. What it cannot see is what travels: a
# task started on the laptop and resumed on the desktop, the branch it left
# behind, and `sync --leave` refusing to let work stay on one machine only.
# Each machine here is its own HOME, projects root and registry; the only
# thing they share is the remotes, which are local bare repos.
# The checks are strings that truthy evaluates: shellcheck does not see the
# variables they read.
# shellcheck disable=SC2034

set -uo pipefail

CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# Without CRUX_IN_TESTS, the hooks install that clone runs took this checkout
# for the person's kernel and rewrote the git hooks of the real repo.
export CRUX_HOME CRUX_IN_TESTS=1
kernel_hooks() { cat "$(git -C "$CRUX_HOME" rev-parse --path-format=absolute --git-common-dir)"/hooks/* 2>/dev/null | cksum; }
hooks_before="$(kernel_hooks)"
# Tasks publish themselves when written; here that is what is being tested.
export CRUX_TASK_SYNC=1

SB="$(mktemp -d "${TMPDIR:-/tmp}/crux-2m-XXXXXX")"
REMOTES="$SB/remotes"
mkdir -p "$REMOTES"

STEP=0; FAILURES=0
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; D=$'\033[2m'; O=$'\033[0m'; else R=""; G=""; D=""; O=""; fi
step()  { STEP=$((STEP + 1)); echo "${D}$STEP. $*${O}"; }
good()  { echo "   ${G}ok${O} $*"; }
bad()   { FAILURES=$((FAILURES + 1)); echo "   ${R}fail${O} $*"; }
truthy(){ if eval "$1"; then good "$2"; else bad "$2"; fi; }

[[ "${CRUX_E2E_KEEP:-0}" == "1" ]] || trap 'rm -rf "$SB"' EXIT

machine() {
  local m="$SB/$1"
  mkdir -p "$m/projects" "$m/.crux"
  printf '[user]\n\temail = %s@localhost\n\tname = %s\n[init]\n\tdefaultBranch = main\n' "$1" "$1" > "$m/.gitconfig"
  printf 'CRUX_REMOTE="%s/{repo}.git"\nCRUX_PROJECTS_DIR="%s/projects"\n' "$REMOTES" "$m/projects" > "$m/.crux/config"
}
# on <machine> <command...>: runs it as that machine, from its projects root.
on() {
  local m="$SB/$1"; shift
  ( cd "${CWD:-$m/projects}" && env HOME="$m" CRUX_PROJECTS_DIR="$m/projects" \
      CLAUDE_SETTINGS="$m/.claude/settings.json" CLAUDE_SKILLS_DIR="$m/.claude/skills" \
      CODEX_HOME_DIR="$m/.codex" CODEX_PROMPTS_DIR="$m/.codex/prompts" "$@" )
}
crux_on() { local m="$1"; shift; on "$m" "$CRUX_HOME/bin/crux" "$@"; }
bare() { git init -q --bare -b main "$REMOTES/$1.git"; }

echo "two machines — $SB"
echo

machine laptop
machine desktop
A="$SB/laptop/projects/demo"
B="$SB/desktop/projects/demo"

step "the laptop creates the project and publishes it"
bare demo-docs; bare api
crux_on laptop init demo --parent "$SB/laptop/projects" --repos api >/dev/null 2>&1
truthy '[[ -f "$A/demo-docs/crux.json" ]]' "the docs repo exists"
truthy 'grep -q "remotes/{repo}.git" "$A/demo-docs/crux.json"' "and the contract says where the repos live"
mkdir -p "$A/api" && git -C "$A/api" init -q -b main
echo "export const one = 1;" > "$A/api/index.js"
on laptop git -C "$A/api" add -A
on laptop git -C "$A/api" commit -qm "chore: start"
on laptop git -C "$A/api" remote add origin "$REMOTES/api.git"
on laptop git -C "$A/api" push -q -u origin main
crux_on laptop link "$A/demo-docs" >/dev/null 2>&1
# The pointers link writes into the code repo are committed with it.
on laptop git -C "$A/api" add -A
on laptop git -C "$A/api" commit -qm "docs: point to demo-docs"
on laptop git -C "$A/api" push -q
on laptop git -C "$A/demo-docs" add -A
on laptop git -C "$A/demo-docs" commit -qm "docs: link api" >/dev/null 2>&1
truthy 'on laptop git -C "$A/demo-docs" push -q -u origin main' "the docs repo reaches its remote"

step "the laptop starts a task and leaves it halfway"
CWD="$A/api" crux_on laptop workspace new checkout --goal "Pay in one step" >/dev/null 2>&1
WA="$A/api-ws-checkout"
truthy '[[ -d "$WA" ]]' "the workspace exists"
echo "export const pay = () => true;" > "$WA/pay.js"
on laptop git -C "$WA" add -A
on laptop git -C "$WA" commit -qm "feat: pay in one step"
CWD="$WA" crux_on laptop task add "Payment endpoint" >/dev/null 2>&1
CWD="$WA" crux_on laptop task next "Try it on mobile" >/dev/null 2>&1

step "leaving with work only here is refused"
out="$(CWD="$A" crux_on laptop sync --leave 2>&1)"; rc=$?
truthy '[[ $rc -ne 0 ]]' "sync --leave fails"
truthy '[[ "$out" == *"ws/checkout"* ]]' "and names the branch that is only here"

step "pushing the branch and the task lets the laptop be left"
on laptop git -C "$WA" push -q -u origin ws/checkout
out="$(CWD="$A" crux_on laptop sync --leave 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 ]]' "sync --leave passes"
truthy 'git -C "$REMOTES/demo-docs.git" rev-parse -q --verify refs/heads/crux/tasks >/dev/null' \
  "the task travelled to the docs repo's task branch"

step "the desktop brings the project"
crux_on desktop clone demo --from "$REMOTES/{repo}.git" --parent "$SB/desktop/projects" >/dev/null 2>&1
truthy '[[ -f "$B/demo-docs/crux.json" && -f "$B/api/index.js" ]]' "the docs repo and the code repo are cloned"
CWD="$B" crux_on desktop sync >/dev/null 2>&1
out="$(crux_on desktop status 2>&1)"
truthy '[[ "$out" == *"demo/checkout"* ]]' "status shows the laptop's task, with no workspace here"

step "the desktop resumes the task where it was left"
out="$(CWD="$B/api" crux_on desktop workspace resume checkout 2>&1)"
WB="$B/api-ws-checkout"
truthy '[[ -f "$WB/pay.js" ]]' "the worktree has the laptop's commit"
truthy '[[ "$(git -C "$WB" rev-parse --abbrev-ref HEAD)" == "ws/checkout" ]]' "on the same branch"
out="$(CWD="$WB" crux_on desktop task 2>&1)"
truthy '[[ "$out" == *"Try it on mobile"* ]]' "and the task says what was next"
truthy 'grep -q "Payment endpoint" "$SB/desktop/.crux/tasks/demo/checkout.md"' "and has the step done on the laptop"

step "the desktop moves it on and publishes"
echo "export const mobile = true;" > "$WB/mobile.js"
on desktop git -C "$WB" add -A
on desktop git -C "$WB" commit -qm "feat: mobile"
CWD="$WB" crux_on desktop task add "Tried on mobile" >/dev/null 2>&1
on desktop git -C "$WB" push -q
out="$(CWD="$B" crux_on desktop sync --leave 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 ]]' "the desktop can be left too"

step "back on the laptop, everything is there"
CWD="$A" crux_on laptop sync >/dev/null 2>&1
truthy '[[ -f "$WA/mobile.js" ]]' "the clean workspace advanced to the desktop's commit"
truthy 'grep -q "Tried on mobile" "$SB/laptop/.crux/tasks/demo/checkout.md"' "and the task has the desktop's step"

step "a task changed on both machines at once is not lost"
CWD="$WA" crux_on laptop task note "laptop decision" --why "measured here" >/dev/null 2>&1
CWD="$WB" crux_on desktop task note "desktop decision" --why "measured there" >/dev/null 2>&1
CWD="$A" crux_on laptop sync >/dev/null 2>&1
CWD="$B" crux_on desktop sync >/dev/null 2>&1
CWD="$A" crux_on laptop sync >/dev/null 2>&1
la="$(cat "$SB"/laptop/.crux/tasks/demo/checkout*.md 2>/dev/null)"
de="$(cat "$SB"/desktop/.crux/tasks/demo/checkout*.md 2>/dev/null)"
truthy '[[ "$la$de" == *"laptop decision"* && "$la$de" == *"desktop decision"* ]]' \
  "both decisions survive: the most recent wins, the other is kept alongside"
truthy 'ls "$SB"/*/.crux/tasks/demo/ | grep -q "checkout.conflict-.*\.md"' "the copy alongside is named in English"

step "the real machine was not touched"
truthy '[[ ! -e "$HOME/.crux/tasks/demo" ]]' "no task of the demo reached the real ~/.crux"
truthy '[[ "$(kernel_hooks)" == "$hooks_before" ]]' "nor were the kernel repo's git hooks rewritten"

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "${G}two machines passed${O} — $STEP steps"
else
  echo "${R}$FAILURES failures in $STEP steps${O}"
fi
[[ $FAILURES -eq 0 ]]
