#!/usr/bin/env bash
# crux bootstrap — dejar una máquina nueva lista para trabajar.
#
#   crux bootstrap [--owner <owner>] [--parent <dir>] [--only a,b] [--dry-run]
#
# Verifica la máquina, descubre todos los proyectos y los trae. Es `crux clone`
# repetido, más las dos cosas que en una máquina virgen no tienes: saber qué
# proyectos existen y saber qué te falta instalar.
#
# La lista sale del remoto, no de un inventario en un fichero. Un inventario
# escrito a mano se desactualiza en cuanto creas un proyecto, y esto se usa
# justamente el día en que no te acuerdas de cuáles tenías. Es el mismo criterio
# que ya usa `crux clone` para la lista de repos de un proyecto: sale del
# contrato.
#
# Lo que NO hace, y a propósito: mover credenciales. Las claves SSH, los tokens
# y los secretos no se copian de una máquina a otra por una herramienta. Al
# terminar dice qué necesita cada proyecto y dónde está documentado.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

OWNER=""
PARENT="$(projects_root)"
SOLO=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)   OWNER="$2"; shift 2 ;;
    --parent)  PARENT="$2"; shift 2 ;;
    --only)    SOLO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "opción desconocida: $1" ;;
  esac
done

# --- 1. La máquina, antes que nada -------------------------------------------
#
# Clonar veinte repos para descubrir después que falta node es la peor forma de
# enterarse. El doctor de máquina ya distingue lo imprescindible de lo que solo
# limita algunas skills, así que aquí solo se decide si se sigue.

echo "1. la máquina"
echo
if ! bash "$CRUX_HOME/bin/machine.sh"; then
  echo
  die "arregla los errores de arriba y vuelve a lanzarlo"
fi

# --- 2. Quién eres en el remoto ----------------------------------------------

command -v gh >/dev/null 2>&1 \
  || die "hace falta gh para descubrir los proyectos — instálalo, o clónalos uno a uno con 'crux clone'"
gh auth status >/dev/null 2>&1 \
  || die "gh sin autenticar — 'gh auth login' y vuelve"

owner_por_defecto() {
  # Sale del mismo sitio del que ya salen las URL de clonado, así que no hay dos
  # fuentes de verdad que puedan discrepar.
  local remoto=""
  local cfg="${CRUX_CONFIG:-$HOME/.crux/config}"
  [[ -f "$cfg" ]] \
    && remoto="$(grep -E '^CRUX_REMOTE=' "$cfg" | cut -d= -f2- | tr -d '"')"
  if [[ "$remoto" =~ github\.com[:/]([^/]+)/ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  gh api user --jq .login 2>/dev/null || true
}

[[ -n "$OWNER" ]] || OWNER="$(owner_por_defecto)"
[[ -n "$OWNER" ]] || die "no sé bajo qué cuenta buscar — pásalo con --owner"

# --- 3. Qué proyectos hay ----------------------------------------------------
#
# Un proyecto es un repo `<algo>-docs` que lleva contrato. Lo segundo importa:
# sin comprobarlo, cualquier repo que acabe en -docs entraría como proyecto.

echo
echo "2. proyectos de $OWNER"
echo

todos_los_repos="$(gh repo list "$OWNER" --limit 300 --json name --jq '.[].name' 2>/dev/null | sort -u)"
candidatos="$(echo "$todos_los_repos" | grep -E -- '-docs$' | sed -E 's/-docs$//' | sort -u)"

if [[ -n "$SOLO" ]]; then
  filtro="$(echo "$SOLO" | tr ',' '\n' | sed '/^$/d' | sort -u)"
  candidatos="$(comm -12 <(echo "$candidatos") <(echo "$filtro"))"
fi

[[ -n "$candidatos" ]] || die "ningún repo *-docs bajo $OWNER"

proyectos=()
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  if gh api "repos/$OWNER/$p-docs/contents/crux.json" --silent >/dev/null 2>&1; then
    proyectos+=("$p")
    ok "$p"
  else
    info "$p-docs sin contrato — no es un proyecto crux, se salta"
  fi
done <<< "$candidatos"

[[ ${#proyectos[@]} -gt 0 ]] || die "ninguno lleva contrato"

if [[ $DRY -eq 1 ]]; then
  echo
  echo "traería ${#proyectos[@]} proyectos a $PARENT: ${proyectos[*]}"
  exit 0
fi

# --- 4. Traerlos -------------------------------------------------------------

echo
echo "3. trayendo ${#proyectos[@]} proyectos a $PARENT"

traidos=(); fallidos=()
for p in "${proyectos[@]}"; do
  echo
  echo "── $p"
  if bash "$CRUX_HOME/bin/clone.sh" "$p" --parent "$PARENT"; then
    traidos+=("$p")
  else
    fallidos+=("$p")
  fi
done

# --- 5. Lo que sigue faltando ------------------------------------------------
#
# Un entorno con todo el código y sin credenciales no está listo, y el peor
# final posible es uno que diga que sí lo está.

echo
echo "4. lo que falta"
echo

ok "${#traidos[@]} proyectos en $PARENT"
if [[ ${#fallidos[@]} -gt 0 ]]; then
  err "no pude con: ${fallidos[*]}"
fi

con_credenciales=()
for p in "${traidos[@]}"; do
  doc="$PARENT/$p/$p-docs/operations/machine-onboarding.md"
  [[ -f "$doc" ]] && con_credenciales+=("$p")
done

if [[ ${#con_credenciales[@]} -gt 0 ]]; then
  echo
  warn "credenciales por poner a mano — no se copian de una máquina a otra:"
  for p in "${con_credenciales[@]}"; do
    info "$p  →  $p/$p-docs/operations/machine-onboarding.md"
  done
fi

# Un repo del remoto que no pertenece a ningún proyecto no lo trae esto, y
# callárselo sería peor que no traerlo: te vas creyendo que está todo.
sueltos=()
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  encontrado=0
  for d in "$PARENT"/*/"$r"; do
    [[ -d "$d" ]] && { encontrado=1; break; }
  done
  [[ $encontrado -eq 0 ]] && sueltos+=("$r")
done <<< "$todos_los_repos"

if [[ ${#sueltos[@]} -gt 0 ]]; then
  echo
  warn "repos de $OWNER que no son de ningún proyecto, así que no vienen aquí:"
  info "${sueltos[*]}"
  info "si alguno hace falta: git clone, o 'crux adopt' si merece ser un proyecto"
fi

echo
info "'crux status' para ver cómo quedó todo"
exit $(( ${#fallidos[@]} > 0 ? 1 : 0 ))
