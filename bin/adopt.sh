#!/usr/bin/env bash
# crux adopt — registers an existing docs repo under the standard.
#
# It rewrites nothing that is already there: it detects the project and its
# repos, writes the missing crux.json and lets 'crux doctor' say what is left
# to align. It is the entry point for projects that predate the kernel.
#
#   crux adopt [dir] [--profile <profile>]

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

TARGET="$PWD"
PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(cd "$TARGET" && pwd)"
[[ "$(basename "$DOCS")" == *-docs ]] || die "$DOCS does not look like a docs repo (it must be named <project>-docs)"

PROJECT="$(basename "$DOCS")"
PROJECT="${PROJECT%-docs}"
ROOT="$(dirname "$DOCS")"
CONFIG="$DOCS/crux.json"

[[ -f "$CONFIG" ]] && die "$PROJECT is already adopted — use 'crux doctor' or 'crux upgrade'"

# --- Profile ------------------------------------------------------------------

PROFILE="${PROFILE:-multi-repo}"
profile_exists "$PROFILE" "$TARGET" || die "unknown profile: $PROFILE"

# --- Repos: those that already have a documentation folder ----------------------

repos=()
if [[ -d "$DOCS/repos" ]]; then
  for dir in "$DOCS"/repos/*/; do
    [[ -d "$dir" ]] && repos+=("$(basename "$dir")")
  done
fi

# Siblings on disk that do not have a doc folder yet: they are reported, not
# added automatically (they might not belong to the project).
orphans=()
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  [[ "$name" == "$(basename "$DOCS")" ]] && continue
  found=0
  for r in "${repos[@]:-}"; do [[ "$r" == "$name" ]] && found=1; done
  [[ $found -eq 0 ]] && orphans+=("$name")
done

# --- Active optional sections -------------------------------------------

sections=()
for s in architecture conventions operations topics; do
  [[ -d "$DOCS/$s" ]] && sections+=("$s")
done

# --- Write the contract ----------------------------------------------------

json_array() {
  # With an empty list bash passes an empty argument, and the contract came out
  # with [""]: a nameless repo that everything then tried to walk.
  local out="" item
  for item in "$@"; do [[ -n "$item" ]] && out="$out\"$item\", "; done
  echo "${out%, }"
}

# The remote is deduced from what is already cloned: the docs repo template,
# and an override for each repo whose origin does not fit it. This is what lets
# adopt ask nothing and lets a project with its code in another account —the
# case of a client repo— be declared correctly the first time.
TMPL="$(remote_from_git "$DOCS" 2>/dev/null || echo "")"
overrides=""
for repo in "${repos[@]:-}"; do
  [[ -d "$ROOT/$repo/.git" ]] || continue
  url="$(git -C "$ROOT/$repo" remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || continue
  expected="${TMPL//\{repo\}/$repo}"
  [[ "$url" == "$expected" ]] && continue
  overrides="$overrides
      \"$repo\": \"$url\","
done
overrides="${overrides%,}"

if [[ -n "$TMPL" ]]; then
  REMOTE_JSON="  \"remote\": {
    \"url\": \"$TMPL\"$([[ -n "$overrides" ]] && printf ',\n    "repos": {%s\n    }' "$overrides")
  },"
elif [[ -n "$overrides" ]]; then
  # Without a remote on the docs repo there is no template, but the code repos
  # that do have one are declared anyway: otherwise clone could not fetch any.
  REMOTE_JSON="  \"remote\": {
    \"repos\": {$overrides
    }
  },"
else
  REMOTE_JSON=""
fi

cat > "$CONFIG" <<EOF
{
  "crux": "$(crux_version)",
  "project": "$PROJECT",
  "profile": "$PROFILE",
  "language": "es",
$REMOTE_JSON
  "repos": [$(json_array "${repos[@]:-}")],
  "sections": [$(json_array "${sections[@]:-}")],
  "conventions": {
    "checks": []
  }
}
EOF

ok "written $PROJECT-docs/crux.json"
info "profile $PROFILE · ${#repos[@]} repos · ${#sections[@]} sections"

if [[ ${#orphans[@]} -gt 0 ]]; then
  echo
  warn "siblings on disk without a folder in repos/ (not declared):"
  for o in "${orphans[@]}"; do info "$o — if it belongs to the project: /add-repo-to-docs $o"; done
fi

echo
rc=0
bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" || rc=$?
# adopt writes the contract and touches nothing else, so a project that predates
# the kernel leaves here without the mandatory structure. Whoever adopts it for
# the first time sees a list of errors and no way out.
if [[ $rc -ne 0 ]]; then
  echo
  info "'crux upgrade' restores whatever is missing without overwriting what is there"
fi
