#!/usr/bin/env bash
# Clasifica el diff y decide qué puertas de `ship` hacen falta.
#
#   diff-scope.sh [base]     por defecto compara con HEAD (staged + sin stagear)
#
# Una puerta que cuesta lo mismo para una errata que para un cambio de esquema
# se deja de pasar en dos semanas. Esto reparte el coste: lo que no puede estar
# incorrecto no paga la revisión de correctitud, y lo que no se ve desde fuera
# no paga levantar el entorno.

set -uo pipefail

BASE="${1:-HEAD}"
files="$(git diff --name-only "$BASE" 2>/dev/null; git diff --cached --name-only 2>/dev/null)"
files="$(echo "$files" | sort -u | grep -v '^$' || true)"

if [[ -z "$files" ]]; then
  echo "scope: vacío"
  echo "runtime: no"
  echo "puertas: ninguna — no hay nada que revisar"
  exit 0
fi

ui=0; api=0; data=0; tests=0; docs=0; deps=0; logica=0; integracion=0; other=0
tocados_test=""; tocados_codigo=""

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *_test.*|*.test.*|*.spec.*|*/tests/*|*/test/*|*/__tests__/*)
      tests=$((tests+1)); tocados_test+="$f"$'\n'; continue ;;
    package.json|*/package.json|*lock.json|*lock.yaml|*.lock|go.mod|Cargo.toml|requirements*.txt|pyproject.toml)
      deps=$((deps+1)); continue ;;
    *.md|*.mdx|*.txt|LICENSE|.gitignore) docs=$((docs+1)); continue ;;
    */migrations/*|*schema.prisma|*.sql) data=$((data+1)); continue ;;
  esac
  tocados_codigo+="$f"$'\n'
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
observable=0
if [[ $ui -gt 0 || $api -gt 0 || $data -gt 0 || $deps -gt 0 || $integracion -gt 0 ]]; then
  observable=1
  echo "runtime: sí"
  [[ $ui   -gt 0 ]] && echo "  - toca interfaz: revisión visual"
  [[ $api  -gt 0 ]] && echo "  - toca API: probar los endpoints afectados"
  [[ $data -gt 0 ]] && echo "  - toca datos: verificar que la migración aplica y revierte"
  [[ $deps -gt 0 ]] && echo "  - cambian dependencias: comprobar que arranca desde cero"
  [[ $integracion -gt 0 ]] && echo "  - toca integración: probar contra el servicio real, no solo con dobles"
else
  echo "runtime: no"
fi

# --- Qué puertas aplican -----------------------------------------------------
#
# Se calculan aquí en vez de dejarlo al criterio de quien pasa la puerta: a ojo
# todo parece pequeño, y así es como se salta justo la que hacía falta.

codigo=$((ui + api + data + logica + integracion + other + tests))
if [[ $codigo -eq 0 ]]; then
  echo "puertas: 2,8,9"
  echo "  - solo texto: no hay código que pueda estar incorrecto ni tests que regresen"
elif [[ $observable -eq 1 ]]; then
  echo "puertas: todas"
  echo "  - el cambio se ve desde fuera: la 7 no es opcional aquí"
else
  echo "puertas: 1,2,3,4,5,6,8,9"
  echo "  - nada observable desde fuera: la 7 se salta"
fi

# --- Qué tests correr en la puerta 1 -----------------------------------------
#
# La 1 solo pregunta si el rojo ya venía de antes, y para eso basta lo afectado.
# La suite entera es la 5. Correrla en las dos es pagar la más cara dos veces
# para responder dos preguntas distintas.

filtro=""
if [[ -n "$tocados_test" ]]; then
  filtro="$(echo "$tocados_test" | grep -v '^$' | head -5 | tr '\n' ' ')"
elif [[ -n "$tocados_codigo" ]]; then
  filtro="$(echo "$tocados_codigo" | grep -v '^$' | head -3 \
    | sed 's|.*/||; s|\.[^.]*$||' | sort -u | tr '\n' ' ')"
fi
filtro="${filtro% }"

# El comando concreto lo declara el proyecto: el kernel no sabe si aquí se
# ejecuta pnpm, pytest o go test.
contrato=""; d="$PWD"
while [[ "$d" != "/" && -n "$d" ]]; do
  for c in "$d"/crux.json "$d"/*-docs/crux.json; do
    [[ -f "$c" ]] && { contrato="$c"; break 2; }
  done
  d="$(dirname "$d")"
done

comando=""
if [[ -n "$contrato" ]] && command -v node >/dev/null 2>&1; then
  comando="$(node -e '
    const fs = require("fs");
    const q = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).quality) || {};
    const f = process.argv[2];
    const c = f && q.testsFiltered ? q.testsFiltered.replace("{filtro}", f) : (q.tests || "");
    process.stdout.write(c);
  ' "$contrato" "$filtro" 2>/dev/null || true)"
fi

if [[ $codigo -eq 0 ]]; then
  echo "tests: ninguno — el diff no toca código"
elif [[ -n "$comando" ]]; then
  echo "tests: $comando"
elif [[ -n "$filtro" ]]; then
  echo "tests: filtra por → $filtro"
  echo "  - declara 'quality.tests' y 'quality.testsFiltered' en crux.json para el comando exacto"
else
  echo "tests: la suite del proyecto"
fi

if [[ $docs -eq 0 && $((ui + api + data + logica)) -gt 0 ]]; then
  echo "doc: el cambio toca superficie y no hay documentación tocada — comprueba si alguna ha quedado desalineada"
fi
