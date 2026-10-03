#!/usr/bin/env bash
# Decides a proposal's risk and which specialist reviewers it deserves.
#
#   review-scope.sh [base]     defaults to the remote's main branch
#
# One reviewer per specialty costs tens of thousands of tokens each. If all are
# launched on every proposal, by the third week reviewing stops; if none is
# launched, the general review misses what only someone who knows where to look
# sees. This splits it: specialists come from the diff, not from whim.

set -uo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/##')"
  [[ -n "$BASE" ]] || for c in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null && { BASE="$c"; break; }
  done
fi
if [[ -z "$BASE" ]] || ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "error: cannot find the base branch '${BASE:-?}' — pass it as an argument" >&2
  exit 1
fi

files="$(git diff --name-only "$BASE...HEAD")"
if [[ -z "$files" ]]; then
  echo "risk: none — no changes against $BASE"
  echo "specialists: none"
  exit 0
fi

code=0; code_lines=0; not_text=0
security=""; data=""; performance=""; interface=""

reason() {
  # reason <variable> <text>: keeps the first reason, which is the one shown.
  # Uses indirect expansion and not `local -n`, which does not exist in bash 3.
  [[ -z "${!1}" ]] && printf -v "$1" '%s' "$2"
  return 0
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  # Dependencies go before text: `requirements.txt` ends in .txt and slipped
  # through as documentation, and with it a new dependency came out as
  # "mergeable without asking".
  case "$f" in
    package.json|*/package.json|*lock.json|*lock.yaml|*.lock|go.mod|Cargo.toml|requirements*.txt|*/requirements*.txt|pyproject.toml|*/pyproject.toml|Gemfile)
      reason security "dependencies change ($f): where they come from and what they run on install" ;;
    *.md|*.mdx|*.txt|LICENSE|.gitignore) continue ;;
    # A test does not call for a specialist, but it is code the CI runs with
    # its secrets at hand: it does not count as text when deciding who merges.
    *_test.*|*.test.*|*.spec.*|*/tests/*|*/test/*|*/__tests__/*|tests/*|test/*)
      not_text=$((not_text + 1)); continue ;;
  esac

  not_text=$((not_text + 1))
  code=$((code + 1))
  case "$f" in
    *lock.json|*lock.yaml|*.lock) ;;
    *)
      n="$(git diff --numstat "$BASE...HEAD" -- "$f" | awk '{s += $1 + $2} END {print s + 0}')"
      code_lines=$((code_lines + n)) ;;
  esac

  shopt -s nocasematch
  case "$f" in
    *auth*|*login*|*session*|*token*|*jwt*|*password*|*permission*|*role*|*acl*|*crypto*|*secret*|*middleware*|*cors*|*csrf*|*webhook*|*upload*|.env*|*/.env*)
      reason security "touches a sensitive path: $f" ;;
  esac
  shopt -u nocasematch

  case "$f" in
    */migrations/*|*schema.prisma|*.sql|*.entity.*|*/models/*|*/entities/*)
      reason data "touches the schema or the models: $f" ;;
  esac

  case "$f" in
    */api/*|*/routes/*|*/server/*|*/handlers/*|*/workers/*|*/jobs/*|*/cron/*|*/queue*|*.repository.*|*/repositories/*|next.config.*|vite.config.*|webpack.config.*)
      reason performance "touches server or build code: $f" ;;
  esac

  case "$f" in
    *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.html|*/components/*|*/pages/*|*/styles/*)
      reason interface "touches the interface: $f" ;;
  esac
done <<< "$files"

# What the added content says, not just the path: a query built from a string
# or an innerHTML get in just the same in a file called utils.ts.
# Without tests: a test that checks a DROP TABLE is detected contains a DROP
# TABLE, and that does not make the change touch data.
content_paths=()
while IFS= read -r f; do
  [[ -n "$f" ]] && content_paths+=("$f")
done < <(echo "$files" | grep -vE '\.(md|mdx|txt)$|_test\.|\.test\.|\.spec\.|(^|/)(tests?|__tests__)/' || true)
added_one=""
if [[ ${#content_paths[@]} -gt 0 ]]; then
  added_one="$(git diff "$BASE...HEAD" -- "${content_paths[@]}" 2>/dev/null | grep '^+' | grep -v '^+++' || true)"
fi

if echo "$added_one" | grep -qE 'eval\(|new Function\(|dangerouslySetInnerHTML|innerHTML *=|child_process|execSync|shell *= *True|Set-Cookie|Authorization'; then
  reason security "the diff adds a sensitive construct (execution, raw HTML, session headers)"
fi
if echo "$added_one" | grep -qiE 'alter table|drop table|drop column|create table|deleteMany|truncate'; then
  reason data "the diff adds operations that change or delete data"
fi
# Without readFileSync: in scripts and terminal tools reading a file
# synchronously is normal, and it asked for a specialist on every tooling
# change. Server code is already recognised by its path.
if echo "$added_one" | grep -qE 'findMany\(|SELECT .* FROM|\.map\(async|Promise\.all\(|setInterval\('; then
  reason performance "the diff adds queries or async loops"
fi

# Lockfiles are regenerated whole: counting them would turn any dependency
# update into a "big change".
total_lines="$(git diff --numstat "$BASE...HEAD" | grep -vE '(lock\.json|lock\.yaml|\.lock)$' \
  | awk '{s += $1 + $2} END {print s + 0}')"

# --- The contract: profile and rigor ---------------------------------------
#
# The project declares the rigor: how much ceremony it deserves. A repo
# without crux.json is not registered, and what is not registered is not
# treated as critical: it goes in `light`. Within each level, the diff decides.

profile=""; rigor=""; rigor_origin=""; d="$PWD"
while [[ "$d" != "/" && -n "$d" ]]; do
  for c in "$d"/crux.json "$d"/*-docs/crux.json; do
    [[ -f "$c" ]] || continue
    read_value="$(node -e '
      try {
        const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write((j.profile || "") + "\t" + (j.rigor || ""));
      } catch (e) { process.stdout.write("unreadable\t"); }
    ' "$c")"
    profile="${read_value%%$'\t'*}"; rigor="${read_value#*$'\t'}"
    rigor_origin="declared in $c"
    [[ -z "$rigor" ]] && rigor_origin="default: the project does not declare it" && rigor="normal"
    break 2
  done
  d="$(dirname "$d")"
done
root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$rigor_origin" && -n "$root" && -f "$root/STANDARD.md" && -f "$root/bin/crux" ]]; then
  # The kernel has no crux.json because it is not a project, but every
  # project consumes it: it cannot be treated as something not registered.
  rigor="normal"; rigor_origin="the kernel itself, which every project consumes"
elif [[ -z "$rigor_origin" ]]; then
  rigor="light"; rigor_origin="no crux.json: project not registered"
elif [[ "$profile" == "unreadable" ]]; then
  rigor="normal"; rigor_origin="crux.json cannot be read"
fi
case "$rigor" in
  light|normal|strict) ;;
  *) echo "error: unknown rigor '$rigor' ($rigor_origin) — valid values are light, normal or strict" >&2; exit 1 ;;
esac

# --- Risk -------------------------------------------------------------------
#
# High if what can go wrong does not show in a screenshot: security and data
# break silently. Low if there is no code, or the change is so small the
# general review covers it entirely; there a specialist sees nothing it does
# not, and only adds cost.

risk="medium"
if [[ $code -eq 0 ]]; then
  risk="low"
elif [[ -n "$security" || -n "$data" || $total_lines -gt 500 ]]; then
  risk="high"
# In strict there is no size shortcut: thirty lines of a banking client may
# be exactly the ones that matter.
elif [[ $code_lines -le 30 && "$rigor" != "strict" ]]; then
  risk="low"
fi

echo "base: $BASE"
echo "change: $(echo "$files" | wc -l | tr -d ' ') files, $total_lines lines ($code_lines of code)"
echo "risk: $risk"
echo "rigor: $rigor — $rigor_origin"

# In light, specialists are reserved for what breaks silently.
list=()
if [[ "$risk" == "high" || ( "$risk" == "medium" && "$rigor" != "light" ) ]]; then
  [[ -n "$security" ]]   && list+=("security|$security")
  [[ -n "$data" ]]       && list+=("data|$data")
  [[ -n "$performance" ]] && list+=("performance|$performance")
  [[ -n "$interface" ]]    && list+=("interface|$interface")
fi

# Three at most: beyond that they overlap and the cost grows without findings.
if [[ ${#list[@]} -eq 0 ]]; then
  if [[ "$risk" == "medium" && "$rigor" == "light" ]]; then
    echo "specialists: none — rigor light, the general review is enough"
  else
    echo "specialists: none — the general review is enough"
  fi
else
  names="$(printf '%s\n' "${list[@]:0:3}" | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')"
  echo "specialists: $names"
  for e in "${list[@]:0:3}"; do
    echo "  - ${e%%|*}: ${e#*|}"
  done
  [[ ${#list[@]} -gt 3 ]] && echo "  - (left out: $(printf '%s\n' "${list[@]:3}" | cut -d'|' -f1 | paste -sd, -), covered by the general review)"
fi

# --- Who merges -------------------------------------------------------------
#
# In a client repo a person always decides, whatever the rigor: the cost of
# being wrong is not paid by whoever merges. Outside that, the rigor moves the
# threshold: in strict it never merges by itself, in normal only text, and in
# light everything that is not high risk.

if [[ "$profile" == "unreadable" ]]; then
  echo "merge: a person decides — the project's crux.json cannot be read"
elif [[ "$profile" == "client-repo" || "$rigor" == "strict" ]]; then
  echo "merge: a person decides"
elif [[ $not_text -eq 0 ]]; then
  echo "merge: can be merged without asking — text only"
elif [[ "$rigor" == "light" && "$risk" != "high" ]]; then
  echo "merge: can be merged without asking — rigor light and risk $risk"
else
  echo "merge: a person decides"
fi
