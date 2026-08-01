#!/usr/bin/env bash
# crux adopt — registra bajo el estándar un docs repo que ya existe.
#
# No reescribe nada de lo que ya hay: detecta el proyecto y sus repos, escribe
# el crux.json que falta y deja que 'crux doctor' diga qué queda por alinear.
# Es la puerta de entrada de los proyectos anteriores al kernel.
#
#   crux adopt [dir] [--profile <perfil>]

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

TARGET="$PWD"
PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(cd "$TARGET" && pwd)"
[[ "$(basename "$DOCS")" == *-docs ]] || die "$DOCS no parece un docs repo (debe llamarse <project>-docs)"

PROJECT="$(basename "$DOCS")"
PROJECT="${PROJECT%-docs}"
ROOT="$(dirname "$DOCS")"
CONFIG="$DOCS/crux.json"

[[ -f "$CONFIG" ]] && die "$PROJECT ya está adoptado — usa 'crux doctor' o 'crux upgrade'"

# --- Perfil ------------------------------------------------------------------

PROFILE="${PROFILE:-multi-repo}"
[[ -f "$CRUX_HOME/profiles/$PROFILE.json" ]] || die "perfil desconocido: $PROFILE"

# --- Repos: los que ya tienen carpeta de documentación ----------------------

repos=()
if [[ -d "$DOCS/repos" ]]; then
  for dir in "$DOCS"/repos/*/; do
    [[ -d "$dir" ]] && repos+=("$(basename "$dir")")
  done
fi

# Hermanos en disco que aún no tienen carpeta de doc: se avisan, no se añaden
# solos (podrían no ser del proyecto).
orphans=()
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  [[ "$name" == "$(basename "$DOCS")" ]] && continue
  found=0
  for r in "${repos[@]:-}"; do [[ "$r" == "$name" ]] && found=1; done
  [[ $found -eq 0 ]] && orphans+=("$name")
done

# --- Secciones opcionales activas -------------------------------------------

sections=()
for s in architecture conventions operations topics; do
  [[ -d "$DOCS/$s" ]] && sections+=("$s")
done

# --- Escribir el contrato ----------------------------------------------------

json_array() {
  local out="" item
  for item in "$@"; do out="$out\"$item\", "; done
  echo "${out%, }"
}

# El remoto se deduce de lo que ya hay clonado: la plantilla del docs repo, y un
# override por cada repo cuyo origin no encaje con ella. Es lo que permite que
# adopt no pregunte nada y que un proyecto con el código en otra cuenta —el caso
# de un repo de cliente— quede bien declarado a la primera.
TMPL="$(remote_desde_git "$DOCS" 2>/dev/null || echo "")"
overrides=""
for repo in "${repos[@]:-}"; do
  [[ -d "$ROOT/$repo/.git" ]] || continue
  url="$(git -C "$ROOT/$repo" remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || continue
  esperada="${TMPL//\{repo\}/$repo}"
  [[ "$url" == "$esperada" ]] && continue
  overrides="$overrides
      \"$repo\": \"$url\","
done
overrides="${overrides%,}"

if [[ -n "$TMPL" ]]; then
  REMOTE_JSON="  \"remote\": {
    \"url\": \"$TMPL\"$([[ -n "$overrides" ]] && printf ',\n    "repos": {%s\n    }' "$overrides")
  },"
else
  REMOTE_JSON=""
fi

cat > "$CONFIG" <<EOF
{
  "crux": "$(crux_version)",
  "project": "$PROJECT",
  "profile": "$PROFILE",
  "language": "es",
$REMOTE_JSON
  "repos": [$(json_array "${repos[@]:-}")],
  "sections": [$(json_array "${sections[@]:-}")]
}
EOF

ok "escrito $PROJECT-docs/crux.json"
info "perfil $PROFILE · ${#repos[@]} repos · ${#sections[@]} secciones"

if [[ ${#orphans[@]} -gt 0 ]]; then
  echo
  warn "hermanos en disco sin carpeta en repos/ (no se han declarado):"
  for o in "${orphans[@]}"; do info "$o — si es del proyecto: /add-repo-to-docs $o"; done
fi

echo
bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" || true
