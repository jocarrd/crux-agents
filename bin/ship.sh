#!/usr/bin/env bash
# crux ship — la puerta de calidad, con recibo.
#
#   crux ship run -- <comando...>   ejecuta el comando y anota su resultado
#   crux ship seal                  cierra el recibo con el sha de HEAD
#   crux ship show                  enseña el recibo
#   crux ship clear                 lo descarta y vuelve a empezar
#
# Antes la marca era un sha suelto que escribía el propio agente después de
# decir que había verificado. Eso no prueba que se verificara: prueba que
# alguien escribió un sha. `run` ejecuta de verdad y anota el código de salida,
# así que el recibo es evidencia y no una declaración.
#
# El atajo sigue existiendo —`finish --sin-puerta`— porque a veces hace falta.
# Lo que no puede pasar es que se tome solo y sin dejar rastro.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "esto no es un repositorio git"
RECIBO="$REPO/.crux-ship"

# Una marca del formato viejo —un sha a secas— no vale como recibo: no dice
# qué se ejecutó. Se trata como si no estuviera.
es_recibo_viejo() {
  [[ -f "$RECIBO" ]] && ! grep -q '^run ' "$RECIBO" 2>/dev/null
}

cmd_run() {
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || die "uso: crux ship run -- <comando...>"

  # Un recibo ya cerrado pertenece a otra pasada: la siguiente empieza limpia.
  if [[ -f "$RECIBO" ]] && { grep -q '^sealed ' "$RECIBO" 2>/dev/null || es_recibo_viejo; }; then
    rm -f "$RECIBO"
  fi
  [[ -f "$RECIBO" ]] || printf '# recibo de la puerta de calidad — crux\nrepo %s\n' "$REPO" > "$RECIBO"

  local inicio fin rc
  inicio=$(date +%s)
  "$@"; rc=$?
  fin=$(date +%s)

  printf 'run %s %s %s\n' "$rc" "$((fin - inicio))" "$*" >> "$RECIBO"
  if [[ $rc -eq 0 ]]; then ok "$* — $((fin - inicio))s"; else err "$* — salida $rc"; fi
  return $rc
}

cmd_seal() {
  [[ -f "$RECIBO" ]] && ! es_recibo_viejo || die "no hay recibo: pasa la puerta con 'crux ship run -- <comando>'"

  local total fallos
  total="$(grep -c '^run ' "$RECIBO" || true)"
  fallos="$(grep -c '^run [^0] ' "$RECIBO" || true)"
  [[ "${total:-0}" -gt 0 ]] || die "el recibo no tiene ni un comando ejecutado"
  if [[ "${fallos:-0}" -gt 0 ]]; then
    err "$fallos de $total comandos fallaron: la puerta no se cierra"
    grep '^run [^0] ' "$RECIBO" | sed 's/^run [^ ]* [^ ]* /      /'
    exit 1
  fi

  grep -v '^sealed ' "$RECIBO" > "$RECIBO.tmp" && mv "$RECIBO.tmp" "$RECIBO"
  printf 'sealed %s %s\n' "$(git -C "$REPO" rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RECIBO"
  ok "puerta cerrada sobre $(git -C "$REPO" rev-parse --short HEAD) con $total comprobaciones"
}

cmd_show() {
  [[ -f "$RECIBO" ]] || die "no hay recibo en $REPO"
  if es_recibo_viejo; then
    warn "recibo del formato antiguo (un sha suelto): no dice qué se ejecutó"
    sed 's/^/      /' "$RECIBO"
    return 0
  fi
  local head sellado
  head="$(git -C "$REPO" rev-parse HEAD)"
  sellado="$(awk '/^sealed /{print $2}' "$RECIBO" | tail -1)"
  sed 's/^/  /' "$RECIBO"
  echo
  if [[ -z "$sellado" ]]; then
    info "sin cerrar: 'crux ship seal'"
  elif [[ "$sellado" != "$head" ]]; then
    warn "cerrado sobre ${sellado:0:8}, y HEAD es ${head:0:8}: hay que volver a pasarla"
  else
    ok "vigente sobre ${head:0:8}"
  fi
}

cmd_clear() { rm -f "$RECIBO"; ok "recibo descartado"; }

# El cuerpo de una propuesta era el único artefacto del flujo sin comprobar, y
# es el que se publica. Por ahí se coló la firma de la herramienta.
cmd_body() {
  local fichero="${1:-}"
  [[ -f "$fichero" ]] || die "uso: crux ship body <fichero con el cuerpo>"

  local fallos=0
  reporta() { err "$1"; shift; printf '%s\n' "$@" | sed 's/^/      /'; fallos=$((fallos+1)); }

  local firma
  firma="$(grep -inE 'co-authored-by:[[:space:]]*(claude|ona|copilot|cursor|devin|gemini)|claude-session:|(generated|generado) with|🤖' "$fichero" || true)"
  [[ -n "$firma" ]] && reporta "la firma de la herramienta no va en una propuesta" "$firma"

  # En un repo de cliente, además, no se enseña nuestro andamiaje.
  local docs perfil escribe
  docs="$(find_docs_repo "$REPO" 2>/dev/null || echo "")"
  if [[ -n "$docs" && -f "$docs/crux.json" ]]; then
    perfil="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"
    escribe="$(json_get "$CRUX_HOME/profiles/$perfil.json" 'pointers.write' 2>/dev/null || echo true)"
    if [[ "$escribe" == "false" ]]; then
      local nuestro
      nuestro="$(grep -inE '\bcrux\b|\.crux-ship|/ship\b|workspace (new|finish)|crux doctor' "$fichero" || true)"
      [[ -n "$nuestro" ]] && reporta "perfil $perfil: esto nombra nuestro tooling en el repo de un cliente" "$nuestro"
    fi
  fi

  if [[ $fallos -gt 0 ]]; then
    echo
    info "el cuerpo dice qué cambia, qué se añade y por qué; ver STANDARD.md §8"
    exit 1
  fi
  ok "el cuerpo de la propuesta no enseña nada que no deba"
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  seal)  cmd_seal ;;
  show)  cmd_show ;;
  clear) cmd_clear ;;
  body)  shift; cmd_body "$@" ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
