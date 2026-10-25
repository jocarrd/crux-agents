#!/usr/bin/env bash
# Real workflows on a blank machine: crux installed the way a person installs
# it and used from the PATH, with GitHub stood in for by a fake gh that keeps
# state and by local bare remotes. No network. Where e2e walks one cycle,
# this walks the journeys around it: a client's project, a task left waiting,
# a proposal merged from GitHub's button, a second machine from nothing.
#
#   bash test/flows.sh        CRUX_FLOWS_KEEP=1 keeps the sandbox to debug it
#
# The checks run through truthy's eval, where shellcheck does not see the
# variables they read.
# shellcheck disable=SC2034
set -u

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CARGO="$(command -v cargo || echo "$HOME/.cargo/bin/cargo")"
"$CARGO" build -q --release --manifest-path "$SRC/rs/Cargo.toml" || exit 1
BIN="$SRC/rs/target/release/crux"

real_settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
real_before="$(sha256sum "$real_settings" 2>/dev/null | cut -d' ' -f1)"
# Any of these left over from the shell that runs it would point the
# installed crux at the real folders instead of the sandbox's.
while read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(CLAUDE|CODEX|CRUX)')
SB="$(mktemp -d "${TMPDIR:-/tmp}/crux-flows-XXXXXX")"
[[ "${CRUX_FLOWS_KEEP:-0}" == "1" ]] || trap 'rm -rf "$SB"' EXIT
# A HOME of its own: install.sh, git and the agents' folders all hang from it.
export HOME="$SB/home"
mkdir -p "$HOME/crux"
# The kernel as a person clones it, without the build output.
tar -C "$SRC" --exclude=./rs/target --exclude=./.git -cf - . | tar -C "$HOME/crux" -xf -
git config --global user.email tester@localhost; git config --global user.name tester; git config --global init.defaultBranch main
mkdir -p "$HOME/bin" "$HOME/remotes" "$HOME/gh"; cp "$SRC/test/fake-gh" "$HOME/bin/gh"; chmod +x "$HOME/bin/gh"
export PATH="$HOME/bin:$HOME/.local/bin:$PATH" GH_STATE="$HOME/gh" GH_REMOTES="$HOME/remotes"
CRUX_BIN="$BIN" bash "$HOME/crux/install.sh" --projects-dir "$HOME/Proyectos" >/dev/null 2>&1
P="$HOME/Proyectos"

echo "flows — real journeys in $SB"
echo

STEP=0; FAILURES=0
step()  { STEP=$((STEP + 1)); echo "$STEP. $*"; }
truthy(){ if eval "$1"; then echo "   ok $2"; else FAILURES=$((FAILURES + 1)); echo "   FAIL $2"; fi; }
bare()  { git init -q --bare -b main "$HOME/remotes/$1.git"; }

step "crux is installed and answers from the PATH"
truthy '[[ "$(command -v crux)" == "$HOME/.local/bin/crux" ]]' "crux is on the PATH"
truthy 'crux --version | grep -q "kernel/"' "and runs the installed kernel"

# --- 1. An own project, the whole cycle -------------------------------------
step "a new project with a code repo, both on their remotes"
bare demo-docs; bare api
crux init demo --no-remote --parent "$P" --repos api >/dev/null 2>&1
D="$P/demo/demo-docs"; A="$P/demo/api"
crux __fn json_set "$D/crux.json" remote "{\"url\":\"$HOME/remotes/{repo}.git\"}"
git -C "$D" remote add origin "$HOME/remotes/demo-docs.git"
git -C "$D" add -A && git -C "$D" commit -qm "chore: remote" && git -C "$D" push -q -u origin main
mkdir -p "$A/src" && git -C "$A" init -q && echo "export const one = 1;" > "$A/src/index.js"
git -C "$A" add -A && git -C "$A" commit -qm "chore: start"
git -C "$A" remote add origin "$HOME/remotes/api.git" && git -C "$A" push -q -u origin main
(cd "$D" && crux link >/dev/null 2>&1)
git -C "$A" add -A && git -C "$A" commit -qm "docs: pointers" && git -C "$A" push -q
truthy '(cd "$D" && crux doctor >/dev/null 2>&1)' "doctor passes on the new project"

step "the guards are installed"
(cd "$D" && crux hooks install >/dev/null 2>&1)
truthy '[[ -x "$A/.git/hooks/commit-msg" && -x "$A/.git/hooks/pre-push" ]]' "commit-msg and pre-push in the code repo"
truthy 'grep -q "wait-guard" "$HOME/.claude/settings.json"' "and the agent hooks in Claude's settings"
truthy '! git -C "$A" push -q origin HEAD:main 2>/dev/null || [[ -z "$(git -C "$A" log origin/main..HEAD)" ]]' "a direct push to main is not taken (nothing new, or blocked)"

step "on main, the agent is reminded of the cycle"
out="$(cd "$A" && echo '{"session_id":"s1","prompt":"add a feature"}' | crux hook cycle-guard 2>&1)"
truthy '[[ "$out" == *"workspace"* ]]' "the reminder points at a workspace"

step "a workspace for the task"
(cd "$A" && crux workspace new checkout --goal "Pay in one step" >/dev/null 2>&1)
W="$P/demo/api-ws-checkout"
truthy '[[ -d "$W" && "$(git -C "$W" rev-parse --abbrev-ref HEAD)" == "ws/checkout" ]]' "worktree on its own branch"
out="$(cd "$W" && echo '{"session_id":"s2"}' | crux hook task-context 2>&1)"
truthy '[[ "$out" == *"checkout"* ]]' "a session opened there is told its task"

step "the commit hook does its job"
echo "export const pay = () => true;" > "$W/src/pay.js"; git -C "$W" add -A
truthy '! git -C "$W" commit -qm "feat: añade el pago en un paso" 2>/dev/null' "a message in Spanish is rejected"
git -C "$W" commit -qm "$(printf 'feat: pay in one step\n\nCo-Authored-By: Claude <noreply@anthropic.com>')" >/dev/null 2>&1
truthy '! git -C "$W" log -1 --format=%B | grep -qi co-authored' "the tool signature is stripped"
truthy '[[ "$(git -C "$W" log -1 --format=%s)" == "feat: pay in one step" ]]' "and the message stays"

step "the task records the work"
(cd "$W" && crux task add "Payment endpoint" >/dev/null && crux task "done" T1 "unit test green" >/dev/null \
  && crux task note "One step, no cart" --why "fewer screens on mobile" >/dev/null)
out="$(cd "$W" && crux task 2>&1)"
truthy '[[ "$out" == *"steps 1/1"* ]]' "one step, done"

step "the gate, with its receipt"
out="$(cd "$W" && crux ship scope main 2>&1)"
truthy '[[ "$out" == *"files: 1"* && "$out" == *"gates:"* ]]' "ship scope classifies the diff"
(cd "$W" && crux ship run -- true >/dev/null 2>&1 && crux ship seal >/dev/null 2>&1)
truthy '(cd "$W" && crux ship show 2>&1 | grep -q sealed)' "the receipt is sealed on HEAD"

step "the proposal"
out="$(cd "$W" && crux workspace finish checkout 2>&1)"
truthy '[[ "$out" == *"proposal opened: https://github.com/acme/api/pull/1"* ]]' "finish pushes and opens it"
truthy 'grep -q "Pay in one step" "$GH_STATE/body.1"' "the description comes from the task"
truthy '! grep -qi "co-authored\|generated with" "$GH_STATE/body.1"' "with no tool signature"
truthy 'grep -q "^status: proposed" "$HOME/.crux/tasks/demo/checkout.md"' "and the task is proposed"

step "finishing again updates the open proposal"
out="$(cd "$W" && crux workspace finish checkout 2>&1)"
truthy '[[ "$out" == *"already open"* && "$out" == *"pull/1"* ]]' "it says the proposal was updated"
truthy '[[ ! -f "$GH_STATE/pr.2" ]]' "and does not open a second one"

step "red CI blocks the merge, green CI lets it through"
echo fail > "$GH_STATE/checks"
out="$(cd "$W" && crux workspace merge checkout --yes 2>&1)"; rc=$?
truthy '[[ $rc -ne 0 && "$out" == *"not merging"* ]]' "with a failing check it does not merge"
echo running > "$GH_STATE/checks"
out="$(cd "$W" && crux workspace merge checkout --yes 2>&1)"; rc=$?
truthy '[[ $rc -ne 0 && "$out" == *"still running"* ]]' "nor with checks still running"
echo pass > "$GH_STATE/checks"
out="$(cd "$W" && crux workspace merge checkout --yes 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 && "$out" == *"merged"* ]]' "green, it merges"
truthy 'git -C "$HOME/remotes/api.git" log main --format=%s | grep -q "pay in one step"' "the change is on the remote's main"
truthy '[[ ! -d "$W" ]]' "the workspace is closed"
truthy '[[ ! -f "$HOME/.crux/tasks/demo/checkout.md" ]]' "the task is archived"
truthy 'grep -q "One step, no cart" "$D/repos/api/notes.md"' "and its decision reached the docs repo"

step "leaving the machine"
out="$(cd "$P" && crux sync --leave 2>&1)"; rc=$?
truthy '[[ $rc -ne 0 && "$out" == *"demo-docs"* ]]' "the decisions not yet pushed keep it from being left"
git -C "$D" push -q
git -C "$A" pull -q --ff-only 2>/dev/null
out="$(cd "$P" && crux sync --leave 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 ]]' "pushed, it can be left"

# --- 2. A client's repo -----------------------------------------------------
step "a client's project: nothing of ours in their repo"
crux init client --no-remote --parent "$P" --repos app --profile client-repo >/dev/null 2>&1
CD="$P/client/client-docs"; CA="$P/client/app"
mkdir -p "$CA" && git -C "$CA" init -q && echo "x" > "$CA/a.ts" && git -C "$CA" add -A && git -C "$CA" commit -qm "chore: start"
(cd "$CD" && crux link >/dev/null 2>&1)
truthy '[[ -f "$CA/CLAUDE.local.md" && ! -e "$CA/AGENTS.md" ]]' "only a local pointer, no AGENTS.md"
truthy 'git -C "$CA" check-ignore -q CLAUDE.local.md' "and the pointer is excluded from git"
out="$(cd "$CA" && crux workspace new fix-login 2>&1)"
truthy '[[ "$out" == *"will be seen in their repository"* ]]' "the workspace warns about our branch naming"
printf 'Fixes the login.\n\nChecked by passing crux ship and workspace finish.\n' > "$HOME/body.md"
truthy '! (cd "$P/client/app-ws-fix-login" && crux ship body "$HOME/body.md" >/dev/null 2>&1)' "a body naming our tooling does not pass"

# --- 3. A task waiting on someone -------------------------------------------
step "a task waiting on another person"
(cd "$A" && crux workspace new data-import >/dev/null 2>&1)
(cd "$P/demo/api-ws-data-import" && crux task wait --on "Ana" --ask "Is the old database still needed?" >/dev/null 2>&1)
out="$(cd "$P" && crux status 2>&1)"
truthy '[[ "$out" == *"waiting for an answer"* && "$out" == *"Ana"* ]]' "status lists it apart, with who it waits on"
truthy '[[ ! -d "$P/demo/api-ws-data-import" ]]' "its clean workspace is retired while it waits"
(cd "$A" && crux workspace resume data-import >/dev/null 2>&1)
truthy '[[ -d "$P/demo/api-ws-data-import" ]]' "the answer arrives: resume opens it again"
truthy '! grep -q "^waiting_on:" "$HOME/.crux/tasks/demo/data-import.md"' "and the task stops waiting"

# --- 4. A project from an older standard ------------------------------------
step "a project materialized with an older kernel"
crux __fn json_set "$D/crux.json" crux '"0.60.0"'
out="$(cd "$D" && crux doctor 2>&1)"
truthy '[[ "$out" == *"materialized with crux 0.60.0"* ]]' "doctor says it is behind"
(cd "$D" && crux upgrade >/dev/null 2>&1)
out="$(cd "$D" && crux doctor 2>&1)"
truthy '[[ "$out" != *"materialized with crux 0.60.0"* ]]' "upgrade brings it up to date"

# --- 5. Archiving a repo ----------------------------------------------------
step "a repo out of production and back"
(cd "$D" && crux archive api --reason "Replaced by the new service" --no-remote >/dev/null 2>&1)
truthy '[[ "$(crux __fn json_value "$D/crux.json" repos)" == "[]" ]]' "it leaves the active repos"
out="$(cd "$A" && crux workspace new late 2>&1)"; rc=$?
truthy '[[ $rc -ne 0 ]]' "and no workspace opens on it"
(cd "$D" && crux unarchive api --no-remote >/dev/null 2>&1)
truthy '[[ "$(crux __fn json_value "$D/crux.json" repos)" == "[\"api\"]" ]]' "unarchived, it is active again"

# --- 6. Merged with GitHub's button, not with crux --------------------------
step "a proposal merged on GitHub: sync notices it, rm closes it"
(cd "$A" && crux workspace new button >/dev/null 2>&1)
WB="$P/demo/api-ws-button"
echo "export const b = 1;" > "$WB/src/b.js"; git -C "$WB" add -A; git -C "$WB" commit -qm "feat: button" >/dev/null 2>&1
(cd "$WB" && crux ship run -- true >/dev/null 2>&1 && crux ship seal >/dev/null 2>&1 && crux workspace finish button >/dev/null 2>&1)
(cd "$WB" && gh pr merge >/dev/null 2>&1)
(cd "$P" && crux sync >/dev/null 2>&1)
truthy 'grep -q "^status: merged" "$HOME/.crux/tasks/demo/button.md" 2>/dev/null' "sync marks the task merged"
out="$(cd "$P" && crux status 2>&1)"
truthy '[[ "$out" == *"button"* ]]' "status still lists the open workspace"
(cd "$A" && crux workspace rm button >/dev/null 2>&1)
truthy '[[ ! -d "$WB" ]]' "rm closes the merged workspace"
truthy '[[ ! -f "$HOME/.crux/tasks/demo/button.md" ]]' "and its task is archived"

# --- 7. The person's profile ------------------------------------------------
step "the person's profile on a fresh machine"
out="$(crux profile init --no-remote 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 ]]' "profile init creates it"
truthy 'grep -q "agent-profile/PROFILE.md" "$HOME/.claude/CLAUDE.md"' "and Claude loads it"
truthy 'grep -q "agent-profile" "$HOME/.codex/AGENTS.md" 2>/dev/null' "and so does Codex"

# --- 8. MCP servers the project declares ------------------------------------
step "an MCP server declared in the contract"
crux __fn json_set "$D/crux.json" mcp '{"docs-search":{"transport":"http","url":"https://mcp.example.com/mcp"},"db":{"transport":"stdio","command":"db-mcp","repos":"all"}}'
(cd "$D" && crux mcp install 2>&1 | sed 's/^/      mcp| /'); cat "$A/.mcp.json" 2>&1 | head -12 | sed 's/^/      json| /' 
truthy 'grep -q "docs-search" "$D/.mcp.json" && grep -q "\"db\"" "$D/.mcp.json"' "the docs repo gets every server"
truthy 'grep -q "\"db\"" "$A/.mcp.json" && ! grep -q "docs-search" "$A/.mcp.json"' "a code repo only the ones declared for it"
out="$(cd "$D" && crux mcp status 2>&1)"
truthy '[[ "$out" == *"docs-search"* ]]' "status lists it"
out="$(cd "$D" && crux doctor 2>&1)"
truthy '[[ "$out" == *"MCP servers declared and written where they belong"* ]]' "doctor agrees"

# --- 9. What the agent remembers and the project does not -------------------
step "an agent memory that belongs in git"
scope="$(echo "$A" | sed 's#/#-#g')"; mkdir -p "$HOME/.claude/projects/$scope/memory"
printf -- '---\nname: deploy-port\ndescription: the api listens on 8080 in production\nmetadata:\n  type: project\n---\n\nThe api listens on 8080.\n' \
  > "$HOME/.claude/projects/$scope/memory/deploy-port.md"
out="$(cd "$A" && crux memory --brief 2>&1)"
truthy '[[ "$out" == *"1"* ]]' "memory --brief counts it"
truthy '! (cd "$A" && crux memory --check >/dev/null 2>&1)' "and --check fails until it is promoted"

# --- 10. Reviewing a proposal ----------------------------------------------
step "the material to review a proposal"
WD="$P/demo/api-ws-data-import"
echo "export const imported = true;" > "$WD/src/import.js"; git -C "$WD" add -A; git -C "$WD" commit -qm "feat: import data" >/dev/null 2>&1
out="$(crux review --repo "$WD" --base main 2>&1)"
truthy '[[ "$out" == *"ws/data-import"* && "$out" == *"src/import.js"* ]]' "review names the branch and the files"
truthy '[[ "$out" == *"risk:"* && "$out" == *"merge:"* ]]' "and classifies the risk and who merges"

# --- 11. A visual review a person approved ----------------------------------
step "a visual review with its receipt"
mkdir -p "$HOME/shots" && printf '\x89PNG\r\n' > "$HOME/shots/home-before.png" && printf '\x89PNG\r\n' > "$HOME/shots/home-after.png"
(cd "$WD" && crux visual approve "$HOME/shots" --note "approved by Ana" >/dev/null 2>&1)
out="$(cd "$WD" && crux visual show 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 && "$out" == *"2 images"* ]]' "show finds the approved images for this commit"
echo "export const later = 1;" >> "$WD/src/import.js"; git -C "$WD" commit -qam "feat: one more change" >/dev/null 2>&1
truthy '! (cd "$WD" && crux visual show >/dev/null 2>&1)' "a new commit asks for the review again"

# --- 12. A second machine, from nothing -------------------------------------
step "a new machine brings every project"
M2="$HOME/m2"; mkdir -p "$M2/.crux"
printf '[user]\n\temail = tester@localhost\n\tname = tester\n[init]\n\tdefaultBranch = main\n' > "$M2/.gitconfig"
printf 'CRUX_REMOTE="%s/{repo}.git"\n' "$HOME/remotes" > "$M2/.crux/config"
env HOME="$M2" CRUX_BIN="$BIN" bash "$HOME/crux/install.sh" --projects-dir "$M2/Proyectos" >/dev/null 2>&1
out="$(env HOME="$M2" "$M2/.local/bin/crux" bootstrap 2>&1)"; rc=$?
truthy '[[ -f "$M2/Proyectos/demo/demo-docs/crux.json" ]]' "bootstrap brings the docs repo"
truthy '[[ -d "$M2/Proyectos/demo/api/.git" ]]' "and the code repo it declares"
out="$(env HOME="$M2" "$M2/.local/bin/crux" status 2>&1)"
truthy '[[ "$out" == *"data-import"* ]]' "and the open task of the first machine"

# --- 13. A project that predates the standard -------------------------------
step "adopting a docs repo that already existed"
OLD="$P/legacy/legacy-docs"; mkdir -p "$OLD" "$P/legacy/backend"
git -C "$P/legacy/backend" init -q -b main && git -C "$P/legacy/backend" commit -q --allow-empty -m "chore: start"
git -C "$OLD" init -q -b main && printf '# Legacy\n\nOur own notes, written by hand.\n' > "$OLD/README.md"
git -C "$OLD" add -A && git -C "$OLD" commit -qm "docs: notes" >/dev/null
out="$(crux adopt "$OLD" 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 && -f "$OLD/crux.json" ]]' "adopt writes the missing contract"
truthy 'grep -q "written by hand" "$OLD/README.md"' "and rewrites nothing that was there"
truthy '[[ "$out" == *"backend"*"not declared"* || "$out" == *"not declared"*"backend"* ]] && ! grep -q "backend" "$OLD/crux.json"' \
  "a sibling repo is named, not declared behind your back"
out="$(cd "$OLD" && crux upgrade 2>&1)"
truthy '[[ -f "$OLD/repos/README.md" && -f "$OLD/CLAUDE.md" ]]' "upgrade restores the structure it was missing"
truthy 'grep -q "written by hand" "$OLD/README.md"' "still without touching what was there"

step "a new repo joins the adopted project"
mkdir -p "$P/legacy/mobile" && git -C "$P/legacy/mobile" init -q -b main && git -C "$P/legacy/mobile" commit -q --allow-empty -m "chore: start"
out="$(crux add-repo backend --description "The API" "$OLD" 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 ]] && grep -q "backend" "$OLD/crux.json" && grep -q "backend" "$OLD/repos/README.md"' \
  "the sibling adopt named joins with add-repo"
out="$(crux add-repo mobile --description "The phone app" "$OLD" 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 ]] && grep -q "mobile" "$OLD/crux.json"' "add-repo declares it in the contract"
truthy '[[ -d "$OLD/repos/mobile" ]]' "with its documentation folder"
truthy 'grep -q "mobile" "$OLD/repos/README.md"' "and its row in the table of repos"
truthy '[[ -f "$P/legacy/mobile/CLAUDE.local.md" || -f "$P/legacy/mobile/CLAUDE.md" ]]' "and the repo gets its pointer"

step "checking a text before handing it over"
printf 'No es solo una herramienta, es una revolución. Rápido, simple y potente. Al final, lo que importa es el viaje.\n' > "$HOME/draft.md"
printf 'El comando clona cada proyecto y escribe sus punteros. Si falta una credencial, lo dice al final.\n' > "$HOME/plain.md"
truthy '! crux prose check "$HOME/draft.md" >/dev/null 2>&1' "a text full of tics is flagged"
truthy 'crux prose check "$HOME/plain.md" >/dev/null 2>&1' "and a plain one passes"

step "a repo's own git hook runs after crux's"
printf '#!/bin/sh\necho own >> "%s"\n' "$HOME/own-hook" > "$A/.git/hooks/commit-msg.local"; chmod +x "$A/.git/hooks/commit-msg.local"
git -C "$A" commit -q --allow-empty -m "chore: tick the release checklist" 2>/dev/null
truthy '[[ -s "$HOME/own-hook" ]]' "the .local hook runs on a commit"
git -C "$A" commit -q --allow-empty -m "chore: añade la lista de la versión" 2>/dev/null
truthy '[[ "$(wc -l < "$HOME/own-hook")" -eq 1 ]]' "and not after crux rejects the message"

step "a hook of the project's own, written once and found on every machine"
out="$(cd "$D" && crux hooks add pre-commit --repo api 2>&1)"
printf '#!/usr/bin/env bash\necho project >> "%s"\n' "$HOME/project-hook" > "$D/repos/api/git-hooks/pre-commit"
git -C "$D" add -A && git -C "$D" commit -qm "chore(api): a pre-commit of its own" 2>/dev/null && git -C "$D" push -q 2>/dev/null
(cd "$D" && crux hooks install >/dev/null 2>&1)
git -C "$A" commit -q --allow-empty -m "chore: tick another box" 2>/dev/null
truthy '[[ -s "$HOME/project-hook" ]]' "the project's hook runs in the code repo"
M3="$HOME/m3"; mkdir -p "$M3/.crux"
printf '[user]\n\temail = tester@localhost\n\tname = tester\n[init]\n\tdefaultBranch = main\n' > "$M3/.gitconfig"
printf 'CRUX_REMOTE="%s/{repo}.git"\n' "$HOME/remotes" > "$M3/.crux/config"
env HOME="$M3" CRUX_BIN="$BIN" bash "$HOME/crux/install.sh" --projects-dir "$M3/Proyectos" >/dev/null 2>&1
env HOME="$M3" "$M3/.local/bin/crux" bootstrap >/dev/null 2>&1
truthy '[[ -x "$M3/Proyectos/demo/api/.git/hooks/pre-commit.project" ]]' "and another machine gets it with bootstrap"

step "a machine that only gets the binary, as npm or a download hands it over"
M4="$HOME/m4"; mkdir -p "$M4/dl"; cp "$BIN" "$M4/dl/crux"
printf '[user]\n\temail = tester@localhost\n\tname = tester\n[init]\n\tdefaultBranch = main\n' > "$M4/.gitconfig"
out="$(cd "$M4/dl" && env HOME="$M4" ./crux --version 2>&1)"
truthy '[[ "$out" == "crux $(tr -d "[:space:]" < "$SRC/VERSION") — not installed"* ]]' \
  "before installing, it knows its version and says what comes next"
out="$(cd "$M4/dl" && env HOME="$M4" ./crux install --projects-dir "$M4/Proyectos" 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 && -x "$M4/.local/bin/crux" ]]' "crux install lays out the kernel it carries"
env HOME="$M4" "$M4/.local/bin/crux" init solo --no-remote --parent "$M4/Proyectos" >/dev/null 2>&1
truthy 'env HOME="$M4" "$M4/.local/bin/crux" doctor "$M4/Proyectos/solo/solo-docs" >/dev/null 2>&1' \
  "and with it a new project passes doctor"

step "setup on a machine with nothing, without a terminal: it takes the defaults"
M5="$HOME/m5"; mkdir -p "$M5/dl" "$M5/.crux"; cp "$BIN" "$M5/dl/crux"
printf '[user]\n\temail = tester@localhost\n\tname = tester\n[init]\n\tdefaultBranch = main\n' > "$M5/.gitconfig"
printf 'CRUX_REMOTE="%s/{repo}.git"\n' "$HOME/remotes" > "$M5/.crux/config"
out="$(cd "$M5/dl" && env HOME="$M5" ./crux setup --projects-dir "$M5/Proyectos" </dev/null 2>&1)"; rc=$?
truthy '[[ $rc -eq 0 && "$out" == *"ready"* ]]' "setup gets to the end without asking"
truthy '[[ -f "$M5/Proyectos/demo/demo-docs/crux.json" ]]' "and brings the account's project, the default answer"
truthy '[[ -x "$M5/.local/bin/crux" ]]' "with crux installed from the binary alone"

step "the real agent settings are not touched"
truthy '[[ "$(sha256sum "$real_settings" 2>/dev/null | cut -d" " -f1)" == "$real_before" ]]' \
  "the settings.json of whoever runs it comes out as it went in"

echo
echo "flows: $FAILURES failures in $STEP steps"
[[ $FAILURES -eq 0 ]]
