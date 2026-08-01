#!/usr/bin/env bash
# Hook de git (commit-msg). Lo copia `crux hooks install`.
#
# El estándar pide los mensajes de commit en inglés desde el primer día, y el
# historial de este kernel estaba entero en español: una regla que nadie
# comprueba es una recomendación.
#
# Detecta por palabras funcionales que no existen en inglés, y exige dos
# apariciones. Con una sola, un nombre propio —"Los Angeles", "Los Angeles"— daría
# falso positivo, y un hook que se equivoca se desactiva a la semana.
#
# Calibrado contra el historial real de este repo: caza 24 de sus 27 mensajes.
# Los tres que se le escapan son títulos casi sin prosa. Es una red para el
# descuido, no un detector de idioma: la disciplina la pone quien escribe.

set -u

[[ -f "${1:-}" ]] || exit 0

# Las líneas de comentario son de git, y lo que va en backticks es código: ni
# una cosa ni la otra dicen en qué idioma está escrito el mensaje.
msg="$(sed -e '/^#/d' -e 's/`[^`]*`//g' "$1" | tr '[:upper:]' '[:lower:]')"

pistas="$(printf '%s' "$msg" | grep -owE \
  'que|para|porque|cuando|esto|esta|este|esa|ese|del|las|los|una|unos|unas|pero|aunque|desde|tambien|segun|asi|muy|cada|donde|hasta|mientras|siempre|nunca|antes|despues|ahora|hace|hacer|tiene|tener|puede|debe|deja|pasa|sigue|vuelve|el|la|al|un|es|son|ser|su|sus|ni|se|de|en|por')"

[[ "$(printf '%s' "$pistas" | grep -c .)" -lt 2 ]] && exit 0
pistas="$(printf '%s' "$pistas" | sort -u)"

echo
echo "mensaje de commit en español — el estándar los pide en inglés"
echo
echo "  pistas: $(printf '%s' "$pistas" | tr '\n' ' ')"
echo
echo "La documentación va en el idioma del proyecto; los nombres, las ramas y"
echo "los commits, en inglés. Reescríbelo, o salta con: git commit --no-verify"
exit 1
