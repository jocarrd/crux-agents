#!/usr/bin/env bash
# crux link — genera y verifica los punteros de contexto de los repos de código
# del proyecto, y materializa sus skills propias.
#
# Todo sale de crux.json: no hay nombres de proyecto ni listas de repos
# hardcodeadas. El perfil decide si se escribe o no en los repos de código.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
source "$CRUX_HOME/lib/skills.sh"

REFRESH=0
TARGET="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh) REFRESH=1; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(find_docs_repo "$TARGET")" || die "no encuentro un docs repo desde $TARGET"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "falta $CONFIG — ejecuta 'crux adopt' primero"

PROJECT="$(json_get "$CONFIG" project)"
PROFILE="$(json_get "$CONFIG" profile)"
DOCS_NAME="$(basename "$DOCS")"
ROOT="$(dirname "$DOCS")"

echo "proyecto $PROJECT · perfil $PROFILE"
echo

# La descripción de una línea de cada repo vive en la tabla de repos/README.md,
# que es su fuente canónica. Sin ella el puntero pierde lo único que decía de
# útil sobre el repo.
tagline_de() {
  local repo="$1" out
  out="$(node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    let out = "";
    try {
      for (const l of fs.readFileSync(file, "utf8").split("\n")) {
        if (!l.startsWith("|")) continue;
        const c = l.split("|").map((x) => x.trim());
        if (c[1]?.replace(/[`\/]/g, "") === repo) { out = c[3] || ""; break; }
      }
    } catch {}
    process.stdout.write(out);
  ' "$DOCS/repos/README.md" "$repo" 2>/dev/null || true)"
  echo "${out:-parte de $PROJECT}"
}

# --- Punteros de los repos de código ----------------------------------------

WRITES_POINTERS="$(json_get "$CRUX_HOME/profiles/$PROFILE.json" 'pointers.write' 2>/dev/null || echo "true")"

if [[ "$WRITES_POINTERS" != "true" ]]; then
  warn "perfil $PROFILE: no se escribe nada fuera del docs repo"
  info "los agentes deben abrir $DOCS_NAME/AGENTS.md explícitamente"
else
  created=0; updated=0; seen=0; sin_marcadores=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    repo_dir="$ROOT/$repo"
    [[ -d "$repo_dir" ]] || { warn "declarado en crux.json pero no está en disco: $repo"; continue; }
    seen=$((seen + 1))

    tagline="$(tagline_de "$repo")"

    for fichero in AGENTS.md CLAUDE.md; do
      # `|| rc=$?` y no `$?` a secas: render_managed devuelve códigos con
      # significado, y con set -e un retorno distinto de cero fuera de un
      # condicional aborta el script sin decir nada.
      rc=0
      render_managed "$CRUX_HOME/templates/code-repo/$fichero" "$repo_dir/$fichero" \
        "REPO=$repo" "PROJECT=$PROJECT" "DOCS=$DOCS_NAME" "TAGLINE=$tagline" || rc=$?
      case $rc in
        0) ok "creado $repo/$fichero"; created=$((created + 1)) ;;
        1) ok "actualizado el bloque de $repo/$fichero"; updated=$((updated + 1)) ;;
        3) sin_marcadores+=("$repo/$fichero") ;;
      esac
    done
  done < <(json_get "$CONFIG" repos 2>/dev/null || true)

  if [[ ${#sin_marcadores[@]} -gt 0 ]]; then
    echo
    if [[ $REFRESH -eq 1 ]]; then
      for f in "${sin_marcadores[@]}"; do
        repo="${f%%/*}"; fichero="${f##*/}"
        propio="$(sed '1{/^# /d}' "$ROOT/$f")"
        render_to_stdout "$CRUX_HOME/templates/code-repo/$fichero" \
          "REPO=$repo" "PROJECT=$PROJECT" "DOCS=$DOCS_NAME" "TAGLINE=$(tagline_de "$repo")" > "$ROOT/$f.tmp"
        printf '\n---\n\n## Contexto propio de %s\n\n%s\n' "$repo" "$propio" >> "$ROOT/$f.tmp"
        mv "$ROOT/$f.tmp" "$ROOT/$f"
        ok "$f reescrito con el bloque, contenido previo conservado debajo"
      done
    else
      warn "estos punteros son anteriores al bloque gestionado:"
      for f in "${sin_marcadores[@]}"; do info "$f"; done
      info "'crux link --refresh' los reescribe conservando su contenido debajo"
    fi
  fi

  if [[ $seen -eq 0 ]]; then
    info "ningún repo de código en disco todavía"
  elif [[ $((created + updated)) -eq 0 && ${#sin_marcadores[@]} -eq 0 ]]; then
    ok "punteros al día ($seen repos)"
  fi

fi

# --- Catálogo del kernel en el índice del proyecto --------------------------
#
# La lista de skills transversales se queda obsoleta en cuanto el kernel crece,
# y un índice que miente es peor que no tenerlo. Si el AGENTS.md marca el hueco,
# se rellena solo.

if grep -q '<!-- crux:skills -->' "$DOCS/AGENTS.md" 2>/dev/null; then
  catalogo="$(for d in "$CRUX_HOME"/skills/*/; do
    n="$(basename "$d")"
    linea="$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description: /,""); print; exit}' "$d/SKILL.md" 2>/dev/null)"
    # Un índice se escanea, no se lee: la frase entera lo vuelve ilegible.
    corta="${linea%%.*}"
    corta="${corta%%:*}"
    [[ ${#corta} -gt 78 ]] && corta="${corta:0:75}…"
    printf -- '- `%s` — %s\n' "$n" "$corta"
  done)"
  node -e '
    const fs = require("fs");
    const [file, catalogo] = process.argv.slice(1);
    const src = fs.readFileSync(file, "utf8");
    const re = /<!-- crux:skills -->[\s\S]*?<!-- \/crux:skills -->/;
    fs.writeFileSync(file, src.replace(re, `<!-- crux:skills -->\n${catalogo}\n<!-- /crux:skills -->`));
  ' "$DOCS/AGENTS.md" "$catalogo"
  ok "catálogo del kernel actualizado en AGENTS.md ($(echo "$catalogo" | wc -l) skills)"
fi

# --- Skills propias del proyecto --------------------------------------------

echo
crux_materialize_skills "$DOCS/.claude/skills" "$PROJECT"
crux_prune_skills
ok "skills del proyecto materializadas"
