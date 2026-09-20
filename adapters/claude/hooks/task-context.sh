#!/usr/bin/env bash
# Hook de Claude Code (UserPromptSubmit).
#
# Dentro de un espacio de trabajo, recuerda en qué punto quedó su tarea: estado,
# pasos y siguiente paso, con la ruta del registro. Una vez por sesión y por
# espacio.
#
# Existe porque retomar dependía de la conversación. Una compactación, un
# reinicio o volver al día siguiente perdían la lista de pasos y lo comprobado,
# y había que reconstruirlo. La instrucción de "lee el registro al retomar"
# compite por atención; un hook llega solo. Ver ADR-012.

set -u

entrada="$(cat 2>/dev/null || true)"
silencio() { exit 0; }

aqui="$(git rev-parse --show-toplevel 2>/dev/null)" || silencio
[[ "$aqui" == *-ws-* ]] || silencio

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/lib/common.sh" && -f "$kernel/lib/task.mjs" ]] || silencio
# shellcheck source=../../../lib/common.sh
source "$kernel/lib/common.sh"

registro="$(task_file_for_path "${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}" "$aqui" 2>/dev/null)" || silencio
[[ -f "$registro" ]] || silencio

sesion="$(printf '%s' "$entrada" | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try { process.stdout.write(String(JSON.parse(s).session_id || "")); } catch { }
  });
' 2>/dev/null || true)"
[[ -n "$sesion" ]] || sesion="$PPID"

# La marca va a ~/.crux/state y no a /tmp: el nombre llevaba dentro la ruta
# del repo, o sea el cliente y la tarea, en un directorio legible por
# cualquiera en la maquina y sin que nadie las limpiara nunca.
estado="$HOME/.crux/state"
( umask 077 && mkdir -p "$estado" ) 2>/dev/null || true
marca="$estado/task-context-$(printf '%s' "$sesion-$aqui" | \
  cksum | tr -d ' ' | tr -c 'A-Za-z0-9' '_')"
find "$estado" -name 'task-context-*' -type f -mtime +2 -delete 2>/dev/null || true
[[ -e "$marca" ]] && silencio

IFS=$'\x1f' read -r tarea estado pasos siguiente < <(node "$kernel/lib/task.mjs" summary --file "$registro" 2>/dev/null) || silencio
: > "$marca"

echo "Tarea '$tarea' · $estado${pasos:+ · pasos $pasos}${siguiente:+ · siguiente: $siguiente}"
echo "Registro: $registro — léelo antes de seguir; se actualiza con 'crux task'."
