#!/usr/bin/env bash

# Each case builds a repo with the real flaw the gate must catch. If the
# heuristic stops firing, the test goes red before anyone discovers in a
# review that the gate was not pointing at anything.

conventions_repo() {
  # conventions_repo — leaves a git repo with a committed base and prints its path
  local dir="$SB/repo"
  mkdir -p "$dir/lib" "$dir/conventions"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    echo '# code style' > conventions/code-style.md
    cat > crux.json <<'JSON'
{
  "crux": "0.19.0",
  "conventions": {
    "checks": [
      { "name": "types declared inside a .consts — they go in the .types",
        "files": "*.consts.ts",
        "forbid": "^\\+\\s*(export )?(interface|type) [A-Z]" },
      { "name": "constants declared inside a .types — they go in the .consts",
        "files": "*.types.ts",
        "forbid": "^\\+\\s*export const [A-Z_]+ *=" }
    ]
  }
}
JSON
    printf "export const NETWORK = { AEMET: 'AEMET' } as const\n" > lib/existing.consts.ts
    printf "export type Foo = 'a'\n" > lib/existing.types.ts
    git add -A
    git commit -qm base
  )
  echo "$dir"
}

conventions_run() {
  # conventions_run <repo> — runs the gate on what is uncommitted
  (cd "$1" && git add -A && bash "$CRUX_HOME/skills/ship/scripts/conventions.sh" 2>&1)
}

test_conventions_lists_applicable_documents() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export const A = 1\n" > "$repo/lib/nuevo.ts"

  assert_contains "$(conventions_run "$repo")" "conventions/code-style.md" \
    "lists the project conventions document"
}

test_conventions_not_applicable_without_code() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  echo "texto" > "$repo/README.md"

  assert_contains "$(conventions_run "$repo")" "not applicable" \
    "a text-only diff does not pay this gate"
}

test_conventions_catches_repeated_literal() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  cat > "$repo/lib/age.ts" <<'EOF'
export type Age = 'fresh' | 'old'
export function classify(h: number): Age {
  return h > 6 ? 'old' : 'fresh'
}
export function label(e: Age): string {
  if (e === 'fresh') return 'recent'
  if (e === 'old') return 'ancient'
  return 'fresh'
}
EOF

  assert_contains "$(conventions_run "$repo")" "repeated literals" \
    "a literal that repeats calls for a dictionary"
}

test_conventions_catches_type_inside_consts() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  cat > "$repo/lib/marker.consts.ts" <<'EOF'
interface Appearance { opacity: number }
export const APPEARANCE: Record<string, Appearance> = {}
EOF

  assert_contains "$(conventions_run "$repo")" "types declared inside a .consts" \
    "a type in the constants file is out of place"
}

test_conventions_catches_constant_inside_types() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export type Bar = 'b'\nexport const MAX_ITEMS = 10\n" > "$repo/lib/bar.types.ts"

  assert_contains "$(conventions_run "$repo")" "constants declared inside a .types" \
    "a constant in the types file is out of place"
}

test_conventions_catches_redeclared_catalog() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export const NETWORK = { SIAR: 'SIAR' } as const\n" > "$repo/lib/networks.consts.ts"

  assert_contains "$(conventions_run "$repo")" "NETWORK already exists" \
    "redeclaring an existing catalog is the costly flaw: the copies diverge"
}

test_conventions_stays_quiet_when_nothing_to_say() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export function add(a: number, b: number): number {\n  return a + b\n}\n" \
    > "$repo/lib/add.ts"

  local out; out="$(conventions_run "$repo")"
  assert_contains "$out" "no signals" "a clean diff does not invent findings"
  assert_not_contains "$out" "repeated literals" "no false positives"
}

test_conventions_does_not_require_what_project_does_not_declare() {
  sandbox >/dev/null
  local dir="$SB/simple"
  mkdir -p "$dir/lib"
  (
    cd "$dir" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    echo '{"crux":"0.19.0"}' > crux.json
    printf "export const A = 1\n" > lib/a.ts
    git add -A && git commit -qm base
  )
  printf "interface B { x: number }\n" > "$dir/lib/b.consts.ts"

  local out; out="$(conventions_run "$dir")"
  assert_not_contains "$out" "they go in the .types" \
    "a project that does not declare the rule does not pay for it"
}

test_conventions_stops_if_contract_unreadable() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  echo '{ roto' > "$repo/crux.json"
  printf "export const A = 1\n" > "$repo/lib/nuevo.ts"

  local out; out="$(conventions_run "$repo")"
  assert_contains "$out" "cannot read the conventions declared" \
    "an unreadable contract is named and stops, it does not turn into zero rules"
}

test_conventions_applies_rules_in_large_repo_too() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  (
    cd "$repo" || exit 1
    mkdir -p filler
    for i in $(seq 1 3000); do : > "filler/f$i.ts"; done
    git add -A && git commit -qm filler
  )
  printf "interface Appearance { opacity: number }\n" > "$repo/lib/large.consts.ts"

  assert_contains "$(conventions_run "$repo")" "types declared inside a .consts" \
    "the file list must not close git's pipe and skip the rules"
}

test_profile_decides_commit_language() {
  sandbox >/dev/null
  local matches="$SB/home"; mkdir -p "$matches/.crux/profiles"
  printf '{"name":"spanish","pointers":{"write":true},"commit":{"language":"es"}}\n' \
    > "$matches/.crux/profiles/spanish.json"

  local root="$CRUX_PROJECTS_DIR/ci"; mkdir -p "$root/app" "$root/ci-docs"
  git -C "$root/app" init -q; git -C "$root/ci-docs" init -q
  printf '{"crux":"0.1.0","project":"ci","profile":"spanish","repos":["app"],"sections":[]}\n' \
    > "$root/ci-docs/crux.json"
  ( cd "$root/ci-docs" && env HOME="$matches" bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )

  local f="$SB/msg"
  printf 'feat: añade el aviso cuando la caché no responde\n\nEsto hace que el usuario vea el error real y no una pantalla en blanco.\n' > "$f"
  assert_exit 0 "a profile that declares Spanish does not reject a Spanish commit" \
    bash "$root/app/.git/hooks/commit-msg" "$f"

  # And one that does not declare it still demands English.
  local other_one="$CRUX_PROJECTS_DIR/en"; mkdir -p "$other_one/app" "$other_one/en-docs"
  git -C "$other_one/app" init -q; git -C "$other_one/en-docs" init -q
  printf '{"crux":"0.1.0","project":"en","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$other_one/en-docs/crux.json"
  ( cd "$other_one/en-docs" && env HOME="$matches" bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )
  assert_exit 1 "and without declaring it English is still required" \
    bash "$other_one/app/.git/hooks/commit-msg" "$f"

  # The project can also declare it in its contract, without a profile of its own.
  local own="$CRUX_PROJECTS_DIR/es"; mkdir -p "$own/app" "$own/es-docs"
  git -C "$own/app" init -q; git -C "$own/es-docs" init -q
  printf '{"crux":"0.1.0","project":"es","profile":"multi-repo","repos":["app"],"sections":[],"commit":{"language":"es"}}\n' \
    > "$own/es-docs/crux.json"
  ( cd "$own/es-docs" && env HOME="$matches" bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )
  assert_exit 0 "a contract that declares Spanish lets a Spanish commit through" \
    bash "$own/app/.git/hooks/commit-msg" "$f"
}

test_profile_declares_what_cannot_leave_in_a_proposal() {
  sandbox >/dev/null
  local matches="$SB/home"; mkdir -p "$matches/.crux/profiles"
  printf '{"name":"nda","pointers":{"write":true},"propose":{"forbid":[{"pattern":"client-name","reason":"the client name does not leave here"}]}}\n' \
    > "$matches/.crux/profiles/nda.json"

  local root="$CRUX_PROJECTS_DIR/pr"; mkdir -p "$root/app" "$root/pr-docs"
  git -C "$root/app" init -q; git -C "$root/app" commit -q --allow-empty -m init
  printf '{"crux":"0.1.0","project":"pr","profile":"nda","repos":["app"],"sections":[]}\n' \
    > "$root/pr-docs/crux.json"

  local b="$SB/body"
  printf 'Fix the calculation for client-name.\n' > "$b"
  local out; out="$(cd "$root/app" && env HOME="$matches" bash "$CRUX_HOME/bin/ship.sh" body "$b" 2>&1)"
  assert_contains "$out" "does not leave here" "the profile pattern is checked, with its reason"

  printf 'Fix the drift calculation.\n' > "$b"
  assert_exit 0 "and a clean body passes" \
    env HOME="$matches" bash -c "cd '$root/app' && bash '$CRUX_HOME/bin/ship.sh' body '$b'"
}

test_profile_forbid_still_reads_legacy_spanish_keys() {
  sandbox >/dev/null
  local matches="$SB/home"; mkdir -p "$matches/.crux/profiles"
  printf '{"name":"nda","pointers":{"write":true},"propose":{"forbid":[{"patron":"client-name","motivo":"the client name does not leave here"}]}}\n' \
    > "$matches/.crux/profiles/nda.json"

  local root="$CRUX_PROJECTS_DIR/pr"; mkdir -p "$root/app" "$root/pr-docs"
  git -C "$root/app" init -q; git -C "$root/app" commit -q --allow-empty -m init
  printf '{"crux":"0.1.0","project":"pr","profile":"nda","repos":["app"],"sections":[]}\n' \
    > "$root/pr-docs/crux.json"

  local b="$SB/body"
  printf 'Fix the calculation for client-name.\n' > "$b"
  local out; out="$(cd "$root/app" && env HOME="$matches" bash "$CRUX_HOME/bin/ship.sh" body "$b" 2>&1)"
  assert_contains "$out" "does not leave here" "profiles written with patron/motivo are still read"
}
