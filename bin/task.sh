#!/usr/bin/env bash
# crux task — el registro de la tarea del espacio de trabajo en que estás.
#
#   crux task                        estado, pasos y siguiente paso
#   crux task path                   dónde está el registro
#   crux task goal "<texto>"         el objetivo: qué y por qué
#   crux task scope "<texto>"        qué entra y qué se queda fuera
#   crux task plan <fichero>         vuelca un plan aprobado y la marca planificada
#   crux task add "<paso>" [...]     añade pasos y devuelve su id (T1, T2…)
#   crux task done <Tn> ["evidencia"] marca un paso hecho con lo que lo prueba
#   crux task next "<texto>"         lo siguiente que hay que hacer
#   crux task note "<qué>" [--why "…"] [--where "…"] [--learned "…"]
#                                    una desviación o una decisión tomada por el camino;
#                                    con --why es una decisión, y al archivar la tarea
#                                    pasa a repos/<repo>/notes.md del docs repo
#   crux task status <estado> [--force]
#   crux task list [--all] [--done]  las tareas abiertas, con su siguiente paso; --done, las archivadas
#   crux task archive                la cierra y la aparta a done/, fechada
#
# Fuera de un espacio de trabajo, --task <proyecto>/<tarea> dice cuál.
#
# El registro vive en ~/.crux/tasks/<proyecto>/<tarea>.md: estado local, junto
# al registro de espacios, y fuera de los repos. Ni el de código —en el de un
# cliente no se puede, y una tarea de varios repos se partiría— ni el de
# documentación, que es para lo que dura. Ver ADR-012.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REGISTRY="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
TASKS="$(task_dir)"
MOTOR="$CRUX_HOME/lib/task.mjs"

op="${1:-show}"; [[ $# -gt 0 ]] && shift || true

# --task <proyecto>/<tarea> manda sobre el espacio en el que se esté.
ELEGIDA=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) ELEGIDA="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# Se llama dentro de $(...): un error por la salida estándar acabaría dentro de
# la variable, y el comando saldría sin decir por qué.
fallar() { err "$*" >&2; exit 1; }

fichero_actual() {
  if [[ -n "$ELEGIDA" ]]; then
    [[ "$ELEGIDA" == */* ]] || fallar "--task va como <proyecto>/<tarea>"
    echo "$TASKS/$ELEGIDA.md"
    return 0
  fi
  local aqui
  aqui="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || fallar "no estás en un repo: usa --task <proyecto>/<tarea>, o 'crux task list'"
  local ruta
  ruta="$(task_file_for_path "$REGISTRY" "$aqui")" \
    || fallar "no estás en un espacio de trabajo con tarea: 'crux workspace new <tarea>', o --task <proyecto>/<tarea>"
  echo "$ruta"
}

motor() { node "$MOTOR" "$@"; }

case "$op" in
  show)
    f="$(fichero_actual)"
    [[ -f "$f" ]] || die "no existe el registro $f"
    IFS=$'\x1f' read -r tarea estado pasos siguiente < <(motor summary --file "$f")
    echo "tarea $tarea · $estado${pasos:+ · pasos $pasos}"
    [[ -n "$siguiente" ]] && echo "siguiente: $siguiente" || info "sin siguiente paso: crux task next \"...\""
    info "$f"
    ;;
  path) fichero_actual ;;
  goal)  f="$(fichero_actual)"; [[ -n "${1:-}" ]] || die "uso: crux task goal \"<texto>\""; motor set --file "$f" --section Objetivo --text "$1"; ok "objetivo anotado" ;;
  scope) f="$(fichero_actual)"; [[ -n "${1:-}" ]] || die "uso: crux task scope \"<texto>\""; motor set --file "$f" --section Alcance --text "$1"; ok "alcance anotado" ;;
  plan)
    f="$(fichero_actual)"
    [[ -f "${1:-}" ]] || die "uso: crux task plan <fichero con el plan aprobado>"
    motor set --file "$f" --section Plan --text "$(cat "$1")"
    motor status --file "$f" --to planned
    ok "plan volcado al registro"
    ;;
  add)
    # Varios pasos en una llamada: el plan sale de una vez, y anotarlo de uno
    # en uno era lo que más llamadas añadía al ciclo.
    f="$(fichero_actual)"; [[ -n "${1:-}" ]] || die "uso: crux task add \"<paso>\" [\"<paso>\"...]"
    for paso in "$@"; do
      id="$(motor add --file "$f" --text "$paso")"
      ok "$id $paso"
    done
    ;;
  "done")
    f="$(fichero_actual)"; [[ -n "${1:-}" ]] || die "uso: crux task done <Tn> [\"evidencia\"]"
    motor "done" --file "$f" --id "$1" ${2:+--evidence "$2"}
    ok "$1 hecho"
    [[ -n "${2:-}" ]] || info "sin evidencia: un paso marcado sin lo que lo prueba es una declaración"
    ;;
  next)  f="$(fichero_actual)"; [[ -n "${1:-}" ]] || die "uso: crux task next \"<texto>\""; motor set --file "$f" --section "Siguiente paso" --text "$1"; ok "siguiente paso anotado" ;;
  note)
    f="$(fichero_actual)"
    [[ -n "${1:-}" && "$1" != --* ]] || die "uso: crux task note \"<qué>\" [--why \"…\"] [--where \"…\"] [--learned \"…\"]"
    que="$1"; shift
    extra=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --why|--where|--learned)
          [[ -n "${2:-}" && "$2" != --* ]] || die "$1 necesita un texto"
          extra+=("$1" "$2"); shift 2 ;;
        *) die "opción desconocida: $1" ;;
      esac
    done
    motor note --file "$f" --text "$que" ${extra[@]+"${extra[@]}"}
    if [[ " ${extra[*]:-} " == *" --why "* ]]; then
      ok "decisión anotada: al archivar la tarea pasa a las notas del repo en el docs repo"
    else
      ok "anotado en desviaciones y decisiones"
      info "si es una decisión que debe durar, añade su porqué: --why \"…\""
    fi
    ;;
  status)
    f="$(fichero_actual)"; [[ -n "${1:-}" ]] || die "uso: crux task status <estado> [--force]"
    motor status --file "$f" --to "$1" ${2:+"$2"}
    ok "estado: $(awk -F': ' '/^status:/{print $2; exit}' "$f")"
    ;;
  archive)
    f="$(fichero_actual)"
    [[ -f "$f" ]] || die "no existe el registro $f"
    promote_decisions "$f"
    destino="$(motor archive --file "$f")"
    ok "tarea archivada: $destino"
    ;;
  list)
    todos=0 archivadas=0
    for a in "$@"; do
      case "$a" in --all) todos=1 ;; --done) archivadas=1 ;; esac
    done
    if [[ $archivadas -eq 1 ]]; then
      hay=0
      for f in "$TASKS"/*/done/*.md; do
        [[ -f "$f" ]] || continue
        hay=1
        printf '%-12s %s\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(basename "$f" .md)"
      done
      [[ $hay -eq 1 ]] || echo "sin tareas archivadas"
      exit 0
    fi
    [[ -d "$TASKS" ]] || { echo "sin tareas abiertas"; exit 0; }
    proyecto=""
    if [[ $todos -eq 0 ]]; then
      aqui="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      [[ -n "$aqui" ]] && proyecto="$(project_name_for "$aqui")"
    fi
    hay=0
    for f in "$TASKS"/*/*.md; do
      [[ -f "$f" ]] || continue
      p="$(basename "$(dirname "$f")")"
      [[ -z "$proyecto" || "$p" == "$proyecto" ]] || continue
      IFS=$'\x1f' read -r tarea estado pasos siguiente < <(motor summary --file "$f")
      [[ "$estado" == "closed" ]] && continue
      hay=1
      printf '%-28s %-12s %-6s %s\n' "$p/$tarea" "$estado" "$pasos" "${siguiente:0:70}"
    done
    [[ $hay -eq 1 ]] || echo "sin tareas abiertas${proyecto:+ en $proyecto (todas: crux task list --all)}"
    ;;
  -h|--help|help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" ;;
  *) die "subcomando desconocido: $op — 'crux task --help'" ;;
esac
