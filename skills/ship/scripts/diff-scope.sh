#!/usr/bin/env bash
# Classifies the diff and decides which `ship` gates are needed.
#
#   diff-scope.sh [base]     defaults to comparing against HEAD (staged + unstaged)
#
# A gate that costs the same for a typo as for a schema change stops being run
# within two weeks. This splits the cost: what cannot be wrong does not pay for
# the correctness review, and what is not visible from outside does not pay for
# bringing up the environment.

set -uo pipefail

BASE="${1:-HEAD}"
files="$(git diff --name-only "$BASE" 2>/dev/null; git diff --cached --name-only 2>/dev/null)"
files="$(echo "$files" | sort -u | grep -v '^$' || true)"

if [[ -z "$files" ]]; then
  echo "scope: empty"
  echo "runtime: no"
  echo "gates: none — nothing to review"
  exit 0
fi

ui=0; api=0; data=0; tests=0; docs=0; deps=0; logic=0; integration=0; other=0
touched_tests=""; touched_code=""

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *_test.*|*.test.*|*.spec.*|*/tests/*|*/test/*|*/__tests__/*)
      tests=$((tests+1)); touched_tests+="$f"$'\n'; continue ;;
    package.json|*/package.json|*lock.json|*lock.yaml|*.lock|go.mod|Cargo.toml|requirements*.txt|pyproject.toml)
      deps=$((deps+1)); continue ;;
    *.md|*.mdx|*.txt|LICENSE|.gitignore) docs=$((docs+1)); continue ;;
    */migrations/*|*schema.prisma|*.sql) data=$((data+1)); continue ;;
  esac
  touched_code+="$f"$'\n'
  case "$f" in
    *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.html|*/components/*|*/pages/*|*/app/*|*/styles/*|*/public/*)
      ui=$((ui+1)) ;;
    */api/*|*/routes/*|*/controllers/*|*/handlers/*|*.controller.*|*/server/*|*/endpoints/*|*/infrastructure/http/*)
      api=$((api+1)) ;;
    # Layered architecture: the domain and the use cases are pure logic and
    # tests cover them; what talks to the world lives in infrastructure.
    */domain/*|*/application/*|*/use-cases/*|*/entities/*)
      logic=$((logic+1)) ;;
    */infrastructure/*|*.adapter.*|*.repository.*|*/adapters/*|*/repositories/*)
      integration=$((integration+1)) ;;
    *) other=$((other+1)) ;;
  esac
done <<< "$files"

total=$(echo "$files" | wc -l)
echo "files: $total"
parts=""
[[ $ui    -gt 0 ]] && parts="$parts ui:$ui"
[[ $api   -gt 0 ]] && parts="$parts api:$api"
[[ $data  -gt 0 ]] && parts="$parts data:$data"
[[ $tests -gt 0 ]] && parts="$parts tests:$tests"
[[ $docs  -gt 0 ]] && parts="$parts docs:$docs"
[[ $deps  -gt 0 ]] && parts="$parts deps:$deps"
[[ $logic -gt 0 ]] && parts="$parts logic:$logic"
[[ $integration -gt 0 ]] && parts="$parts integration:$integration"
[[ $other -gt 0 ]] && parts="$parts other:$other"
echo "scope:$parts"

# The runtime is needed when the change can be seen from outside, or when
# dependencies or the schema change: what breaks there is not the logic, it is
# the startup.
observable=0
if [[ $ui -gt 0 || $api -gt 0 || $data -gt 0 || $deps -gt 0 || $integration -gt 0 ]]; then
  observable=1
  echo "runtime: yes"
  [[ $ui   -gt 0 ]] && echo "  - touches the interface: visual review"
  [[ $api  -gt 0 ]] && echo "  - touches the API: test the affected endpoints"
  [[ $data -gt 0 ]] && echo "  - touches data: verify the migration applies and reverts"
  [[ $deps -gt 0 ]] && echo "  - dependencies change: check it starts from scratch"
  [[ $integration -gt 0 ]] && echo "  - touches an integration: test against the real service, not only with doubles"
else
  echo "runtime: no"
fi

# --- Which gates apply -------------------------------------------------------
#
# They are computed here instead of left to the judgement of whoever passes
# the gate: by eye everything looks small, and that is how the one that was
# needed gets skipped.

code=$((ui + api + data + logic + integration + other + tests))
if [[ $code -eq 0 ]]; then
  echo "gates: 2,8,9"
  echo "  - text only: no code that can be wrong and no tests that can regress"
elif [[ $observable -eq 1 ]]; then
  echo "gates: all"
  echo "  - the change is visible from outside: gate 7 is not optional here"
else
  echo "gates: 1,2,3,4,5,6,8,9"
  echo "  - nothing observable from outside: gate 7 is skipped"
fi

# --- Which tests to run in gate 1 --------------------------------------------
#
# Gate 1 only asks whether the red was already there, and the affected tests
# are enough for that. The whole suite is gate 5. Running it in both is paying
# for the most expensive one twice to answer two different questions.

filter=""
if [[ -n "$touched_tests" ]]; then
  filter="$(echo "$touched_tests" | grep -v '^$' | head -5 | tr '\n' ' ')"
elif [[ -n "$touched_code" ]]; then
  filter="$(echo "$touched_code" | grep -v '^$' | head -3 \
    | sed 's|.*/||; s|\.[^.]*$||' | sort -u | tr '\n' ' ')"
fi
filter="${filter% }"

# The concrete command is declared by the project: the kernel does not know
# whether pnpm, pytest or go test runs here.
contract=""; d="$PWD"
while [[ "$d" != "/" && -n "$d" ]]; do
  for c in "$d"/crux.json "$d"/*-docs/crux.json; do
    [[ -f "$c" ]] && { contract="$c"; break 2; }
  done
  d="$(dirname "$d")"
done

command=""
if [[ -n "$contract" ]] && command -v node >/dev/null 2>&1; then
  command="$(node -e '
    const fs = require("fs");
    const q = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).quality) || {};
    const f = process.argv[2];
    const c = f && q.testsFiltered ? q.testsFiltered.replace(/\{(filter|filtro)\}/, f) : (q.tests || "");
    process.stdout.write(c);
  ' "$contract" "$filter" 2>/dev/null || true)"
fi

if [[ $code -eq 0 ]]; then
  echo "tests: none — the diff does not touch code"
elif [[ -n "$command" ]]; then
  echo "tests: $command"
elif [[ -n "$filter" ]]; then
  echo "tests: filter by → $filter"
  echo "  - declare 'quality.tests' and 'quality.testsFiltered' in crux.json for the exact command"
else
  echo "tests: the project suite"
fi

if [[ $docs -eq 0 && $((ui + api + data + logic)) -gt 0 ]]; then
  echo "doc: the change touches surface and no documentation is touched — check whether any has drifted"
fi

# What sneaks in with a `git add -A`: screenshots a tool wrote into the
# working directory, dumps, one-off files. No test or linter reports them, and
# they travel to the branch without anyone looking.
suspects="$(echo "$files" | grep -E '^[^/]*\.(png|jpe?g|gif|webp|pdf|zip|tar|gz|mp4|log|tmp|bak|html)$' || true)"
if [[ -n "$suspects" ]]; then
  echo "artifacts: loose files at the root that probably do not belong in the repo —"
  while IFS= read -r f; do
    [[ -n "$f" ]] && echo "  - $f"
  done <<< "$suspects"
fi
