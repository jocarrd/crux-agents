#!/usr/bin/env bash
# The checks are strings that truthy evaluates: shellcheck does not see the
# variables they read.
# shellcheck disable=SC2034
# End-to-end battery: the complete cycle on a real project.
#
#   test/e2e.sh
#
# The test/run.sh suite tests pieces. This tests the journey: create the
# project, register a repo, install the guards, open a workspace, pass the
# gate, propose and merge. The kernel's costliest failures have shown up here
# and not there, because they only show when the pieces are used in sequence.
#
# It depends on no provider: the remote is a local bare repo.

set -uo pipefail

CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export CRUX_HOME CRUX_IN_TESTS=1

SB="$(mktemp -d "${TMPDIR:-/tmp}/crux-e2e-XXXXXX")"
export CRUX_PROJECTS_DIR="$SB/projects"
export CLAUDE_SKILLS_DIR="$SB/home/.claude/skills"
export CODEX_PROMPTS_DIR="$SB/home/.codex/prompts"
export CODEX_HOME_DIR="$SB/home/.codex"
export CRUX_REGISTRY="$SB/workspaces.json"
# Without this, `crux hooks install` rewrote the real hooks of whoever ran the
# gate and left them pointing at the tree being tested.
export CLAUDE_SETTINGS="$SB/home/.claude/settings.json"
mkdir -p "$CRUX_PROJECTS_DIR" "$CLAUDE_SKILLS_DIR" "$CODEX_PROMPTS_DIR"
real_settings="$HOME/.claude/settings.json"
real_before="$(sha256sum "$real_settings" 2>/dev/null | cut -d' ' -f1)"
# A HOME of its own: with the real one, the machine's ~/.crux/config put its
# remote in the project's contract, and finish refused the local remote. In CI
# there is no config and the step passed; only on a used machine did it fail.
export HOME="$SB/home"
printf '[user]\n\temail = e2e@localhost\n\tname = e2e\n[init]\n\tdefaultBranch = main\n' > "$HOME/.gitconfig"

STEP=0; FAILURES=0
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; D=$'\033[2m'; O=$'\033[0m'; else R=""; G=""; D=""; O=""; fi

step()  { STEP=$((STEP + 1)); echo "${D}$STEP. $*${O}"; }
good()  { echo "   ${G}ok${O} $*"; }
bad()   { FAILURES=$((FAILURES + 1)); echo "   ${R}fail${O} $*"; }
truthy(){ if eval "$1"; then good "$2"; else bad "$2"; fi; }

git_() { git -c user.email=e2e@localhost -c user.name=e2e "$@"; }

crux() { "$CRUX_HOME/bin/crux" "$@"; }

# CRUX_E2E_KEEP=1 keeps the sandbox: without it, debugging a failing step
# means reproducing the whole journey by hand.
[[ "${CRUX_E2E_KEEP:-0}" == "1" ]] || trap 'rm -rf "$SB"' EXIT

echo "e2e — the complete cycle in $SB"
echo

# --- 1. A new project, with its remote ---------------------------------------

step "create the project"
REMOTE="$SB/remotes/demo-docs.git"
mkdir -p "$(dirname "$REMOTE")"
# The bare repo's HEAD decides which branch a clone checks out: if it points at
# one that does not exist, the clone comes out empty without saying why.
git init -q --bare -b main "$REMOTE" 2>/dev/null || { git init -q --bare "$REMOTE"; git -C "$REMOTE" symbolic-ref HEAD refs/heads/main; }
crux init demo --no-remote --parent "$CRUX_PROJECTS_DIR" --repos api >/dev/null 2>&1
DOCS="$CRUX_PROJECTS_DIR/demo/demo-docs"
truthy '[[ -f "$DOCS/crux.json" ]]' "the docs repo exists"
truthy '[[ "$(git -C "$DOCS" rev-parse --abbrev-ref HEAD)" == "main" ]]' "it is born on the declared branch"
git -C "$DOCS" remote add origin "$REMOTE"

step "the code repo, registered and linked"
REPO="$CRUX_PROJECTS_DIR/demo/api"
mkdir -p "$REPO/src" && git init -q -b main "$REPO"
echo "export const uno = 1;" > "$REPO/src/index.js"
git_ -C "$REPO" add -A && git_ -C "$REPO" commit -qm "chore: init"
crux link "$DOCS" >/dev/null 2>&1
truthy '[[ -f "$REPO/AGENTS.md" && -f "$REPO/CLAUDE.md" ]]' "the pointers are in the code repo"
truthy 'grep -q "crux:begin" "$REPO/AGENTS.md"' "and carry the managed block"

step "conformance"
"$CRUX_HOME/bin/crux" doctor "$DOCS" >/dev/null 2>&1
truthy '[[ $? -eq 0 ]]' "doctor passes on the freshly created project"

# --- 2. The guards -----------------------------------------------------------

step "install the guards"
( cd "$DOCS" && crux hooks install >/dev/null 2>&1 )
truthy '[[ -x "$REPO/.git/hooks/pre-push" ]]' "pre-push installed in the code repo"
truthy 'grep -q "refs/heads/main" "$REPO/.git/hooks/pre-push"' "watches the declared main branch"
truthy '[[ ! -e "$DOCS/.git/hooks/pre-push" ]]' "the docs repo does not carry it: it is pushed directly"

step "a direct push to main is blocked in code, not in docs"
git_ -C "$DOCS" add -A >/dev/null 2>&1
git_ -C "$DOCS" commit -qm "docs: initial" >/dev/null 2>&1
git -C "$DOCS" push -q origin main >/dev/null 2>&1
echo "more" >> "$DOCS/README.md"
git_ -C "$DOCS" commit -qam "docs: tweak" >/dev/null 2>&1
git -C "$DOCS" push -q origin main >/dev/null 2>&1
truthy '[[ "$(git -C "$REMOTE" rev-parse main)" == "$(git -C "$DOCS" rev-parse HEAD)" ]]' \
  "the documentation reaches the remote without a proposal"
# A separate remote so as not to touch the one the proposal uses further down.
git init -q --bare "$SB/remotes/api-blocked.git"
git -C "$REPO" push -q "$SB/remotes/api-blocked.git" HEAD:refs/heads/main >/dev/null 2>&1
truthy 'git -C "$SB/remotes/api-blocked.git" show-ref --verify --quiet refs/heads/main' "the first push creates main"
before="$(git -C "$SB/remotes/api-blocked.git" rev-parse main)"
echo "// more" >> "$REPO/src/index.js"
git_ -C "$REPO" commit -qam "feat: tweak" >/dev/null 2>&1
output="$(git -C "$REPO" push "$SB/remotes/api-blocked.git" HEAD:refs/heads/main 2>&1)"
truthy '[[ "$output" == *"blocked"* ]]' "the hook prevents updating the code main"
truthy '[[ "$(git -C "$SB/remotes/api-blocked.git" rev-parse main)" == "$before" ]]' "and nothing new reached the remote"

step "a commit message outside the language is rejected"
( cd "$REPO" && crux hooks install >/dev/null 2>&1 )
echo "// dos" >> "$REPO/src/index.js"
git_ -C "$REPO" add -A
output="$(git_ -C "$REPO" commit -m "feat: esto es para que el usuario pueda ver una cosa" 2>&1)"
truthy '[[ "$output" == *"in Spanish"* ]]' "the hook rejects it"
git_ -C "$REPO" commit -qm "feat: add a second export" >/dev/null 2>&1

# --- 3. The cycle ------------------------------------------------------------

step "open the workspace"
( cd "$REPO" && crux workspace new task >/dev/null 2>&1 )
WS="$CRUX_PROJECTS_DIR/demo/api-ws-task"
truthy '[[ -d "$WS" ]]' "the worktree exists"
truthy '[[ "$(git -C "$WS" rev-parse --abbrev-ref HEAD)" == "ws/task" ]]' "on its own branch"

step "develop and pass the gate"
echo "export const tres = 3;" >> "$WS/src/index.js"
mkdir -p "$WS/test" && echo "// test" > "$WS/test/index.test.js"
git_ -C "$WS" add -A && git_ -C "$WS" commit -qm "feat: add a third export" >/dev/null 2>&1
printf '%s\n' "$(git -C "$WS" rev-parse HEAD)" > "$WS/.crux-ship"
truthy '[[ -z "$(git -C "$WS" status --porcelain)" ]]' "the gate mark does not dirty the repo"

step "gather the review material"
output="$("$CRUX_HOME/bin/crux" review --repo "$WS" --base main 2>&1)"
truthy '[[ "$output" == *"ws/task"* ]]' "review says which branch it reviews"
truthy '[[ "$output" == *"src/index.js"* ]]' "and which files it touches"

step "propose the change"
git -C "$REPO" remote add origin "$SB/remotes/api.git" 2>/dev/null
git init -q --bare -b main "$SB/remotes/api.git" 2>/dev/null \
  || { git init -q --bare "$SB/remotes/api.git"; git -C "$SB/remotes/api.git" symbolic-ref HEAD refs/heads/main; }
# The gate is no longer declared: it is passed, and the receipt says what ran.
( cd "$WS" && crux ship run -- true >/dev/null 2>&1 && crux ship seal >/dev/null 2>&1 )
output="$( cd "$WS" && crux workspace finish task 2>&1 )"
truthy '[[ "$output" != *"uncommitted"* ]]' "the gate mark does not block the proposal"
truthy 'git -C "$SB/remotes/api.git" show-ref --verify --quiet refs/heads/ws/task' "the branch reached the remote"

step "close the workspace"
( cd "$REPO" && crux workspace rm task >/dev/null 2>&1 )
truthy '[[ ! -d "$WS" ]]' "the worktree is removed"
truthy '! grep -q "\"task\"" "$CRUX_REGISTRY"' "and the slot is freed"

# --- 4. Another machine ------------------------------------------------------

step "the project is recovered on another machine"
# The integration is done by the proposal; here its result is simulated, which
# is the only thing that matters for the question: does the project survive a
# change of machine?
git -C "$DOCS" push -q --no-verify origin main 2>/dev/null
OTHER="$SB/other"
mkdir -p "$OTHER"
git clone -q "$REMOTE" "$OTHER/demo-docs" 2>/dev/null
truthy '[[ -f "$OTHER/demo-docs/crux.json" ]]' "the docs repo travels by git"
truthy '[[ -f "$OTHER/demo-docs/repos/api/README.md" ]]' "with the documentation of its repos"

# --- 5. One more repo, hot ---------------------------------------------------

step "register a second repo in the project"
REPO2="$CRUX_PROJECTS_DIR/demo/worker"
mkdir -p "$REPO2" && git init -q -b main "$REPO2"
echo "worker" > "$REPO2/main.py"
git_ -C "$REPO2" add -A && git_ -C "$REPO2" commit -qm "chore: init"
( cd "$DOCS" && crux add-repo worker --description "Processes the queue" >/dev/null 2>&1 )
truthy '[[ -f "$DOCS/repos/worker/README.md" ]]' "the doc folder is created"
truthy 'grep -q "worker" "$DOCS/crux.json"' "and it is declared in the contract"
truthy '[[ -f "$REPO2/AGENTS.md" ]]' "with its pointer in the code repo"

step "a repo name cannot escape the folder"
output="$( cd "$DOCS" && crux add-repo "../../outside" --description "x" 2>&1 )"
truthy '[[ "$output" == *"kebab-case"* ]]' "it is rejected"
truthy '[[ ! -e "$CRUX_PROJECTS_DIR/outside" ]]' "and nothing is created outside"

# --- 6. Idempotence ----------------------------------------------------------

step "repeating link and hooks changes nothing"
before="$(md5sum "$REPO/AGENTS.md" | cut -d" " -f1)"
crux link "$DOCS" >/dev/null 2>&1
( cd "$DOCS" && crux hooks install >/dev/null 2>&1 )
truthy '[[ "$before" == "$(md5sum "$REPO/AGENTS.md" | cut -d" " -f1)" ]]' "the pointer is the same"
truthy '[[ "$(grep -c "crux workspace" "$DOCS/.git/hooks/pre-push")" -le 2 ]]' "the hook is not duplicated"

# --- 7. A project that already existed ---------------------------------------

step "adopt a docs repo that was not born with crux"
FOREIGN="$CRUX_PROJECTS_DIR/inherited/inherited-docs"
mkdir -p "$FOREIGN" && git init -q -b main "$FOREIGN"
echo "# inherited" > "$FOREIGN/README.md"
git_ -C "$FOREIGN" add -A && git_ -C "$FOREIGN" commit -qm "docs: init"
( cd "$FOREIGN" && crux adopt . >/dev/null 2>&1 )
truthy '[[ -f "$FOREIGN/crux.json" ]]' "it ends up with a contract"
output="$("$CRUX_HOME/bin/crux" upgrade "$FOREIGN" 2>&1)"
truthy '[[ "$output" == *"materialized"* || "$output" == *"no piece of the standard is missing"* ]]' "and upgrade completes whatever is missing"
"$CRUX_HOME/bin/crux" doctor "$FOREIGN" >/dev/null 2>&1
truthy '[[ $? -eq 0 ]]' "until doctor passes"

# --- 8. The client profile ---------------------------------------------------

step "with a client profile nothing is written in the foreign repo"
crux init client --no-remote --parent "$CRUX_PROJECTS_DIR" --repos vendor --profile client-repo >/dev/null 2>&1
CDOCS="$CRUX_PROJECTS_DIR/client/client-docs"
VENDOR="$CRUX_PROJECTS_DIR/client/vendor"
mkdir -p "$VENDOR" && git init -q -b main "$VENDOR"
echo "code" > "$VENDOR/main.c"
git_ -C "$VENDOR" add -A && git_ -C "$VENDOR" commit -qm "chore: init"
crux link "$CDOCS" >/dev/null 2>&1
truthy '[[ ! -f "$VENDOR/AGENTS.md" && ! -f "$VENDOR/CLAUDE.md" ]]' "link leaves no pointers"

step "and the workspace warns, but lets you work"
output="$( cd "$VENDOR" && crux workspace new task 2>&1 )"
truthy '[[ "$output" == *"documentation of vendor"* ]]' "warns where the documentation goes"
truthy '[[ "$output" == *"will be seen in their repository"* ]]' "and that the client will see the branch"
truthy '[[ -d "$CRUX_PROJECTS_DIR/client/vendor-ws-task" ]]' "and still creates the workspace"

step "doctor detects what is missing and what is extra"
rm -rf "$DOCS/repos/worker"
output="$("$CRUX_HOME/bin/crux" doctor "$DOCS" 2>&1)"
truthy '[[ "$output" == *"without a doc folder"* ]]' "reports the declared repo without docs"
"$CRUX_HOME/bin/crux" doctor "$DOCS" >/dev/null 2>&1
truthy '[[ $? -ne 0 ]]' "and exits with an error"

step "the real Claude Code settings are not touched"
truthy '[[ "$(sha256sum "$real_settings" 2>/dev/null | cut -d" " -f1)" == "$real_before" ]]' \
  "the settings.json of whoever runs it comes out as it went in"

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "${G}e2e passed${O} — $STEP steps of the cycle"
else
  echo "${R}$FAILURES failures${O} in $STEP steps"
fi
exit $(( FAILURES > 0 ? 1 : 0 ))
