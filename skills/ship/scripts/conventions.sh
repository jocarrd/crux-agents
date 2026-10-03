#!/usr/bin/env bash
# Checks the diff against the project's written conventions.
#
#   conventions.sh [base]    defaults to comparing against HEAD (staged + unstaged)
#
# The gate exists because having the conventions written down is not enough:
# they are read after writing the code, when they only serve to reorder. This
# does not judge whether the diff "follows the style" (such a judgement always
# says yes); it points at concrete lines and leaves the verdict to whoever
# looks at them.
#
# Universal signals live here. Each project's are declared in its crux.json,
# because the kernel does not know, and should not know, how each one writes.

set -uo pipefail

BASE="${1:-HEAD}"

find_docs_repo() {
  local dir
  for dir in . .. ../*/ ; do
    [[ -f "$dir/crux.json" ]] && { (cd "$dir" && pwd); return; }
  done
}

DOCS="$(find_docs_repo)"

files="$(
  git diff --name-only --diff-filter=d "$BASE" 2>/dev/null
  git diff --cached --name-only --diff-filter=d 2>/dev/null
)"
files="$(echo "$files" | sort -u | grep -v '^$' || true)"
code="$(echo "$files" | grep -E '\.(ts|tsx|js|jsx|mjs|rs|go|py|rb|java|kt|swift|php)$' \
  | grep -vE '\.(test|spec)\.' || true)"

if [[ -z "$code" ]]; then
  echo "conventions: not applicable — the diff does not touch code"
  exit 0
fi

echo "== Required reading =="
if [[ -n "$DOCS" && -d "$DOCS/conventions" ]]; then
  for f in "$DOCS"/conventions/*.md; do
    [[ -e "$f" ]] || continue
    echo "  $f"
  done
  for repo_doc in $(echo "$code" | sed 's|/.*||' | sort -u); do
    [[ -f "$DOCS/repos/$repo_doc/conventions.md" ]] && echo "  $DOCS/repos/$repo_doc/conventions.md"
  done
else
  echo "  (cannot find the documentation repo — look for conventions/ by hand)"
fi

added() { git diff --unified=0 "$BASE" -- "$@" 2>/dev/null; git diff --cached --unified=0 -- "$@" 2>/dev/null; }

echo
echo "== Signals =="
findings=0

# --- Universal ---------------------------------------------------------------

duplicates="$(added $code | grep '^+' | grep -v '^+++' \
  | grep -oE "'[A-Za-z][A-Za-z0-9 _-]{2,40}'|\"[A-Za-z][A-Za-z0-9 _-]{2,40}\"" \
  | grep -vE "use (client|server)" | sort | uniq -c | sort -rn \
  | awk '$1 >= 3 {print "  " $1 "x  " substr($0, index($0,$2))}' | head -8)"
if [[ -n "$duplicates" ]]; then
  echo "repeated literals — a dictionary?"
  echo "$duplicates"
  findings=$((findings+1))
fi

# The expensive failure: the two copies diverge and it goes unnoticed until a
# screen shows a value the other does not know.
new_items="$(added $code | grep '^+' \
  | grep -oE '^\+ *(export )?(const|static|pub const) [A-Z][A-Z0-9_]{2,} *[:=]' \
  | grep -oE '[A-Z][A-Z0-9_]{2,}' | sort -u)"
for n in $new_items; do
  others="$(git grep -lE "(export |pub |static )?const $n\b" 2>/dev/null \
    | grep -vFx -f <(echo "$code") | head -3)"
  if [[ -n "$others" ]]; then
    echo "$n already exists in the repo — reuse instead of redeclaring?"
    echo "$others" | sed 's/^/  /'
    findings=$((findings+1))
  fi
done

comments="$(added $code | grep -cE '^\+\s*(//|#)[^!]' || true)"
if [[ "$comments" -gt 0 ]]; then
  echo "new comments: $comments — do they explain a why that cannot be read off the code?"
  findings=$((findings+1))
fi

# --- Declared by the project -------------------------------------------------
# {name, files, forbid}: in the files matching the glob, no added line may
# match the pattern.

if [[ -n "$DOCS" && -f "$DOCS/crux.json" ]] && command -v node >/dev/null 2>&1; then
  checks="$(node -e '
    const fs = require("fs")
    let c
    try { c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) }
    catch (e) { console.error("crux.json unreadable: " + e.message); process.exit(2) }
    for (const chk of c.conventions?.checks ?? []) {
      if (!chk.files || !chk.forbid) continue
      console.log([chk.name ?? chk.files, chk.files, chk.forbid].join("\t"))
    }
  ' "$DOCS/crux.json")" || {
    echo "cannot read the conventions declared in $DOCS/crux.json — fix it before going on"
    exit 1
  }

  # Read once: inside the loop it would be a pipe into `grep -q`, which closes
  # the output and kills `git` with SIGPIPE; under `pipefail` that is a
  # failure, and the large repo silently skipped every rule.
  tracked="$(git ls-files)"

  while IFS=$'\t' read -r name glob forbid; do
    [[ -z "$glob" ]] && continue
    # With not a single such file, the rule is declared but the repo does not use it.
    grep -qE "${glob//\*/.*}$" <<< "$tracked" || continue
    culprits=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      # The contract's glob has to expand: quoting it would make it a literal
      # comparison and no rule would ever match.
      # shellcheck disable=SC2053
      [[ "$f" == $glob ]] || continue
      lines="$(added "$f" | grep '^+' || true)"
      grep -qE "$forbid" <<< "$lines" && culprits+="  $f"$'\n'
    done <<< "$code"
    if [[ -n "$culprits" ]]; then
      echo "$name"
      printf '%s' "$culprits"
      findings=$((findings+1))
    fi
  done <<< "$checks"
fi

echo
[[ "$findings" -eq 0 ]] && echo "no signals — whoever reads the conventions still closes the gate"
exit 0
