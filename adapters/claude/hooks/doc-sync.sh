#!/usr/bin/env bash
# Hook de Claude Code (PostToolUse / Stop).
#
# Si el agente tocó ficheros que la documentación del repo menciona, se lo
# recuerda antes de cerrar. Silencioso mientras no haya nada que verificar.
#
# La raíz de proyectos sale de la configuración, no de una carpeta asumida: en
# una máquina con otra convención este hook no fallaba, simplemente no hacía
# nada, y el sistema parecía vigilado sin estarlo.

set -u

raiz="${CRUX_PROJECTS_DIR:-}"
if [[ -z "$raiz" && -f "$HOME/.crux/config" ]]; then
  raiz="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  if [[ -z "$raiz" ]]; then
    kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
    [[ -n "$kernel" ]] && raiz="$(dirname "$kernel")"
  fi
fi
[[ -n "$raiz" ]] || exit 0

cwd="$(pwd)"
case "$cwd/" in
  "$raiz"/*/*/*) ;;
  *) exit 0 ;;
esac

rel="${cwd#"$raiz"/}"
project="${rel%%/*}"
rest="${rel#*/}"
repo="${rest%%/*}"

docs_root="$raiz/$project/$project-docs"
[[ -d "$docs_root/repos/$repo" ]] || exit 0

cd "$cwd" 2>/dev/null || exit 0
modified="$(git status --porcelain 2>/dev/null | awk '$1 !~ /^\?\?$/ {print $2}')"
[[ -z "$modified" ]] && exit 0

hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.lock|*lock.yaml|*lock.json|*tsbuildinfo|.env*|*.log) continue ;;
  esac
  basename="${f##*/}"
  if grep -rqF "$f" "$docs_root/repos/$repo/" 2>/dev/null; then
    hits+="  - $f (referenciado por ruta completa)\n"
  elif grep -rqF "\`$basename\`" "$docs_root/repos/$repo/" 2>/dev/null; then
    hits+="  - $f (referenciado por nombre)\n"
  fi
done <<< "$modified"

if [[ -n "$hits" ]]; then
  echo "sync discipline: tocaste ficheros referenciados en $project-docs/repos/$repo/"
  echo -e "$hits"
  echo "Revisa si la documentación sigue alineada antes de cerrar."
fi

exit 0
