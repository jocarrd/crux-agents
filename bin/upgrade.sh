#!/usr/bin/env bash
# crux upgrade — alinea un docs repo con la versión actual del kernel.
#
# Materializa las piezas del estándar que falten (las que una versión nueva
# haya añadido) y actualiza la versión declarada en crux.json. No sobrescribe
# contenido existente salvo --force: la documentación es del proyecto, las
# plantillas solo cubren huecos.
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

DOCS="$(find_docs_repo "$TARGET")" || die "no encuentro un docs repo desde $TARGET"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "falta crux.json — ejecuta 'crux adopt' primero"

PROJECT="$(json_get "$CONFIG" project)"
FROM="$(json_get "$CONFIG" crux)"
TO="$(crux_version)"

echo "$PROJECT: crux $FROM → $TO"
[[ $DRY -eq 1 ]] && warn "dry-run: no se escribe nada"
echo

if [[ "$FROM" == "$TO" && $FORCE -eq 0 ]]; then
  ok "ya está en la versión del kernel"
  echo
  exec bash "$CRUX_HOME/bin/doctor.sh" "$DOCS"
fi

# --- Materializar lo que falte ----------------------------------------------

added=0
while IFS= read -r src; do
  rel="${src#"$CRUX_HOME/templates/docs-repo/"}"
  dst="$DOCS/$rel"
  [[ "$rel" == "gitignore" ]] && dst="$DOCS/.gitignore"

  if [[ -e "$dst" && $FORCE -eq 0 ]]; then
    continue
  fi

  if [[ $DRY -eq 1 ]]; then
    echo "      [dry-run] materializaría $rel"
  else
    DESCRIPTION="$(json_get "$CONFIG" description 2>/dev/null || echo "Documentación transversal de $PROJECT.")"
    render_template "$src" "$dst" "PROJECT=$PROJECT" "DESCRIPTION=$DESCRIPTION"
    ok "materializado $rel"
  fi
  added=$((added + 1))
done < <(find "$CRUX_HOME/templates/docs-repo" -type f | sort)

[[ $added -eq 0 ]] && ok "no falta ninguna pieza del estándar"

# --- Actualizar la versión declarada ----------------------------------------

if [[ $DRY -eq 0 ]]; then
  node -e '
    const fs = require("fs");
    const [file, version] = process.argv.slice(1);
    const o = JSON.parse(fs.readFileSync(file, "utf8"));
    o.crux = version;
    fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
  ' "$CONFIG" "$TO"
  ok "crux.json actualizado a $TO"
fi

echo
[[ $DRY -eq 0 ]] && exec bash "$CRUX_HOME/bin/doctor.sh" "$DOCS"
