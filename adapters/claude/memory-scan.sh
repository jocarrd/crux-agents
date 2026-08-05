#!/usr/bin/env bash
# Adaptador de memoria — Claude Code.
#
# Lo que sabe este fichero y no sabe el kernel: dónde guarda este agente sus
# memorias y cómo declara el tipo de cada una.
#
# Emite una línea por memoria, separada por tabuladores:
#
#   <tipo>	<ámbito>	<ruta>
#
# El tipo es el que declara el frontmatter. `?` si no declara ninguno y `!` si
# el fichero está y no se puede leer: los dos casos los resuelve el kernel, y
# aquí no se inventa un valor por defecto para seguir adelante.
#
# El ámbito se emite tal como lo nombra el agente —la ruta de trabajo con los
# separadores cambiados por guiones— y sin decodificar. La vuelta atrás es
# ambigua en cuanto un proyecto lleva un guion en el nombre; quien conoce los
# proyectos que hay es el kernel, y la conversión que sí es unívoca es la suya.

set -uo pipefail

raiz="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
[[ -d "$raiz" ]] || exit 0

for dir in "$raiz"/*/memory; do
  [[ -d "$dir" ]] || continue
  ambito="$(basename "$(dirname "$dir")")"

  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || continue
    # El índice no es una memoria: es la tabla de contenidos de las demás.
    [[ "$(basename "$f")" == "MEMORY.md" ]] && continue

    if [[ ! -r "$f" ]]; then
      printf '!\t%s\t%s\n' "$ambito" "$f"
      continue
    fi

    tipo="$(awk '
      NR == 1 && $0 != "---" { exit }
      NR > 1 && $0 == "---" { exit }
      /^[[:space:]]*type:[[:space:]]*/ {
        sub(/^[[:space:]]*type:[[:space:]]*/, "")
        gsub(/[[:space:]"'"'"']/, "")
        print
        exit
      }
    ' "$f")"

    printf '%s\t%s\t%s\n' "${tipo:-?}" "$ambito" "$f"
  done
done
