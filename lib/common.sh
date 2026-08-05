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

# --- Requisitos --------------------------------------------------------------
#
# Node se usa para leer el contrato. Sin él, los comandos fallaban con un
# "orden no encontrada" en mitad de la salida, que no dice nada de lo que pasa.

command -v node >/dev/null || {
  echo "crux necesita node para leer el contrato del proyecto" >&2
  echo "instálalo y repite; 'crux doctor --machine' comprueba el resto" >&2
  exit 1
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

# --- Nombres y versiones -----------------------------------------------------

nombre_valido() {
  # Aquí no se legisla el estilo —hay repos reales en CamelCase— sino lo que
  # hace daño: un nombre con '/' o con '..' se concatena a una ruta y acaba
  # escribiendo fuera del docs repo.
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *".."* ]]
}

es_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

preferencia() {
  # preferencia <clave> [defecto] — de ~/.crux/config, que es del usuario y no
  # del proyecto: cada uno cierra su ciclo como quiera sin tocar el contrato.
  local clave="$1" defecto="${2:-}" valor=""
  [[ -f "$HOME/.crux/config" ]] &&
    valor="$(grep -E "^$clave=" "$HOME/.crux/config" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  echo "${valor:-$defecto}"
}

rama_principal() {
  # rama_principal <dir> — la declarada en el contrato, la del remoto, o la que
  # el repo esté usando. En ese orden.
  local dir="$1" docs declarada
  docs="$(find_docs_repo "$dir" 2>/dev/null || echo "")"
  if [[ -n "$docs" && -f "$docs/crux.json" ]]; then
    declarada="$(json_get "$docs/crux.json" branch 2>/dev/null || echo "")"
    [[ -n "$declarada" ]] && { echo "$declarada"; return 0; }
  fi
  declarada="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  if [[ -z "$declarada" ]]; then
    # La rama actual solo como último recurso: desde un worktree es la de
    # trabajo, y tomarla por principal deja el hook bloqueando justo esa.
    for c in main master; do
      git -C "$dir" show-ref --verify --quiet "refs/heads/$c" && { declarada="$c"; break; }
    done
  fi
  [[ -n "$declarada" ]] || declarada="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$declarada" && "$declarada" != "HEAD" ]] || declarada=main
  echo "$declarada"
}

es_worktree() {
  # En un worktree, .git es un fichero y el directorio común vive en el repo
  # principal.
  local comun
  comun="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$comun" != ".git" && "$comun" != "$1/.git" ]]
}

repo_principal() {
  dirname "$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)"
}

version_mayor_que() {
  # version_mayor_que <a> <b>. Comparadas como texto, 0.9.0 sale mayor que 0.10.0.
  # Lo que no es semver no se compara: 'sort -V' colocaría "?" por encima de todo.
  es_semver "$1" && es_semver "$2" || return 1
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# --- Lectura de crux.json ----------------------------------------------------
#
# Se usa node (presente en cualquier máquina donde se trabaja con estos repos)
# en vez de jq, que no siempre está instalado.

json_valido() {
  # json_valido <fichero> — 0 si parsea; si no, escribe el motivo del parser.
  node -e '
    const fs = require("fs");
    try { JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stdout.write(e.message); process.exit(1); }
  ' "$1"
}

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

# --- Raíz de los proyectos ---------------------------------------------------
#
# No se asume una carpeta concreta: la pista más fiable es que el propio kernel
# vive dentro de la raíz, así que su padre la identifica sin configurar nada.
# Sin esto, en una máquina con otra convención los comandos que recorren todos
# los proyectos no fallan: reportan cero, que es peor porque parece un dato.

projects_root() {
  if [[ -n "${CRUX_PROJECTS_DIR:-}" ]]; then
    echo "$CRUX_PROJECTS_DIR"; return
  fi
  if [[ -f "$HOME/.crux/config" ]]; then
    local declarado
    declarado="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"' || true)"
    [[ -n "$declarado" ]] && { echo "$declarado"; return; }
  fi
  local home
  home="$(crux_home)"
  [[ -n "$home" && -d "$(dirname "$home")" ]] && { dirname "$home"; return; }
  echo "$HOME/Proyectos"
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
  # Devuelve: 0 creado, 1 bloque actualizado, 2 sin cambios, 3 existe sin
  # marcadores, 4 la plantilla no trae bloque gestionado.
  #
  # El 4 no puede colapsarse en el 1: una plantilla mal formada se reportaba
  # como escrita sin haber tocado el destino.
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
    // Comparación insensible a espacios: muchos repos pasan un formateador que
    // alinea las tablas markdown. Sin esto, el formateador y `crux link` se
    // reescriben el bloque mutuamente en cada pasada, para siempre.
    // Los formateadores alinean columnas con espacios y estiran los guiones de
    // la línea separadora: hay que neutralizar las dos cosas.
    const norm = (t) => t
      .replace(/-{2,}/g, "--")
      .replace(/[ \t]+/g, " ")
      .replace(/ *\n/g, "\n");
    const previo = actual.match(re)?.[0];
    if (previo && norm(previo) === norm(bloque[0])) process.exit(2);
    fs.writeFileSync(dst, actual.replace(re, bloque[0]));
  ' "$dst" "$nuevo"
  local code=$?
  [[ $code -eq 2 ]] && return 2
  [[ $code -eq 4 ]] && return 4
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

# --- Remoto del proyecto -----------------------------------------------------
#
# El kernel no sabe de proveedores. Cada proyecto declara cómo se compone la URL
# de sus repos, y con eso vale igual para GitHub, GitLab —incluido el self-hosted
# con puerto—, Bitbucket o Azure DevOps.
#
#   "remote": { "url": "git@github.com:jocarrd/{repo}.git" }
#
# Atajo equivalente, por comodidad:
#
#   "remote": { "host": "gitlab.empresa.com", "owner": "equipo/sub", "protocol": "ssh" }

remote_url() {
  # remote_url <crux.json> <repo>
  #
  # El override por repo existe porque un proyecto puede tener la documentación
  # en tu remoto y el código en el de otra persona: es el caso de un repo de
  # cliente, y sin esto el clonado busca donde no está.
  local cfg="$1" repo="$2"
  node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    let r = {};
    try { r = (JSON.parse(fs.readFileSync(file, "utf8")).remote) || {}; } catch {}

    const propio = (r.repos || {})[repo];
    if (propio) { process.stdout.write(propio.replace(/\{repo\}/g, repo)); process.exit(0); }

    let tmpl = r.url;
    if (!tmpl && r.host && r.owner) {
      tmpl = (r.protocol === "https")
        ? `https://${r.host}/${r.owner}/{repo}.git`
        : `git@${r.host}:${r.owner}/{repo}.git`;
    }
    if (!tmpl) process.exit(2);
    process.stdout.write(tmpl.replace(/\{repo\}/g, repo));
  ' "$cfg" "$repo"
}

remote_desde_git() {
  # Deduce la plantilla del origin de un repo ya clonado. Es lo que permite que
  # adopt no tenga que preguntar por el remoto.
  local dir="$1" nombre url
  nombre="$(basename "$dir")"
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$url" ]] || return 1
  # Solo la última aparición: si el propietario se llama igual que el repo,
  # sustituir todas produce una plantilla rota.
  node -e '
    const [url, nombre] = process.argv.slice(1);
    const i = url.lastIndexOf(nombre);
    if (i === -1) { process.stdout.write(url); process.exit(0); }
    process.stdout.write(url.slice(0, i) + "{repo}" + url.slice(i + nombre.length));
  ' "$url" "$nombre"
}
