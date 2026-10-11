#!/usr/bin/env bash

_repo_with_config() {
  # Creates a git repo with a sibling docs repo that declares the workspace allocation.
  local root="$CRUX_PROJECTS_DIR/proj"
  mkdir -p "$root/app" "$root/proj-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo content > "$root/app/f.txt"
  git -C "$root/app" add -A
  git -C "$root/app" commit -qm init
  cat > "$root/proj-docs/crux.json" <<'EOF'
{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["app"],"sections":[],
 "workspace":{"portBase":4000,"portsPerSlot":5,"envFile":".env.local",
   "env":{"PORT":"{{PORT0}}","API_PORT":"{{PORT1}}","DATABASE_URL":"postgres://localhost/app_ws{{SLOT}}"}}}
EOF
  echo "$root"
}

test_workspace_isolates_ports_and_database() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new uno --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new dos --repo "$root/app" >/dev/null 2>&1

  local a b
  a="$(cat "$root/app-ws-uno/.env.local")"
  b="$(cat "$root/app-ws-dos/.env.local")"

  assert_contains "$a" "PORT=4000" "the first workspace starts at the base port"
  assert_contains "$b" "PORT=4005" "the second takes the next range"
  assert_contains "$a" "app_ws0" "each workspace has its own database"
  assert_contains "$b" "app_ws1" "each workspace has its own database"
  assert_not_contains "$b" "PORT=4000" "the ranges do not overlap"
}

test_workspace_keeps_relative_pointers_resolvable() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new rel --repo "$root/app" >/dev/null 2>&1

  # The worktree goes in as a sibling precisely for this: if it lived outside
  # the project, the @-import of ../<project>-docs/ would stop resolving.
  assert_file "$root/app-ws-rel/../proj-docs/crux.json" \
    "the docs repo is still reachable at ../ from the workspace"
}

test_workspace_keeps_uncommitted_work() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new wip --repo "$root/app" >/dev/null 2>&1
  echo "half-done change" >> "$root/app-ws-wip/f.txt"

  assert_exit 1 "refuses to delete a workspace with changes" \
    bash "$CRUX_HOME/bin/workspace.sh" rm wip
  assert_file "$root/app-ws-wip/f.txt" "the work is still there"
}

test_workspace_warns_if_hooks_point_to_the_deleted_workspace() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new conhooks --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-conhooks"
  printf '{"hooks":{"Stop":[{"hooks":[{"command":"%s/adapters/x.sh"}]}]}}\n' "$ws" > "$CLAUDE_SETTINGS"

  rm -f "$ws/.env.local"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm conhooks 2>&1)"
  assert_contains "$out" "will break" "warns before leaving the hooks dangling"
  assert_contains "$out" "crux hooks install" "and says how to repair them"
}

test_workspace_rm_returns_hooks_to_kernel_main_checkout() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"
  local kernel="$root/app" ws="$root/app-ws-probar"
  cp -r "$CRUX_HOME/bin" "$CRUX_HOME/lib" "$CRUX_HOME/adapters" "$kernel/"
  git -C "$kernel" add -A
  git -C "$kernel" commit -qm kernel

  bash "$CRUX_HOME/bin/workspace.sh" new probar --repo "$kernel" >/dev/null 2>&1
  rm -f "$ws/.env.local"
  printf '#!/usr/bin/env bash\n' > "$ws/adapters/claude/hooks/new-guard.sh"
  git -C "$ws" add -A
  git -C "$ws" commit -qm "new hook"

  echo '{}' > "$CLAUDE_SETTINGS"
  ( cd "$ws" && CRUX_HOME="$ws" bash "$ws/bin/hooks.sh" install >/dev/null 2>&1 )
  node -e '
    const fs = require("fs");
    const [file, cmd] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(file, "utf8"));
    s.hooks.Stop.push({ matcher: "", hooks: [{ type: "command", command: cmd }] });
    fs.writeFileSync(file, JSON.stringify(s));
  ' "$CLAUDE_SETTINGS" "$ws/adapters/claude/hooks/new-guard.sh"
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "$ws/adapters/claude/hooks/doc-sync.sh" \
    "installing from the workspace hooks the workspace, which is what makes testing possible"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm probar 2>&1)"
  local settings; settings="$(cat "$CLAUDE_SETTINGS")"
  assert_contains "$settings" "$kernel/adapters/claude/hooks/doc-sync.sh" \
    "closing the workspace returns the hooks to the main checkout"
  assert_not_contains "$settings" "$ws/" "and none points to the deleted folder"
  assert_contains "$out" "returned to the main checkout" "and says so"
  assert_contains "$out" "removed 1" "the hook that only existed in the workspace is removed"
}

test_prune_does_not_stop_at_first_failing_branch() {
  sandbox >/dev/null
  local repo="$CRUX_PROJECTS_DIR/podado"
  git init -q "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m init
  for b in uno dos tres; do git -C "$repo" branch "ws/$b"; done

  # Fake gh: all three have a merged proposal, no network.
  local bin="$SB/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "test/repo" ;;
  pr) printf 'ws/uno\nws/dos\nws/tres\n' ;;
esac
STUB
  chmod +x "$bin/gh"

  # With no remote configured, the remote delete fails on all three: with set -e
  # the first one took the whole pass down with it.
  local out; out="$(cd "$repo" && PATH="$bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" prune --yes 2>&1)"

  assert_contains "$out" "3 of 3 branches cleaned" "all three are deleted even if the remote fails"
  assert_eq "" "$(git -C "$repo" branch --list 'ws/*')" "none is left"
}

test_workspace_prune_does_not_guess_without_gh() {
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" \
    "an authenticated gh is needed to know which proposals were merged" \
    "prune stops if it cannot query the proposals"
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" \
    "is used by a worktree: it stays" "and does not delete the branch of a live workspace"
}

# Like prune, this needs gh and a remote: it is asserted on the source, which is
# what the suite can check without a network.
test_status_flags_open_proposal_without_receipt() {
  local src; src="$(cat "$CRUX_HOME/bin/status.sh")"
  assert_contains "$src" "has no gate receipt" \
    "status warns about an open proposal whose branch did not pass the gate"
  assert_contains "$src" "if command -v gh >/dev/null; then" \
    "and does not even try without gh"
  assert_contains "$src" "sealed " "reading the receipt seal, not a loose sha"
}

test_workspace_releases_and_reuses_slot() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new a --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$root/app" >/dev/null 2>&1
  rm -f "$root/app-ws-a/.env.local"
  bash "$CRUX_HOME/bin/workspace.sh" rm a >/dev/null 2>&1

  bash "$CRUX_HOME/bin/workspace.sh" new c --repo "$root/app" >/dev/null 2>&1
  assert_contains "$(cat "$root/app-ws-c/.env.local")" "PORT=4000" \
    "the released slot is reused instead of growing endlessly"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" list)"
  assert_not_contains "$out" "app-ws-a " "the deleted workspace disappears from the registry"
}

test_ship_tells_what_needs_an_environment() {
  sandbox >/dev/null
  local root; root="$(_repo_with_config)"
  cd "$root/app" || return

  mkdir -p src/components db/migrations docs
  touch src/components/Card.tsx
  git add -A
  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "runtime: yes" "a UI change calls for real validation"
  assert_contains "$out" "visual review" "and says what to validate"

  git reset -q; rm -rf src
  touch docs/note.md
  git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "runtime: no" "a documentation change does not ask for it"

  cd "$CRUX_HOME" || return
}

test_workspace_supports_per_repo_config() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/multi"
  mkdir -p "$root/front" "$root/back" "$root/multi-docs"
  for r in front back; do
    git -C "$root/$r" init -q
    git -C "$root/$r" config user.email t@t
    git -C "$root/$r" config user.name t
    echo x > "$root/$r/f.txt"
    git -C "$root/$r" add -A
    git -C "$root/$r" commit -qm init
  done
  cat > "$root/multi-docs/crux.json" <<'JSON'
{"crux":"0.1.0","project":"multi","profile":"multi-repo","repos":["front","back"],"sections":[],
 "workspace":{"portBase":5000,"portsPerSlot":10,"envFile":".env.local",
   "env":{"COMMON":"yes"},
   "repos":{
     "front":{"env":{"PORT":"{{PORT0}}","API":"http://localhost:{{PORT1}}"}},
     "back":{"env":{"PORT":"{{PORT1}}","DB":"db_{{SLOT}}"},
             "setup":"echo 'created  db_{{SLOT}}' > $CRUX_PROJECTS_DIR/setup-ran.txt"}}}}
JSON

  bash "$CRUX_HOME/bin/workspace.sh" new f --repo "$root/front" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$root/back" >/dev/null 2>&1

  local f b
  f="$(cat "$root/front-ws-f/.env.local")"
  b="$(cat "$root/back-ws-b/.env.local")"

  assert_contains "$f" "PORT=5000" "the front receives its port"
  assert_contains "$f" "API=http://localhost:5001" "and knows where the backend of its slot is"
  assert_contains "$b" "PORT=5011" "the backend in another slot does not collide"
  assert_contains "$b" "DB=db_1" "each slot has its own database"
  assert_contains "$f" "COMMON=yes" "common variables are inherited"
  assert_not_contains "$f" "DB=" "those of another repo do not leak in"

  assert_file "$CRUX_PROJECTS_DIR/setup-ran.txt" "the setup hook runs"
  # Its single quotes used to be stripped on the way to the shell.
  assert_contains "$(cat "$CRUX_PROJECTS_DIR/setup-ran.txt")" "created  db_1" "with its quotes intact"
}

test_workspace_env_starts_from_the_main_checkouts() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/envp"
  mkdir -p "$root/app" "$root/envp-docs"
  git -C "$root/app" init -q
  printf 'AUTH_SECRET=\nPORT=\nDB_URL=\nNEW_KEY=\n' > "$root/app/.env.example"
  printf '.env.local\n' > "$root/app/.gitignore"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  # The real one, ignored by git: it never reaches a worktree on its own.
  printf '# local\nAUTH_SECRET=s3cr3t\nPORT=3000\nDB_URL=mysql://main\n' > "$root/app/.env.local"
  cat > "$root/envp-docs/crux.json" <<'JSON'
{"crux":"0.1.0","project":"envp","profile":"multi-repo","repos":["app"],"sections":[],
 "workspace":{"portBase":5000,"portsPerSlot":10,"envFile":".env.local",
   "repos":{"app":{"env":{"PORT":"{{PORT0}}","DB_URL":"mysql://ws{{SLOT}}"}}}}}
JSON
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new e --repo "$root/app" 2>&1)"
  local env; env="$(cat "$root/app-ws-e/.env.local")"
  assert_contains "$env" "AUTH_SECRET=s3cr3t" "the workspace gets the keys of the main checkout"
  assert_contains "$env" "PORT=5000" "the template wins on what is per slot"
  assert_contains "$env" "DB_URL=mysql://ws0" "including the database"
  assert_not_contains "$env" "PORT=3000" "without the main checkout's port left behind"
  assert_contains "$out" "lacks what .env.example asks for: NEW_KEY" "and says what .env.example asks for that nobody has"
}

# The machine doctor looks at the same directories as the rest of the kernel,
# and like the rest it lets them be redirected. Pointing them at the fake home
# says what is being tested; forcing only HOME depended on no override being set.
_machine_in() {
  local home="$1"
  HOME="$home" \
  CRUX_CONFIG="$home/.crux/config" \
  CLAUDE_SKILLS_DIR="$home/.claude/skills" \
  CLAUDE_SETTINGS="$home/.claude/settings.json" \
    bash "$CRUX_HOME/bin/machine.sh"
}

test_machine_runs_the_checks_this_machine_declares() {
  sandbox >/dev/null
  local fakehome="$SB/home"
  mkdir -p "$fakehome/.claude/skills" "$fakehome/.crux"
  echo "CRUX_HOME=\"$CRUX_HOME\"" > "$fakehome/.crux/config"
  # A refresh token that expired said nothing until the integration failed.
  cat > "$fakehome/.crux/machine-checks.json" <<'JSON'
{ "checks": [
  { "name": "still valid", "command": "true" },
  { "name": "expired token", "command": "printf '{\n  \"error\": \"invalid_grant\"\n}\n'; exit 1", "fix": "reauthorize it" },
  { "name": "hangs", "command": "sleep 5" }
] }
JSON
  local out
  out="$(CRUX_MACHINE_CHECK_TIMEOUT=1 _machine_in "$fakehome" 2>&1)"
  assert_contains "$out" "ok    still valid" "a check that passes says so"
  assert_contains "$out" 'expired token: { "error": "invalid_grant" } — reauthorize it' "one that fails says why, on one line, and how to fix it"
  assert_contains "$out" "hangs: no answer in 1 s" "and one that hangs does not hang the doctor"

  echo '{ "checks": [' > "$fakehome/.crux/machine-checks.json"
  out="$(_machine_in "$fakehome" 2>&1)" || true
  assert_contains "$out" "machine-checks.json cannot be read" "a broken file is named, not taken as empty"
}

test_machine_detects_broken_hook() {
  sandbox >/dev/null
  local fakehome="$SB/home"
  mkdir -p "$fakehome/.claude/skills" "$fakehome/.crux"
  echo "CRUX_HOME=\"$CRUX_HOME\"" > "$fakehome/.crux/config"
  ln -s "$CRUX_HOME/skills/end-session" "$fakehome/.claude/skills/end-session"
  cat > "$fakehome/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/path/that/does/not/exist.sh"}]}]}}
JSON

  local out; out="$(_machine_in "$fakehome" 2>&1)"
  assert_contains "$out" "point at files that do not exist" "detects the broken hook"

  assert_exit 1 "a broken hook is an error: it looks watched and is not" \
    _machine_in "$fakehome"
}

test_machine_detects_broken_skill_links() {
  sandbox >/dev/null
  local fakehome="$SB/home2"
  mkdir -p "$fakehome/.claude/skills" "$fakehome/.crux"
  echo "CRUX_HOME=\"$CRUX_HOME\"" > "$fakehome/.crux/config"
  ln -s "$SB/deleted-skill" "$fakehome/.claude/skills/ghost"

  local out; out="$(_machine_in "$fakehome" 2>&1)"
  assert_contains "$out" "broken skill links" "detects the dead link"
}

test_usage_does_not_report_zero_as_data() {
  sandbox >/dev/null
  local empty="$SB/no-transcripts"
  mkdir -p "$empty"

  local out
  out="$(CRUX_TRANSCRIPTS="$empty" node "$CRUX_HOME/bin/usage.mjs" 2>&1)"
  assert_contains "$out" "No data, not no usage" "distinguishes absence of data from absence of use"
}

test_code_health_separates_real_from_noise() {
  sandbox >/dev/null
  local repo="$SB/project"
  mkdir -p "$repo/src" "$repo/src/__tests__"

  # Genuinely duplicated logic in two files
  for n in a b; do
    cat > "$repo/src/$n.ts" <<'TS'
export function calculate(items: Item[], factor: number) {
  const filtered = items.filter((x) => x.active && x.value > 0)
  const total = filtered.reduce((acc, x) => acc + x.value * factor, 0)
  if (total > LIMIT) {
    throw new Error('exceeds the allowed limit for the calculation')
  }
  return Math.round(total * 100) / 100
}
TS
  done

  # Noise that must NOT be counted: a multiline import and a data catalog
  cat > "$repo/src/catalog.ts" <<'TS'
import {
  FirstVeryLongThing,
  SecondVeryLongThing,
  ThirdVeryLongThing,
  FourthVeryLongThing,
} from './types'
TS
  cat > "$repo/src/__tests__/a.test.ts" <<'TS'
export function calculate(items: Item[], factor: number) {
  const filtered = items.filter((x) => x.active && x.value > 0)
  const total = filtered.reduce((acc, x) => acc + x.value * factor, 0)
  if (total > LIMIT) {
    throw new Error('exceeds the allowed limit for the calculation')
  }
  return Math.round(total * 100) / 100
}
TS

  local out; out="$(node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" 2>&1)"
  assert_contains "$out" "src/a.ts" "detects the real duplication"
  assert_contains "$out" "src/b.ts" "and its pair"
  assert_not_contains "$out" "FirstVeryLongThing" "does not count the multiline import"
  assert_not_contains "$out" "__tests__" "tests are left out by default"

  out="$(node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" --tests 2>&1)"
  assert_contains "$out" "__tests__" "with --tests they do come in"
}

test_code_health_compares_against_baseline() {
  sandbox >/dev/null
  local repo="$SB/base"
  mkdir -p "$repo/src"
  printf 'export const x = 1\n' > "$repo/src/a.ts"

  node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" --save >/dev/null 2>&1
  assert_file "$repo/.crux-health.json" "saves the baseline"

  local out; out="$(node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" 2>&1)"
  assert_contains "$out" "Compared with the baseline" "compares against it"
  assert_not_contains "$out" "No baseline" "and no longer says there is none"
}

test_workspace_respects_client_profile() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor" "$root/cli-docs"
  git -C "$root/vendor" init -q
  git -C "$root/vendor" config user.email t@t
  git -C "$root/vendor" config user.name t
  echo x > "$root/vendor/f.txt"; git -C "$root/vendor" add -A; git -C "$root/vendor" commit -qm init
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"

  # A local branch is not documentation, and in a client repo developing is the
  # job: it warns where the documentation goes and lets the work proceed.
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" 2>&1)"
  assert_contains "$out" "documentation of vendor" "warns that the documentation does not go to the client repo"
  assert_file "$root/vendor-ws-x/f.txt" "and still creates the workspace"
  assert_file "$root/vendor-ws-x/CLAUDE.local.md" "the worktree carries its local pointer"
  assert_contains "$(cat "$root/vendor-ws-x/CLAUDE.local.md")" "@../cli-docs/CLAUDE.md" "pointing to the docs repo"
  assert_eq "" "$(git -C "$root/vendor-ws-x" status --porcelain)" "without showing up in git status"

  # The branch is published in their repository: it warns that it carries our
  # naming, and another can be chosen.
  assert_contains "$out" "will be seen in their repository" "warns that the client will see the branch"
  assert_contains "$out" "--branch" "and says how to choose it"

  bash "$CRUX_HOME/bin/workspace.sh" rm x >/dev/null 2>&1
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" --branch fix/a-real-name 2>&1)"
  assert_eq "fix/a-real-name" "$(git -C "$root/vendor-ws-x" rev-parse --abbrev-ref HEAD)" \
    "--branch sets the branch name"
  assert_not_contains "$out" "will be seen in their repository" "and then it does not warn"

  bash "$CRUX_HOME/bin/workspace.sh" rm x >/dev/null 2>&1
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" --force 2>&1)"
  assert_not_contains "$out" "documentation of vendor" "with --force it does not repeat the warning"
  assert_file "$root/vendor-ws-x/f.txt" "and creates the workspace anyway"
}

test_hooks_install_commit_msg_in_client_repo_too() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor" "$root/cli-docs"
  git -C "$root/vendor" init -q
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"
  git -C "$root/cli-docs" init -q

  ( cd "$root/cli-docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1

  # `.git/hooks/` is not versioned and travels in no push: hooking it is not
  # writing to the client's repo. Skipping it left without a safety net exactly
  # the place where the tool's signature cannot show up.
  assert_file "$root/vendor/.git/hooks/commit-msg" "hooks the commit-msg in the client repo"

  local f="$SB/MSG"
  printf 'feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$f"
  bash "$root/vendor/.git/hooks/commit-msg" "$f" >/dev/null 2>&1
  assert_not_contains "$(cat "$f")" "Co-Authored-By" "and the hook strips the signature"

  # The format of a client's history is theirs: ours is not imposed.
  printf 'Update the readme\n' > "$f"
  assert_exit 0 "does not impose our commit format on it" \
    bash "$root/vendor/.git/hooks/commit-msg" "$f"

  # The language comes from the contract, English unless it says otherwise.
  # Leaving it out let dozens of Spanish commits into an English-only client.
  printf 'Añadido lo que hacia falta para que esto pase de una vez\n' > "$f"
  assert_exit 1 "but checks the language the contract asks for" \
    bash "$root/vendor/.git/hooks/commit-msg" "$f"
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[],"commit":{"language":"es"}}\n' \
    > "$root/cli-docs/crux.json"
  ( cd "$root/cli-docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1
  assert_exit 0 "and a client that writes Spanish declares it" \
    bash "$root/vendor/.git/hooks/commit-msg" "$f"
}

test_hooks_run_in_a_repo_with_its_own_hooks_path() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor/.githooks" "$root/cli-docs"
  git -C "$root/vendor" init -q
  git -C "$root/vendor" config core.hooksPath .githooks
  printf '#!/usr/bin/env bash\necho client-hook-ran >> "%s/ran"\n' "$SB" > "$root/vendor/.githooks/commit-msg"
  chmod +x "$root/vendor/.githooks/commit-msg"
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"
  git -C "$root/cli-docs" init -q

  # git ignores .git/hooks when core.hooksPath is set: crux's hooks never ran.
  local out; out="$( cd "$root/cli-docs" && bash "$CRUX_HOME/bin/hooks.sh" install 2>&1 )"
  assert_contains "$out" "has its own hooks (.githooks)" "says the repo has its own hooks"

  local f="$SB/MSG" rc=0
  printf 'Añadido lo que hacia falta para que esto pase de una vez\n' > "$f"
  ( cd "$root/vendor" && git hook run commit-msg -- "$f" ) >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "git now runs crux's commit-msg"

  printf 'Update the readme\n' > "$f"
  rc=0; ( cd "$root/vendor" && git hook run commit-msg -- "$f" ) >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "a good message goes through"
  assert_contains "$(cat "$SB/ran" 2>/dev/null)" "client-hook-ran" "and the repo's own hook still runs after it"

  out="$( cd "$root/cli-docs" && bash "$CRUX_HOME/bin/hooks.sh" remove 2>&1 )"
  assert_eq ".githooks" "$(git -C "$root/vendor" config --get core.hooksPath)" "remove gives the repo its hooks path back"
}

test_hooks_enforce_conventions_in_own_repo() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/own"
  mkdir -p "$root/app" "$root/own-docs"
  git -C "$root/app" init -q
  git -C "$root/own-docs" init -q
  printf '{"crux":"0.1.0","project":"own","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/own-docs/crux.json"

  ( cd "$root/own-docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1
  assert_file "$root/app/.git/hooks/commit-msg" "hooks the commit-msg in the own repo"

  local f="$SB/MSG" hook="$root/app/.git/hooks/commit-msg"
  printf 'feat: add the thing\n' > "$f"
  assert_exit 0 "lets a conforming message through" bash "$hook" "$f"
  printf 'Added the thing\n' > "$f"
  assert_exit 1 "rejects a subject without a conventional prefix" bash "$hook" "$f"
  printf 'feat: Add the thing\n' > "$f"
  assert_exit 1 "rejects a capital letter after the prefix" bash "$hook" "$f"
}

test_ship_gate_reads_checks_from_contract() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/g"
  mkdir -p "$root/app" "$root/g-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t; git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm "feat: init"

  # Without a declaration, the gate says how to declare it instead of inventing anything.
  printf '{"crux":"0.1.0","project":"g","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/g-docs/crux.json"
  local out; out="$(cd "$root/app" && bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)"
  assert_contains "$out" "does not declare what to check" "without a contract, it does not invent the checks"
  assert_contains "$out" "quality" "and says where to declare them"

  # Declared per repo: it runs them and records them with the command as is.
  printf '{"crux":"0.1.0","project":"g","profile":"multi-repo","repos":["app"],"sections":[],
    "quality":{"repos":{"app":{"gate":["true","echo done"]}}}}\n' > "$root/g-docs/crux.json"
  ( cd "$root/app" && bash "$CRUX_HOME/bin/ship.sh" gate >/dev/null 2>&1 )
  assert_contains "$(cat "$root/app/.crux-ship")" "run 0 " "runs and records the result"
  assert_contains "$(cat "$root/app/.crux-ship")" "echo done" "with the declared command, not the wrapper"

  # A failing check does not close the gate.
  printf '{"crux":"0.1.0","project":"g","profile":"multi-repo","repos":["app"],"sections":[],
    "quality":{"repos":{"app":{"gate":["false"]}}}}\n' > "$root/g-docs/crux.json"
  out="$(cd "$root/app" && bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)"
  assert_contains "$out" "failing" "and a failing one leaves it open"
}

test_ship_body_blocks_signature_and_our_scaffolding() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor" "$root/cli-docs"
  git -C "$root/vendor" init -q
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"

  local b="$SB/BODY.md"
  printf 'Adds the thing and says why.\n' > "$b"
  assert_exit 0 "lets a clean body through" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"

  printf 'Adds the thing.\n\nGenerated with Claude Code\n' > "$b"
  assert_exit 1 "stops the tool signature" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"

  # In a client repo, moreover, how we work internally is not shown.
  printf 'Adds the thing.\n\nChecked by passing crux ship and workspace finish.\n' > "$b"
  assert_exit 1 "and our tooling in a client repo" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"

  # Nor a path to our documentation repo, which changes with each project.
  printf 'Adds the thing.\n\nSee cli-docs/repos/vendor/notes.md\n' > "$b"
  assert_exit 1 "nor the name of our docs repo" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"
}

test_finish_does_not_propose_unreviewed_code() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/prop"
  mkdir -p "$root/app" "$root/prop-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"prop","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/prop-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new task --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-task"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task 2>&1)"
  assert_contains "$out" "has not passed the quality gate" "refuses to propose without review"
  # The bash error for reading a file that does not exist used to slip in on top
  # of the message, and it is the output seen by anyone who has not yet passed the gate.
  assert_not_contains "$out" ".crux-ship:" "without the raw shell error on top"

  # A loose sha is what used to be written: it does not say what was run, so it
  # no longer counts as having passed the gate.
  git -C "$ws" rev-parse HEAD > "$ws/.crux-ship"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task 2>&1)"
  assert_contains "$out" "not a single command run" "a loose sha is not valid as a receipt"

  # Neither does a receipt with a failing check.
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- false >/dev/null 2>&1 ) || true
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task 2>&1)"
  assert_contains "$out" "in red" "a failed check does not close the gate"

  # A good receipt, but for an earlier commit: the gate has to be passed again.
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  echo more > "$ws/other.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: more"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task 2>&1)"
  assert_contains "$out" "has not passed the quality gate" "an old receipt does not count"
  assert_contains "$out" "the receipt is for" "and says why it does not count"

  # The shortcut exists to obey a person, and it shows.
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task --skip-gate 2>&1)"
  assert_contains "$out" "WITHOUT passing the quality gate" "with --skip-gate it says so out loud"
}

test_receipt_records_crux_version_that_sealed_it() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/ver"
  mkdir -p "$root/app" "$root/ver-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"ver","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/ver-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new t --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-t" version
  version="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  echo change > "$ws/new.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"

  # Sealing leaves the kernel version in the receipt and warns that the project
  # pins another.
  local out
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal 2>&1)"
  assert_contains "$(cat "$ws/.crux-ship")" "kernel $version" "the receipt records the kernel version"
  assert_contains "$out" "pins crux 0.1.0" "warns if the project pins another version"

  # A receipt sealed with another version is not valid: the rules may differ.
  sed -i "s/^kernel .*/kernel 0.0.1/" "$ws/.crux-ship"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish t 2>&1)"
  assert_contains "$out" "was sealed with crux 0.0.1" "rejects a receipt from another version"

  # Nor is one without a version, from the previous format.
  sed -i "/^kernel /d" "$ws/.crux-ship"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish t 2>&1)"
  assert_contains "$out" "does not say which crux version" "rejects a receipt without a version"
}

test_finish_does_not_propose_branch_clashing_with_main() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/clash"
  mkdir -p "$root/app" "$root/clash-docs"
  git init -q --bare -b main "$SB/remote.git"
  git -C "$root/app" init -q -b main
  git -C "$root/app" config user.email t@t; git -C "$root/app" config user.name t
  echo base > "$root/app/f.txt"; echo other > "$root/app/g.txt"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm "chore: init"
  git -C "$root/app" remote add origin "$SB/remote.git"
  git -C "$root/app" push -q -u origin main
  printf '{"crux":"0.1.0","project":"clash","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/clash-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new t --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-t"
  echo branch > "$ws/f.txt"; git -C "$ws" commit -qam "feat: branch"

  # Meanwhile the main branch changes the same line.
  local other_one="$SB/other"
  git clone -q "$SB/remote.git" "$other_one"
  git -C "$other_one" config user.email t@t; git -C "$other_one" config user.name t
  echo main > "$other_one/f.txt"; git -C "$other_one" commit -qam "fix: main"
  git -C "$other_one" push -q origin main

  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish t 2>&1)"
  assert_contains "$out" "clashes with origin/main" "does not propose a branch that cannot be integrated"
  assert_contains "$out" "f.txt" "and says which file clashes"
  assert_eq "" "$(git -C "$ws" ls-remote --heads origin ws/t)" "nor pushes it"

  # Once rebased, the gate is passed again and the proposal goes out.
  git -C "$ws" fetch -q origin
  git -C "$ws" reset -q --hard origin/main
  echo new > "$ws/h.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: no clash"
  echo more > "$other_one/g.txt"; git -C "$other_one" commit -qam "fix: g"; git -C "$other_one" push -q origin main
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish t 2>&1)"
  assert_contains "$out" "do not clash" "if it is only behind, it warns and carries on"
  assert_contains "$out" "pushed" "and pushes it"
}

_merge_scenario() {
  # A workspace with an open proposal and a fake gh that answers whatever $1
  # says to 'pr view'. Returns the worktree path on stdout.
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/mrg"
  mkdir -p "$root/app" "$root/mrg-docs" "$SB/bin"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"mrg","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/mrg-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new m --repo "$root/app" >/dev/null 2>&1
  echo change > "$root/app-ws-m/new.txt"
  git -C "$root/app-ws-m" add -A; git -C "$root/app-ws-m" commit -qm "feat: something"

  cat > "$SB/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")
    cat <<'JSON'
$1
JSON
    ;;
  "pr merge") echo merged ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$SB/bin/gh"
  echo "$root/app-ws-m"
}

test_merge_refuses_with_failing_checks() {
  sandbox >/dev/null
  _merge_scenario '{"number":7,"title":"t","url":"u","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"FAILURE"}]}' >/dev/null

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" merge m --yes 2>&1)" || rc=$?
  assert_eq "1" "$rc" "exits with failure"
  assert_contains "$out" "checks failing" "says how many fail"
  assert_contains "$out" "not merging" "and that it does not merge"
}

test_merge_refuses_with_conflicts() {
  sandbox >/dev/null
  _merge_scenario '{"number":7,"title":"t","url":"u","mergeable":"CONFLICTING","reviewDecision":"","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}' >/dev/null

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" merge m --yes 2>&1)" || rc=$?
  assert_eq "1" "$rc" "exits with failure"
  assert_contains "$out" "conflicts to resolve" "names the conflict"
}

test_merge_without_yes_reports_and_touches_nothing() {
  sandbox >/dev/null
  local ws; ws="$(_merge_scenario '{"number":7,"title":"t","url":"u","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}')"

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" merge m 2>&1)" || rc=$?
  assert_eq "0" "$rc" "without --yes it is not an error"
  assert_contains "$out" "all green" "summarizes the state"
  assert_contains "$out" "--yes" "and says how to really merge"
  assert_file "$ws/new.txt" "the worktree is still where it was"
}

test_finish_survives_main_branch_not_named_main() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/trunk"
  mkdir -p "$root/app" "$root/trunk-docs"
  git -C "$root/app" init -q -b trunk
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"trunk","profile":"multi-repo","repos":["app"],"branch":"trunk","sections":[]}\n' \
    > "$root/trunk-docs/crux.json"

  # A real remote, but with no origin/HEAD: it is what a manually added remote
  # leaves, and it is where the fallback to origin/main used to crash.
  git init -q --bare "$SB/remote.git"
  git -C "$root/app" remote add origin "$SB/remote.git"
  git -C "$root/app" push -q origin trunk

  bash "$CRUX_HOME/bin/workspace.sh" new t --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-t"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "a step" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local out rc
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish t 2>&1)"; rc=$?
  assert_eq "$rc" "0" "finishes fine even if the main branch is not called main"
  assert_contains "$out" "pushed" "pushes the branch"
  # Without gh there is no proposal, but it has to get this far instead of dying
  # silently after the push.
  assert_contains "$out" "open the proposal" "and reaches the end of the command"
}

test_finish_stops_before_pushing_if_origin_is_not_the_declared_remote() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/moved"
  mkdir -p "$root/app" "$root/moved-docs"
  git -C "$root/app" init -q -b main
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"moved","profile":"multi-repo","repos":["app"],"sections":[],"remote":{"repos":{"app":"git@github.com:new-owner/app.git"}}}\n' \
    > "$root/moved-docs/crux.json"
  git init -q --bare "$SB/remote.git"
  git -C "$root/app" remote add origin "$SB/remote.git"
  git -C "$root/app" push -q origin main

  bash "$CRUX_HOME/bin/workspace.sh" new m --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-m"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "a step" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local out rc
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish m 2>&1)"; rc=$?
  assert_eq "$rc" "1" "it stops instead of opening a proposal against the old owner"
  assert_contains "$out" "crux.json declares git@github.com:new-owner/app.git" "and names the cause"
  assert_contains "$out" "remote set-url origin git@github.com:new-owner/app.git" "with the command that aligns it"
  assert_eq "" "$(git -C "$SB/remote.git" branch --list ws/m)" "the branch is not pushed to the old place"
}

test_finish_warns_if_task_closes_without_steps() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/empty"
  mkdir -p "$root/app" "$root/empty-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"empty","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/empty-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new task --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-task"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  # Without a remote the push fails afterwards, but the warning comes first and shows all the same.
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task 2>&1)"
  assert_contains "$out" "without a single step noted" "says the record is left empty"
  assert_contains "$out" "recovered by nobody" "and says what is lost"
  assert_contains "$out" "warn" "it is a warning and not an error: the proposal carries on"

  # With a step noted it does not bother.
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "what I did" >/dev/null 2>&1 )
  echo more > "$ws/other.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: more"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish task 2>&1)"
  assert_not_contains "$out" "without a single step noted" "with steps noted it stays quiet"
}

test_workspace_warns_if_another_session_is_in_the_repo() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/two"
  mkdir -p "$root/app"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init

  bash "$CRUX_HOME/bin/workspace.sh" new first --repo "$root/app" >/dev/null 2>&1
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new second --repo "$root/app" 2>&1)"
  assert_contains "$out" "there is already open work" "warns about the other live session"
  assert_contains "$out" "first" "and says which"
}

test_workspace_installs_workspace_dependencies() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/dep"
  mkdir -p "$root/app"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  # A recognizable lockfile and a .gitignore that leaves node_modules out: it is
  # the real situation that makes a worktree be born without dependencies.
  printf 'lockfileVersion: 1\n' > "$root/app/pnpm-lock.yaml"
  printf 'node_modules/\n' > "$root/app/.gitignore"
  printf '{"name":"app"}\n' > "$root/app/package.json"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  mkdir -p "$root/app/node_modules"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/app" 2>&1)"
  assert_contains "$out" "dependencies" "detects the manager and tries it"
  assert_no_file "$root/app-ws-x/node_modules/.keep" "the worktree does not inherit node_modules"
}

test_diff_scope_understands_layered_architecture() {
  sandbox >/dev/null
  local repo="$SB/layers"
  mkdir -p "$repo"; cd "$repo" || return
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p src/modules/x/domain src/modules/x/infrastructure
  touch src/modules/x/domain/entity.ts
  git add -A

  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "logic:1" "the domain is logic, not 'other'"
  assert_contains "$out" "runtime: no" "and pure logic does not ask to bring up the environment"

  touch src/modules/x/infrastructure/repo.adapter.ts
  git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "integration:1" "the infrastructure stands out"
  assert_contains "$out" "runtime: yes" "and it does ask to test against the real service"

  cd "$CRUX_HOME" || return
}

test_pre_push_blocks_main_branch() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/protected"
  mkdir -p "$root/app" "$root/protected-docs"
  git init -q --bare "$SB/remote.git"
  git -C "$root/app" init -q -b main
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm "chore: init"
  git -C "$root/app" remote add origin "$SB/remote.git"
  git -C "$root/protected-docs" init -q
  printf '{"crux":"0.1.0","project":"protected","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/protected-docs/crux.json"
  ( cd "$root/protected-docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1

  # The first push creates the branch on an empty remote: no proposal is
  # skipped, and without this the only way out was --no-verify.
  assert_exit 0 "lets the main branch be created on an empty remote" git -C "$root/app" push -q origin main

  echo y >> "$root/app/f.txt"; git -C "$root/app" commit -qam "fix: tweak"
  local out; out="$(git -C "$root/app" push origin main 2>&1)"
  assert_contains "$out" "blocked" "but not updating it without a proposal"

  git -C "$root/app" checkout -q -b ws/x
  assert_exit 0 "a working branch goes through without trouble" git -C "$root/app" push -q origin ws/x
}

test_proposal_title_comes_from_first_commit() {
  sandbox >/dev/null
  local repo="$SB/titles"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  echo base > "$repo/f.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm "init"

  git init -q --bare "$SB/remote.git"
  git -C "$repo" remote add origin "$SB/remote.git"
  git -C "$repo" push -q origin main

  git -C "$repo" checkout -q -b ws/task
  echo one > "$repo/a.txt"; git -C "$repo" add -A
  git -C "$repo" commit -qm "feat: what was set out to do"
  echo two > "$repo/b.txt"; git -C "$repo" add -A
  git -C "$repo" commit -qm "chore: minor finishing touch"

  # The branch already pushed: it is the real state when the title is computed,
  # because the push happens before opening the proposal. With --not --remotes
  # nothing is left here and the title went to the last commit.
  git -C "$repo" push -q origin ws/task

  local first_one
  first_one="$(git -C "$repo" log --format='%s' "origin/main..ws/task" | tail -1)"
  assert_eq "feat: what was set out to do" "$first_one" \
    "the title is what was set out to do, even if the branch is already pushed"
}

test_gate_scales_with_the_diff() {
  sandbox >/dev/null
  local repo="$SB/graded"
  mkdir -p "$repo/docs" "$repo/src/components" "$repo/src/lib"
  cd "$repo" || return
  git init -q; git config user.email t@t; git config user.name t

  touch docs/note.md; git add -A
  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "gates: 2,8,9" "a text-only change does not pay for all nine gates"
  assert_contains "$out" "tests: none" "and has no tests to run"

  git reset -q; rm -f docs/nota.md
  touch src/lib/util.ts; git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "gates: 1,2,3,4,5,6,8,9" "code that is not visible from outside skips gate 7"

  touch src/components/Card.tsx; git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "gates: all" "if it is visible from outside, gate 7 stops being optional"

  cd "$CRUX_HOME" || return
}

test_gate_1_runs_only_what_is_affected() {
  sandbox >/dev/null
  local repo="$SB/filtered"
  mkdir -p "$repo/src"
  cd "$repo" || return
  git init -q; git config user.email t@t; git config user.name t

  # Without a contract: the kernel does not know what runs the tests here, so it
  # gives the filter and says how to declare the command.
  touch src/geohash.ts; git add -A
  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "geohash" "without a contract, it at least says what to filter by"
  assert_contains "$out" "quality.tests" "and how to declare the exact command"

  # Outside the repo: the contract is searched upwards, so it does not sneak
  # into the very diff being classified.
  cat > "$SB/crux.json" <<'JSON'
{ "quality": { "tests": "pnpm test", "testsFiltered": "pnpm test {filter}" } }
JSON
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "tests: pnpm test geohash" "with a contract, the exact command"

  # Text only: there is nothing to filter and the whole suite is not proposed either.
  git reset -q; rm -f src/geohash.ts
  touch README.md; git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_not_contains "$out" "pnpm test" "a text change does not drag in the suite"

  cd "$CRUX_HOME" || return
}

test_hook_reminds_of_cycle_on_main_branch() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/claude/hooks/cycle-guard.sh"
  local fakehome="$SB/home"
  mkdir -p "$fakehome/.crux"
  echo "CRUX_PROJECTS_DIR=\"$CRUX_PROJECTS_DIR\"" > "$fakehome/.crux/config"

  # The fake HOME is passed to each invocation, not exported: exporting it takes
  # the rest of the suite along, and when the sandbox is deleted the next case is
  # left without a $HOME.
  _guard() {
    (cd "$1" && echo "{\"session_id\":\"$2\"}" \
      | env HOME="$fakehome" TMPDIR="$SB" bash "$hook")
  }

  local repo="$CRUX_PROJECTS_DIR/demo/demo-app"
  mkdir -p "$repo" "$CRUX_PROJECTS_DIR/demo/demo-docs"
  echo '{"project":"demo"}' > "$CRUX_PROJECTS_DIR/demo/demo-docs/crux.json"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  echo x > "$repo/f"; git -C "$repo" add -A; git -C "$repo" commit -qm init

  local out; out="$(_guard "$repo" s1)"
  assert_contains "$out" "crux workspace new" "on the main branch of a managed repo, it reminds of the cycle"

  # Repeating it every turn turns it into noise, and noise gets ignored.
  out="$(_guard "$repo" s1)"
  assert_eq "" "$out" "does not repeat it in the same session"
  out="$(_guard "$repo" s2)"
  assert_contains "$out" "crux workspace new" "but it does in a new session"

  git -C "$repo" checkout -q -b ws/thing
  out="$(_guard "$repo" s3)"
  assert_eq "" "$out" "outside the main branch it stays quiet"

  # In the docs repo work happens on the main branch: the warning would be noise.
  local docs="$CRUX_PROJECTS_DIR/demo/demo-docs"
  git -C "$docs" init -q -b main
  git -C "$docs" config user.email t@t; git -C "$docs" config user.name t
  git -C "$docs" add -A; git -C "$docs" commit -qm init
  out="$(_guard "$docs" s5)"
  assert_eq "" "$out" "the docs repo does not get the warning"

  # Any repo crux does not manage is none of its business.
  local foreign="$SB/foreign"
  mkdir -p "$foreign"; git -C "$foreign" init -q -b main
  git -C "$foreign" config user.email t@t; git -C "$foreign" config user.name t
  echo x > "$foreign/f"; git -C "$foreign" add -A; git -C "$foreign" commit -qm init
  out="$(_guard "$foreign" s4)"
  assert_eq "" "$out" "in a repo it does not manage, quiet"

  # A loose repo at the root, with no project or docs repo, also belongs to the
  # system: ADR-014. It used to be left out and was where work directly on the
  # main branch slipped in.
  local standalone="$CRUX_PROJECTS_DIR/loose"
  mkdir -p "$standalone"; git -C "$standalone" init -q -b main
  git -C "$standalone" config user.email t@t; git -C "$standalone" config user.name t
  echo x > "$standalone/f"; git -C "$standalone" add -A; git -C "$standalone" commit -qm init
  out="$(_guard "$standalone" s6)"
  assert_contains "$out" "crux workspace new" "a loose repo under the root gets the warning"

  # And what lives there without being yours is excluded by configuration, not by layout.
  echo "CRUX_UNMANAGED=\"$CRUX_PROJECTS_DIR/loose\"" >> "$fakehome/.crux/config"
  out="$(_guard "$standalone" s7)"
  assert_eq "" "$out" "a repo excluded in the configuration goes quiet again"

  unset -f _guard
}

test_usage_counts_procedure_followed_by_hand() {
  sandbox >/dev/null
  local kernel="$SB/kernel" trans="$SB/trans/proj"
  mkdir -p "$kernel/skills/withscript/scripts" "$kernel/skills/noscript" "$trans"
  touch "$kernel/skills/withscript/scripts/measure.sh"

  # A skill whose script runs but which is never called by name: the report
  # counted it as dead, and it is exactly the one being used the most.
  {
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash skills/withscript/scripts/measure.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash measure.sh --again"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat skills/withscript/scripts/measure.sh"}}]}}\n'
  } > "$trans/s.jsonl"

  # The path is resolved before the assignment in front is applied, so it comes
  # from the real kernel; the fake CRUX_HOME is only the catalog it is going to read.
  local usage="$CRUX_HOME/bin/usage.mjs" out
  out="$(CRUX_HOME="$kernel" CRUX_PROJECTS_DIR="$SB/empty" CRUX_TRANSCRIPTS="$SB/trans" \
    node "$usage" 2>&1)"

  assert_contains "$out" "withscript" "the skill shows as used even though nobody called it by name"

  # One session, not two executions or three mentions: reading the file is not
  # using it, and calling it twice in the same session is still one occasion.
  local row; row="$(printf '%s' "$out" | grep withscript | head -1)"
  assert_contains "$row" "1" "counts occasions, not executions"

  local dead; dead="$(printf '%s' "$out" | sed -n '/Unused in the period/,$p')"
  assert_not_contains "$dead" "withscript" "and it is not counted among the dead"
  assert_contains "$dead" "noscript" "the one that is really not used still shows up"
}

test_usage_does_not_count_writing_skill_as_using_it() {
  sandbox >/dev/null
  local kernel="$SB/kernel" trans="$SB/trans/proj"
  mkdir -p "$kernel/skills/fresh/scripts" "$kernel/skills/veteran/scripts" "$trans"
  touch "$kernel/skills/fresh/scripts/measure.sh"
  touch "$kernel/skills/veteran/scripts/run.sh"

  # The session in which a skill is written names its script over and over. If
  # that is not kept apart, the brand-new tops the ranking of the most used.
  {
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > skills/fresh/scripts/measure.sh <<EOF"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"chmod +x skills/fresh/scripts/measure.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i s/a/b/ skills/fresh/scripts/measure.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash run.sh"}}]}}\n'
  } > "$trans/s.jsonl"

  local usage="$CRUX_HOME/bin/usage.mjs" out
  out="$(CRUX_HOME="$kernel" CRUX_PROJECTS_DIR="$SB/empty" CRUX_TRANSCRIPTS="$SB/trans" \
    node "$usage" 2>&1)"

  assert_contains "$out" "veteran" "the one that was executed does count"
  local used; used="$(printf '%s' "$out" | sed -n '/Used:/,/Unused in the period/p' | grep -c fresh || true)"
  assert_eq "0" "$used" "writing a skill does not make it used"
}

test_ship_warns_about_artifacts_slipping_into_the_root() {
  sandbox >/dev/null
  local repo="$SB/repo"; mkdir -p "$repo/public/img"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  echo x > "$repo/README.md"
  git -C "$repo" add -A && git -C "$repo" commit -qm init

  # A tool writes its capture to the working directory and a `git add -A`
  # takes it into the branch. Neither a test nor the linter sees it.
  touch "$repo/capture.png" "$repo/output.log" "$repo/public/img/logo.png"
  echo "export const a = 1" > "$repo/code.ts"
  git -C "$repo" add -A

  local out; out="$(cd "$repo" && bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh" 2>&1)"

  assert_contains "$out" "capture.png" "names the loose capture"
  assert_contains "$out" "output.log" "names the loose dump"
  assert_not_contains "$out" "public/img/logo.png" "an asset inside the tree is not an artifact"
  assert_not_contains "$out" "code.ts" "code is not an artifact"
}

test_usage_flags_skill_whose_procedure_is_followed_without_calling_it() {
  sandbox >/dev/null
  local kernel="$SB/kernel" trans="$SB/trans/proj"
  mkdir -p "$kernel/skills/mute/scripts" "$kernel/skills/spoken/scripts" "$trans"
  touch "$kernel/skills/mute/scripts/measure.sh" "$kernel/skills/spoken/scripts/run.sh"

  # Its procedure is followed and its name is not invoked: the conclusion is not
  # that it is surplus, it is that its description does not activate. The report
  # counted it as read.
  {
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash measure.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"spoken"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash run.sh"}}]}}\n'
  } > "$trans/s.jsonl"

  local usage="$CRUX_HOME/bin/usage.mjs" out
  out="$(CRUX_HOME="$kernel" CRUX_PROJECTS_DIR="$SB/empty" CRUX_TRANSCRIPTS="$SB/trans" \
    node "$usage" 2>&1)"

  assert_contains "$out" "Followed by hand" "opens the section when there is one"
  local section; section="$(printf '%s' "$out" | sed -n '/Followed by hand/,/problem shows up/p')"
  assert_contains "$section" "mute" "points out the one that was not called by name"
  assert_not_contains "$section" "spoken" "the one that was invoked does not appear there"
}

# --- Edges measured in a bug hunt (v0.36.0) ----------------------------------

test_gate_counts_two_digit_failures() {
  sandbox >/dev/null
  local repo="$CRUX_PROJECTS_DIR/rc"
  mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m init

  # A command that does not exist exits with 127, a timeout with 124 and a
  # process the system kills for memory with 137. Counting only single-digit
  # codes let exactly those three through, which are the ones that show up most.
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- bash -c 'exit 127' ) >/dev/null 2>&1
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- bash -c 'exit 124' ) >/dev/null 2>&1

  local out; out="$(cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" seal 2>&1)"
  assert_contains "$out" "does not close" "127 and 124 are failures: the gate does not close"
  assert_not_contains "$out" "gate closed" "and it is not declared closed"
  assert_not_contains "$(cat "$repo/.crux-ship")" "sealed " "nor is the seal written"
}

test_finish_does_not_publish_with_two_digit_red_receipt() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"
  bash "$CRUX_HOME/bin/workspace.sh" new r --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-r"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"

  # A receipt sealed on the commit, but with a check at 127.
  printf '# receipt\nrepo %s\nrun 127 1 npm test\nsealed %s x\n' \
    "$ws" "$(git -C "$ws" rev-parse HEAD)" > "$ws/.crux-ship"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish r 2>&1)"
  assert_contains "$out" "in red" "a receipt with a 127 does not let the proposal open"
}

test_usage_understands_days_separated_by_space() {
  sandbox >/dev/null
  local t="$SB/transcripts/p"; mkdir -p "$t"
  printf '{"name":"Skill","input":{"skill":"adr"}}\n' > "$t/s.jsonl"

  local out
  out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" --days 7 2>&1)"
  assert_contains "$out" "last 7 days" "the documented form '--days N' is respected"
  out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" --days=7 2>&1)"
  assert_contains "$out" "last 7 days" "and the form with an equals sign still works"
  out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" --days abc 2>&1)"
  assert_contains "$out" "not a number" "a value that is not a number is reported, not ignored"
}

test_usage_counts_what_subagents_did() {
  sandbox >/dev/null
  local t="$SB/transcripts/p"; mkdir -p "$t/session/subagents"
  # The parent session invokes nothing; its subagent does. The work got done.
  printf '{"type":"user"}\n' > "$t/session.jsonl"
  printf '{"name":"Skill","input":{"skill":"review-pr"}}\n' > "$t/session/subagents/a.jsonl"

  local out; out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" 2>&1)"
  assert_contains "$out" "review-pr" "what a subagent invokes counts as use"
  assert_contains "$out" "1 sessions reviewed" "and the subagent does not inflate the session count"
}

test_workspace_rejects_name_escaping_the_tree() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  # With a valid branch git no longer stops the name: it planted the worktree
  # wherever the name pointed, plus a junk 'app-ws-..' directory that rm did not pick up.
  local out
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new '../../outside' --repo "$root/app" --branch fix/ok 2>&1)"
  assert_contains "$out" "invalid workspace name" "a name with .. is rejected"
  assert_no_file "$root/outside" "and nothing is created outside the repo"
  assert_no_file "$root/app-ws-.." "nor the directory that used to be left on the way"
  assert_not_contains "$(cat "$CRUX_REGISTRY" 2>/dev/null || echo '')" "outside" \
    "nor is it registered"

  # Asking for help does not create a workspace called '--help'.
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new --help 2>&1)"
  assert_contains "$out" "crux workspace new" "'new --help' shows the usage"
  assert_not_contains "$(cat "$CRUX_REGISTRY" 2>/dev/null || echo '')" "help" \
    "and does not register a workspace with that name"
}

test_registry_lock_does_not_leave_kernel_dead() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  # A process killed dead (an OOM, a hard Ctrl-C) used to leave the lock in
  # place forever, and no command knew how to remove it.
  mkdir -p "$(dirname "$CRUX_REGISTRY")/.workspaces.lock"
  echo 999999 > "$(dirname "$CRUX_REGISTRY")/.workspaces.lock/pid"
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new after-oom --repo "$root/app" 2>&1)"
  assert_contains "$out" "ready" "a lock held by a process that no longer exists is removed on its own"

  # And two workspaces launched at the same time must both come out: the lock
  # was held during setup, which can take minutes, with a five-second wait. The
  # result is checked, not the lock mechanism.
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.workspace.setup = "sleep 3";
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$root/proj-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new par-one --repo "$root/app" >/dev/null 2>&1 &
  local first_one=$!
  sleep 1
  bash "$CRUX_HOME/bin/workspace.sh" new par-two --repo "$root/app" >/dev/null 2>&1
  local rc_two=$?
  wait "$first_one"; local rc_one=$?

  assert_eq "0 0" "$rc_one $rc_two" "both workspaces in parallel come out fine"
  assert_eq "2" "$(node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const s = Object.entries(r.workspaces).filter(([n]) => n.startsWith("par-")).map(([, w]) => w.slot);
    process.stdout.write(String(new Set(s).size));
  ' "$CRUX_REGISTRY")" "and each with a different slot"
}

test_two_projects_do_not_share_the_same_port() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  # Another project, with its own port base. The slot is unique in the registry,
  # but the range comes from each one's portBase: with different bases, two
  # different slots gave the same range.
  local other_one="$CRUX_PROJECTS_DIR/other"
  mkdir -p "$other_one/api" "$other_one/other-docs"
  git -C "$other_one/api" init -q
  git -C "$other_one/api" config user.email t@t; git -C "$other_one/api" config user.name t
  echo x > "$other_one/api/f.txt"; git -C "$other_one/api" add -A; git -C "$other_one/api" commit -qm init
  printf '{"crux":"0.1.0","project":"other","profile":"multi-repo","repos":["api"],"sections":[],
    "workspace":{"portBase":4005,"portsPerSlot":5,"envFile":".env","env":{"PORT":"{{PORT0}}"}}}\n' \
    > "$other_one/other-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$other_one/api" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new a --repo "$root/app" >/dev/null 2>&1

  local clashes
  clashes="$(node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const e = Object.entries(r.workspaces);
    let n = 0;
    for (let i = 0; i < e.length; i++) for (let j = i + 1; j < e.length; j++) {
      const [, A] = e[i], [, B] = e[j];
      if (A.ports[0] <= B.ports[1] && B.ports[0] <= A.ports[1]) n++;
    }
    process.stdout.write(String(n));
  ' "$CRUX_REGISTRY")"
  assert_eq "0" "$clashes" "no workspace overlaps the range of another"
}

test_interruption_does_not_declare_workspace_ready() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.workspace.setup = "sleep 10";
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$root/proj-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new interrupted --repo "$root/app" > "$SB/output" 2>&1 &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"; local rc=$?

  assert_not_contains "$(cat "$SB/output")" "ready" "a signal does not let the workspace be declared ready"
  assert_eq "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "and exits with an error code"

  # The worktree is already on disk: the entry stays, because deleting it left a
  # worktree the tool no longer recognized and a slot handed out twice.
  if [[ -d "$root/app-ws-interrupted" ]]; then
    assert_contains "$(bash "$CRUX_HOME/bin/workspace.sh" list --all)" "interrupted" \
      "the half-done workspace shows in the list"
    assert_not_contains "$(bash "$CRUX_HOME/bin/workspace.sh" rm interrupted 2>&1)" "does not exist" \
      "and it can be removed"
  fi
}

test_unreadable_contract_does_not_become_default_ports() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"
  printf '{"crux":"0.1.0","project":"proj","workspace":{"portBase":4000' \
    > "$root/proj-docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new broken --repo "$root/app" 2>&1)"
  assert_contains "$out" "unreadable" "a broken contract is reported"
  assert_not_contains "$out" "no workspace configuration" "and it is not passed off as 'no configuration'"
  assert_no_file "$root/app-ws-broken/.env.local" "the workspace does not start with the default ports"
}

test_gc_reconciles_registry_with_disk() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new alive --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new ghost --repo "$root/app" >/dev/null 2>&1
  # The worktree disappears from outside: it is how things are left after a manual delete.
  git -C "$root/app" worktree remove --force "$root/app-ws-ghost" 2>/dev/null || rm -rf "$root/app-ws-ghost"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" gc 2>&1)"
  assert_contains "$out" "ghost" "points out the entry with no worktree"
  assert_not_contains "$out" "alive " "and does not touch the one that has it"
  assert_contains "$(cat "$CRUX_REGISTRY")" "ghost" "without --yes it deletes nothing"

  bash "$CRUX_HOME/bin/workspace.sh" gc --yes >/dev/null 2>&1
  assert_not_contains "$(cat "$CRUX_REGISTRY")" "ghost" "with --yes it removes the entry"
  assert_contains "$(cat "$CRUX_REGISTRY")" "alive" "and keeps the live one"
}

test_gc_sees_worktrees_unknown_to_registry() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"

  # A hand-made worktree, or the one left by a version with the name bug.
  git -C "$root/app" worktree add -b loose "$root/app-ws-loose" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" gc 2>&1)"
  assert_contains "$out" "app-ws-loose" "sees the worktree that is not registered"
  assert_contains "$out" "--include-disk" "and says how to remove it"

  bash "$CRUX_HOME/bin/workspace.sh" gc --yes >/dev/null 2>&1
  assert_file "$root/app-ws-loose/f.txt" "without --include-disk the disk is not touched"

  # With work inside it is not removed even when asked.
  echo pending > "$root/app-ws-loose/uncommitted.txt"
  bash "$CRUX_HOME/bin/workspace.sh" gc --yes --include-disk >/dev/null 2>&1
  assert_file "$root/app-ws-loose/uncommitted.txt" "a worktree with uncommitted changes stays"

  rm -f "$root/app-ws-loose/uncommitted.txt"
  bash "$CRUX_HOME/bin/workspace.sh" gc --yes --include-disk >/dev/null 2>&1
  assert_no_file "$root/app-ws-loose" "clean and with --include-disk, it is removed"
}

test_env_file_does_not_block_workspace_closure() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"
  bash "$CRUX_HOME/bin/workspace.sh" new withenv --repo "$root/app" >/dev/null 2>&1

  assert_file "$root/app-ws-withenv/.env.local" "the command writes the environment file"
  assert_eq "" "$(git -C "$root/app-ws-withenv" status --porcelain)" \
    "and does not count as an uncommitted change: crux wrote it, not you"
  assert_contains "$(bash "$CRUX_HOME/bin/workspace.sh" rm withenv 2>&1)" "slot released" \
    "so it does not block closing the workspace"
}

test_list_says_since_when_a_workspace_is_open() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_with_config)"
  bash "$CRUX_HOME/bin/workspace.sh" new recent --repo "$root/app" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" list --all)"
  assert_contains "$out" "today" "a workspace opened today shows as such"
}

test_profile_decides_branch_name() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local matches="$SB/home"; mkdir -p "$matches/.crux/profiles"
  printf '{"name":"mine","pointers":{"write":true},"branch":{"pattern":"feature/{{name}}"}}\n' \
    > "$matches/.crux/profiles/mine.json"
  local root; root="$(_repo_with_config)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8")); j.profile = "mine";
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$root/proj-docs/crux.json"

  env HOME="$matches" bash "$CRUX_HOME/bin/workspace.sh" new thing --repo "$root/app" >/dev/null 2>&1
  assert_eq "feature/thing" "$(git -C "$root/app-ws-thing" rev-parse --abbrev-ref HEAD)" \
    "the branch follows the profile pattern"
}

test_usage_says_with_what_words_the_problem_appeared() {
  sandbox >/dev/null
  local t="$SB/transcripts/p"; mkdir -p "$t"
  # The procedure is followed by hand and nobody calls the skill: what is missing
  # is knowing with what words it was asked for, which is what its description
  # does not carry.
  {
    printf '{"type":"user","message":{"role":"user","content":"this looks like spaghetti with duplication and I am nervous about touching it"}}\n'
    printf '{"name":"Bash","input":{"command":"node scripts/health.mjs ."}}\n'
  } > "$t/s.jsonl"

  local out; out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" 2>&1)"
  assert_contains "$out" "code-health" "points out the skill that was followed without being called"
  assert_contains "$out" "spaghetti" "and with what words the work was asked for"
  assert_not_contains "$out" "duplication" "without repeating what the description already says"
  assert_not_contains "$out" " about" "without the stop words"
}

test_proposal_title_does_not_execute_commands() {
  # The title comes from gh, that is, from whoever can rename the proposal. It
  # ended up in an eval between double quotes, where bash still expands $(...).
  sandbox >/dev/null
  local witness="$SB/RCE_TITLE"
  local status
  status="{\"number\":7,\"title\":\"fix: thing \$(touch $witness)\",\"url\":\"u\",\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"\",\"statusCheckRollup\":[]}"

  # the same block cmd_merge uses, extracted from the file so as not to depend on gh
  local block
  block="$(sed -n '/^  eval "\$(node -e/,/^  '"'"' "\$status")"/p' "$CRUX_HOME/bin/workspace.sh")"
  [[ -n "$block" ]] && PASS=$((PASS + 1)) || _fail "cannot find the eval block in workspace.sh"

  ( status="$status"; eval "$block" >/dev/null 2>&1 ) || true
  assert_no_file "$witness" "the proposal title executes nothing"
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "Single quotes, as in load_config" \
    "and the reason is stated"
}

test_poisoned_main_branch_does_not_write_pre_push() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/poison"
  mkdir -p "$root/app" "$root/poison-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  # the branch field ends up inside an unquoted heredoc
  cat > "$root/poison-docs/crux.json" <<'JSON'
{"crux":"0.1.0","project":"poison","profile":"multi-repo","repos":["app"],
 "branch":"main\" ]] || { touch /tmp/CRUX_RCE_PREPUSH; }; : \"","sections":[]}
JSON
  rm -f /tmp/CRUX_RCE_PREPUSH

  git -C "$root/poison-docs" init -q
  git -C "$root/poison-docs" config user.email t@t
  git -C "$root/poison-docs" config user.name t
  git -C "$root/poison-docs" add -A; git -C "$root/poison-docs" commit -qm init
  local out
  out="$(cd "$root/poison-docs" && bash "$CRUX_HOME/bin/hooks.sh" install 2>&1)" || true
  assert_no_file "/tmp/CRUX_RCE_PREPUSH" "the generated hook does not execute what the contract brings"
  assert_contains "$out" "invalid characters" "and says the branch is not valid"
  assert_no_file "$root/app/.git/hooks/pre-push" "without installing a poisoned hook"
}

test_poisoned_commit_language_falls_back_to_default() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/lang"
  mkdir -p "$root/app" "$root/lang-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"lang","profile":"client-repo","repos":["app"],"sections":[]}\n' \
    > "$root/lang-docs/crux.json"
  printf '{"commit":{"language":"en}\\"; touch /tmp/CRUX_RCE_COMMITMSG; #"}}\n' \
    > "$root/lang-docs/profile.json"
  rm -f /tmp/CRUX_RCE_COMMITMSG

  bash "$CRUX_HOME/bin/hooks.sh" install "$root/lang-docs" >/dev/null 2>&1 || true
  local hook="$root/app/.git/hooks/commit-msg"
  if [[ -f "$hook" ]]; then
    printf 'feat: thing\n' > "$SB/msg"
    bash "$hook" "$SB/msg" >/dev/null 2>&1 || true
  fi
  assert_no_file "/tmp/CRUX_RCE_COMMITMSG" "the commit-msg does not execute what the profile brings"
}

test_prune_does_not_delete_branch_that_never_had_a_proposal() {
  # `git branch --merged` is true for any branch pointing at an ancestor of the
  # main one: a freshly created one, or develop right after a release. They were
  # deleted here and on the remote saying "already merged".
  sandbox >/dev/null
  local repo="$SB/repo"; mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" branch develop        # long-lived
  git -C "$repo" branch ws/fresh      # freshly created, without a commit of its own
  git -C "$repo" branch ws/finished       # this one did have a proposal

  local bin="$SB/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "test/repo" ;;
  pr) echo "ws/finished" ;;
esac
STUB
  chmod +x "$bin/gh"

  local out; out="$(cd "$repo" && PATH="$bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" prune --yes 2>&1)"
  local remaining; remaining="$(git -C "$repo" branch --list --format='%(refname:short)' | tr '\n' ' ')"

  assert_contains "$remaining" "develop" "develop is left alone"
  assert_contains "$remaining" "ws/fresh" "neither is a branch without a proposal"
  assert_not_contains "$remaining" "ws/finished" "and the one that did have a merged proposal is cleaned"
  assert_contains "$out" "1 of 1" "only counts the one that was really merged"
}

_two_repos() {
  local root="$CRUX_PROJECTS_DIR/tworepos"
  mkdir -p "$root/app" "$root/api" "$root/tworepos-docs"
  local r
  for r in app api; do
    git -C "$root/$r" init -q
    git -C "$root/$r" config user.email t@t
    git -C "$root/$r" config user.name t
    echo x > "$root/$r/f.txt"; git -C "$root/$r" add -A; git -C "$root/$r" commit -qm init
  done
  printf '{"crux":"0.1.0","project":"tworepos","profile":"multi-repo","repos":["app","api"],"sections":[]}\n' \
    > "$root/tworepos-docs/crux.json"
  echo "$root"
}

test_two_workspaces_with_same_name_do_not_clobber_each_other() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_two_repos)"

  bash "$CRUX_HOME/bin/workspace.sh" new fix --repo "$root/app" >/dev/null 2>&1
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new fix --repo "$root/api" 2>&1)" || rc=$?

  assert_eq "1" "$rc" "the second one refuses"
  assert_contains "$out" "there is already a workspace called" "and says why"
  assert_contains "$out" "app-ws-fix" "pointing out which one holds the name"
  assert_contains "$(cat "$CRUX_REGISTRY")" "app-ws-fix" "the first one's entry is still standing"
  assert_no_file "$root/api-ws-fix/f.txt" "and the second one does not leave an orphan worktree"
}

test_workspace_with_ignored_files_is_not_considered_clean() {
  # a plain git status does not see them, but removing the worktree deletes them
  # all the same: the workspace's .env.local and database live there.
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_two_repos)"
  printf 'data/\nprivate-notes.md\n' > "$root/app/.gitignore"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm ignore

  bash "$CRUX_HOME/bin/workspace.sh" new withdata --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-withdata"
  mkdir -p "$ws/data"
  echo "notes" > "$ws/private-notes.md"
  echo "data" > "$ws/data/dump.sql"

  assert_eq "" "$(git -C "$ws" status --porcelain)" "for plain git the workspace is clean"
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm withdata 2>&1)" || rc=$?
  assert_eq "1" "$rc" "but rm refuses"
  assert_file "$ws/private-notes.md" "and what was written by hand is still there"
  assert_file "$ws/data/dump.sql" "and so is the data"
}

test_regenerable_folders_do_not_hold_a_workspace_at_any_depth() {
  # Only the ones at the root were left out: a server/__pycache__/ made rm
  # refuse, as if it were work that would be lost.
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_two_repos)"
  printf '__pycache__/\nnode_modules/\n.astro/\n.pytest_cache/\n*.tsbuildinfo\n' > "$root/app/.gitignore"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm ignore

  bash "$CRUX_HOME/bin/workspace.sh" new regen --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-regen"
  mkdir -p "$ws/server/__pycache__" "$ws/packages/ui/node_modules/x"
  echo x > "$ws/server/__pycache__/main.cpython-312.pyc"
  echo x > "$ws/packages/ui/node_modules/x/index.js"
  mkdir -p "$ws/apps/web/.astro" "$ws/.pytest_cache"
  echo x > "$ws/apps/web/.astro/types.d.ts"; echo x > "$ws/.pytest_cache/README.md"
  echo x > "$ws/tsconfig.tsbuildinfo"; echo x > "$ws/apps/web/tsconfig.app.tsbuildinfo"

  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm regen 2>&1)" || rc=$?
  assert_eq "0" "$rc" "rm goes ahead"
  assert_no_file "$ws/server/__pycache__/main.cpython-312.pyc" "and the worktree is gone"
}

test_nonexistent_base_does_not_fall_back_to_head_silently() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_two_repos)"

  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new overbase --repo "$root/app" --base v9-nonexistent 2>&1)" || rc=$?
  assert_eq "1" "$rc" "it stops"
  assert_contains "$out" "does not exist" "and says the base does not exist"
  assert_no_file "$root/app-ws-overbase/f.txt" "without leaving a workspace on the wrong base"
}

test_proposal_body_goes_through_the_filter() {
  # ship body existed and nobody called it: the body went from the task record
  # straight to gh pr create.
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/filter"
  mkdir -p "$root/app" "$root/filter-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"filter","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/filter-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new withpoison --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-withpoison"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "tested with ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/task.sh" "done" T1 "in /home/otheruser/Projects/otherclient/api" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish withpoison 2>&1)" || rc=$?
  assert_eq "1" "$rc" "does not publish a body that does not pass the filter"
  assert_contains "$out" "does not pass the filter" "and says so"
  assert_contains "$out" "credential" "pointing at the token"
}

test_machine_paths_appear_in_no_section() {
  sandbox >/dev/null
  local f="$SB/t.md"
  cat > "$f" <<'MD'
---
task: t
project: p
status: open
---

## Objective

The part in /home/someone/Projects/client/api

## Steps

- [x] T1 measure · evidence: /home/someone/output.txt

## Verification

- ok · cmd (1s)
MD
  local body; body="$(node "$CRUX_HOME/lib/task.mjs" body --file "$f" --lang es)"
  assert_not_contains "$body" "/home/someone" "neither in the objective nor in the evidence"
  # The tilde here is the text expected in the output, not a path.
  # shellcheck disable=SC2088
  assert_contains "$body" "~/Projects/client/api" "they are replaced with the tilde"
}

_visual_scenario() {
  # A repo with a fake GitHub remote and two approved images. Returns the repo
  # path on stdout.
  local root="$SB/vis" remote="$SB/remote.git"
  git init -q --bare "$remote"
  mkdir -p "$root/app" "$root/captures"
  git -C "$root/app" init -q -b main
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  git -C "$root/app" remote add origin "$remote"
  git -C "$root/app" push -q origin main
  git -C "$root/app" checkout -qb feat/cover
  printf 'png' > "$root/captures/01-cover-desktop.png"
  printf 'webp' > "$root/captures/02-cover-mobile.webp"
  printf 'nothing' > "$root/captures/notes.txt"
  echo "$root/app"
}

test_visual_no_section_without_approval() {
  sandbox >/dev/null
  local app; app="$(_visual_scenario)"
  local out rc=0
  out="$(cd "$app" && bash "$CRUX_HOME/bin/visual.sh" section 2>&1)" || rc=$?
  assert_eq "1" "$rc" "without a receipt there is no section"
  assert_contains "$out" "no visual review approved" "and says what is missing"
}

test_visual_section_counts_approved_images() {
  sandbox >/dev/null
  local app; app="$(_visual_scenario)"
  local out
  out="$(cd "$app" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures --note "Cover reviewed." 2>&1)"
  assert_contains "$out" "with 2 images" "only counts the images, not the text"
  out="$(cd "$app" && bash "$CRUX_HOME/bin/visual.sh" section --lang es 2>&1)"
  assert_contains "$out" "<!-- visual-review:start -->" "opens with its marker"
  assert_contains "$out" "Revisión visual aprobada el" "says when it was approved"
  assert_contains "$out" "Cover reviewed." "carries the note"
  assert_not_contains "$out" "![" "without --publish it links no images"
}

test_visual_publishes_on_separate_branch_without_touching_proposal() {
  sandbox >/dev/null
  local app; app="$(_visual_scenario)"
  # The remote poses as GitHub so that the section knows how to link.
  git -C "$app" remote set-url origin "$SB/remote.git"
  git -C "$app" config "url.$SB/remote.git.insteadOf" "https://github.com/acme/web.git"
  git -C "$app" remote set-url origin "https://github.com/acme/web.git"
  ( cd "$app" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1 )
  local before out
  before="$(git -C "$app" rev-parse HEAD)"
  out="$(cd "$app" && bash "$CRUX_HOME/bin/visual.sh" section --publish --lang en 2>&1)"
  assert_contains "$out" "https://github.com/acme/web/blob/crux-review/feat/cover/01-cover-desktop.png?raw=true" "links the image on the review branch"
  assert_contains "$out" "Before and after" "respects the language"
  assert_eq "$before" "$(git -C "$app" rev-parse HEAD)" "the proposal branch receives no commit"
  assert_eq "" "$(git -C "$app" status --porcelain | grep -v crux-visual)" "and the working tree stays clean"
  local files
  files="$(git --git-dir="$SB/remote.git" ls-tree -r --name-only crux-review)"
  assert_contains "$files" "feat/cover/02-cover-mobile.webp" "the images are on the review branch"
  assert_not_contains "$files" "notes.txt" "without what is not an image"
}

test_visual_does_not_publish_captures_of_another_commit() {
  sandbox >/dev/null
  local app; app="$(_visual_scenario)"
  ( cd "$app" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1 )
  echo more > "$app/g.txt"; git -C "$app" add -A; git -C "$app" commit -qm "feat: more"
  local out rc=0
  out="$(cd "$app" && bash "$CRUX_HOME/bin/visual.sh" section --publish 2>&1)" || rc=$?
  assert_eq "1" "$rc" "it refuses"
  assert_contains "$out" "show them again" "and asks to show them again"
}

test_visual_in_client_repo_pushes_no_images() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/app" "$root/cli-docs" "$root/captures"
  git -C "$root/app" init -q
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["app"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"
  printf 'png' > "$root/captures/01.png"
  ( cd "$root/app" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1 )
  local out
  out="$(cd "$root/app" && bash "$CRUX_HOME/bin/visual.sh" section --publish 2>&1)"
  assert_contains "$out" "Visual review approved" "leaves the review note"
  assert_not_contains "$out" "![" "without images in the client repo"
  assert_not_contains "$out" "crux" "nor the name of our tooling"
}

test_visual_second_publication_keeps_other_proposals_images() {
  sandbox >/dev/null
  local app; app="$(_visual_scenario)"
  git -C "$app" config "url.$SB/remote.git.insteadOf" "https://github.com/acme/web.git"
  git -C "$app" remote set-url origin "https://github.com/acme/web.git"
  ( cd "$app" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1
    bash "$CRUX_HOME/bin/visual.sh" section --publish >/dev/null 2>&1 )
  git -C "$app" checkout -qb feat/sheet
  ( cd "$app" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1
    bash "$CRUX_HOME/bin/visual.sh" section --publish >/dev/null 2>&1 )
  local files
  files="$(git --git-dir="$SB/remote.git" ls-tree -r --name-only crux-review)"
  assert_contains "$files" "feat/cover/01-cover-desktop.png" "the first proposal's is still there"
  assert_contains "$files" "feat/sheet/01-cover-desktop.png" "and the second one's is added"
}

_finish_with_visual() {
  # A workspace with the gate passed, a remote posing as GitHub and a fake gh
  # that saves the proposal body in $SB/body.md.
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/vis" remote="$SB/remote.git"
  mkdir -p "$root/app" "$root/vis-docs" "$root/captures" "$SB/bin"
  git init -q --bare "$remote"
  git -C "$root/app" init -q -b main
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  git -C "$root/app" config "url.$remote.insteadOf" "https://github.com/acme/web.git"
  git -C "$root/app" remote add origin "https://github.com/acme/web.git"
  git -C "$root/app" push -q origin main
  printf '{"crux":"0.1.0","project":"vis","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/vis-docs/crux.json"
  printf 'png' > "$root/captures/01-cover.png"
  cat > "$SB/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr create")
    while [[ \$# -gt 0 ]]; do
      [[ "\$1" == "--body" ]] && printf '%s' "\$2" > "$SB/body.md"
      shift
    done
    echo "https://github.com/acme/web/pull/9" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$SB/bin/gh"
  bash "$CRUX_HOME/bin/workspace.sh" new cover --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-cover"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: cover"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  echo "$ws"
}

test_finish_puts_visual_review_in_the_proposal() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  ( cd "$ws" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1 )
  local out
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover 2>&1)"
  assert_contains "$out" "visual review added" "reports it"
  local body; body="$(cat "$SB/body.md" 2>/dev/null)"
  assert_contains "$body" "blob/crux-review/ws/cover/01-cover.png?raw=true" "the proposal links the capture"
  assert_contains "$body" "visual-review:start" "between its markers"
}

test_finish_does_not_publish_visual_review_of_another_commit() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  ( cd "$ws" && bash "$CRUX_HOME/bin/visual.sh" approve ../captures >/dev/null 2>&1 )
  echo more > "$ws/other.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: more"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  local out
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover 2>&1)"
  assert_contains "$out" "does not go into the proposal" "warns"
  assert_contains "$out" "show them again" "and says what to do"
  assert_contains "$out" "proposal opened" "but does not block the proposal"
  assert_not_contains "$(cat "$SB/body.md" 2>/dev/null)" "crux-review" "without the old captures"
}

test_finish_without_gate_does_not_claim_it_passed() {
  # The default body used to claim "gate passed" even when it was skipped.
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1 )
  env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover --skip-gate >/dev/null 2>&1
  local body; body="$(cat "$SB/body.md" 2>/dev/null)"
  assert_contains "$body" "WITHOUT passing the quality gate" "the proposal says the gate was skipped"
  assert_not_contains "$body" "gate passed" "and does not claim it passed"
}

test_finish_with_gate_says_so_in_the_proposal() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover >/dev/null 2>&1
  local body; body="$(cat "$SB/body.md" 2>/dev/null)"
  assert_contains "$body" "- ok · true" "with a receipt, the proposal shows what was checked"
  assert_not_contains "$body" "WITHOUT passing" "and does not say the gate was skipped"
}

test_old_options_name_their_new_form() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local out
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish x --sin-puerta 2>&1)" || true
  assert_contains "$out" "--skip-gate" "finish --sin-puerta names the new one"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm x --con-ignorados 2>&1)" || true
  assert_contains "$out" "--include-ignored" "rm --con-ignorados names the new one"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" gc --con-disco 2>&1)" || true
  assert_contains "$out" "--include-disk" "gc --con-disco names the new one"
}

test_finish_warns_of_proposal_over_400_lines() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  seq 1 450 > "$ws/big.txt"; seq 1 900 > "$ws/pnpm-lock.yaml"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: big"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  local out; out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover 2>&1)"
  assert_contains "$out" "451 written lines" "counts what was written, without the lockfile"
  assert_contains "$out" "proposal opened" "and warns without blocking"
}

test_finish_does_not_warn_of_size_if_big_part_is_generated() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  seq 1 900 > "$ws/pnpm-lock.yaml"
  git -C "$ws" add -A; git -C "$ws" commit -qm "chore: lock"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  local out; out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover 2>&1)"
  assert_not_contains "$out" "written lines" "a lockfile does not count as review"
}

test_finish_warns_of_big_change_without_plan() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  seq 1 150 > "$ws/big.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: big"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  local out; out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover 2>&1)"
  assert_contains "$out" "the task has no plan" "warns about the big change without a plan"
  assert_contains "$out" "crux task plan" "and says how to save it"
  assert_contains "$out" "proposal opened" "without blocking"
}

test_finish_does_not_warn_about_plan_if_saved() {
  sandbox >/dev/null
  local ws; ws="$(_finish_with_visual)"
  printf 'What changes: the big file.\n' > "$SB/plan.md"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" plan "$SB/plan.md" >/dev/null 2>&1 )
  seq 1 150 > "$ws/big.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: big"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  local out; out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" finish cover 2>&1)"
  assert_not_contains "$out" "has no plan" "with a saved plan it does not warn"
  assert_contains "$out" "proposal opened" "and the proposal opens"
}

# A finish cut off after pushing the branch and before opening the proposal
# left the branch on the remote, and the second attempt died saying there was
# nothing to propose: the branch's own remote copy counted as "already there".
test_finish_can_be_repeated_after_the_branch_was_pushed() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/again"
  mkdir -p "$root/app" "$root/again-docs"
  git -C "$root/app" init -q -b main
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"again","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/again-docs/crux.json"
  git init -q --bare "$SB/again.git"
  git -C "$root/app" remote add origin "$SB/again.git"
  git -C "$root/app" push -q origin main

  bash "$CRUX_HOME/bin/workspace.sh" new r --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-r"
  echo change > "$ws/new.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: something"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "a step" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  git -C "$ws" push -q origin ws/r

  local out
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish r 2>&1)"
  assert_not_contains "$out" "nothing to propose" "the pushed branch still has its commit to propose"
  assert_contains "$out" "open the proposal" "and it gets to the proposal"
}

test_ship_a_command_run_again_replaces_its_red_result() {
  sandbox >/dev/null
  local repo="$SB/repo" out
  mkdir -p "$repo" && git init -q -b main "$repo"
  echo x > "$repo/f" && git -C "$repo" add -A && git -C "$repo" commit -qm "chore: init"
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- test -f ok >/dev/null 2>&1 ) || true
  touch "$repo/ok"
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- test -f ok >/dev/null 2>&1 )

  out="$(cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" seal 2>&1)"
  assert_contains "$out" "gate closed" "the green run replaces the red one of the same command"

  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- test -f missing >/dev/null 2>&1 ) || true
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- test -f ok >/dev/null 2>&1 )
  out="$(cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" seal 2>&1)"
  assert_contains "$out" "does not close" "a different command in red still keeps it shut"
  teardown
}

test_a_copy_identical_to_the_main_repo_does_not_hold_a_workspace() {
  # The env file the workspace was born with, and Expo's cache, made rm refuse
  # as if they were work: neither loses anything when removed.
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_two_repos)"
  printf '.env.local\n.expo/\nnotes.txt\n' > "$root/app/.gitignore"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm ignore
  echo "KEY=1" > "$root/app/.env.local"

  bash "$CRUX_HOME/bin/workspace.sh" new copy --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-copy" rc=0
  cp "$root/app/.env.local" "$ws/.env.local"
  mkdir -p "$ws/.expo" && echo x > "$ws/.expo/devices.json"
  echo "mine" > "$ws/notes.txt"
  bash "$CRUX_HOME/bin/workspace.sh" rm copy >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a file that only exists here still holds it"

  rm "$ws/notes.txt"; rc=0
  bash "$CRUX_HOME/bin/workspace.sh" rm copy >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "the identical copy and the cache do not"
  assert_no_file "$ws/.env.local" "and the worktree is gone"
}
