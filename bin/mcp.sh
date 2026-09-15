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

ADAPTADOR="$CRUX_HOME/adapters/claude/mcp.mjs"

DOCS="$(find_docs_repo "$PWD" 2>/dev/null)" || die "no encuentro el docs repo desde aquí"
CONTRATO="$DOCS/crux.json"
[[ -f "$CONTRATO" ]] || die "no hay crux.json en $DOCS"

PROFILE="$(json_get "$CONTRATO" profile 2>/dev/null || echo "multi-repo")"
RAIZ="$(dirname "$DOCS")"

# El nombre de un servidor sale de un contrato que viaja en git, así que nunca
# se concatena dentro de una expresión: `json_get` la pasa por `eval`, y un
# nombre con una comilla ejecutaba código con solo leer el proyecto. Aquí va
# como argumento, donde no es código.
mcp_campo() {
  # mcp_campo <nombre> <campo> — un campo del servidor, o nada si no está
  node -e '
    const fs = require("fs");
    const [fichero, nombre, campo] = process.argv.slice(1);
    const d = ((JSON.parse(fs.readFileSync(fichero, "utf8")).mcp || {})[nombre] || {})[campo];
    if (d === undefined || d === null) process.exit(2);
    process.stdout.write((Array.isArray(d) ? d.join(" ") : String(d)) + "\n");
  ' "$CONTRATO" "$1" "$2" 2>/dev/null || true
}

nombres_declarados() {
  json_get "$CONTRATO" 'mcp && Object.keys(root.mcp)' 2>/dev/null || true
}

# Los destinos de un servidor. La resolución de `repos` vive en el kernel junto
# a la del formato, para que `doctor` sepa dónde debería haber fichero sin
# deducirlo por su cuenta; aquí solo se le aplica lo que el perfil permita.
destinos() {
  local nombre="$1" repo
  echo "$DOCS"

  # El perfil de cliente dice que no se escribe en su repo: ni punteros, ni
  # AGENTS.md, ni carpetas. Un .mcp.json es exactamente lo mismo, así que la
  # decisión ya está tomada y aquí solo se respeta.
  local escribe_fuera; escribe_fuera="$(perfil_get "$PROFILE" "$DOCS" pointers.write true)"

  # Con `node -e`, argv[1] es ya el primer argumento: no hay nombre de script
  # delante. Y el error no se tapa — si esto falla, el servidor se quedaría sin
  # la mitad de sus destinos sin que nadie lo dijera.
  local pedidos
  pedidos="$(node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { reposDe } from "'"$CRUX_HOME"'/lib/mcp-format.mjs";
    const [fichero, nombre] = process.argv.slice(1);
    const contrato = JSON.parse(readFileSync(fichero, "utf8"));
    process.stdout.write(reposDe(contrato, nombre).join("\n"));
  ' "$CONTRATO" "$nombre")" || die "no pude resolver los repos de '$nombre'"

  [[ -n "$pedidos" ]] || return 0
  if [[ "$escribe_fuera" != "true" ]]; then
    warn "$nombre: el perfil '$PROFILE' no escribe en los repos de código — solo en el docs repo" >&2
    return 0
  fi

  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if [[ -d "$RAIZ/$repo" ]]; then echo "$RAIZ/$repo"
    else warn "$nombre: declara el repo '$repo', que no está clonado" >&2; fi
  done <<<"$pedidos"
}

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
    transporte="$(mcp_campo "$n" transport)"; transporte="${transporte:-stdio}"
    if [[ "$transporte" == "stdio" ]]; then donde="$(mcp_campo "$n" command)"
    else donde="$(mcp_campo "$n" url)"; fi
    info "$(printf '%-18s %-6s %s' "$n" "$transporte" "${donde:-?}")"
  done <<<"$nombres"

  echo
  echo "escrito en los repos"
  local dir salida rc
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rc=0
    salida="$(node "$ADAPTADOR" diff "$CONTRATO" "$dir" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      # Un fichero que no se puede leer es justo el que no puede desaparecer del
      # informe: el repo parecería sano por no salir.
      err "$(basename "$dir") — $salida"
      continue
    fi
    local linea
    while IFS= read -r linea; do
      case "$linea" in
        ok\ *)      ok "$(basename "$dir") — ${linea#ok }" ;;
        falta\ *)   warn "$(basename "$dir") — falta ${linea#falta }; ejecuta 'crux mcp install'" ;;
        difiere\ *) warn "$(basename "$dir") — ${linea#difiere } difiere del contrato; 'crux mcp install'" ;;
        ajeno\ *)   info "$(basename "$dir") — ${linea#ajeno } lo puso alguien a mano; crux no lo toca" ;;
      esac
    done <<<"$salida"
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
  transporte="$(mcp_campo "$n" transport)"; transporte="${transporte:-stdio}"

  if [[ "$transporte" == "stdio" ]]; then
    cmd="$(mcp_campo "$n" command)"
    if [[ -z "$cmd" ]]; then err "$n — sin 'command'"
    elif command -v "$cmd" >/dev/null 2>&1; then ok "$n — '$cmd' está en el PATH"
    else err "$n — '$cmd' no está en el PATH de esta máquina"; fi
    return 0
  fi

  url="$(mcp_campo "$n" url)"
  [[ -n "$url" ]] || { err "$n — sin 'url'"; return 0; }
  command -v curl >/dev/null 2>&1 || { warn "$n — sin curl, no se puede comprobar"; return 0; }

  # `-w` ya escribe 000 cuando la conexión falla. Añadir un `|| echo 000`
  # concatenaba un segundo y dejaba el caso más frecuente —servidor caído— sin
  # su mensaje, cayendo en el comodín con un "responde 000000".
  local respuesta
  respuesta="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"crux","version":"1"}}}' \
    2>/dev/null)" || true

  case "$respuesta" in
    2*) ok "$n — responde ($respuesta)" ;;
    401|403) warn "$n — responde pero pide credenciales ($respuesta)" ;;
    000|"") err "$n — no contesta" ;;
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

  local dir salida rc
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rc=0
    salida="$(node "$ADAPTADOR" write "$CONTRATO" "$dir" 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || die "$(basename "$dir") — $salida"
    ok "$(basename "$dir") — $salida"
  done < <(todos_los_destinos)

  echo
  info "el cliente pide aprobación la primera vez que abre un proyecto con .mcp.json"
  info "y se apaga por proyecto con /mcp, sin tocar esta configuración"
}

# --- remove ------------------------------------------------------------------

cmd_remove() {
  local dir salida rc
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rc=0
    salida="$(node "$ADAPTADOR" clear "$CONTRATO" "$dir" 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || { err "$(basename "$dir") — $salida"; continue; }
    ok "$(basename "$dir") — $salida"
  done < <(todos_los_destinos)
  info "lo que no declaraba el contrato se ha quedado como estaba"
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) die "uso: crux mcp status|install|remove" ;;
esac
