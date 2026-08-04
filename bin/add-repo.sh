#!/usr/bin/env bash
# crux add-repo — registra un repo nuevo en un proyecto ya adoptado.
#
#   crux add-repo <repo> [--description "..."] [dir]
#
# Crea su carpeta de documentación, lo declara en crux.json, lo registra en la
# tabla de repos/README.md y regenera los punteros.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="${1:-}"
[[ -n "$REPO" ]] || die "uso: crux add-repo <repo> [--description \"...\"]"
nombre_valido "$REPO" || die "el nombre debe ir en kebab-case minúscula, sin barras: $REPO"
shift

DESCRIPTION="Qué hace este repo, en una línea."
TARGET="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(find_docs_repo "$TARGET")" || die "no encuentro un docs repo desde $TARGET"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "falta crux.json — ejecuta 'crux adopt' primero"

PROJECT="$(json_get "$CONFIG" project)"
ROOT="$(dirname "$DOCS")"

json_get "$CONFIG" repos 2>/dev/null | grep -qxF "$REPO" && die "$REPO ya está declarado en crux.json"
[[ -d "$DOCS/repos/$REPO" ]] && die "ya existe repos/$REPO/ en el docs repo"

[[ -d "$ROOT/$REPO" ]] || warn "$REPO no está todavía en $ROOT/ — se registra igual"

render_template "$CRUX_HOME/templates/repo-doc/README.md" "$DOCS/repos/$REPO/README.md" \
  "REPO=$REPO" "PROJECT=$PROJECT" "DESCRIPTION=$DESCRIPTION"
ok "creado repos/$REPO/README.md"

node -e '
  const fs = require("fs");
  const [file, repo] = process.argv.slice(1);
  const o = JSON.parse(fs.readFileSync(file, "utf8"));
  o.repos = o.repos || [];
  if (!o.repos.includes(repo)) o.repos.push(repo);
  fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
' "$CONFIG" "$REPO"
ok "declarado en crux.json"

# La tabla de repos/README.md es el índice que lee un humano; se mantiene sola
# mientras exista, y si el proyecto la borró no se reinventa.
INDEX="$DOCS/repos/README.md"
if [[ -f "$INDEX" ]] && grep -q '^| *Carpeta' "$INDEX"; then
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
  ok "registrado en repos/README.md"
else
  warn "repos/README.md sin tabla — regístralo a mano"
fi

echo
bash "$CRUX_HOME/bin/link.sh" "$DOCS"

echo
info "commit sugerido: docs(repos): add $REPO"
