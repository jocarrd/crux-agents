#!/usr/bin/env bash
# Decide el riesgo de una propuesta y qué revisores especialistas merece.
#
#   review-scope.sh [base]     por defecto, la rama principal del remoto
#
# Un revisor por especialidad cuesta decenas de miles de tokens cada uno. Si se
# lanzan todos en cada propuesta, a la tercera semana se deja de revisar; si no
# se lanza ninguno, la revisión general no ve lo que solo ve quien sabe dónde
# mirar. Esto reparte: los especialistas salen del diff, no de las ganas.

set -uo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/##')"
  [[ -n "$BASE" ]] || for c in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null && { BASE="$c"; break; }
  done
fi
if [[ -z "$BASE" ]] || ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "error: no encuentro la rama base '${BASE:-?}' — pásala como argumento" >&2
  exit 1
fi

files="$(git diff --name-only "$BASE...HEAD")"
if [[ -z "$files" ]]; then
  echo "riesgo: ninguno — no hay cambios contra $BASE"
  echo "especialistas: ninguno"
  exit 0
fi

codigo=0; lineas_codigo=0; no_texto=0
seguridad=""; datos=""; rendimiento=""; interfaz=""

motivo() {
  # motivo <variable> <texto>: guarda el primer motivo, que es el que se enseña.
  # Con expansión indirecta y no con `local -n`, que no existe en bash 3.
  [[ -z "${!1}" ]] && printf -v "$1" '%s' "$2"
  return 0
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  # Las dependencias van antes que el texto: `requirements.txt` acaba en .txt y
  # se colaba como documentación, y con él una dependencia nueva salía
  # "fusionable sin preguntar".
  case "$f" in
    package.json|*/package.json|*lock.json|*lock.yaml|*.lock|go.mod|Cargo.toml|requirements*.txt|*/requirements*.txt|pyproject.toml|*/pyproject.toml|Gemfile)
      motivo seguridad "cambian dependencias ($f): de dónde salen y qué ejecutan al instalarse" ;;
    *.md|*.mdx|*.txt|LICENSE|.gitignore) continue ;;
    # Un test no pide especialista, pero es código que el CI ejecuta con sus
    # secretos delante: no cuenta como texto para decidir quién fusiona.
    *_test.*|*.test.*|*.spec.*|*/tests/*|*/test/*|*/__tests__/*|tests/*|test/*)
      no_texto=$((no_texto + 1)); continue ;;
  esac

  no_texto=$((no_texto + 1))
  codigo=$((codigo + 1))
  case "$f" in
    *lock.json|*lock.yaml|*.lock) ;;
    *)
      n="$(git diff --numstat "$BASE...HEAD" -- "$f" | awk '{s += $1 + $2} END {print s + 0}')"
      lineas_codigo=$((lineas_codigo + n)) ;;
  esac

  shopt -s nocasematch
  case "$f" in
    *auth*|*login*|*session*|*token*|*jwt*|*password*|*permission*|*role*|*acl*|*crypto*|*secret*|*middleware*|*cors*|*csrf*|*webhook*|*upload*|.env*|*/.env*)
      motivo seguridad "toca una ruta sensible: $f" ;;
  esac
  shopt -u nocasematch

  case "$f" in
    */migrations/*|*schema.prisma|*.sql|*.entity.*|*/models/*|*/entities/*)
      motivo datos "toca el esquema o los modelos: $f" ;;
  esac

  case "$f" in
    */api/*|*/routes/*|*/server/*|*/handlers/*|*/workers/*|*/jobs/*|*/cron/*|*/queue*|*.repository.*|*/repositories/*|next.config.*|vite.config.*|webpack.config.*)
      motivo rendimiento "toca código de servidor o de build: $f" ;;
  esac

  case "$f" in
    *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.html|*/components/*|*/pages/*|*/styles/*)
      motivo interfaz "toca interfaz: $f" ;;
  esac
done <<< "$files"

# Lo que dice el contenido añadido, no solo la ruta: una consulta armada con
# texto o un innerHTML entran igual en un fichero que se llama utils.ts.
# Sin tests: un test que prueba que se detecta un DROP TABLE contiene un DROP
# TABLE, y no por eso el cambio toca datos.
rutas_contenido=()
while IFS= read -r f; do
  [[ -n "$f" ]] && rutas_contenido+=("$f")
done < <(echo "$files" | grep -vE '\.(md|mdx|txt)$|_test\.|\.test\.|\.spec\.|(^|/)(tests?|__tests__)/' || true)
anadido=""
if [[ ${#rutas_contenido[@]} -gt 0 ]]; then
  anadido="$(git diff "$BASE...HEAD" -- "${rutas_contenido[@]}" 2>/dev/null | grep '^+' | grep -v '^+++' || true)"
fi

if echo "$anadido" | grep -qE 'eval\(|new Function\(|dangerouslySetInnerHTML|innerHTML *=|child_process|execSync|shell *= *True|Set-Cookie|Authorization'; then
  motivo seguridad "el diff añade una construcción sensible (ejecución, HTML crudo, cabeceras de sesión)"
fi
if echo "$anadido" | grep -qiE 'alter table|drop table|drop column|create table|deleteMany|truncate'; then
  motivo datos "el diff añade operaciones que cambian o borran datos"
fi
# Sin readFileSync: en scripts y herramientas de terminal leer un fichero de
# forma síncrona es lo normal, y pedía un especialista en cada cambio de tooling.
# El código de servidor ya se reconoce por su ruta.
if echo "$anadido" | grep -qE 'findMany\(|SELECT .* FROM|\.map\(async|Promise\.all\(|setInterval\('; then
  motivo rendimiento "el diff añade consultas o bucles asíncronos"
fi

# Los lockfiles se regeneran enteros: contarlos convertiría cualquier
# actualización de una dependencia en "cambio grande".
total_lineas="$(git diff --numstat "$BASE...HEAD" | grep -vE '(lock\.json|lock\.yaml|\.lock)$' \
  | awk '{s += $1 + $2} END {print s + 0}')"

# --- El contrato: perfil y rigor -------------------------------------------
#
# El rigor lo declara el proyecto: cuánta ceremonia merece. Un repo sin
# crux.json no está dado de alta, y lo que no se ha dado de alta no se trata
# como si fuera crítico: va en ligero. Dentro de cada nivel, lo que decide es
# el diff.

perfil=""; rigor=""; origen_rigor=""; d="$PWD"
while [[ "$d" != "/" && -n "$d" ]]; do
  for c in "$d"/crux.json "$d"/*-docs/crux.json; do
    [[ -f "$c" ]] || continue
    leido="$(node -e '
      try {
        const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write((j.profile || "") + "\t" + (j.rigor || ""));
      } catch (e) { process.stdout.write("ilegible\t"); }
    ' "$c")"
    perfil="${leido%%$'\t'*}"; rigor="${leido#*$'\t'}"
    origen_rigor="declarado en $c"
    [[ -z "$rigor" ]] && origen_rigor="por defecto: el proyecto no lo declara" && rigor="normal"
    break 2
  done
  d="$(dirname "$d")"
done
raiz="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$origen_rigor" && -n "$raiz" && -f "$raiz/STANDARD.md" && -f "$raiz/bin/crux" ]]; then
  # El kernel no lleva crux.json porque no es un proyecto, pero todos los
  # proyectos lo consumen: no puede tratarse como algo que no se ha dado de alta.
  rigor="normal"; origen_rigor="el propio kernel, que consumen todos los proyectos"
elif [[ -z "$origen_rigor" ]]; then
  rigor="ligero"; origen_rigor="sin crux.json: proyecto no dado de alta"
elif [[ "$perfil" == "ilegible" ]]; then
  rigor="normal"; origen_rigor="el crux.json no se puede leer"
fi
case "$rigor" in
  ligero|normal|estricto) ;;
  *) echo "error: rigor desconocido '$rigor' ($origen_rigor) — vale ligero, normal o estricto" >&2; exit 1 ;;
esac

# --- Riesgo -----------------------------------------------------------------
#
# Alto si lo que puede salir mal no se ve en una captura: seguridad y datos
# rompen en silencio. Bajo si no hay código, o si el cambio es tan pequeño que
# la revisión general lo cubre entero; ahí un especialista no ve nada que no
# vea ella, y solo añade coste.

riesgo="medio"
if [[ $codigo -eq 0 ]]; then
  riesgo="bajo"
elif [[ -n "$seguridad" || -n "$datos" || $total_lineas -gt 500 ]]; then
  riesgo="alto"
# En estricto no hay atajo por tamaño: treinta líneas de un cliente de banca
# pueden ser justo las que importan.
elif [[ $lineas_codigo -le 30 && "$rigor" != "estricto" ]]; then
  riesgo="bajo"
fi

echo "base: $BASE"
echo "cambio: $(echo "$files" | wc -l | tr -d ' ') ficheros, $total_lineas líneas ($lineas_codigo de código)"
echo "riesgo: $riesgo"
echo "rigor: $rigor — $origen_rigor"

# En ligero, los especialistas se reservan para lo que rompe en silencio.
lista=()
if [[ "$riesgo" == "alto" || ( "$riesgo" == "medio" && "$rigor" != "ligero" ) ]]; then
  [[ -n "$seguridad" ]]   && lista+=("seguridad|$seguridad")
  [[ -n "$datos" ]]       && lista+=("datos|$datos")
  [[ -n "$rendimiento" ]] && lista+=("rendimiento|$rendimiento")
  [[ -n "$interfaz" ]]    && lista+=("interfaz|$interfaz")
fi

# Tres como máximo: a partir de ahí se solapan y el coste crece sin hallazgos.
if [[ ${#lista[@]} -eq 0 ]]; then
  if [[ "$riesgo" == "medio" && "$rigor" == "ligero" ]]; then
    echo "especialistas: ninguno — rigor ligero, basta la revisión general"
  else
    echo "especialistas: ninguno — basta la revisión general"
  fi
else
  nombres="$(printf '%s\n' "${lista[@]:0:3}" | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')"
  echo "especialistas: $nombres"
  for e in "${lista[@]:0:3}"; do
    echo "  - ${e%%|*}: ${e#*|}"
  done
  [[ ${#lista[@]} -gt 3 ]] && echo "  - (se queda fuera: $(printf '%s\n' "${lista[@]:3}" | cut -d'|' -f1 | paste -sd, -), la cubre la revisión general)"
fi

# --- Quién fusiona ----------------------------------------------------------
#
# En un repo de cliente decide siempre una persona, sea cual sea el rigor: el
# coste de equivocarse no lo paga quien fusiona. Fuera de eso, el rigor mueve
# el umbral: en estricto nunca se fusiona solo, en normal solo el texto, y en
# ligero todo lo que no es riesgo alto.

if [[ "$perfil" == "ilegible" ]]; then
  echo "fusión: decide una persona — el crux.json del proyecto no se puede leer"
elif [[ "$perfil" == "client-repo" || "$rigor" == "estricto" ]]; then
  echo "fusión: decide una persona"
elif [[ $no_texto -eq 0 ]]; then
  echo "fusión: puede fusionarse sin preguntar — solo texto"
elif [[ "$rigor" == "ligero" && "$riesgo" != "alto" ]]; then
  echo "fusión: puede fusionarse sin preguntar — rigor ligero y riesgo $riesgo"
else
  echo "fusión: decide una persona"
fi
