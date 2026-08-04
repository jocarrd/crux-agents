#!/usr/bin/env bash
# Batería de extremo a extremo: el ciclo completo sobre un proyecto de verdad.
#
#   test/e2e.sh
#
# La suite de test/run.sh prueba piezas. Esto prueba el recorrido: crear el
# proyecto, registrar un repo, instalar las guardas, abrir un espacio, pasar la
# puerta, proponer y fusionar. Los fallos más caros del kernel han aparecido
# aquí y no allí, porque solo se ven cuando las piezas se usan seguidas.
#
# No depende de ningún proveedor: el remoto es un repo bare local.

set -uo pipefail

CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export CRUX_HOME CRUX_IN_TESTS=1

SB="$(mktemp -d "${TMPDIR:-/tmp}/crux-e2e-XXXXXX")"
export CRUX_PROJECTS_DIR="$SB/proyectos"
export CLAUDE_SKILLS_DIR="$SB/home/.claude/skills"
export CODEX_PROMPTS_DIR="$SB/home/.codex/prompts"
export CODEX_HOME_DIR="$SB/home/.codex"
export CRUX_REGISTRY="$SB/workspaces.json"
mkdir -p "$CRUX_PROJECTS_DIR" "$CLAUDE_SKILLS_DIR" "$CODEX_PROMPTS_DIR"

PASO=0; FALLOS=0
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; D=$'\033[2m'; O=$'\033[0m'; else R=""; G=""; D=""; O=""; fi

paso()  { PASO=$((PASO + 1)); echo "${D}$PASO. $*${O}"; }
bien()  { echo "   ${G}ok${O} $*"; }
mal()   { FALLOS=$((FALLOS + 1)); echo "   ${R}fallo${O} $*"; }
cierto(){ if eval "$1"; then bien "$2"; else mal "$2"; fi; }

git_() { git -c user.email=e2e@localhost -c user.name=e2e "$@"; }

crux() { bash "$CRUX_HOME/bin/crux" "$@"; }

# CRUX_E2E_KEEP=1 conserva el sandbox: sin él, depurar un paso que falla exige
# reproducir todo el recorrido a mano.
[[ "${CRUX_E2E_KEEP:-0}" == "1" ]] || trap 'rm -rf "$SB"' EXIT

echo "e2e — el ciclo completo en $SB"
echo

# --- 1. Un proyecto nuevo, con su remoto -------------------------------------

paso "crear el proyecto"
REMOTO="$SB/remotos/demo-docs.git"
mkdir -p "$(dirname "$REMOTO")"
# El HEAD del bare decide qué rama saca un clon: si apunta a una que no existe,
# el clon sale vacío sin decir por qué.
git init -q --bare -b main "$REMOTO" 2>/dev/null || { git init -q --bare "$REMOTO"; git -C "$REMOTO" symbolic-ref HEAD refs/heads/main; }
crux init demo --no-remote --parent "$CRUX_PROJECTS_DIR" --repos api >/dev/null 2>&1
DOCS="$CRUX_PROJECTS_DIR/demo/demo-docs"
cierto '[[ -f "$DOCS/crux.json" ]]' "el docs repo existe"
cierto '[[ "$(git -C "$DOCS" rev-parse --abbrev-ref HEAD)" == "main" ]]' "nace en la rama declarada"
git -C "$DOCS" remote add origin "$REMOTO"

paso "el repo de código, registrado y enlazado"
REPO="$CRUX_PROJECTS_DIR/demo/api"
mkdir -p "$REPO/src" && git init -q -b main "$REPO"
echo "export const uno = 1;" > "$REPO/src/index.js"
git_ -C "$REPO" add -A && git_ -C "$REPO" commit -qm "chore: init"
crux link "$DOCS" >/dev/null 2>&1
cierto '[[ -f "$REPO/AGENTS.md" && -f "$REPO/CLAUDE.md" ]]' "los punteros están en el repo de código"
cierto 'grep -q "crux:begin" "$REPO/AGENTS.md"' "y llevan el bloque gestionado"

paso "conformidad"
bash "$CRUX_HOME/bin/doctor.sh" "$DOCS" >/dev/null 2>&1
cierto '[[ $? -eq 0 ]]' "doctor pasa sobre el proyecto recién creado"

# --- 2. Las guardas ----------------------------------------------------------

paso "instalar las guardas"
( cd "$DOCS" && crux hooks install >/dev/null 2>&1 )
cierto '[[ -x "$DOCS/.git/hooks/pre-push" ]]' "pre-push instalado"
cierto 'grep -q "refs/heads/main" "$DOCS/.git/hooks/pre-push"' "vigila la rama principal declarada"

paso "el push directo a la principal se bloquea"
git_ -C "$DOCS" add -A >/dev/null 2>&1
git_ -C "$DOCS" commit -qm "docs: initial" >/dev/null 2>&1
salida="$(git -C "$DOCS" push origin main 2>&1)"
cierto '[[ "$salida" == *"bloqueado"* ]]' "el hook lo impide"
cierto '! git -C "$REMOTO" show-ref --verify --quiet refs/heads/main' "y nada llegó al remoto"

paso "el mensaje de commit fuera del idioma se rechaza"
( cd "$REPO" && crux hooks install >/dev/null 2>&1 )
echo "// dos" >> "$REPO/src/index.js"
git_ -C "$REPO" add -A
salida="$(git_ -C "$REPO" commit -m "feat: esto es para que el usuario pueda ver una cosa" 2>&1)"
cierto '[[ "$salida" == *"español"* ]]' "el hook lo rechaza"
git_ -C "$REPO" commit -qm "feat: add a second export" >/dev/null 2>&1

# --- 3. El ciclo -------------------------------------------------------------

paso "abrir el espacio de trabajo"
( cd "$REPO" && crux workspace new tarea >/dev/null 2>&1 )
WS="$CRUX_PROJECTS_DIR/demo/api-ws-tarea"
cierto '[[ -d "$WS" ]]' "el worktree existe"
cierto '[[ "$(git -C "$WS" rev-parse --abbrev-ref HEAD)" == "ws/tarea" ]]' "en su propia rama"

paso "desarrollar y pasar la puerta"
echo "export const tres = 3;" >> "$WS/src/index.js"
mkdir -p "$WS/test" && echo "// prueba" > "$WS/test/index.test.js"
git_ -C "$WS" add -A && git_ -C "$WS" commit -qm "feat: add a third export" >/dev/null 2>&1
printf '%s\n' "$(git -C "$WS" rev-parse HEAD)" > "$WS/.crux-ship"
cierto '[[ -z "$(git -C "$WS" status --porcelain)" ]]' "la marca de la puerta no ensucia el repo"

paso "reunir el material de la revisión"
salida="$(bash "$CRUX_HOME/bin/review.sh" --repo "$WS" --base main 2>&1)"
cierto '[[ "$salida" == *"ws/tarea"* ]]' "review dice qué rama revisa"
cierto '[[ "$salida" == *"src/index.js"* ]]' "y qué ficheros toca"

paso "proponer el cambio"
git -C "$REPO" remote add origin "$SB/remotos/api.git" 2>/dev/null
git init -q --bare -b main "$SB/remotos/api.git" 2>/dev/null \
  || { git init -q --bare "$SB/remotos/api.git"; git -C "$SB/remotos/api.git" symbolic-ref HEAD refs/heads/main; }
salida="$( cd "$WS" && crux workspace finish tarea 2>&1 )"
cierto '[[ "$salida" != *"sin commitear"* ]]' "la marca de la puerta no bloquea la propuesta"
cierto 'git -C "$SB/remotos/api.git" show-ref --verify --quiet refs/heads/ws/tarea' "la rama llegó al remoto"

paso "cerrar el espacio"
( cd "$REPO" && crux workspace rm tarea >/dev/null 2>&1 )
cierto '[[ ! -d "$WS" ]]' "el worktree se retira"
cierto '! grep -q "\"tarea\"" "$CRUX_REGISTRY"' "y el slot queda libre"

# --- 4. Otra máquina ---------------------------------------------------------

paso "el proyecto se recupera en otra máquina"
# La integración la hace la propuesta; aquí se simula su resultado, que es lo
# único que importa para la pregunta: ¿sobrevive el proyecto al cambio de
# máquina?
git -C "$DOCS" push -q --no-verify origin main 2>/dev/null
OTRA="$SB/otra"
mkdir -p "$OTRA"
git clone -q "$REMOTO" "$OTRA/demo-docs" 2>/dev/null
cierto '[[ -f "$OTRA/demo-docs/crux.json" ]]' "el docs repo viaja por git"
cierto '[[ -f "$OTRA/demo-docs/repos/api/README.md" ]]' "con la documentación de sus repos"

echo
if [[ $FALLOS -eq 0 ]]; then
  echo "${G}e2e correcto${O} — $PASO pasos del ciclo"
else
  echo "${R}$FALLOS fallos${O} en $PASO pasos"
fi
exit $(( FALLOS > 0 ? 1 : 0 ))
