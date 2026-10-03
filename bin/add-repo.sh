#!/usr/bin/env bash
# crux add-repo — registers a new repo in an already adopted project.
#
#   crux add-repo <repo> [--description "..."] [dir]
#
# Creates its documentation folder, declares it in crux.json, registers it in
# the table of repos/README.md and regenerates the pointers.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="${1:-}"
[[ -n "$REPO" ]] || die "usage: crux add-repo <repo> [--description \"...\"]"
valid_name "$REPO" || die "the name must be lowercase kebab-case, without slashes: $REPO"
shift

DESCRIPTION="What this repo does, in one line."
TARGET="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(find_docs_repo "$TARGET")" || die "cannot find a docs repo from $TARGET"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "crux.json is missing — run 'crux adopt' first"

PROJECT="$(json_get "$CONFIG" project)"
ROOT="$(dirname "$DOCS")"

json_get "$CONFIG" repos 2>/dev/null | grep -qxF "$REPO" && die "$REPO is already declared in crux.json"
[[ -d "$DOCS/repos/$REPO" ]] && die "repos/$REPO/ already exists in the docs repo"

[[ -d "$ROOT/$REPO" ]] || warn "$REPO is not yet in $ROOT/ — registering it anyway"

render_template "$CRUX_HOME/templates/repo-doc/README.md" "$DOCS/repos/$REPO/README.md" \
  "REPO=$REPO" "PROJECT=$PROJECT" "DESCRIPTION=$DESCRIPTION"
ok "created repos/$REPO/README.md"

node -e '
  const fs = require("fs");
  const [file, repo] = process.argv.slice(1);
  const o = JSON.parse(fs.readFileSync(file, "utf8"));
  o.repos = o.repos || [];
  if (!o.repos.includes(repo)) o.repos.push(repo);
  fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
' "$CONFIG" "$REPO"
ok "declared in crux.json"

# If the repo already has an origin and the contract template does not compose
# it, clone would not know where to fetch it from. adopt deduces it the same
# way; here it was left undeclared.
if [[ -d "$ROOT/$REPO/.git" ]]; then
  ORIGIN="$(git -C "$ROOT/$REPO" remote get-url origin 2>/dev/null || true)"
  EXPECTED="$(remote_url "$CONFIG" "$REPO" 2>/dev/null || true)"
  if [[ -n "$ORIGIN" && "$ORIGIN" != "$EXPECTED" ]]; then
    node -e '
      const fs = require("fs");
      const [file, repo, url] = process.argv.slice(1);
      const o = JSON.parse(fs.readFileSync(file, "utf8"));
      o.remote = o.remote || {};
      o.remote.repos = o.remote.repos || {};
      o.remote.repos[repo] = url;
      fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
    ' "$CONFIG" "$REPO" "$ORIGIN"
    ok "remote taken from its origin: $ORIGIN"
  fi
fi

# The table in repos/README.md is the index a human reads; it maintains itself
# while it exists, and if the project deleted it, it is not reinvented.
INDEX="$DOCS/repos/README.md"
if [[ -f "$INDEX" ]] && grep -qE '^\| *(Carpeta|Folder)' "$INDEX"; then
  node -e '
    const fs = require("fs");
    const [file, repo, project, desc] = process.argv.slice(1);
    const lines = fs.readFileSync(file, "utf8").split("\n");
    let last = -1;
    for (let i = 0; i < lines.length; i++) if (/^\|/.test(lines[i])) last = i;
    if (last === -1) process.exit(0);
    const row = `| \`${repo}/\` | \`${project}/${repo}\` | ${desc.replace(/\|/g, "\\|")} |`;
    const empty = lines.findIndex((l, i) => i <= last && /^\|\s*\|\s*\|\s*\|\s*$/.test(l));
    if (empty !== -1) lines[empty] = row; else lines.splice(last + 1, 0, row);
    fs.writeFileSync(file, lines.join("\n"));
  ' "$INDEX" "$REPO" "$PROJECT" "$DESCRIPTION"
  ok "registered in repos/README.md"
else
  warn "repos/README.md has no table — register it by hand"
fi

echo
bash "$CRUX_HOME/bin/link.sh" "$DOCS"

echo
info "suggested commit: docs(repos): add $REPO"
