#!/usr/bin/env bash
# Funciones compartidas por los comandos de crux.
# Se carga con: source "$CRUX_HOME/lib/common.sh"
#
# Una librería NO fija las opciones del shell: quien la carga ya declaró las
# suyas, y pisárselas rompe de la peor manera —el script muere en silencio en
# el primer comando que devuelve algo distinto de cero.

# --- Localización del kernel -------------------------------------------------

crux_home() {
  if [[ -n "${CRUX_HOME:-}" ]]; then
    echo "$CRUX_HOME"
  elif [[ -f "$HOME/.crux/config" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.crux/config"
    echo "$CRUX_HOME"
  else
    echo "" # el llamante decide si es un error
  fi
}

crux_version() {
  local home
  home="$(crux_home)"
  [[ -f "$home/VERSION" ]] && tr -d '[:space:]' < "$home/VERSION" || echo "unknown"
}

# --- Salida ------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_OFF=""
fi

ok()   { echo "${C_GRN}ok${C_OFF}    $*"; }
warn() { echo "${C_YEL}aviso${C_OFF} $*"; }
err()  { echo "${C_RED}error${C_OFF} $*"; }
info() { echo "${C_DIM}      $*${C_OFF}"; }
die()  { err "$*"; exit 1; }

# --- Lectura de crux.json ----------------------------------------------------
#
# Se usa node (presente en cualquier máquina donde se trabaja con estos repos)
# en vez de jq, que no siempre está instalado.

json_get() {
  # json_get <fichero> <expresión js sobre el objeto raíz>
  local file="$1" expr="$2"
  node -e '
    const fs = require("fs");
    let o;
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stderr.write("json inválido: " + e.message + "\n"); process.exit(1); }
    const v = (function (root) { return eval(process.argv[2]); })(o);
    if (v === undefined || v === null) process.exit(2);
    // Newline final: sin él, `while read` descarta el último elemento.
    process.stdout.write((Array.isArray(v) ? v.join("\n") : String(v)) + "\n");
  ' "$file" "root.$expr"
}

json_has() {
  json_get "$1" "$2" >/dev/null 2>&1
}

# --- Localización del docs repo ----------------------------------------------

find_docs_repo() {
  # Sube desde el directorio dado hasta encontrar un crux.json.
  # Si no lo encuentra, prueba con el hermano <project>-docs del padre.
  local dir="${1:-$PWD}"
  dir="$(cd "$dir" && pwd)"

  local probe="$dir"
  while [[ "$probe" != "/" ]]; do
    [[ -f "$probe/crux.json" ]] && { echo "$probe"; return 0; }
    probe="$(dirname "$probe")"
  done

  # Fallback: convención de layout — hermano <project>-docs
  local parent project candidate
  parent="$(dirname "$dir")"
  project="$(basename "$parent")"
  candidate="$parent/${project}-docs"
  [[ -d "$candidate" ]] && { echo "$candidate"; return 0; }

  [[ "$(basename "$dir")" == *-docs ]] && { echo "$dir"; return 0; }

  return 1
}

project_root() {
  dirname "$(find_docs_repo "${1:-$PWD}")"
}

# --- Plantillas --------------------------------------------------------------

render_managed() {
  # render_managed <origen> <destino> <VAR=valor>...
  #
  # Escribe la plantilla respetando lo que el repo haya añadido: si el destino
  # ya tiene el bloque marcado, solo se sustituye ese bloque. Sin esto, mejorar
  # el puntero obligaría a pisar el contexto propio de cada repo, y nadie
  # actualizaría nunca.
  #
  # Devuelve: 0 creado, 1 bloque actualizado, 2 sin cambios, 3 existe sin marcadores
  local src="$1" dst="$2"; shift 2
  local nuevo
  nuevo="$(render_to_stdout "$src" "$@")"

  if [[ ! -e "$dst" ]]; then
    mkdir -p "$(dirname "$dst")"
    printf '%s\n' "$nuevo" > "$dst"
    return 0
  fi

  grep -qF 'crux:begin' "$dst" || return 3

  node -e '
    const fs = require("fs");
    const [dst, nuevo] = process.argv.slice(1);
    const re = /<!-- crux:begin[\s\S]*?crux:end -->/;
    const bloque = nuevo.match(re);
    if (!bloque) process.exit(4);
    const actual = fs.readFileSync(dst, "utf8");
    if (actual.match(re)?.[0] === bloque[0]) process.exit(2);
    fs.writeFileSync(dst, actual.replace(re, bloque[0]));
  ' "$dst" "$nuevo"
  local code=$?
  [[ $code -eq 2 ]] && return 2
  return 1
}

render_to_stdout() {
  local src="$1"; shift
  local content pair key value
  content="$(cat "$src")"
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    content="${content//\{\{$key\}\}/$value}"
  done
  printf '%s' "$content"
}

render_template() {
  # render_template <origen> <destino> <VAR=valor>...
  local src="$1" dst="$2"; shift 2
  local content
  content="$(cat "$src")"
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    content="${content//\{\{$key\}\}/$value}"
  done
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" > "$dst"
}
