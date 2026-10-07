#!/usr/bin/env bash
# crux upgrade — aligns a docs repo with the current kernel version.
#
# Materializes the pieces of the standard that are missing (those a new version
# has added) and updates the version declared in crux.json. It does not
# overwrite existing content unless --force: the documentation belongs to the
# project, the templates only fill gaps.
#
#   crux upgrade [dir] [--force] [--dry-run]

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

TARGET="$PWD"; FORCE=0; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(find_docs_repo "$TARGET")" || die "cannot find a docs repo from $TARGET"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "crux.json is missing — run 'crux adopt' first"

PROJECT="$(json_get "$CONFIG" project)"
FROM="$(json_get "$CONFIG" crux)"
TO="$(crux_version)"

echo "$PROJECT: crux $FROM → $TO"
[[ $DRY -eq 1 ]] && warn "dry-run: nothing is written"
echo

# Downgrading the contract on the machine that has the old kernel leaves the
# project declaring less than what it already has materialized, without telling
# anyone.
#
# version_greater_than returns 1 both for "is not greater" and for "cannot
# compare this", and treating them the same opened the guard on its own: a
# kernel without VERSION wrote "crux": "unknown" into the contract, and from
# then on no comparison worked again.
if ! is_semver "$TO"; then
  err "this kernel does not declare a valid version: '$TO'"
  info "reinstall it from the kernel repo: bash install.sh"
  exit 1
fi
if ! is_semver "$FROM"; then
  err "the project declares a version that cannot be compared: '$FROM'"
  info "fix \"crux\" in crux.json before upgrading"
  [[ $FORCE -eq 0 ]] && exit 1
fi
if version_greater_than "$FROM" "$TO"; then
  err "the project declares crux $FROM and this kernel is $TO"
  info "update the kernel ('git pull' in $CRUX_HOME) instead of downgrading the contract"
  info "if you really want to lower it: crux upgrade --force"
  [[ $FORCE -eq 0 ]] && exit 1
fi

# --- Materialize what is missing ----------------------------------------------

added=0
while IFS= read -r src; do
  rel="${src#"$CRUX_HOME/templates/docs-repo/"}"
  dst="$DOCS/$rel"
  [[ "$rel" == "gitignore" ]] && dst="$DOCS/.gitignore"
  [[ "$rel" == "gitattributes" ]] && dst="$DOCS/.gitattributes"

  if [[ -e "$dst" && $FORCE -eq 0 ]]; then
    continue
  fi

  if [[ $DRY -eq 1 ]]; then
    echo "      [dry-run] would materialize $rel"
  else
    DESCRIPTION="$(json_get "$CONFIG" description 2>/dev/null || echo "Cross-cutting documentation for $PROJECT.")"
    render_template "$src" "$dst" "PROJECT=$PROJECT" "DESCRIPTION=$DESCRIPTION"
    ok "materialized $rel"
  fi
  added=$((added + 1))
done < <(find "$CRUX_HOME/templates/docs-repo" -type f | sort)

# A matching version does not guarantee that all pieces are there: 'crux adopt'
# writes the current version over a repo that does not have the structure yet,
# and if it exits before looking, the command meant to complete it completes
# nothing.
[[ $added -eq 0 ]] && ok "no piece of the standard is missing"

# CLAUDE.md is a symlink, not a template: without this, an adopted project goes
# without it and doctor reports it as a missing piece forever.
if [[ $DRY -eq 0 && -f "$DOCS/AGENTS.md" && ! -e "$DOCS/CLAUDE.md" ]]; then
  ( cd "$DOCS" && ln -s AGENTS.md CLAUDE.md )
  ok "materialized CLAUDE.md"
fi

# --- Update the declared version ----------------------------------------

if [[ $DRY -eq 0 ]]; then
  node -e '
    const fs = require("fs");
    const [file, version] = process.argv.slice(1);
    const o = JSON.parse(fs.readFileSync(file, "utf8"));
    o.crux = version;
    fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
  ' "$CONFIG" "$TO"
  ok "crux.json updated to $TO"
fi

echo
if [[ $DRY -eq 0 ]]; then
  exec bash "$CRUX_HOME/bin/doctor.sh" "$DOCS"
fi
exit 0
