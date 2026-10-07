#!/usr/bin/env bash
# crux archive — mark a code repo of the project as archived, or bring it back.
#
#   crux archive <repo> --reason "<why>" [--no-remote]
#   crux unarchive <repo> [--no-remote]
#
# An archived repo is out of production but kept. The contract is what says
# so —`archived` in crux.json, with since and reason— whatever the git
# provider allows: on GitHub the remote is archived too and becomes read only;
# elsewhere crux still treats it as archived. Without this, a retired service
# kept its deploy workflow and a merge in its repo started deploying it again.
#
# From then on it is no longer in `repos`: clone, sync, link and doctor treat
# it as gone; workspace new and merge refuse to work in it, and its local clone
# refuses to push.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

MODE="archive"; REPO=""; REASON=""; REMOTE=1
[[ "${1:-}" == "--undo" ]] && { MODE="unarchive"; shift; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)    REASON="${2:-}"; shift 2 ;;
    --no-remote) REMOTE=0; shift ;;
    -*)          die "unknown option: $1" ;;
    *)           REPO="$1"; shift ;;
  esac
done
[[ -n "$REPO" ]] || die "usage: crux $MODE <repo>$([[ $MODE == archive ]] && echo ' --reason "<why>"')"
valid_name "$REPO" || die "not a valid repo name: $REPO"

DOCS="$(find_docs_repo "$PWD")" || die "run it from the project's docs repo, or one of its repos"
CONFIG="$DOCS/crux.json"
ROOT="$(dirname "$DOCS")"
reason="$(valid_json "$CONFIG")" || die "crux.json cannot be read: $reason"
LANG_DOCS="$(json_get "$CONFIG" language 2>/dev/null || echo en)"
TODAY="$(date +%Y-%m-%d)"

# The provider part. GitHub is the one the kernel knows how to archive; for any
# other the contract is enough, and the person is told to do it there by hand.
provider() {
  local action="$1" url slug
  (( REMOTE )) || { info "remote left as it is (--no-remote)"; return 0; }
  url="$(remote_url "$CONFIG" "$REPO" 2>/dev/null || true)"
  if [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
    slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    if ! command -v gh >/dev/null 2>&1; then
      warn "without gh I cannot $action $slug on GitHub: do it by hand"
    elif gh repo "$action" "$slug" --yes >/dev/null 2>&1; then
      ok "$slug ${action}d on GitHub"
    else
      warn "GitHub did not $action $slug — check permissions and do it by hand"
    fi
  else
    warn "the remote of $REPO is not on GitHub: crux treats it as ${action}d, $action it in your provider by hand"
  fi
}

banner_start() { [[ "$LANG_DOCS" == es ]] && echo "> **Archivado el" || echo "> **Archived on"; }

if [[ "$MODE" == archive ]]; then
  [[ -n "$REASON" ]] || die "say why: --reason \"<why>\" (it is what stops someone from bringing it back blindly)"
  node -e '
    const fs = require("fs");
    const [file, repo, since, reason] = process.argv.slice(1);
    const c = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!(c.repos || []).includes(repo)) { console.error(`${repo} is not an active repo of the project`); process.exit(3); }
    c.repos = c.repos.filter((r) => r !== repo);
    c.archived = { ...(c.archived || {}), [repo]: { since, reason } };
    fs.writeFileSync(file, JSON.stringify(c, null, 2) + "\n");
  ' "$CONFIG" "$REPO" "$TODAY" "$REASON" || die "$REPO is not an active repo of $(basename "$DOCS")"
  ok "$REPO archived in crux.json (since $TODAY)"

  readme="$DOCS/repos/$REPO/README.md"
  if [[ -f "$readme" ]] && ! grep -qF "$(banner_start)" "$readme"; then
    if [[ "$LANG_DOCS" == es ]]; then
      line="> **Archivado el $TODAY.** $REASON — \`crux unarchive $REPO\` lo devuelve."
    else
      line="> **Archived on $TODAY.** $REASON — \`crux unarchive $REPO\` brings it back."
    fi
    awk -v line="$line" 'NR == 1 && /^# / { print; print ""; print line; next } { print }' "$readme" > "$readme.tmp" \
      && mv "$readme.tmp" "$readme"
    ok "notice at the top of repos/$REPO/README.md"
  fi

  # The local clone stops pushing: a merge or a push there is exactly what
  # brought the retired service back.
  if [[ -d "$ROOT/$REPO/.git" ]]; then
    hooks="$(git -C "$ROOT/$REPO" rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "$hooks"
    cat > "$hooks/pre-push" <<HOOK
#!/usr/bin/env bash
# Installed by crux archive.
echo
echo "$REPO is archived since $TODAY: push blocked"
echo "  if it is coming back to life: crux unarchive $REPO, from its docs repo"
exit 1
HOOK
    chmod +x "$hooks/pre-push"
    ok "the local clone refuses to push"
  fi

  provider archive
  info "suggested commit in $(basename "$DOCS"): chore(repos): archive $REPO"
  exit 0
fi

# --- unarchive -------------------------------------------------------------------
node -e '
  const fs = require("fs");
  const [file, repo] = process.argv.slice(1);
  const c = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!(c.archived || {})[repo]) { process.exit(3); }
  delete c.archived[repo];
  if (!Object.keys(c.archived).length) delete c.archived;
  c.repos = [...(c.repos || []), repo];
  fs.writeFileSync(file, JSON.stringify(c, null, 2) + "\n");
' "$CONFIG" "$REPO" || die "$REPO is not archived in $(basename "$DOCS")"
ok "$REPO is an active repo again in crux.json"

readme="$DOCS/repos/$REPO/README.md"
if [[ -f "$readme" ]] && grep -qF "$(banner_start)" "$readme"; then
  awk -v start="$(banner_start)" '
    index($0, start) == 1 { skip = 1; next }
    skip && /^$/ { skip = 0; next }
    { skip = 0; print }' "$readme" > "$readme.tmp" && mv "$readme.tmp" "$readme"
  ok "notice removed from repos/$REPO/README.md"
fi

if [[ -d "$ROOT/$REPO/.git" ]]; then
  hooks="$(git -C "$ROOT/$REPO" rev-parse --path-format=absolute --git-path hooks)"
  grep -q "Installed by crux archive" "$hooks/pre-push" 2>/dev/null && rm -f "$hooks/pre-push"
  info "its usual hooks come back with 'crux hooks install' from the docs repo"
fi

provider unarchive
info "suggested commit in $(basename "$DOCS"): chore(repos): unarchive $REPO"
