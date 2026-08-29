#!/usr/bin/env bash
# Devuelve cada fichero de entorno a su sitio, leyendo el mapa de al lado.
#
#   ./restaurar.sh                     dice qué haría, sin tocar nada
#   ./restaurar.sh --hazlo             lo copia
#   ./restaurar.sh /ruta/proyecto --hazlo   si el proyecto no está donde se espera
#
# No sobreescribe nunca: perder un valor que solo estaba en el destino es peor
# que copiar de menos.

set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPA="$AQUI/mapa.txt"
[[ -f "$MAPA" ]] || { echo "falta mapa.txt junto a este script"; exit 1; }

NOMBRE="$(head -1 "$MAPA" | sed -n 's/^# proyecto: //p')"
HAZLO=0; DESTINO=""
for a in "$@"; do
  if [[ "$a" == "--hazlo" ]]; then HAZLO=1; else DESTINO="$a"; fi
done

# La raíz en ESTA máquina, que no tiene por qué ser la de la que salió la carpeta.
PROYECTO="${DESTINO:-${CRUX_PROJECTS_DIR:-$HOME/Proyectos}/$NOMBRE}"
[[ -d "$PROYECTO" ]] || {
  echo "no encuentro el proyecto en $PROYECTO"
  echo "pásalo como argumento: ./restaurar.sh /ruta/al/proyecto --hazlo"
  exit 1
}
echo "restaurando en $PROYECTO"
echo

puestos=0; saltados=0; sin_repo=0
while IFS='|' read -r origen destino; do
  [[ -n "$origen" && "$origen" != \#* ]] || continue
  src="$AQUI/$origen"; dst="$PROYECTO/$destino"
  [[ -f "$src" ]] || { echo "  falta aquí   $origen"; continue; }
  if [[ ! -d "$(dirname "$dst")" ]]; then
    echo "  sin repo     $destino"; sin_repo=$((sin_repo+1)); continue
  fi
  if [[ -f "$dst" ]]; then
    echo "  ya existe    $destino"; saltados=$((saltados+1)); continue
  fi
  if [[ $HAZLO -eq 1 ]]; then
    cp -p "$src" "$dst"; chmod 600 "$dst"; echo "  puesto       $destino"
  else
    echo "  pondría      $destino"
  fi
  puestos=$((puestos+1))
done < "$MAPA"

echo
if [[ $HAZLO -eq 1 ]]; then
  echo "$puestos puestos, $saltados ya estaban, $sin_repo sin repo clonado"
  echo "cuando termines, borra esta carpeta"
else
  echo "$puestos por poner, $saltados ya están, $sin_repo sin repo clonado"
  echo "para hacerlo de verdad: ./restaurar.sh --hazlo"
fi
