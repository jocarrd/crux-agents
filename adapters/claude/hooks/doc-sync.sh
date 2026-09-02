#!/usr/bin/env bash
# Hook de Claude Code (Stop) — la puerta de la documentación.
#
# Antes vigilaba una sola cosa: que no cerraras con ficheros sin commitear que
# la doc mencionase por nombre. Eso dejaba fuera el caso que de verdad hace
# daño, y que se comprobó el 2026-09-02: una sesión que mide cosas, descubre un
# riesgo y resuelve una pregunta abierta, commitea limpio, y se cierra sin que
# nada de ese conocimiento llegue al docs repo. Con el árbol limpio el hook
# salía en la primera comprobación y el sistema parecía vigilado sin estarlo.
#
# Ahora hace dos cosas:
#
#   1. Mide la deriva entre código y documentación (check-doc-drift.mjs).
#   2. Si la sesión ha movido algo, BLOQUEA el cierre una vez y obliga a
#      responder qué de lo hablado se queda en git.
#
# Bloquea como mucho una vez por sesión: la segunda pasada sale sola. Un hook
# que bloquea siempre se acaba desinstalando, y entonces no vigila nada.

set -u

entrada=""
[[ ! -t 0 ]] && entrada="$(cat 2>/dev/null || true)"

leer_json() {
  local campo="$1"
  [[ -z "$entrada" ]] && return 0
  node -e '
    let d = "";
    try { d = JSON.parse(process.argv[1] || "{}"); } catch { d = {}; }
    const v = d[process.argv[2]];
    if (v !== undefined && v !== null) process.stdout.write(String(v));
  ' "$entrada" "$campo" 2>/dev/null || true
}

# Claude Code marca así el turno que ya viene de un Stop bloqueado. Sin esto,
# bloquear en Stop es un bucle infinito.
[[ "$(leer_json stop_hook_active)" == "true" ]] && exit 0

sesion="$(leer_json session_id)"
[[ -z "$sesion" ]] && sesion="sin-id"

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)}"

raiz="${CRUX_PROJECTS_DIR:-}"
if [[ -z "$raiz" && -f "$HOME/.crux/config" ]]; then
  raiz="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  if [[ -z "$raiz" ]]; then
    kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
    [[ -n "$kernel" ]] && raiz="$(dirname "$kernel")"
  fi
fi
[[ -n "$raiz" ]] || exit 0

cwd="$(pwd)"
case "$cwd/" in
  "$raiz"/*/*) ;;
  *) exit 0 ;;
esac

rel="${cwd#"$raiz"/}"
project="${rel%%/*}"
rest="${rel#*/}"
repo="${rest%%/*}"

docs_root="$raiz/$project/$project-docs"
[[ -f "$docs_root/crux.json" ]] || exit 0

# --- 1. Deriva medible -------------------------------------------------------

deriva=""
if [[ -f "$CRUX_HOME/lib/check-doc-drift.mjs" ]]; then
  deriva="$(node "$CRUX_HOME/lib/check-doc-drift.mjs" "$docs_root" 2>/dev/null || true)"
fi

# --- 2. Ficheros tocados que la doc menciona por nombre -----------------------

referenciados=""
if [[ -d "$docs_root/repos/$repo" ]]; then
  modificados="$(git -C "$cwd" status --porcelain 2>/dev/null | awk '$1 !~ /^\?\?$/ {print $2}')"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      *.lock|*lock.yaml|*lock.json|*tsbuildinfo|.env*|*.log) continue ;;
    esac
    base="${f##*/}"
    if grep -rqF "$f" "$docs_root/repos/$repo/" 2>/dev/null; then
      referenciados+="  - $f (referenciado por ruta)"$'\n'
    elif grep -rqF "\`$base\`" "$docs_root/repos/$repo/" 2>/dev/null; then
      referenciados+="  - $f (referenciado por nombre)"$'\n'
    fi
  done <<< "$modificados"
fi

# --- 3. ¿Ha pasado algo en esta sesión? --------------------------------------
#
# Si no se ha tocado nada en el proyecto, no hay nada que promocionar y callar
# es lo correcto. Preguntar en sesiones vacías es la forma más rápida de que
# alguien desinstale el hook.

hubo_actividad=0
[[ -n "$deriva" || -n "$referenciados" ]] && hubo_actividad=1
if [[ $hubo_actividad -eq 0 ]]; then
  for d in "$raiz/$project"/*/; do
    [[ -d "$d/.git" ]] || continue
    if [[ -n "$(git -C "$d" log -1 --since='12 hours ago' --format=%h 2>/dev/null)" ]]; then
      hubo_actividad=1
      break
    fi
  done
fi
[[ $hubo_actividad -eq 1 ]] || exit 0

# --- 4. Una vez por sesión ---------------------------------------------------

estado="$HOME/.crux/state"
mkdir -p "$estado" 2>/dev/null || true
marca="$estado/doc-gate-$(printf '%s' "$sesion" | tr -c 'A-Za-z0-9_.-' '_')"
if [[ -f "$marca" ]]; then
  exit 0
fi
: > "$marca" 2>/dev/null || true

# Sin dejar basura: las marcas de hace más de dos días no le sirven a nadie.
find "$estado" -name 'doc-gate-*' -type f -mtime +2 -delete 2>/dev/null || true

# --- 5. La puerta ------------------------------------------------------------

{
  echo "PUERTA DE DOCUMENTACIÓN — proyecto $project"
  echo
  echo "Esta sesión ha movido cosas. Antes de cerrar, responde en una línea qué"
  echo "de lo que ha pasado se queda en $project-docs y qué no."

  if [[ -n "$deriva" ]]; then
    echo
    echo "Deriva medida:"
    while IFS= read -r l; do [[ -n "$l" ]] && echo "  $l"; done <<< "$deriva"
  fi

  if [[ -n "$referenciados" ]]; then
    echo
    echo "Ficheros tocados que la documentación menciona:"
    printf '%s' "$referenciados"
  fi

  cat <<'GUIA'

Repasa la conversación, no solo el diff. Lo que se pierde no suele ser un
fichero, es lo que se midió, se decidió o se descubrió y nunca fue un fichero:

  - decisión con alternativas descartadas ....... decisions/ (ADR)
  - algo medido que costaría repetir ............ repos/<repo>/ o operations/
  - gotcha de infraestructura o despliegue ...... operations/
  - riesgo nuevo ................................ operations/open-risks.md
  - pregunta abierta que se ha resuelto ......... donde estaba la pregunta
  - estado de un repo que ha cambiado ........... repos/<repo>/notes.md

Si nada de la sesión encaja, dilo explícitamente y cierra: la respuesta "no hay
nada que promocionar" es válida, pero tiene que ser una respuesta, no un olvido.
Si algo encaja, usa /promote-to-docs ahora y commitea antes de cerrar.
GUIA
} >&2

exit 2
