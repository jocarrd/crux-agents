#!/usr/bin/env bash
# crux visual — la revisión visual que aprueba una persona, con recibo.
#
#   crux visual approve <carpeta> [--note "<texto>"]   anota la aprobación
#   crux visual show                                    enseña el recibo
#   crux visual section [--publish] [--lang es|en]      la sección de la propuesta
#   crux visual pr <número|url>                         la pone en una ya abierta
#   crux visual clear                                   descarta el recibo
#
# `approve` se ejecuta después de que quien decide haya visto las comparativas
# y haya dicho que sí. El recibo guarda el commit sobre el que se capturaron:
# si después entra otro, las imágenes ya no enseñan lo que se propone, y finish
# lo dice en vez de publicarlas como si fueran las de ahora.
#
# Las imágenes no se commitean en la rama de la propuesta: acabarían en la
# principal. Van a una rama aparte que nunca se fusiona, escrita con plumbing
# para no tocar el árbol de trabajo.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "esto no es un repositorio git"
RECIBO="$REPO/.crux-visual"
MARCA_INICIO="<!-- visual-review:start -->"
MARCA_FIN="<!-- visual-review:end -->"
IMAGENES='\.(png|webp|jpe?g)$'

perfil_del_repo() {
  local docs perfil=""
  docs="$(find_docs_repo "$REPO" 2>/dev/null || echo "")"
  [[ -n "$docs" && -f "$docs/crux.json" ]] &&
    perfil="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"
  printf '%s\t%s' "$perfil" "$docs"
}

modo_publicacion() {
  local perfil docs
  IFS=$'\t' read -r perfil docs <<< "$(perfil_del_repo)"
  perfil_get "$perfil" "$docs" visual.publish branch 2>/dev/null || echo branch
}

rama_de_revision() {
  local perfil docs
  IFS=$'\t' read -r perfil docs <<< "$(perfil_del_repo)"
  perfil_get "$perfil" "$docs" visual.branch crux-review 2>/dev/null || echo crux-review
}

recibo_valor() { awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$RECIBO"; }

leer_recibo() {
  [[ -f "$RECIBO" ]] || die "no hay revisión visual aprobada: 'crux visual approve <carpeta>' después del sí"
  local dir
  dir="$(recibo_valor dir)"
  [[ -n "$dir" && -d "$dir" ]] || die "la carpeta del recibo no existe: ${dir:-vacía}"
}

imagenes_de() { find "$1" -maxdepth 1 -type f | grep -Ei "$IMAGENES" | sort; }

cmd_approve() {
  local dir="" nota=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) nota="${2:-}"; shift 2 ;;
      *) dir="$1"; shift ;;
    esac
  done
  [[ -n "$dir" ]] || die "uso: crux visual approve <carpeta> [--note \"<texto>\"]"
  [[ -d "$dir" ]] || die "no existe la carpeta: $dir"
  dir="$(cd "$dir" && pwd)"
  local total
  total="$(imagenes_de "$dir" | grep -c . || true)"
  [[ "$total" -gt 0 ]] || die "no hay imágenes en $dir (png, webp o jpg)"
  {
    printf '# revisión visual aprobada — crux\n'
    printf 'sha %s\n' "$(git -C "$REPO" rev-parse HEAD)"
    printf 'branch %s\n' "$(git -C "$REPO" branch --show-current)"
    printf 'dir %s\n' "$dir"
    printf 'approved %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "$nota" ]] && printf 'note %s\n' "$nota"
  } > "$RECIBO"
  ok "revisión visual anotada sobre $(git -C "$REPO" rev-parse --short HEAD) con $total imágenes"
}

cmd_show() {
  leer_recibo
  local sha head
  sha="$(recibo_valor sha)"; head="$(git -C "$REPO" rev-parse HEAD)"
  info "aprobada el $(recibo_valor approved) sobre ${sha:0:8}"
  info "$(imagenes_de "$(recibo_valor dir)" | grep -c .) imágenes en $(recibo_valor dir)"
  if [[ "$sha" != "$head" ]]; then
    warn "las capturas son de ${sha:0:8} y HEAD es ${head:0:8}: vuelve a enseñarlas"
    return 1
  fi
}

repo_github() {
  local url
  url="$(git -C "$REPO" config --get remote.origin.url)" || return 1
  [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 1
  printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
}

publicar() {
  # publicar <rama de revisión> <prefijo> <carpeta> — escribe las imágenes en
  # la rama de revisión sin checkout: índice temporal, árbol y commit a mano.
  local rama="$1" prefijo="$2" dir="$3" padre="" indice arbol commit
  if git -C "$REPO" fetch -q origin "$rama" 2>/dev/null; then
    padre="$(git -C "$REPO" rev-parse FETCH_HEAD)"
  fi
  indice="$(mktemp "${TMPDIR:-/tmp}/crux-visual-index.XXXXXX")"
  rm -f "$indice"
  if [[ -n "$padre" ]]; then
    GIT_INDEX_FILE="$indice" git -C "$REPO" read-tree "$padre" || { rm -f "$indice"; return 1; }
  fi
  GIT_INDEX_FILE="$indice" git -C "$REPO" rm -rq --cached --ignore-unmatch "$prefijo" >/dev/null
  local fichero blob
  while IFS= read -r fichero; do
    blob="$(git -C "$REPO" hash-object -w "$fichero")" || { rm -f "$indice"; return 1; }
    GIT_INDEX_FILE="$indice" git -C "$REPO" update-index --add \
      --cacheinfo "100644,$blob,$prefijo/$(basename "$fichero")" || { rm -f "$indice"; return 1; }
  done < <(imagenes_de "$dir")
  arbol="$(GIT_INDEX_FILE="$indice" git -C "$REPO" write-tree)"
  rm -f "$indice"
  commit="$(git -C "$REPO" commit-tree "$arbol" ${padre:+-p "$padre"} -m "chore(review): before and after for $prefijo")" || return 1
  git -C "$REPO" push -q origin "$commit:refs/heads/$rama"
}

texto() {
  # texto <idioma> <clave>
  case "$1:$2" in
    es:titulo) echo "Antes y después" ;;
    en:titulo) echo "Before and after" ;;
    es:aprobada) echo "Revisión visual aprobada el" ;;
    en:aprobada) echo "Visual review approved on" ;;
    es:leyenda) echo "Antes a la izquierda, después a la derecha." ;;
    en:leyenda) echo "Before on the left, after on the right." ;;
  esac
}

cmd_section() {
  local publish=0 idioma="es"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish) publish=1; shift ;;
      --lang) idioma="${2:-es}"; shift 2 ;;
      *) die "opción desconocida: $1" ;;
    esac
  done
  [[ "$idioma" == "en" ]] || idioma="es"
  leer_recibo
  local sha head dir fecha nota modo
  sha="$(recibo_valor sha)"; head="$(git -C "$REPO" rev-parse HEAD)"
  [[ "$sha" == "$head" ]] || die "las capturas son de ${sha:0:8} y HEAD es ${head:0:8}: vuelve a enseñarlas"
  dir="$(recibo_valor dir)"; fecha="$(recibo_valor approved)"; nota="$(recibo_valor note)"
  modo="$(modo_publicacion)"

  printf '%s\n## %s\n\n%s %s.' "$MARCA_INICIO" "$(texto "$idioma" titulo)" \
    "$(texto "$idioma" aprobada)" "${fecha:0:10}"
  [[ -n "$nota" ]] && printf ' %s' "$nota"
  printf '\n'

  if [[ "$modo" == "branch" && "$publish" -eq 1 ]]; then
    local slug rama prefijo
    slug="$(repo_github)" || die "el remoto no es de GitHub: no sé dónde enlazar las imágenes"
    rama="$(rama_de_revision)"
    prefijo="$(recibo_valor branch)"
    [[ -n "$prefijo" ]] || prefijo="${sha:0:8}"
    publicar "$rama" "$prefijo" "$dir" || die "no pude subir las imágenes a la rama $rama"
    printf '\n%s\n' "$(texto "$idioma" leyenda)"
    local fichero nombre
    while IFS= read -r fichero; do
      nombre="$(basename "$fichero")"
      printf '\n![%s](https://github.com/%s/blob/%s/%s/%s?raw=true)\n' \
        "${nombre%.*}" "$slug" "$rama" "$prefijo" "$nombre"
    done < <(imagenes_de "$dir")
  fi
  printf '%s\n' "$MARCA_FIN"
}

reemplazar_seccion() {
  # reemplazar_seccion <cuerpo actual> <sección nueva> — la cambia si ya estaba
  # entre las marcas; si no, la añade al final.
  node -e '
    const [cuerpo, seccion, ini, fin] = process.argv.slice(1);
    const a = cuerpo.indexOf(ini), b = cuerpo.indexOf(fin);
    const salida = a !== -1 && b > a
      ? cuerpo.slice(0, a) + seccion.trim() + cuerpo.slice(b + fin.length)
      : `${cuerpo.trimEnd()}\n\n${seccion.trim()}\n`;
    process.stdout.write(salida);
  ' "$1" "$2" "$MARCA_INICIO" "$MARCA_FIN"
}

cmd_pr() {
  local pr="${1:-}" idioma="${2:-es}"
  [[ -n "$pr" ]] || die "uso: crux visual pr <número|url>"
  command -v gh >/dev/null || die "hace falta gh para editar la propuesta"
  local seccion cuerpo nuevo tmp
  seccion="$(cmd_section --publish --lang "$idioma")" || exit 1
  cuerpo="$(cd "$REPO" && gh pr view "$pr" --json body -q .body)" || die "no pude leer la propuesta $pr"
  nuevo="$(reemplazar_seccion "$cuerpo" "$seccion")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/crux-visual-body.XXXXXX")"
  printf '%s\n' "$nuevo" > "$tmp"
  ( cd "$REPO" && bash "$CRUX_HOME/bin/ship.sh" body "$tmp" >/dev/null 2>&1 ) ||
    { rm -f "$tmp"; die "el cuerpo nuevo no pasa el filtro de la propuesta"; }
  ( cd "$REPO" && gh pr edit "$pr" --body-file "$tmp" >/dev/null ) || { rm -f "$tmp"; die "no pude editar la propuesta $pr"; }
  rm -f "$tmp"
  ok "revisión visual puesta en la propuesta $pr"
}

cmd_clear() { rm -f "$RECIBO"; ok "revisión visual descartada"; }

case "${1:-}" in
  approve) shift; cmd_approve "$@" ;;
  show)    cmd_show ;;
  section) shift; cmd_section "$@" ;;
  pr)      shift; cmd_pr "$@" ;;
  clear)   cmd_clear ;;
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
