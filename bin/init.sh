#!/usr/bin/env bash
# crux init — creates the docs repo of a new project from the templates.
#
#   crux init <project> [--description "..."] [--repos a,b,c] [--branch <branch>]
#                       [--profile multi-repo] [--visibility private]
#                       [--language es] [--remote <template>] [--no-remote]
#
# The remote is not assumed: it is declared. `--remote` accepts a template with
# {repo} —valid for any provider— and it is written into the contract, which
# is where `crux clone` and `crux doctor` will read it from later.
#
# Deterministic: the result comes from templates/, not from an agent
# reproducing files by hand. Two runs give the same tree.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

PROJECT="${1:-}"
[[ -n "$PROJECT" ]] || die "usage: crux init <project> [options]"
shift

DESCRIPTION="Cross-cutting documentation for $PROJECT."
REPOS=""
BRANCH="main"
PROFILE="multi-repo"
VISIBILITY="private"
LANGUAGE="es"
REMOTE_TMPL=""
REMOTE=1
PARENT="$(projects_root)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    --repos)       REPOS="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --profile)     PROFILE="$2"; shift 2 ;;
    --visibility)  VISIBILITY="$2"; shift 2 ;;
    --language)    LANGUAGE="$2"; shift 2 ;;
    --remote)      REMOTE_TMPL="$2"; shift 2 ;;
    --no-remote)   REMOTE=0; shift ;;
    --parent)      PARENT="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

profile_exists "$PROFILE" || die "unknown profile: $PROFILE"
[[ "$PROJECT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "the name must be lowercase kebab-case: $PROJECT"

ROOT="$PARENT/$PROJECT"
DOCS="$ROOT/$PROJECT-docs"
[[ -e "$DOCS" ]] && die "$DOCS already exists"

# Where the remote comes from, in order: what is passed, the machine's default,
# and if there is none it says so instead of guessing.
if [[ -z "$REMOTE_TMPL" && -f "$HOME/.crux/config" ]]; then
  REMOTE_TMPL="$(grep -E '^CRUX_REMOTE=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"' || true)"
fi

if [[ $REMOTE -eq 1 && -z "$REMOTE_TMPL" ]]; then
  err "I do not know where to push $PROJECT-docs"
  info "say it with --remote 'git@your-remote:org/{repo}.git'"
  info "or set the usual one in ~/.crux/config:  CRUX_REMOTE=\"git@github.com:your-user/{repo}.git\""
  info "or create the project locally only with --no-remote"
  exit 1
fi

URL_DOCS="${REMOTE_TMPL//\{repo\}/$PROJECT-docs}"

# Creating the remote repo does depend on the provider. GitHub is covered
# because there is an official CLI; for the rest the repo is left ready and
# it says what to do, which is two clicks and does not justify an integration
# per provider.
CREATE_REMOTE=0
if [[ $REMOTE -eq 1 ]]; then
  if [[ "$URL_DOCS" == *github.com* ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    CREATE_REMOTE=1
  fi
fi

echo "creating $PROJECT-docs · profile $PROFILE"
[[ $REMOTE -eq 1 ]] && echo "remote: $URL_DOCS"
echo

# --- 1. Repo -----------------------------------------------------------------

mkdir -p "$ROOT"
if [[ $CREATE_REMOTE -eq 1 ]]; then
  # The owner comes from the remote template. Without this, gh always creates
  # under the authenticated account even if the contract declares an
  # organization, and the docs repo is born in the wrong place.
  OWNER_DOCS="$(owner_from_template "$URL_DOCS")"
  SLUG_DOCS="${OWNER_DOCS:+$OWNER_DOCS/}$PROJECT-docs"
  ( cd "$ROOT" && gh repo create "$SLUG_DOCS" \
      "--$VISIBILITY" --description "$DESCRIPTION" --clone >/dev/null )
  ok "repo created on the remote and cloned ($VISIBILITY${OWNER_DOCS:+ · $OWNER_DOCS})"

  # The provider creates the branch per the account's preference. It is
  # normalized to the declared one because the rest of the kernel —hooks,
  # worktrees, review— reads it from the contract: if they diverge, the guard
  # watches a branch nobody uses.
  created_branch="$(git -C "$DOCS" symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [[ -n "$created_branch" && "$created_branch" != "$BRANCH" ]]; then
    git -C "$DOCS" branch -M "$BRANCH"
    ok "branch normalized to $BRANCH (the remote created it as $created_branch)"
  fi
else
  mkdir -p "$DOCS"
  # Without this the repo is born on the machine's default branch, and the hook
  # that protects the main branch is installed looking at another one.
  ( cd "$DOCS" && { git init -q -b "$BRANCH" 2>/dev/null || { git init -q && git symbolic-ref HEAD "refs/heads/$BRANCH"; }; } )
  if [[ $REMOTE -eq 1 ]]; then
    ( cd "$DOCS" && git remote add origin "$URL_DOCS" )
    ok "local repo with origin pointing at $URL_DOCS"
    PENDING_CREATE=1
  else
    ok "local repo created (no remote)"
  fi
fi

# --- 2. Templates -----------------------------------------------------------

VARS=("PROJECT=$PROJECT" "DESCRIPTION=$DESCRIPTION")

while IFS= read -r src; do
  rel="${src#"$CRUX_HOME/templates/docs-repo/"}"
  dst="$DOCS/$rel"
  [[ "$rel" == "gitignore" ]] && dst="$DOCS/.gitignore"
  [[ "$rel" == "gitattributes" ]] && dst="$DOCS/.gitattributes"
  render_template "$src" "$dst" "${VARS[@]}"
done < <(find "$CRUX_HOME/templates/docs-repo" -type f | sort)

ln -sfn AGENTS.md "$DOCS/CLAUDE.md"
mkdir -p "$DOCS/.claude/skills/project"
ok "minimal structure materialized"

# --- 3. Folders of the declared repos ---------------------------------------

repos=()
if [[ -n "$REPOS" ]]; then
  IFS=',' read -ra repos <<< "$REPOS"
fi

clean_items=()
for repo in ${repos[@]+"${repos[@]}"}; do
  repo="$(echo "$repo" | tr -d '[:space:]')"
  [[ -n "$repo" ]] || continue
  valid_name "$repo" || die "invalid repo name: $repo"
  clean_items+=("$repo")
done
repos=(${clean_items[@]+"${clean_items[@]}"})

for repo in ${repos[@]+"${repos[@]}"}; do
  render_template "$CRUX_HOME/templates/repo-doc/README.md" "$DOCS/repos/$repo/README.md" \
    "REPO=$repo" "PROJECT=$PROJECT" "DESCRIPTION=What this repo does, in one line."

  # The index row: the description that ends up in each repo's pointer comes
  # from there, so an empty table leaves the pointers mute.
  node -e '
    const fs = require("fs");
    const [file, repo, project] = process.argv.slice(1);
    const lines = fs.readFileSync(file, "utf8").split("\n");
    const row = `| \`${repo}/\` | \`${project}/${repo}\` | What this repo does, in one line |`;
    const empty = lines.findIndex((l) => /^\|\s*\|\s*\|\s*\|\s*$/.test(l));
    if (empty !== -1) lines[empty] = row;
    else {
      let last = -1;
      for (let i = 0; i < lines.length; i++) if (/^\|/.test(lines[i])) last = i;
      if (last !== -1) lines.splice(last + 1, 0, row);
    }
    fs.writeFileSync(file, lines.join("\n"));
  ' "$DOCS/repos/README.md" "$repo" "$PROJECT"
done
[[ ${#repos[@]} -gt 0 ]] && ok "${#repos[@]} folders in repos/"

# --- 4. The contract ----------------------------------------------------------

json_array() {
  local out="" item
  for item in "$@"; do
    item="$(echo "$item" | tr -d '[:space:]')"
    [[ -n "$item" ]] && out="$out\"$item\", "
  done
  echo "${out%, }"
}

cat > "$DOCS/crux.json" <<EOF
{
  "crux": "$(crux_version)",
  "project": "$PROJECT",
  "profile": "$PROFILE",
  "language": "${LANGUAGE:-es}",
  "branch": "$BRANCH",
  "repos": [$(json_array "${repos[@]:-}")],
  "sections": [],
  "quality": {
    "gate": [],
    "repos": {}
  },
  "conventions": {
    "checks": []
  },
  "remote": {
    "url": "${REMOTE_TMPL:-}",
    "visibility": "$VISIBILITY"
  },
  "workspace": {
    "portBase": 3000,
    "portsPerSlot": 10,
    "envFile": ".env.local",
    "repos": {}
  }
}
EOF
ok "crux.json written"

# --- 5. Initial commit -------------------------------------------------------

(
  cd "$DOCS"
  git add -A
  # On a freshly set up machine there may be no identity configured, and
  # bootstrap should not fall over because of that.
  git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo crux)}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo crux@localhost)}" \
      commit -q -m "init: scaffold the docs repo under the crux standard"
  [[ $REMOTE -eq 1 ]] && git push -q -u origin HEAD 2>/dev/null || true
)
ok "initial commit"

# --- 6. Pointers and skills ----------------------------------------------------

echo
bash "$CRUX_HOME/bin/link.sh" "$DOCS"

echo
echo "done: $DOCS"
echo
if [[ "${PENDING_CREATE:-0}" == "1" ]]; then
  echo
  warn "the remote repo does not exist yet: create it on your provider as **$VISIBILITY**"
  info "crux cannot apply visibility outside GitHub: you choose it when creating it"
  info "cd $DOCS && git push -u origin HEAD"
fi

echo "Next steps:"
echo "  1. Put the code repos in $ROOT/ as siblings of the docs repo."
echo "  2. To register a new one: /add-repo-to-docs <repo>"
echo "  3. To check at any time: crux doctor"
