#!/usr/bin/env bash
# Contrasta el diff con las convenciones escritas del proyecto.
#
#   conventions.sh [base]    por defecto compara con HEAD (staged + sin stagear)
#
# La puerta existe porque tener las convenciones escritas no basta: se leen
# después de escribir el código, cuando ya solo sirven para reordenar. Esto no
# juzga si el diff "sigue el estilo" —un juicio así siempre sale que sí—; señala
# líneas concretas y deja el veredicto a quien las mire.
#
# Las señales universales van aquí. Las de cada proyecto se declaran en su
# crux.json, porque el kernel no sabe —ni debe saber— cómo escribe cada uno.

set -uo pipefail

BASE="${1:-HEAD}"

find_docs_repo() {
  local dir
  for dir in . .. ../*/ ; do
    [[ -f "$dir/crux.json" ]] && { (cd "$dir" && pwd); return; }
  done
}

DOCS="$(find_docs_repo)"

files="$(
  git diff --name-only --diff-filter=d "$BASE" 2>/dev/null
  git diff --cached --name-only --diff-filter=d 2>/dev/null
)"
files="$(echo "$files" | sort -u | grep -v '^$' || true)"
code="$(echo "$files" | grep -E '\.(ts|tsx|js|jsx|mjs|rs|go|py|rb|java|kt|swift|php)$' \
  | grep -vE '\.(test|spec)\.' || true)"

if [[ -z "$code" ]]; then
  echo "convenciones: no aplica — el diff no toca código"
  exit 0
fi

echo "== Lectura obligatoria =="
if [[ -n "$DOCS" && -d "$DOCS/conventions" ]]; then
  for f in "$DOCS"/conventions/*.md; do
    [[ -e "$f" ]] || continue
    echo "  $f"
  done
  for repo_doc in $(echo "$code" | sed 's|/.*||' | sort -u); do
    [[ -f "$DOCS/repos/$repo_doc/conventions.md" ]] && echo "  $DOCS/repos/$repo_doc/conventions.md"
  done
else
  echo "  (no encuentro el repo de documentación — busca conventions/ a mano)"
fi

added() { git diff --unified=0 "$BASE" -- "$@" 2>/dev/null; git diff --cached --unified=0 -- "$@" 2>/dev/null; }

echo
echo "== Señales =="
hallazgos=0

# --- Universales -------------------------------------------------------------

repes="$(added $code | grep '^+' | grep -v '^+++' \
  | grep -oE "'[A-Za-z][A-Za-z0-9 _-]{2,40}'|\"[A-Za-z][A-Za-z0-9 _-]{2,40}\"" \
  | grep -vE "use (client|server)" | sort | uniq -c | sort -rn \
  | awk '$1 >= 3 {print "  " $1 "x  " substr($0, index($0,$2))}' | head -8)"
if [[ -n "$repes" ]]; then
  echo "literales repetidos — ¿diccionario?"
  echo "$repes"
  hallazgos=$((hallazgos+1))
fi

# El fallo caro: las dos copias divergen y no se nota hasta que una pantalla
# enseña un valor que la otra no conoce.
nuevos="$(added $code | grep '^+' \
  | grep -oE '^\+ *(export )?(const|static|pub const) [A-Z][A-Z0-9_]{2,} *[:=]' \
  | grep -oE '[A-Z][A-Z0-9_]{2,}' | sort -u)"
for n in $nuevos; do
  otros="$(git grep -lE "(export |pub |static )?const $n\b" 2>/dev/null \
    | grep -vFx -f <(echo "$code") | head -3)"
  if [[ -n "$otros" ]]; then
    echo "$n ya existe en el repo — ¿reutilizar en vez de redeclarar?"
    echo "$otros" | sed 's/^/  /'
    hallazgos=$((hallazgos+1))
  fi
done

coment="$(added $code | grep -cE '^\+\s*(//|#)[^!]' || true)"
if [[ "$coment" -gt 0 ]]; then
  echo "comentarios nuevos: $coment — ¿explican un porqué que no se deduce leyendo?"
  hallazgos=$((hallazgos+1))
fi

# --- Declaradas por el proyecto ----------------------------------------------
# {name, files, forbid}: en los ficheros que casan con el glob, ninguna línea
# añadida debe casar con el patrón.

if [[ -n "$DOCS" && -f "$DOCS/crux.json" ]] && command -v node >/dev/null 2>&1; then
  checks="$(node -e '
    const fs = require("fs")
    let c
    try { c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) }
    catch (e) { console.error("crux.json ilegible: " + e.message); process.exit(2) }
    for (const chk of c.conventions?.checks ?? []) {
      if (!chk.files || !chk.forbid) continue
      console.log([chk.name ?? chk.files, chk.files, chk.forbid].join("\t"))
    }
  ' "$DOCS/crux.json")" || {
    echo "no puedo leer las convenciones declaradas en $DOCS/crux.json — arréglalo antes de seguir"
    exit 1
  }

  # Se lee una vez: dentro del bucle sería una tubería con `grep -q`, que cierra
  # la salida y mata a `git` con SIGPIPE; con `pipefail` eso es un fallo, y el
  # repo grande se saltaba en silencio todas las reglas.
  tracked="$(git ls-files)"

  while IFS=$'\t' read -r name glob forbid; do
    [[ -z "$glob" ]] && continue
    # Sin un solo fichero así, la regla está declarada pero el repo no la usa.
    grep -qE "${glob//\*/.*}$" <<< "$tracked" || continue
    culpables=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      # El glob del contrato tiene que expandirse: entrecomillarlo lo volvería
      # una comparación literal y ninguna regla casaría nunca.
      # shellcheck disable=SC2053
      [[ "$f" == $glob ]] || continue
      lineas="$(added "$f" | grep '^+' || true)"
      grep -qE "$forbid" <<< "$lineas" && culpables+="  $f"$'\n'
    done <<< "$code"
    if [[ -n "$culpables" ]]; then
      echo "$name"
      printf '%s' "$culpables"
      hallazgos=$((hallazgos+1))
    fi
  done <<< "$checks"
fi

echo
[[ "$hallazgos" -eq 0 ]] && echo "sin señales — la puerta la cierra igualmente quien lee las convenciones"
exit 0
