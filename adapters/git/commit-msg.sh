#!/usr/bin/env bash
# Hook de git (commit-msg). Lo copia `crux hooks install`.
#
# Una regla que nadie comprueba es una recomendación. El estándar pedía los
# mensajes en inglés desde el primer día y el historial de este kernel estaba
# entero en español; pedía no firmar con la herramienta y la firma acabó en la
# propuesta de un cliente.
#
# Tiene dos alcances, y la diferencia importa:
#
#   full       repo nuestro: se comprueban nuestras convenciones
#   signature  repo de cliente: solo se quita la firma de la herramienta
#
# En el repo de un cliente, el idioma y el formato de su historial son suyos.
# Imponerles nuestras convenciones sería exactamente el mismo error que el
# perfil client-repo existe para evitar. Lo que no es suyo ni nuestro es la
# firma del agente: esa no debe aparecer en ningún sitio.
SCOPE="${CRUX_COMMIT_MSG_SCOPE:-full}"
IDIOMA="${CRUX_COMMIT_MSG_LANG:-en}"

set -u

[[ -f "${1:-}" ]] || exit 0

# --- Firma de la herramienta (en todos los repos) ----------------------------
#
# Se borra en vez de rechazar el commit: el agente la añade porque su propio
# entorno se lo pide, así que bloquear obliga a reescribir un mensaje que por lo
# demás está bien, y el descuido vuelve en el commit siguiente.
FIRMA='^[[:space:]]*(co-authored-by:[[:space:]]*(claude|ona|copilot|cursor|devin|gemini)|claude-session:|(🤖[[:space:]]*)?(generated|generado) with)'
if grep -qiE "$FIRMA" "$1"; then
  tmp="$(mktemp)"
  grep -viE "$FIRMA" "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$tmp"
  mv "$tmp" "$1"
  echo "crux: quitada la firma de la herramienta del mensaje de commit"
fi

[[ "$SCOPE" == "full" ]] || exit 0

# Un merge, un revert o un fixup no los redacta nadie: los genera git.
asunto="$(grep -v '^#' "$1" | grep -m1 . || true)"
case "$asunto" in
  Merge\ *|Revert\ *|fixup!\ *|squash!\ *|amend!\ *) exit 0 ;;
esac

# El detalle llega como un bloque de varias líneas: se indenta entero, no se
# parte por palabras.
rechazo() {
  echo; echo "$1"; echo
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/  /'
  echo
  echo "Reescríbelo, o salta con: git commit --no-verify"
  exit 1
}

# --- Conventional commits ----------------------------------------------------
#
# Los 97 commits del kernel lo cumplen salvo los 8 merges, ya exentos arriba.
TIPOS='feat|fix|chore|docs|refactor|test|style|perf|build|ci|revert'
if ! printf '%s' "$asunto" | grep -qE "^($TIPOS)(\([^)]+\))?!?: ."; then
  rechazo "el asunto no sigue conventional commits" \
    "$(printf '%s\n\ntipos: %s' "$asunto" "$TIPOS")"
fi

# Ni uno solo del historial empieza en mayúscula tras el prefijo: cuesta cero.
if printf '%s' "$asunto" | grep -qE "^($TIPOS)(\([^)]+\))?!?: [A-Z]"; then
  rechazo "el asunto empieza en mayúscula tras el prefijo" "$asunto"
fi

# --- Ancho del cuerpo --------------------------------------------------------
#
# 100 caracteres. Del historial real solo dos líneas se pasan, y por uno.
# Una línea sin espacios no se puede partir: una URL larga no es un descuido.
largas="$(grep -v '^#' "$1" | awk 'length($0)>100 && $0 ~ / / {print NR": "substr($0,1,60)"…"}')"
if [[ -n "$largas" ]]; then
  rechazo "hay líneas de más de 100 caracteres en el cuerpo" "$largas"
fi

# --- Idioma ------------------------------------------------------------------
#
# Detecta por palabras funcionales y por los verbos con que empieza un asunto en
# español (añade, arregla, quita…), que no existen en inglés, y exige dos
# apariciones. Con una sola, un nombre propio —"Los Angeles", "Los Angeles"— daría
# falso positivo, y un hook que se equivoca se desactiva a la semana.
#
# Las líneas de comentario son de git, y lo que va en backticks es código: ni
# una cosa ni la otra dicen en qué idioma está escrito el mensaje.
[[ "$IDIOMA" == "en" ]] || exit 0

msg="$(sed -e '/^#/d' -e 's/`[^`]*`//g' "$1" | tr '[:upper:]' '[:lower:]')"

pistas="$(printf '%s' "$msg" | grep -owE \
  'que|para|porque|cuando|esto|esta|este|esa|ese|del|las|los|una|unos|unas|pero|aunque|desde|tambien|segun|asi|muy|cada|donde|hasta|mientras|siempre|nunca|antes|despues|ahora|hace|hacer|tiene|tener|puede|debe|deja|pasa|sigue|vuelve|el|la|al|un|es|son|ser|su|sus|ni|se|de|en|por|añade|anade|arregla|corrige|quita|elimina|actualiza|mejora|cambia|mueve|evita|permite|crea|borra|sube|muestra|comprueba')"

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
