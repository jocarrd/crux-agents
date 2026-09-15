#!/usr/bin/env bash
# crux mcp — los servidores MCP que el proyecto declara, puestos donde el
# agente los lee.
#
#   crux mcp status     qué declara el contrato, qué hay escrito y si responde
#   crux mcp install    escribe los .mcp.json de los repos que correspondan
#   crux mcp remove     retira solo lo que declara el contrato
#
# Un MCP es una capacidad del proyecto, no de la máquina: el que hace falta en
# uno estorba en otro. Por eso se declara en `crux.json` y viaja en git, igual
# que los punteros de contexto, y no en la configuración local de cada portátil
# —que es lo que hace `claude mcp add` y lo que se pierde al cambiar de equipo.
#
# El contrato manda. El .mcp.json de cada repo es un derivado: `install` lo
# reescribe, `remove` retira lo declarado y lo que haya puesto alguien a mano se
# queda donde está.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

ADAPTADOR="$CRUX_HOME/adapters/claude/mcp.sh"

DOCS="$(find_docs_repo "$PWD" 2>/dev/null)" || die "no encuentro el docs repo desde aquí"
CONTRATO="$DOCS/crux.json"
[[ -f "$CONTRATO" ]] || die "no hay crux.json en $DOCS"

PROFILE="$(json_get "$CONTRATO" profile 2>/dev/null || echo "multi-repo")"
RAIZ="$(dirname "$DOCS")"

# Los destinos donde se escribe el fichero. `repos` en el contrato admite
# "docs" (el defecto), "all", o la lista de repos concretos.
destinos() {
  local nombre="$1" quiere repo
  quiere="$(json_get "$CONTRATO" "mcp[\"$nombre\"].repos" 2>/dev/null || echo "docs")"

  # El perfil de cliente dice que no se escribe en su repo: ni punteros, ni
  # AGENTS.md, ni carpetas. Un .mcp.json es exactamente lo mismo, así que la
  # decisión ya está tomada y aquí solo se respeta.
  local escribe_fuera; escribe_fuera="$(perfil_get "$PROFILE" "$DOCS" pointers.write true)"

  if [[ "$quiere" == "docs" ]]; then
    echo "$DOCS"
    return 0
  fi

  if [[ "$escribe_fuera" != "true" ]]; then
    warn "$nombre: el perfil '$PROFILE' no escribe en los repos de código — solo en el docs repo" >&2
    echo "$DOCS"
    return 0
  fi

  echo "$DOCS"
  if [[ "$quiere" == "all" ]]; then
    while IFS= read -r repo; do
      [[ -n "$repo" && -d "$RAIZ/$repo" ]] && echo "$RAIZ/$repo"
    done < <(json_get "$CONTRATO" repos 2>/dev/null || true)
  else
    # Lista explícita. json_get devuelve un elemento por línea.
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      [[ "$repo" == "$(basename "$DOCS")" ]] && continue
      if [[ -d "$RAIZ/$repo" ]]; then echo "$RAIZ/$repo"
      else warn "$nombre: declara el repo '$repo', que no está clonado" >&2; fi
    done < <(json_get "$CONTRATO" "mcp[\"$nombre\"].repos" 2>/dev/null || true)
  fi
}

nombres_declarados() {
  # json_get antepone `root.` a la expresión, así que la clave va delante y el
  # resto se evalúa detrás.
  json_get "$CONTRATO" 'mcp && Object.keys(root.mcp)' 2>/dev/null || true
}

# Todos los destinos de todos los servidores, sin repetir.
todos_los_destinos() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] && destinos "$n"
  done < <(nombres_declarados) | sort -u
}

# --- status ------------------------------------------------------------------

cmd_status() {
  local nombres; nombres="$(nombres_declarados)"
  if [[ -z "$nombres" ]]; then
    info "el contrato no declara ningún servidor MCP"
    return 0
  fi

  echo "declarados en $(basename "$DOCS")/crux.json"
  local n transporte donde
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    transporte="$(json_get "$CONTRATO" "mcp[\"$n\"].transport" 2>/dev/null || echo "stdio")"
    if [[ "$transporte" == "stdio" ]]; then
      donde="$(json_get "$CONTRATO" "mcp[\"$n\"].command" 2>/dev/null || echo "?")"
    else
      donde="$(json_get "$CONTRATO" "mcp[\"$n\"].url" 2>/dev/null || echo "?")"
    fi
    info "$(printf '%-18s %-6s %s' "$n" "$transporte" "$donde")"
  done <<<"$nombres"

  echo
  echo "escrito en los repos"
  local dir linea
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    while IFS= read -r linea; do
      case "$linea" in
        ok\ *)      ok "$(basename "$dir") — ${linea#ok }" ;;
        falta\ *)   warn "$(basename "$dir") — falta ${linea#falta }; ejecuta 'crux mcp install'" ;;
        difiere\ *) warn "$(basename "$dir") — ${linea#difiere } difiere del contrato; 'crux mcp install'" ;;
        ajeno\ *)   info "$(basename "$dir") — ${linea#ajeno } lo puso alguien a mano; crux no lo toca" ;;
      esac
    done < <(bash "$ADAPTADOR" diff "$CONTRATO" "$dir" 2>/dev/null || true)
  done < <(todos_los_destinos)

  echo
  echo "¿responden?"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    probar "$n"
  done <<<"$nombres"
}

# Un servidor declarado que no responde es el problema del hook roto: el
# proyecto parece tener una capacidad que no tiene. Con stdio no se arranca el
# proceso —eso son efectos secundarios y no es asunto de un status— sino que se
# comprueba que el binario existe, que es donde falla de verdad.
probar() {
  local n="$1" transporte url cmd
  transporte="$(json_get "$CONTRATO" "mcp[\"$n\"].transport" 2>/dev/null || echo "stdio")"

  if [[ "$transporte" == "stdio" ]]; then
    cmd="$(json_get "$CONTRATO" "mcp[\"$n\"].command" 2>/dev/null || echo "")"
    if [[ -z "$cmd" ]]; then err "$n — sin 'command'"
    elif command -v "$cmd" >/dev/null 2>&1; then ok "$n — '$cmd' está en el PATH"
    else err "$n — '$cmd' no está en el PATH de esta máquina"; fi
    return 0
  fi

  url="$(json_get "$CONTRATO" "mcp[\"$n\"].url" 2>/dev/null || echo "")"
  [[ -n "$url" ]] || { err "$n — sin 'url'"; return 0; }
  command -v curl >/dev/null 2>&1 || { warn "$n — sin curl, no se puede comprobar"; return 0; }

  local respuesta
  respuesta="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"crux","version":"1"}}}' \
    2>/dev/null || echo "000")"

  case "$respuesta" in
    2*) ok "$n — responde ($respuesta)" ;;
    401|403) warn "$n — responde pero pide credenciales ($respuesta)" ;;
    000) err "$n — no contesta" ;;
    *)  err "$n — responde $respuesta" ;;
  esac
}

# --- install -----------------------------------------------------------------

cmd_install() {
  local nombres; nombres="$(nombres_declarados)"
  [[ -n "$nombres" ]] || { info "el contrato no declara ningún servidor MCP"; return 0; }

  # La forma se valida antes de escribir: un .mcp.json inválido no lo avisa
  # nadie, el cliente simplemente no conecta.
  local problemas; problemas="$(node "$CRUX_HOME/lib/check-mcp.mjs" "$DOCS" | grep '^error ' || true)"
  if [[ -n "$problemas" ]]; then
    while IFS= read -r linea; do err "${linea#error }"; done <<<"$problemas"
    die "el contrato tiene errores; no se escribe nada"
  fi

  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    ok "$(basename "$dir") — $(bash "$ADAPTADOR" write "$CONTRATO" "$dir")"
  done < <(todos_los_destinos)

  echo
  info "el cliente pide aprobación la primera vez que abre un proyecto con .mcp.json"
  info "y se apaga por proyecto con /mcp, sin tocar esta configuración"
}

# --- remove ------------------------------------------------------------------

cmd_remove() {
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    ok "$(basename "$dir") — $(bash "$ADAPTADOR" clear "$CONTRATO" "$dir")"
  done < <(todos_los_destinos)
  info "lo que no declaraba el contrato se ha quedado como estaba"
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) die "uso: crux mcp {status|install|remove}" ;;
esac
