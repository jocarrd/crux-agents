#!/usr/bin/env bash
# Suite de tests del kernel.
#
#   test/run.sh              todos los casos
#   test/run.sh <patrón>     solo los que casan con el patrón
#
# Sin dependencias: bash y node, lo mismo que necesita el propio kernel.
#
# Cada caso corre en un sandbox aislado y con los directorios de agentes
# redirigidos, así que la suite NUNCA toca ~/.claude, ~/.codex ni ~/Proyectos.

set -uo pipefail

CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export CRUX_HOME
# Lo leen los comandos que a su vez ejecutan la suite, para no llamarse en bucle.
export CRUX_IN_TESTS=1

PASS=0; FAIL=0; CURRENT=""; FAILED_CASES=()

if [[ -t 1 ]]; then
  T_RED=$'\033[31m'; T_GRN=$'\033[32m'; T_DIM=$'\033[2m'; T_OFF=$'\033[0m'
else
  T_RED=""; T_GRN=""; T_DIM=""; T_OFF=""
fi

# --- Aserciones --------------------------------------------------------------
#
# Todas registran el fallo y siguen: un caso puede reportar varios problemas.

_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$CURRENT: $1")
  echo "  ${T_RED}fallo${T_OFF} $1"
}

assert_eq() {
  # assert_eq <esperado> <obtenido> <descripción>
  if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — esperaba '$1', obtuve '$2'"
  fi
}

assert_contains() {
  # assert_contains <texto> <fragmento> <descripción>
  if [[ "$1" == *"$2"* ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — no contiene '$2'"
  fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — no debería contener '$2'"
  fi
}

assert_file() {
  if [[ -f "$1" ]]; then PASS=$((PASS + 1)); else _fail "$2 — no existe $1"; fi
}

assert_symlink() {
  # assert_symlink <ruta> <destino esperado> <descripción>
  if [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — $1 no enlaza a $2"
  fi
}

assert_no_file() {
  if [[ ! -e "$1" ]]; then PASS=$((PASS + 1)); else _fail "$2 — existe y no debería: $1"; fi
}

assert_exit() {
  # assert_exit <código esperado> <descripción> <comando...>
  local expected="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ $got -eq $expected ]]; then PASS=$((PASS + 1)); else
    _fail "$desc — esperaba exit $expected, obtuve $got"
  fi
}

# --- Sandbox -----------------------------------------------------------------

sandbox() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/crux-test-XXXXXX")"
  export CRUX_PROJECTS_DIR="$SB/Proyectos"
  export CLAUDE_SKILLS_DIR="$SB/home/.claude/skills"
  export CODEX_PROMPTS_DIR="$SB/home/.codex/prompts"
  export CODEX_HOME_DIR="$SB/home/.codex"
  # Sin esto, un caso que use workspace y olvide declararlo escribe en el
  # registro real de quien ejecuta la suite.
  export CRUX_REGISTRY="$SB/registry.json"
  mkdir -p "$CRUX_PROJECTS_DIR" "$CLAUDE_SKILLS_DIR" "$CODEX_PROMPTS_DIR"
  echo "$SB"
}

teardown() { [[ -n "${SB:-}" && "$SB" == *"crux-test-"* ]] && rm -rf "$SB"; }

crux() { bash "$CRUX_HOME/bin/crux" "$@"; }

new_project() {
  # new_project <nombre> [opciones de init...] — devuelve la ruta del docs repo
  local name="$1"; shift
  crux init "$name" --no-remote --parent "$CRUX_PROJECTS_DIR" "$@" >/dev/null 2>&1
  echo "$CRUX_PROJECTS_DIR/$name/$name-docs"
}

# --- Runner ------------------------------------------------------------------

for f in "$CRUX_HOME"/test/cases/*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

PATTERN="${1:-}"
echo "crux test — $(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
echo

HOME_LIMPIO="$HOME"; TMPDIR_LIMPIO="${TMPDIR:-/tmp}"; PWD_LIMPIO="$PWD"

for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  [[ -n "$PATTERN" && "$fn" != *"$PATTERN"* ]] && continue
  CURRENT="${fn#test_}"
  echo "${T_DIM}· ${CURRENT//_/ }${T_OFF}"
  before=$FAIL
  "$fn"
  # Un caso que cargue un script estricto dejaría 'set -e' activo y mataría la
  # suite en la primera aserción negativa, sin decir por qué.
  set +e; set -uo pipefail

  # Y un caso que exporte HOME o TMPDIR se los lleva al siguiente, que al
  # borrarse el sandbox se queda apuntando a un directorio que ya no existe.
  # Eso colgó la suite entera una vez, sin un solo mensaje.
  if [[ "$HOME" != "$HOME_LIMPIO" || "${TMPDIR:-/tmp}" != "$TMPDIR_LIMPIO" ]]; then
    _fail "el caso exporta HOME o TMPDIR — pásalos por invocación, no al shell de la suite"
    HOME="$HOME_LIMPIO"; TMPDIR="$TMPDIR_LIMPIO"
  fi
  cd "$PWD_LIMPIO" || exit 1

  teardown
  [[ $FAIL -eq $before ]] || true
done

echo
if [[ $FAIL -eq 0 ]]; then
  echo "${T_GRN}$PASS aserciones, 0 fallos${T_OFF}"
else
  echo "${T_RED}$FAIL fallos${T_OFF} de $((PASS + FAIL)) aserciones:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
fi
exit $(( FAIL > 0 ? 1 : 0 ))
