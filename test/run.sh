#!/usr/bin/env bash
# The kernel's test suite.
#
#   test/run.sh              all the cases
#   test/run.sh <pattern>    only those matching the pattern
#
# No dependencies: bash and node, the same the kernel itself needs.
#
# Each case runs in an isolated sandbox with the agent directories redirected,
# so the suite NEVER touches ~/.claude, ~/.codex or ~/Proyectos.

set -uo pipefail

CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export CRUX_HOME
# Read by the commands that in turn run the suite, so they do not call each
# other in a loop.
export CRUX_IN_TESTS=1

PASS=0; FAIL=0; CURRENT=""; FAILED_CASES=()

if [[ -t 1 ]]; then
  T_RED=$'\033[31m'; T_GRN=$'\033[32m'; T_DIM=$'\033[2m'; T_OFF=$'\033[0m'
else
  T_RED=""; T_GRN=""; T_DIM=""; T_OFF=""
fi

# --- Assertions --------------------------------------------------------------
#
# All of them record the failure and carry on: a case can report several
# problems.

_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$CURRENT: $1")
  echo "  ${T_RED}fail${T_OFF} $1"
}

assert_eq() {
  # assert_eq <expected> <got> <description>
  if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — expected '$1', got '$2'"
  fi
}

assert_contains() {
  # assert_contains <text> <fragment> <description>
  if [[ "$1" == *"$2"* ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — does not contain '$2'"
  fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — should not contain '$2'"
  fi
}

assert_file() {
  if [[ -f "$1" ]]; then PASS=$((PASS + 1)); else _fail "$2 — does not exist: $1"; fi
}

assert_symlink() {
  # assert_symlink <path> <expected target> <description>
  if [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; then PASS=$((PASS + 1)); else
    _fail "$3 — $1 does not link to $2"
  fi
}

assert_no_file() {
  if [[ ! -e "$1" ]]; then PASS=$((PASS + 1)); else _fail "$2 — exists and should not: $1"; fi
}

assert_exit() {
  # assert_exit <expected code> <description> <command...>
  local expected="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ $got -eq $expected ]]; then PASS=$((PASS + 1)); else
    _fail "$desc — expected exit $expected, got $got"
  fi
}

# --- Sandbox -----------------------------------------------------------------

sandbox() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/crux-test-XXXXXX")"
  export CRUX_PROJECTS_DIR="$SB/Proyectos"
  export CLAUDE_SKILLS_DIR="$SB/home/.claude/skills"
  # Without this, the memory cases would read the real memories of whoever runs
  # the suite, and the result would depend on the machine.
  export CLAUDE_CONFIG_DIR="$SB/home/.claude"
  # And without this, any case that installs hooks hooks them into the real
  # settings: when the suite runs from a worktree, the machine is left with
  # hooks pointing at a directory that is deleted when the workspace closes.
  export CLAUDE_SETTINGS="$SB/settings.json"
  # The git identity used to come from the machine. A clean runner has none, so
  # the cases' `git commit` failed and a `|| true` swallowed it: the suite
  # passed locally and had been red in CI for days for a reason that looked
  # nothing like the message. A harness cannot depend on the environment.
  export GIT_AUTHOR_NAME="crux test" GIT_AUTHOR_EMAIL="test@localhost"
  export GIT_COMMITTER_NAME="crux test" GIT_COMMITTER_EMAIL="test@localhost"
  export CODEX_PROMPTS_DIR="$SB/home/.codex/prompts"
  export CODEX_HOME_DIR="$SB/home/.codex"
  # Without this, a case that uses workspace and forgets to declare it writes
  # into the real registry of whoever runs the suite.
  export CRUX_REGISTRY="$SB/registry.json"
  # And the local state —marks, locks, the base of the task replica—, which
  # would otherwise be written to the ~/.crux of whoever runs the suite.
  export CRUX_STATE_DIR="$SB/state"
  mkdir -p "$CRUX_PROJECTS_DIR" "$CLAUDE_SKILLS_DIR" "$CODEX_PROMPTS_DIR"
  echo "$SB"
}

teardown() { [[ -n "${SB:-}" && "$SB" == *"crux-test-"* ]] && rm -rf "$SB"; }

crux() { bash "$CRUX_HOME/bin/crux" "$@"; }

new_project() {
  # new_project <name> [init options...] — prints the docs repo path
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

CLEAN_HOME="$HOME"; CLEAN_TMPDIR="${TMPDIR:-/tmp}"; CLEAN_PWD="$PWD"

# Each case starts in an empty directory of its own, never in the one the suite
# was launched from. A `( cd "$ws" && a; b )` whose cd fails runs b right here,
# and from the repo that meant a case writing a red gate receipt into the
# developer's own worktree.
STRAY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crux-test-cwd.XXXXXX")"
trap 'rm -rf "$STRAY_DIR"' EXIT

for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  [[ -n "$PATTERN" && "$fn" != *"$PATTERN"* ]] && continue
  if [[ -n "${CRUX_TEST_FILE:-}" ]]; then
    defined_in="$(shopt -s extdebug; declare -F "$fn" | awk '{print $3}')"
    [[ "$(basename "$defined_in" .sh)" == "$CRUX_TEST_FILE" ]] || continue
  fi
  CURRENT="${fn#test_}"
  echo "${T_DIM}· ${CURRENT//_/ }${T_OFF}"
  before=$FAIL
  cd "$STRAY_DIR" || exit 1
  "$fn"
  # A case that loads a strict script would leave 'set -e' on and kill the
  # suite at the first negative assertion, without saying why.
  set +e; set -uo pipefail

  # And a case that exports HOME or TMPDIR carries them into the next one,
  # which, once the sandbox is deleted, is left pointing at a directory that no
  # longer exists. That hung the whole suite once, without a single message.
  if [[ "$HOME" != "$CLEAN_HOME" || "${TMPDIR:-/tmp}" != "$CLEAN_TMPDIR" ]]; then
    _fail "the case exports HOME or TMPDIR — pass them per invocation, not to the suite shell"
    HOME="$CLEAN_HOME"; TMPDIR="$CLEAN_TMPDIR"
  fi

  # A case that puts the agent settings back to their real place —with an
  # unset, usually— leaves them like that for the next one, and the one that
  # installs hooks hooks those of whoever runs the suite. It happened, and it
  # left the machine with three hooks pointing at a deleted worktree.
  if [[ -n "${SB:-}" && ( -z "${CLAUDE_SETTINGS:-}" || "${CLAUDE_SETTINGS}" == "$CLEAN_HOME"/.claude/* ) ]]; then
    _fail "the case leaves CLAUDE_SETTINGS outside the sandbox — the real hooks end up touched"
    export CLAUDE_SETTINGS="$SB/settings.json"
  fi
  if [[ -n "$(ls -A "$STRAY_DIR" 2>/dev/null)" ]]; then
    _fail "the case wrote into the directory it was started from: $(ls -A "$STRAY_DIR" | tr '\n' ' ')"
    find "$STRAY_DIR" -mindepth 1 -delete
  fi
  cd "$CLEAN_PWD" || exit 1

  teardown
  [[ $FAIL -eq $before ]] || true
done

echo
if [[ $FAIL -eq 0 ]]; then
  echo "${T_GRN}$PASS assertions, 0 failures${T_OFF}"
else
  echo "${T_RED}$FAIL failures${T_OFF} of $((PASS + FAIL)) assertions:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
fi
exit $(( FAIL > 0 ? 1 : 0 ))
