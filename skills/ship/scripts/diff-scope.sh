#!/usr/bin/env bash
# Clasifica el diff para decidir qué puertas de `ship` hacen falta.
#
#   diff-scope.sh [base]     por defecto compara con HEAD (staged + sin stagear)
#
# Levantar el entorno y hacer QA cuesta minutos; hacerlo siempre es lo que
# consigue que la gente deje de pasar la puerta a las dos semanas. Esto separa
# los cambios que tocan superficie observable de los que no.

set -uo pipefail

BASE="${1:-HEAD}"
files="$(git diff --name-only "$BASE" 2>/dev/null; git diff --cached --name-only 2>/dev/null)"
files="$(echo "$files" | sort -u | grep -v '^$' || true)"

[[ -z "$files" ]] && { echo "scope: vacío"; echo "runtime: no"; exit 0; }

ui=0; api=0; data=0; tests=0; docs=0; deps=0; logica=0; integracion=0; other=0

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *_test.*|*.test.*|*.spec.*|*/tests/*|*/test/*|*/__tests__/*) tests=$((tests+1)); continue ;;
    *.md|*.mdx|*.txt|LICENSE|.gitignore) docs=$((docs+1)); continue ;;
    package.json|*/package.json|*lock.json|*lock.yaml|*.lock|go.mod|Cargo.toml|requirements*.txt|pyproject.toml)
      deps=$((deps+1)); continue ;;
    */migrations/*|*schema.prisma|*.sql) data=$((data+1)); continue ;;
  esac
  case "$f" in
    *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.html|*/components/*|*/pages/*|*/app/*|*/styles/*|*/public/*)
      ui=$((ui+1)) ;;
    */api/*|*/routes/*|*/controllers/*|*/handlers/*|*.controller.*|*/server/*|*/endpoints/*|*/infrastructure/http/*)
      api=$((api+1)) ;;
    # Arquitectura por capas: el dominio y los casos de uso son lógica pura y
    # los cubren los tests; lo que habla con el mundo vive en infraestructura.
    */domain/*|*/application/*|*/use-cases/*|*/entities/*)
      logica=$((logica+1)) ;;
    */infrastructure/*|*.adapter.*|*.repository.*|*/adapters/*|*/repositories/*)
      integracion=$((integracion+1)) ;;
    *) other=$((other+1)) ;;
  esac
done <<< "$files"

total=$(echo "$files" | wc -l)
echo "ficheros: $total"
parts=""
[[ $ui    -gt 0 ]] && parts="$parts ui:$ui"
[[ $api   -gt 0 ]] && parts="$parts api:$api"
[[ $data  -gt 0 ]] && parts="$parts datos:$data"
[[ $tests -gt 0 ]] && parts="$parts tests:$tests"
[[ $docs  -gt 0 ]] && parts="$parts docs:$docs"
[[ $deps  -gt 0 ]] && parts="$parts deps:$deps"
[[ $logica -gt 0 ]] && parts="$parts lógica:$logica"
[[ $integracion -gt 0 ]] && parts="$parts integración:$integracion"
[[ $other -gt 0 ]] && parts="$parts otros:$other"
echo "scope:$parts"

# El runtime hace falta cuando el cambio puede verse desde fuera, o cuando
# cambian las dependencias o el esquema: ahí lo que se rompe no es la lógica,
# es el arranque.
if [[ $ui -gt 0 || $api -gt 0 || $data -gt 0 || $deps -gt 0 || $integracion -gt 0 ]]; then
  echo "runtime: sí"
  [[ $ui   -gt 0 ]] && echo "  - toca interfaz: revisión visual"
  [[ $api  -gt 0 ]] && echo "  - toca API: probar los endpoints afectados"
  [[ $data -gt 0 ]] && echo "  - toca datos: verificar que la migración aplica y revierte"
  [[ $deps -gt 0 ]] && echo "  - cambian dependencias: comprobar que arranca desde cero"
  [[ $integracion -gt 0 ]] && echo "  - toca integración: probar contra el servicio real, no solo con dobles"
else
  echo "runtime: no"
fi

if [[ $docs -eq 0 && $((ui + api + data + logica)) -gt 0 ]]; then
  echo "doc: el cambio toca superficie y no hay documentación tocada — comprueba si alguna ha quedado desalineada"
fi
