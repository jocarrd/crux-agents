#!/usr/bin/env bash
# crux memory — qué sabe el agente que todavía no sabe el proyecto.
#
#   crux memory           las memorias por tipo, y las que faltan en git
#   crux memory --brief   una línea con lo que falta, para engancharlo a un hook
#   crux memory --check   silencioso; sale 1 si alguna debería estar promovida
#
# El estándar reparte por a quién pertenece cada cosa: `project` y `reference`
# son del proyecto y van a git; `user` y `feedback` son de la persona y se
# quedan en local. La regla estaba escrita desde el primer día y no la
# comprobaba nadie, así que había análisis de proyecto viviendo en una sola
# máquina. Esto es lo que la convierte en verificable.
#
# No decide dónde va cada memoria ni la mueve: eso es una decisión, y las
# decisiones no las toma un hook. Dice qué falta y en qué docs repo va.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

CHECK=false
BRIEF=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    --brief) BRIEF=true ;;
    *) die "uso: crux memory [--brief|--check]" ;;
  esac
done

# --- Qué proyecto es cada ámbito ---------------------------------------------
#
# Los agentes nombran el ámbito de una memoria con la ruta de trabajo y los
# separadores cambiados por guiones. Deshacer eso es ambiguo —un proyecto puede
# llevar guiones—, pero hacerlo no lo es: se calcula el nombre de cada proyecto
# que existe y se busca cuál encaja. Gana el más largo, para que un proyecto no
# se lleve las memorias de otro cuyo nombre empiece igual.

raiz="$(projects_root)"

# Sin raíz de proyectos toda memoria saldría "sin proyecto", que se lee igual
# que "no pertenece a ninguno" y no lo es: se dice, y el listado sigue porque
# detectar la fuga no depende de saber su destino.
if [[ ! -d "$raiz" ]] && ! $CHECK && ! $BRIEF; then
  warn "la raíz de proyectos no existe: $raiz"
  info "sin ella no se puede decir a qué docs repo pertenece cada memoria"
  echo
fi

slug_de() { printf '%s' "$1" | tr '/.' '-'; }

proyecto_de_ambito() {
  local ambito="$1" mejor="" mejor_len=0 dir nombre slug
  for dir in "$raiz"/*/; do
    [[ -d "$dir" ]] || continue
    nombre="$(basename "$dir")"
    [[ -d "$raiz/$nombre/$nombre-docs" ]] || continue
    slug="$(slug_de "$raiz/$nombre")"
    if [[ "$ambito" == "$slug" || "$ambito" == "$slug"-* ]] && (( ${#slug} > mejor_len )); then
      mejor="$nombre"; mejor_len=${#slug}
    fi
  done
  echo "$mejor"
}

# --- Recolección --------------------------------------------------------------

lineas=""
adaptadores=0
for scan in "$CRUX_HOME"/adapters/*/memory-scan.sh; do
  [[ -f "$scan" ]] || continue
  adaptadores=$((adaptadores + 1))
  salida="$(bash "$scan")" || die "el adaptador $scan falló; no se puede afirmar que no haya memorias sin promover"
  [[ -n "$salida" ]] && lineas+="$salida"$'\n'
done

(( adaptadores > 0 )) || die "no hay ningún adaptador de memoria en $CRUX_HOME/adapters"

total=0; ambitos=""; sin_promover=""; sin_tipo=""; ilegibles=""
n_user=0; n_feedback=0; n_ambitos=0

while IFS=$'\t' read -r tipo ambito ruta; do
  [[ -n "${tipo:-}" ]] || continue
  total=$((total + 1))
  [[ "$ambitos" == *"|$ambito|"* ]] || { ambitos+="|$ambito|"; n_ambitos=$((n_ambitos + 1)); }
  nombre="$(basename "$ruta" .md)"

  case "$tipo" in
    project|reference)
      proyecto="$(proyecto_de_ambito "$ambito")"
      # Sin proyecto no se adivina: se dice de qué ámbito salió, que es el dato
      # que permite decidir. Deducirlo del nombre del fichero acertaría a veces
      # y colocaría documentación en el proyecto equivocado el resto.
      destino="${proyecto:+$proyecto-docs}"
      sin_promover+="$tipo	$nombre	${destino:-ámbito $ambito}	$ruta"$'\n'
      ;;
    user)     n_user=$((n_user + 1)) ;;
    feedback) n_feedback=$((n_feedback + 1)) ;;
    '?')
      sin_tipo+="$nombre	$ruta"$'\n'
      ;;
    '!')
      ilegibles+="$ruta"$'\n'
      ;;
    *)
      sin_tipo+="$nombre ($tipo)	$ruta"$'\n'
      ;;
  esac
done <<< "$lineas"

# Un fichero que está y no se puede leer no se cuenta como "nada que promover":
# ese es justo el fallo que parece funcionar.
if [[ -n "$ilegibles" ]]; then
  err "hay memorias que no se pueden leer:"
  printf '%s' "$ilegibles" | sed 's/^/      /'
  exit 1
fi

n_sin_promover=0
[[ -n "$sin_promover" ]] && n_sin_promover=$(grep -c . <<< "${sin_promover%$'\n'}")

if $CHECK; then
  (( n_sin_promover > 0 )) && exit 1
  exit 0
fi

if $BRIEF; then
  (( n_sin_promover > 0 )) || exit 0
  muestra="$(cut -f2 <<< "${sin_promover%$'\n'}" | head -3 |
    awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')"
  (( n_sin_promover > 3 )) && muestra+=", +$((n_sin_promover - 3))"
  warn "$n_sin_promover memorias de proyecto viven solo en esta máquina: $muestra"
  info "crux memory las lista · /promote-to-docs las coloca en git"
  exit 1
fi

# --- Reporte -------------------------------------------------------------------

echo "memorias del agente — $total en $n_ambitos ámbito(s)"
echo

if (( n_sin_promover > 0 )); then
  warn "sin promover ($n_sin_promover)"
  echo
  printf '%s' "$sin_promover" | while IFS=$'\t' read -r tipo nombre destino _; do
    printf '      %-10s %-34s → %s\n' "$tipo" "$nombre" "$destino"
  done
  echo
  info "van a git: en local no sobreviven al cambio de máquina."
  info "/promote-to-docs las coloca en el docs repo y borra la copia local."
  if [[ "$sin_promover" == *"	ámbito "* ]]; then
    info "las que salen con un ámbito en vez de un docs repo vienen de un"
    info "directorio que no es ningún proyecto: el destino lo decides tú."
  fi
  echo
else
  ok "nada sin promover"
  echo
fi

if [[ -n "$sin_tipo" ]]; then
  warn "sin tipo declarado ($(grep -c . <<< "${sin_tipo%$'\n'}"))"
  printf '%s' "$sin_tipo" | while IFS=$'\t' read -r nombre _; do
    printf '      %s\n' "$nombre"
  done
  info "no se les asume ninguno: declara el tipo o bórralas."
  echo
fi

resumen=""
(( n_user > 0 )) && resumen+="$n_user user"
(( n_feedback > 0 )) && resumen+="${resumen:+ · }$n_feedback feedback"
[[ -n "$resumen" ]] && info "locales por diseño: $resumen"

exit 0
