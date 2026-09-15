#!/usr/bin/env bash
# crux clone — traer un proyecto entero a una máquina nueva.
#
#   crux clone <project> [--from <plantilla|url>] [--parent <dir>]
#
# Clona el docs repo, lee su contrato y clona los repos que declara. Dos cosas
# salen del contrato y no de un supuesto: la lista de repos —que en una guía
# escrita a mano se queda desfasada en cuanto añades uno— y **de dónde se
# clonan**, que puede ser distinto para la documentación y para el código.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

PROJECT="${1:-}"
[[ -n "$PROJECT" ]] || die "uso: crux clone <project> [--from <plantilla|url>] [--parent <dir>]"
shift

FROM=""
PARENT="$(projects_root)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)   FROM="$2"; shift 2 ;;
    --parent) PARENT="$2"; shift 2 ;;
    *) die "opción desconocida: $1" ;;
  esac
done

PROJECT="${PROJECT##*/}"
PROJECT="${PROJECT%-docs}"

ROOT="$PARENT/$PROJECT"
DOCS="$ROOT/$PROJECT-docs"

# Para traer el docs repo hace falta una URL, y todavía no hay contrato que la
# diga: o la pasa el usuario, o se hereda del valor por defecto de la máquina.
plantilla_inicial() {
  [[ -n "$FROM" ]] && { echo "$FROM"; return; }
  local cfg="${CRUX_CONFIG:-$HOME/.crux/config}"
  if [[ -f "$cfg" ]]; then
    local defecto
    defecto="$(grep -E '^CRUX_REMOTE=' "$cfg" | cut -d= -f2- | tr -d '"')"
    [[ -n "$defecto" ]] && { echo "$defecto"; return; }
  fi
  echo ""
}

echo "clonando $PROJECT"
echo

mkdir -p "$ROOT"

# --- 1. El docs repo, que es quien sabe el resto ------------------------------

if [[ -d "$DOCS/.git" ]]; then
  ok "$PROJECT-docs ya está"
else
  TMPL="$(plantilla_inicial)"
  if [[ -z "$TMPL" ]]; then
    err "no sé de dónde traer $PROJECT-docs"
    info "pásalo con --from 'git@tu-remoto:org/{repo}.git' (o la URL completa),"
    info "o fija un valor por defecto con CRUX_REMOTE en ~/.crux/config"
    exit 1
  fi
  URL="${TMPL//\{repo\}/$PROJECT-docs}"
  git clone -q "$URL" "$DOCS" || die "no pude clonar desde $URL"
  ok "$PROJECT-docs"
fi

CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "$PROJECT-docs no está adoptado (sin crux.json): clona el resto a mano"

PROFILE="$(json_get "$CONFIG" profile 2>/dev/null || echo "?")"

# --- 2. Los repos que declara el contrato -------------------------------------

clonados=0; fallidos=(); sin_remoto=()
while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  if [[ -d "$ROOT/$repo/.git" ]]; then
    info "$repo ya está"
    continue
  fi
  url="$(remote_url "$CONFIG" "$repo" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    sin_remoto+=("$repo")
    continue
  fi
  if git clone -q "$url" "$ROOT/$repo" 2>/dev/null; then
    ok "$repo"
    clonados=$((clonados + 1))
  else
    fallidos+=("$repo  ($url)")
  fi
done < <(json_get "$CONFIG" repos 2>/dev/null || true)

if [[ ${#sin_remoto[@]} -gt 0 ]]; then
  echo
  warn "sin remoto declarado: ${sin_remoto[*]}"
  info "añade \"remote\" a $PROJECT-docs/crux.json, o un override en remote.repos"
fi

if [[ ${#fallidos[@]} -gt 0 ]]; then
  echo
  warn "no pude clonar:"
  for f in "${fallidos[@]}"; do info "$f"; done
  # En un proyecto de cliente lo normal es que el código esté en otra
  # organización, así que esto no es un fallo: es información.
  [[ "$PROFILE" == "client-repo" ]] \
    && info "perfil $PROFILE: el código suele estar en el remoto del cliente, clónalo tú" \
    || info "comprueba el nombre o los permisos"
fi

# --- 3. Punteros y verificación ----------------------------------------------

echo
bash "$CRUX_HOME/bin/link.sh" "$DOCS"

echo
bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" || true

# Traer un proyecto y no engancharle nada deja una copia que parece lista y no lo
# está: todo lo que sostiene el estándar es automático. Se hace con los repos ya
# en disco, porque los hooks por repo los necesitan.
echo
( cd "$DOCS" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1 \
  && ok "hooks enganchados" \
  || warn "no pude enganchar los hooks — hazlo con 'crux hooks install' desde $PROJECT-docs"

# Y por el mismo motivo los servidores MCP que el proyecto declare: sin esto la
# máquina nueva se queda sin ellos y el doctor no tendría con qué compararlo.
if json_has "$DOCS/crux.json" 'mcp && Object.keys(root.mcp).length'; then
  ( cd "$DOCS" && bash "$CRUX_HOME/bin/mcp.sh" install ) >/dev/null 2>&1 \
    && ok "servidores MCP escritos" \
    || warn "no pude escribir los servidores MCP — hazlo con 'crux mcp install' desde $PROJECT-docs"
fi

echo
echo "listo: $ROOT"
if [[ -f "$DOCS/operations/machine-onboarding.md" ]]; then
  info "credenciales y secretos del proyecto: $PROJECT-docs/operations/machine-onboarding.md"
fi
exit 0
