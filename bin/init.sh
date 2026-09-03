#!/usr/bin/env bash
# crux init — crea el docs repo de un proyecto nuevo desde las plantillas.
#
#   crux init <project> [--description "..."] [--repos a,b,c] [--branch <rama>]
#                       [--profile multi-repo] [--visibility private]
#                       [--language es] [--remote <plantilla>] [--no-remote]
#
# El remoto no se asume: se declara. `--remote` acepta una plantilla con {repo}
# —vale para cualquier proveedor— y queda escrito en el contrato, que es de
# donde lo leerán después `crux clone` y `crux doctor`.
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
BRANCH="main"
PROFILE="multi-repo"
VISIBILITY="private"
LANGUAGE="es"
REMOTE_TMPL=""
REMOTE=1
PARENT="$(projects_root)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    --repos)       REPOS="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --profile)     PROFILE="$2"; shift 2 ;;
    --visibility)  VISIBILITY="$2"; shift 2 ;;
    --language)    LANGUAGE="$2"; shift 2 ;;
    --remote)      REMOTE_TMPL="$2"; shift 2 ;;
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

# De dónde sale el remoto, por orden: lo que se pasa, el defecto de la máquina,
# y si no hay ninguno se dice en vez de adivinar.
if [[ -z "$REMOTE_TMPL" && -f "$HOME/.crux/config" ]]; then
  REMOTE_TMPL="$(grep -E '^CRUX_REMOTE=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"' || true)"
fi

if [[ $REMOTE -eq 1 && -z "$REMOTE_TMPL" ]]; then
  err "no sé dónde subir $PROJECT-docs"
  info "dilo con --remote 'git@tu-remoto:org/{repo}.git'"
  info "o fija el habitual en ~/.crux/config:  CRUX_REMOTE=\"git@github.com:tu-usuario/{repo}.git\""
  info "o crea el proyecto solo en local con --no-remote"
  exit 1
fi

URL_DOCS="${REMOTE_TMPL//\{repo\}/$PROJECT-docs}"

# La creación del repo remoto sí depende del proveedor. Se cubre GitHub porque
# hay CLI oficial; para el resto se deja el repo listo y se dice qué hacer, que
# son dos clics y no justifica una integración por proveedor.
CREA_REMOTO=0
if [[ $REMOTE -eq 1 ]]; then
  if [[ "$URL_DOCS" == *github.com* ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    CREA_REMOTO=1
  fi
fi

echo "creando $PROJECT-docs · perfil $PROFILE"
[[ $REMOTE -eq 1 ]] && echo "remoto: $URL_DOCS"
echo

# --- 1. Repo -----------------------------------------------------------------

mkdir -p "$ROOT"
if [[ $CREA_REMOTO -eq 1 ]]; then
  # El owner sale de la plantilla del remoto. Sin esto, gh crea siempre bajo la
  # cuenta autenticada aunque el contrato declare una organización, y el docs
  # repo nace en el sitio equivocado.
  OWNER_DOCS="$(owner_from_template "$URL_DOCS")"
  SLUG_DOCS="${OWNER_DOCS:+$OWNER_DOCS/}$PROJECT-docs"
  ( cd "$ROOT" && gh repo create "$SLUG_DOCS" \
      "--$VISIBILITY" --description "$DESCRIPTION" --clone >/dev/null )
  ok "repo creado en el remoto y clonado ($VISIBILITY${OWNER_DOCS:+ · $OWNER_DOCS})"

  # El proveedor crea la rama según la preferencia de la cuenta. Se normaliza a
  # la declarada porque el resto del kernel —hooks, worktrees, revisión— la lee
  # del contrato: si divergen, la guarda vigila una rama que nadie usa.
  rama_creada="$(git -C "$DOCS" symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [[ -n "$rama_creada" && "$rama_creada" != "$BRANCH" ]]; then
    git -C "$DOCS" branch -M "$BRANCH"
    ok "rama normalizada a $BRANCH (el remoto la creó como $rama_creada)"
  fi
else
  mkdir -p "$DOCS"
  # Sin esto el repo nace en la rama por defecto de la máquina, y el hook que
  # protege la principal se instala mirando otra.
  ( cd "$DOCS" && { git init -q -b "$BRANCH" 2>/dev/null || { git init -q && git symbolic-ref HEAD "refs/heads/$BRANCH"; }; } )
  if [[ $REMOTE -eq 1 ]]; then
    ( cd "$DOCS" && git remote add origin "$URL_DOCS" )
    ok "repo local con origin apuntando a $URL_DOCS"
    PENDIENTE_CREAR=1
  else
    ok "repo local creado (sin remoto)"
  fi
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

limpios=()
for repo in ${repos[@]+"${repos[@]}"}; do
  repo="$(echo "$repo" | tr -d '[:space:]')"
  [[ -n "$repo" ]] || continue
  nombre_valido "$repo" || die "nombre de repo inválido: $repo"
  limpios+=("$repo")
done
repos=(${limpios[@]+"${limpios[@]}"})

for repo in ${repos[@]+"${repos[@]}"}; do
  render_template "$CRUX_HOME/templates/repo-doc/README.md" "$DOCS/repos/$repo/README.md" \
    "REPO=$repo" "PROJECT=$PROJECT" "DESCRIPTION=Qué hace este repo, en una línea."

  # La fila del índice: de ahí sale la descripción que acaba en el puntero de
  # cada repo, así que una tabla vacía deja los punteros mudos.
  node -e '
    const fs = require("fs");
    const [file, repo, project] = process.argv.slice(1);
    const lines = fs.readFileSync(file, "utf8").split("\n");
    const row = `| \`${repo}/\` | \`${project}/${repo}\` | Qué hace este repo, en una línea |`;
    const vacia = lines.findIndex((l) => /^\|\s*\|\s*\|\s*\|\s*$/.test(l));
    if (vacia !== -1) lines[vacia] = row;
    else {
      let last = -1;
      for (let i = 0; i < lines.length; i++) if (/^\|/.test(lines[i])) last = i;
      if (last !== -1) lines.splice(last + 1, 0, row);
    }
    fs.writeFileSync(file, lines.join("\n"));
  ' "$DOCS/repos/README.md" "$repo" "$PROJECT"
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
  "language": "${LANGUAGE:-es}",
  "branch": "$BRANCH",
  "repos": [$(json_array "${repos[@]:-}")],
  "sections": [],
  "quality": {
    "gate": [],
    "repos": {}
  },
  "conventions": {
    "checks": []
  },
  "remote": {
    "url": "${REMOTE_TMPL:-}",
    "visibility": "$VISIBILITY"
  },
  "workspace": {
    "portBase": 3000,
    "portsPerSlot": 10,
    "envFile": ".env.local",
    "repos": {}
  }
}
EOF
ok "crux.json escrito"

# --- 5. Commit inicial -------------------------------------------------------

(
  cd "$DOCS"
  git add -A
  # En una máquina recién puesta puede no haber identidad configurada, y el
  # bootstrap no debería caerse por eso.
  git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo crux)}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo crux@localhost)}" \
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
if [[ "${PENDIENTE_CREAR:-0}" == "1" ]]; then
  echo
  warn "el repo remoto no existe todavía: créalo en tu proveedor como **$VISIBILITY**"
  info "la visibilidad no la puede aplicar crux fuera de GitHub: la eliges tú al crearlo"
  info "cd $DOCS && git push -u origin HEAD"
fi

echo "Siguientes pasos:"
echo "  1. Coloca los repos de código en $ROOT/ como hermanos del docs repo."
echo "  2. Para registrar uno nuevo: /add-repo-to-docs <repo>"
echo "  3. Para verificar en cualquier momento: crux doctor"
