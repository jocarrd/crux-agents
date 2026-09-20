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

# Degradar el contrato en la máquina que lleva el kernel viejo deja al proyecto
# declarando menos de lo que ya tiene materializado, y sin avisar a nadie.
#
# version_mayor_que devuelve 1 tanto para "no es mayor" como para "no se
# comparar esto", y tratarlas igual abria la guarda sola: un kernel sin VERSION
# escribia "crux": "unknown" en el contrato, y a partir de ahi ninguna
# comparacion volvia a funcionar.
if ! es_semver "$TO"; then
  err "este kernel no declara una versión válida: '$TO'"
  info "reinstálalo desde el repo del kernel: bash install.sh"
  exit 1
fi
if ! es_semver "$FROM"; then
  err "el proyecto declara una versión que no se puede comparar: '$FROM'"
  info "corrige \"crux\" en el crux.json antes de actualizar"
  [[ $FORCE -eq 0 ]] && exit 1
fi
if version_mayor_que "$FROM" "$TO"; then
  err "el proyecto declara crux $FROM y este kernel es $TO"
  info "actualiza el kernel ('git pull' en $CRUX_HOME) en vez de degradar el contrato"
  info "si de verdad quieres bajarlo: crux upgrade --force"
  [[ $FORCE -eq 0 ]] && exit 1
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

# La versión que coincide no garantiza que estén todas las piezas: 'crux adopt'
# escribe la versión actual sobre un repo que aún no tiene la estructura, y si
# se sale antes de mirar, el comando que debía completarla no completa nada.
[[ $added -eq 0 ]] && ok "no falta ninguna pieza del estándar"

# CLAUDE.md es un symlink, no una plantilla: sin esto, un proyecto adoptado se
# queda sin él y doctor lo reporta como pieza que falta para siempre.
if [[ $DRY -eq 0 && -f "$DOCS/AGENTS.md" && ! -e "$DOCS/CLAUDE.md" ]]; then
  ( cd "$DOCS" && ln -s AGENTS.md CLAUDE.md )
  ok "materializado CLAUDE.md"
fi

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
if [[ $DRY -eq 0 ]]; then
  exec bash "$CRUX_HOME/bin/doctor.sh" "$DOCS"
fi
exit 0
