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

DOCS="$(find_docs_repo "${1:-$PWD}")" || die "no encuentro un docs repo desde ${1:-$PWD}"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "falta $CONFIG — ejecuta 'crux adopt' primero"

PROJECT="$(json_get "$CONFIG" project)"
PROFILE="$(json_get "$CONFIG" profile)"
DOCS_NAME="$(basename "$DOCS")"
ROOT="$(dirname "$DOCS")"

echo "proyecto $PROJECT · perfil $PROFILE"
echo

# --- Punteros de los repos de código ----------------------------------------

WRITES_POINTERS="$(json_get "$CRUX_HOME/profiles/$PROFILE.json" 'pointers.write' 2>/dev/null || echo "true")"

if [[ "$WRITES_POINTERS" != "true" ]]; then
  warn "perfil $PROFILE: no se escribe nada fuera del docs repo"
  info "los agentes deben abrir $DOCS_NAME/AGENTS.md explícitamente"
else
  created=0; seen=0; missing_import=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    repo_dir="$ROOT/$repo"
    [[ -d "$repo_dir" ]] || { warn "declarado en crux.json pero no está en disco: $repo"; continue; }
    seen=$((seen + 1))

    if [[ ! -e "$repo_dir/AGENTS.md" ]]; then
      render_template "$CRUX_HOME/templates/code-repo/AGENTS.md" "$repo_dir/AGENTS.md" \
        "REPO=$repo" "PROJECT=$PROJECT" "DOCS=$DOCS_NAME"
      ok "creado $repo/AGENTS.md"
      created=$((created + 1))
    fi

    # No se pisa: el repo puede tener contexto propio debajo del import.
    import_line="@../$DOCS_NAME/CLAUDE.md"
    if [[ ! -e "$repo_dir/CLAUDE.md" ]]; then
      render_template "$CRUX_HOME/templates/code-repo/CLAUDE.md" "$repo_dir/CLAUDE.md" \
        "REPO=$repo" "PROJECT=$PROJECT" "DOCS=$DOCS_NAME"
      ok "creado $repo/CLAUDE.md"
      created=$((created + 1))
    elif ! grep -qF "$import_line" "$repo_dir/CLAUDE.md"; then
      missing_import+=("$repo")
    fi
  done < <(json_get "$CONFIG" repos 2>/dev/null || true)

  if [[ $seen -eq 0 ]]; then
    info "ningún repo de código en disco todavía"
  elif [[ $created -eq 0 ]]; then
    ok "punteros ya en su sitio ($seen repos)"
  fi

  if [[ ${#missing_import[@]} -gt 0 ]]; then
    echo
    warn "estos CLAUDE.md no importan la doc transversal:"
    for r in "${missing_import[@]}"; do
      info "$r/CLAUDE.md — añade al final: @../$DOCS_NAME/CLAUDE.md"
    done
  fi
fi

# --- Skills propias del proyecto --------------------------------------------

echo
crux_materialize_skills "$DOCS/.claude/skills" "$PROJECT"
crux_prune_skills
ok "skills del proyecto materializadas"
