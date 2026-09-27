#!/usr/bin/env bash
# Hook de Claude Code (PreToolUse, Bash).
#
# Para un `gh pr create` lanzado a mano en un repo de código que gestiona crux.
# La propuesta la abre `crux workspace finish`, que es quien exige el recibo de
# la puerta: abrirla a mano sube trabajo sin comprobar por el único camino que
# no vigilaba nadie. El pre-push solo cierra la rama principal.
#
# Solo actúa donde hay contrato (un docs repo con crux.json). En el kernel o en
# un repo sin docs repo, `finish` no aplica y el comando se deja.

set -u

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

parsed="$(printf '%s' "$input" | node -e '
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    let event;
    try { event = JSON.parse(raw); } catch { process.exit(0); }
    const command = String(event.tool_input?.command || "");
    // Igual que el guardia destructivo: lo que no se ejecuta no cuenta.
    const runnable = command
      .replace(/<<-?\s*([\x27"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)/g, " ")
      .replace(/\b(bash|sh|zsh|eval)\s+(-c\s+)?(["\x27])([\s\S]*?)\3/g, " $4 ")
      .replace(/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/g, " \"\" ")
      .replace(/(^|\s)#[^\n]*/g, " ");
    if (!/\bgh\b[^;&|\n]*\bpr\s+(create|new)\b/.test(runnable)) process.exit(0);
    // Si el comando entra antes en otra carpeta, esa es la que cuenta.
    const cd = runnable.match(/(?:^|[;&|]\s*)cd\s+(\S+)\s*&&[^;&|\n]*\bgh\b[^;&|\n]*\bpr\s+(create|new)\b/);
    process.stdout.write(cd ? cd[1] : String(event.cwd || process.cwd()));
  });
' 2>/dev/null)"

[[ -n "$parsed" ]] || exit 0
target="${parsed/#\~/$HOME}"
[[ -d "$target" ]] || exit 0

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)}"
# shellcheck source=../../../lib/common.sh
source "$CRUX_HOME/lib/common.sh" 2>/dev/null || exit 0

toplevel="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || exit 0
docs="$(find_docs_repo "$toplevel" 2>/dev/null)" || exit 0
[[ -n "$docs" && "$docs" != "$toplevel" ]] || exit 0

base="$(basename "$toplevel")"
if [[ "$base" == *-ws-* ]]; then
  next="  crux workspace finish ${base##*-ws-}"
else
  # Fuera de un espacio no hay finish que valga: el trabajo tiene que pasar
  # antes por uno.
  next="  crux workspace new <tarea>     y trabaja ahí; después
  crux workspace finish <tarea>"
fi

cat >&2 <<MSG
Parado: en este proyecto la propuesta la abre crux, no gh pr create a mano.

$next

finish sube la rama y abre la propuesta, pero antes exige el recibo de la
puerta de calidad (crux ship run y crux ship seal). Abrirla a mano se lo salta.

Si una persona lo quiere tal cual, lo ejecuta ella con '! <comando>' en la
conversación.
MSG
exit 2
