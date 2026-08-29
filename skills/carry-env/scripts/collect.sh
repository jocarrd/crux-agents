#!/usr/bin/env bash
# Reúne los ficheros de entorno de un proyecto en una carpeta que puedas llevarte.
#
#   collect.sh [--project <dir>] [--out <dir>]
#
# Los copia con `cp` y no los abre nunca: si un agente ejecuta esto, ningún valor
# entra en su contexto ni queda en la transcripción de la sesión.
#
# Deja el mapa de a dónde va cada uno y el script que los devuelve a su sitio.
# Doce ficheros con nombres planos y ninguna pista de su ruta no sirven de nada
# dentro de tres meses, que es justo cuando se usan.

set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROYECTO="$PWD"
SALIDA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROYECTO="$2"; shift 2 ;;
    --out)     SALIDA="$2"; shift 2 ;;
    *) echo "opción desconocida: $1" >&2; exit 1 ;;
  esac
done

PROYECTO="$(cd "$PROYECTO" && pwd)"

# El ancla es la raíz del proyecto, no el repo desde el que se llame. Apuntar
# esto a un repo deja un paquete inservible de dos maneras a la vez: el mapa
# guarda rutas relativas al repo, y el paquete dice llamarse como él, así que al
# restaurar se busca <raíz>/<repo> — que no existe — en vez de <raíz>/<proyecto>.
# El fallo no se ve al reunirlos: se ve meses después, en la máquina nueva.
docs_repo() {
  local probe="$1" d
  while [[ "$probe" != "/" ]]; do
    [[ -f "$probe/crux.json" ]] && { echo "$probe"; return 0; }
    for d in "$probe"/*-docs; do
      [[ -f "$d/crux.json" ]] && { echo "$d"; return 0; }
    done
    probe="$(dirname "$probe")"
  done
  return 1
}

NOMBRE=""
if DOCS="$(docs_repo "$PROYECTO")"; then
  RAIZ="$(dirname "$DOCS")"
  if [[ "$RAIZ" != "$PROYECTO" ]]; then
    echo "$(basename "$PROYECTO") es un repo de $(basename "$RAIZ"): reúno el proyecto entero"
    echo "desde $RAIZ, que es lo que la otra máquina sabrá encontrar."
    echo
    PROYECTO="$RAIZ"
  fi
  # El nombre declarado manda sobre el del directorio: es el que usa
  # `crux bootstrap` para crear la carpeta en la máquina de destino.
  NOMBRE="$(sed -n 's/.*"project"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DOCS/crux.json" | head -1)"
fi
NOMBRE="${NOMBRE:-$(basename "$PROYECTO")}"
SALIDA="${SALIDA:-$HOME/entornos-$NOMBRE}"

# Lo que se excluye, y por qué:
#
#   *-ws-*                  copias que genera `crux workspace` del repo
#                           principal. Son derivadas, y restaurarlas encima de
#                           las buenas es meter la pata.
#   .next, dist, build, out artefactos de construcción: el mismo fichero copiado
#                           por la herramienta. Restaurar uno no arregla nada.
#   *.example y compañía    plantillas sin valores; ya están en el repo.
buscar() {
  find "$PROYECTO" -maxdepth 6 \
    \( -name ".env" -o -name ".env.*" \) \
    -not -path "*/node_modules/*" -not -path "*/.git/*" \
    -not -path "*-ws-*" \
    -not -path "*/.next/*" -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/out/*" \
    -not -name "*.example" -not -name "*.sample" -not -name "*.template" \
    -type f 2>/dev/null | sort
}

# .env → sin sufijo; .env.local → .local. Si el fichero está anidado dentro del
# repo, el directorio que lo contiene entra en el nombre: si no, el .env de la
# raíz y el de un servicio de dentro se pisarían.
nombre_plano() {
  local rel="${1#$PROYECTO/}"
  local variante; variante="$(basename "$1")"; variante="${variante#.env}"

  # Un fichero en la raíz del proyecto no tiene repo del que tomar el nombre.
  # Sin esto se toma `.env` por nombre de repo y sale `.env..env.`, que es justo
  # lo contrario de para lo que están estos nombres: decir de dónde salió.
  [[ "$rel" == */* ]] || { echo ".env${variante}"; return; }

  local repo="${rel%%/*}"
  local dir; dir="$(dirname "$rel")"
  local sufijo=""
  local hoja; hoja="$(basename "$dir")"
  [[ "$dir" != "$repo" && "$hoja" != "$repo" ]] && sufijo=".$hoja"
  echo ".env.${repo}${sufijo}${variante}"
}

mapfile -t FICHEROS < <(buscar)
[[ ${#FICHEROS[@]} -gt 0 ]] || { echo "ningún fichero de entorno bajo $PROYECTO"; exit 1; }

rm -rf "$SALIDA"; mkdir -p "$SALIDA"; chmod 700 "$SALIDA"

echo "# proyecto: $NOMBRE" > "$SALIDA/mapa.txt"
for f in "${FICHEROS[@]}"; do
  n="$(nombre_plano "$f")"
  cp -p "$f" "$SALIDA/$n"
  chmod 600 "$SALIDA/$n"
  echo "$n|${f#$PROYECTO/}" >> "$SALIDA/mapa.txt"
  printf "  ok   %-44s ← %s\n" "$n" "${f#$PROYECTO/}"
done

cp "$AQUI/restaurar.sh" "$SALIDA/restaurar.sh"
chmod 700 "$SALIDA/restaurar.sh"

{
  echo "# Entornos de $NOMBRE — copia para otra máquina"
  echo
  echo "**Aquí no hay ningún secreto**: este fichero solo dice qué va dónde."
  echo
  echo "## Antes de nada"
  echo
  echo "La carpeta lleva claves y tokens en claro. No la dejes donde se sincronice"
  echo "sola, no la enseñes en una pantalla compartida, y bórrala en cuanto acabes"
  echo "de restaurar."
  echo
  echo "## Cómo se restaura"
  echo
  echo '```bash'
  echo "./restaurar.sh           # dice qué haría, sin tocar nada"
  echo "./restaurar.sh --hazlo   # lo copia a su sitio"
  echo '```'
  echo
  echo "Busca el proyecto en \`~/Proyectos/$NOMBRE\`; si está en otro sitio, pásalo"
  echo "como argumento. Nunca sobreescribe: si el destino existe lo salta y lo dice."
  echo
  echo "## Qué va dónde"
  echo
  echo "| Fichero | Destino, relativo a la raíz del proyecto |"
  echo "| ------- | ---------------------------------------- |"
  while IFS='|' read -r n d; do
    [[ -n "$n" && "$n" != \#* ]] && echo "| \`$n\` | \`$d\` |"
  done < "$SALIDA/mapa.txt"
  echo
  echo "## Lo que NO está aquí"
  echo
  echo "**Nada del servidor.** Los ficheros de entorno de producción viven donde"
  echo "corre el servicio; esto es para trabajar en local."
  echo
  echo "**Nada personal y regenerable**: claves SSH, sesiones de CLI, tokens de"
  echo "registro, OAuth. Eso se genera en cada máquina y no se copia — copiarlo es"
  echo "peor, porque un token que viaja es un token que ya no sabes dónde ha estado."
  echo
  echo "**Ni copias de espacios de trabajo ni artefactos de construcción**, que son"
  echo "derivados del repo principal."
} > "$SALIDA/RESTAURAR.md"

echo
echo "${#FICHEROS[@]} ficheros en $SALIDA (carpeta 0700, ficheros 0600)"
echo "el mapa está en RESTAURAR.md y el camino de vuelta en restaurar.sh"
