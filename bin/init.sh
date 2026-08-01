#!/usr/bin/env bash
# crux init — crea el docs repo de un proyecto nuevo desde las plantillas.
#
#   crux init <project> [--description "..."] [--repos a,b,c]
#                       [--profile multi-repo] [--visibility private]
#                       [--no-remote]
#
# Determinista: el resultado sale de templates/, no de que un agente reproduzca
# ficheros a mano. Dos ejecuciones dan el mismo árbol.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

PROJECT="${1:-}"
[[ -n "$PROJECT" ]] || die "uso: crux init <project> [opciones]"
shift

DESCRIPTION="Documentación transversal de $PROJECT."
REPOS=""
PROFILE="multi-repo"
VISIBILITY="private"
REMOTE=1
PARENT="${CRUX_PROJECTS_DIR:-$HOME/Proyectos}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    --repos)       REPOS="$2"; shift 2 ;;
    --profile)     PROFILE="$2"; shift 2 ;;
    --visibility)  VISIBILITY="$2"; shift 2 ;;
    --no-remote)   REMOTE=0; shift ;;
    --parent)      PARENT="$2"; shift 2 ;;
    *) die "opción desconocida: $1" ;;
  esac
done

[[ -f "$CRUX_HOME/profiles/$PROFILE.json" ]] || die "perfil desconocido: $PROFILE"
[[ "$PROJECT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "el nombre debe ir en kebab-case minúscula: $PROJECT"

ROOT="$PARENT/$PROJECT"
DOCS="$ROOT/$PROJECT-docs"
[[ -e "$DOCS" ]] && die "ya existe $DOCS"

if [[ $REMOTE -eq 1 ]]; then
  command -v gh >/dev/null || die "gh no está instalado (o usa --no-remote)"
  gh auth status >/dev/null 2>&1 || die "gh no autenticado"
fi

echo "creando $PROJECT-docs · perfil $PROFILE"
echo

# --- 1. Repo -----------------------------------------------------------------

mkdir -p "$ROOT"
if [[ $REMOTE -eq 1 ]]; then
  ( cd "$ROOT" && gh repo create "$PROJECT-docs" \
      "--$VISIBILITY" --description "$DESCRIPTION" --clone >/dev/null )
  ok "repo creado y clonado ($VISIBILITY)"
else
  mkdir -p "$DOCS"
  ( cd "$DOCS" && git init -q )
  ok "repo local creado (sin remoto)"
fi

# --- 2. Plantillas -----------------------------------------------------------

VARS=("PROJECT=$PROJECT" "DESCRIPTION=$DESCRIPTION")

while IFS= read -r src; do
  rel="${src#"$CRUX_HOME/templates/docs-repo/"}"
  dst="$DOCS/$rel"
  [[ "$rel" == "gitignore" ]] && dst="$DOCS/.gitignore"
  render_template "$src" "$dst" "${VARS[@]}"
done < <(find "$CRUX_HOME/templates/docs-repo" -type f | sort)

ln -sfn AGENTS.md "$DOCS/CLAUDE.md"
mkdir -p "$DOCS/.claude/skills/project"
ok "estructura mínima materializada"

# --- 3. Carpetas de los repos declarados ------------------------------------

repos=()
if [[ -n "$REPOS" ]]; then
  IFS=',' read -ra repos <<< "$REPOS"
fi

for repo in "${repos[@]:-}"; do
  repo="$(echo "$repo" | tr -d '[:space:]')"
  [[ -n "$repo" ]] || continue
  render_template "$CRUX_HOME/templates/repo-doc/README.md" "$DOCS/repos/$repo/README.md" \
    "REPO=$repo" "PROJECT=$PROJECT" "DESCRIPTION=Qué hace este repo, en una línea."
done
[[ ${#repos[@]} -gt 0 ]] && ok "${#repos[@]} carpetas en repos/"

# --- 4. El contrato ----------------------------------------------------------

json_array() {
  local out="" item
  for item in "$@"; do
    item="$(echo "$item" | tr -d '[:space:]')"
    [[ -n "$item" ]] && out="$out\"$item\", "
  done
  echo "${out%, }"
}

cat > "$DOCS/crux.json" <<EOF
{
  "crux": "$(crux_version)",
  "project": "$PROJECT",
  "profile": "$PROFILE",
  "repos": [$(json_array "${repos[@]:-}")],
  "sections": []
}
EOF
ok "crux.json escrito"

# --- 5. Commit inicial -------------------------------------------------------

(
  cd "$DOCS"
  git add -A
  git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo crux)}" \
      commit -q -m "init: scaffold del docs repo bajo el estándar crux"
  [[ $REMOTE -eq 1 ]] && git push -q -u origin HEAD 2>/dev/null || true
)
ok "commit inicial"

# --- 6. Punteros y skills ----------------------------------------------------

echo
bash "$CRUX_HOME/bin/link.sh" "$DOCS"

echo
echo "listo: $DOCS"
echo
echo "Siguientes pasos:"
echo "  1. Coloca los repos de código en $ROOT/ como hermanos del docs repo."
echo "  2. Para registrar uno nuevo: /add-repo-to-docs <repo>"
echo "  3. Para verificar en cualquier momento: crux doctor"
