#!/usr/bin/env bash
# crux review — reúne el material de la revisión de una propuesta.
#
#   crux review [--base <rama>] [--repo <dir>]
#
# No revisa: prepara. La revisión la hace `/review-pr` con esto delante, y así
# no depende de que alguien se acuerde de juntar el diff, la propuesta y las
# comprobaciones.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="$PWD"; BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) die "opción desconocida: $1" ;;
  esac
done

REPO="$(cd "$REPO" && git rev-parse --show-toplevel 2>/dev/null)" || die "no es un repo git: $REPO"
cd "$REPO" || die "no puedo entrar en $REPO"

RAMA="$(git rev-parse --abbrev-ref HEAD)"

if [[ -z "$BASE" ]]; then
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/##')"
  [[ -n "$BASE" ]] || for c in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null && { BASE="$c"; break; }
  done
fi
[[ -n "$BASE" ]] || die "no encuentro la rama base — pásala con --base"

[[ "$(git rev-parse "$RAMA")" != "$(git rev-parse "$BASE" 2>/dev/null)" ]] \
  || die "$RAMA está en el mismo commit que $BASE: no hay nada que revisar"

nombre="$(basename "$REPO")"
es_worktree "$REPO" && nombre="$(basename "$(repo_principal "$REPO")")"
echo "revisión de $RAMA sobre $BASE — $nombre"
echo

# --- 1. Qué se propone -------------------------------------------------------

section_head() { echo; echo "${C_DIM}── $* ${C_OFF}"; }

section_head "commits"
git log --oneline "$BASE..$RAMA" | sed 's/^/      /'

section_head "ficheros"
git diff --stat "$BASE...$RAMA" | sed 's/^/      /'

sucio="$(git status --porcelain | head -5)"
[[ -n "$sucio" ]] && { warn "hay cambios sin commitear: no entran en la propuesta"; echo "$sucio" | sed 's/^/      /'; }

# --- 2. La propuesta y sus comprobaciones ------------------------------------

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  pr="$(gh pr view "$RAMA" --json number,title,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null || true)"
  if [[ -n "$pr" ]]; then
    section_head "propuesta"
    node -e '
      const d = JSON.parse(process.argv[1]);
      console.log(`      #${d.number} ${d.title}`);
      console.log(`      ${d.mergeable} · ${d.mergeStateStatus}`);
      const checks = d.statusCheckRollup || [];
      if (!checks.length) {
        console.log("      sin comprobaciones automáticas — nada las bloquea no es lo mismo que verificado");
      } else {
        for (const c of checks) {
          console.log(`      ${(c.conclusion || c.state || "?").toLowerCase().padEnd(10)} ${c.name || c.context}`);
        }
      }
    ' "$pr"
  else
    info "sin propuesta abierta para $RAMA"
  fi
fi

# --- 3. Señales objetivas ----------------------------------------------------
#
# No son veredictos: son los sitios donde mirar primero. Cada una ha aparecido
# en una revisión real como el hallazgo que nadie vio.

section_head "señales"

hay_senal=0
senal() { hay_senal=1; warn "$*"; }

ficheros="$(git diff --name-only "$BASE...$RAMA")"
codigo="$(echo "$ficheros" | grep -vE '\.(md|txt|json|ya?ml|lock)$|^docs/' || true)"
tests="$(echo "$ficheros" | grep -iE '(^|/)(test|tests|spec|__tests__)/|\.(test|spec)\.[a-z]+$' || true)"

[[ -n "$codigo" && -z "$tests" ]] && senal "toca código y no toca ningún test"

# Un console.log en un test es su forma de reportar, no trabajo a medias.
rutas_codigo=()
while IFS= read -r r; do [[ -n "$r" ]] && rutas_codigo+=("$r"); done < <(
  echo "$codigo" | grep -ivE '(^|/)(test|tests|spec|__tests__)/|\.(test|spec)\.[a-z]+$' || true)
anadidas="$(git diff "$BASE...$RAMA" -- ${rutas_codigo[@]+"${rutas_codigo[@]}"} 2>/dev/null \
  | grep '^+' | grep -v '^+++' || true)"

marcas="$(echo "$anadidas" | grep -owE 'TODO|FIXME|XXX|HACK|console\.log|debugger|binding\.pry' \
  | sort -u | tr '\n' ' ' || true)"
[[ -n "${marcas// /}" ]] && senal "añade marcadores de trabajo a medias: ${marcas% }"

secretos="$(echo "$anadidas" | grep -oiE '(api[_-]?key|secret|token|password|passwd)["'"'"']?\s*[:=]\s*["'"'"'][^"'"'"']{8,}' | head -3 || true)"
[[ -n "$secretos" ]] && senal "parece haber credenciales en el diff — compruébalo antes de nada"

deps="$(echo "$ficheros" | grep -iE 'package\.json|.*\.lock$|requirements.*\.txt|pyproject\.toml|go\.mod|Cargo\.toml|Gemfile' || true)"
[[ -n "$deps" ]] && senal "cambia dependencias: $(echo "$deps" | tr '\n' ' ')"

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  n="$(wc -l < "$f")"
  [[ "$n" -gt 700 ]] && senal "$f queda en $n líneas"
done <<< "$ficheros"

grandes="$(git diff --numstat "$BASE...$RAMA" | awk '$1 + $2 > 400 {print $3" ("$1"+/"$2"-)"}' || true)"
[[ -n "$grandes" ]] && senal "cambios grandes de revisar de una sentada: $(echo "$grandes" | tr '\n' ' ')"

[[ $hay_senal -eq 0 ]] && ok "ninguna señal automática"

# --- 4. Riesgo y especialistas ---------------------------------------------
#
# Qué revisores especialistas merece la propuesta y quién la fusiona. Lo decide
# el diff y no el humor del momento: a ojo todo parece de riesgo bajo.

section_head "riesgo y especialistas"
alcance="$(bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" "$BASE" 2>&1)" \
  || die "no se pudo clasificar la propuesta: $alcance"
echo "$alcance" | grep -v '^base:' | sed 's/^/      /'

# --- 5. El diff -------------------------------------------------------------

section_head "el diff, para leerlo entero"
echo "      git diff $BASE...$RAMA"

echo
info "esto es el material, no la revisión: la revisión es /review-pr"
exit 0
