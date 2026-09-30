#!/usr/bin/env bash
# Hook de Claude Code (UserPromptSubmit).
#
# Una sesión que se deja abierta y se retoma horas después no pasa por
# SessionStart: para Claude Code no ha empezado nada. Aquí se mide el hueco
# desde el último mensaje y, si pasa de CRUX_TASKS_IDLE_HOURS (3 por defecto),
# se hace lo mismo que al abrir: poner la máquina al día y enseñar las tareas
# abiertas, como recordatorio y sin empujar a retomarlas.

set -u

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/lib/task-sync.mjs" ]] || exit 0

entrada="$(cat 2>/dev/null || true)"
datos="$(printf '%s' "$entrada" | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try { const j = JSON.parse(s); process.stdout.write(`${j.session_id || ""}\t${j.cwd || ""}`); } catch {}
  });' 2>/dev/null)"
IFS=$'\t' read -r sesion cwd <<< "$datos"
[[ -n "$sesion" ]] || exit 0

estado="${CRUX_STATE_DIR:-$HOME/.crux/state}/sesiones"
( umask 077 && mkdir -p "$estado" ) 2>/dev/null || exit 0
marca="$estado/$(printf '%s' "$sesion" | tr -c 'A-Za-z0-9-' '_')"
find "$estado" -type f -mtime +30 -delete 2>/dev/null || true

horas="${CRUX_TASKS_IDLE_HOURS:-3}"
[[ "$horas" =~ ^[0-9]+$ ]] || horas=3
parada=0
# Sin marca es el primer mensaje: de eso ya se ocupó el inicio de sesión.
if [[ -f "$marca" && -n "$(find "$marca" -mmin +"$((horas * 60))" 2>/dev/null)" ]]; then
  parada=1
fi
: > "$marca"
[[ $parada -eq 1 ]] || exit 0

sincronizado="$(bash "$kernel/bin/sync.sh" --hook < /dev/null 2>/dev/null || true)"
recordatorio="$(node "$kernel/lib/task-sync.mjs" remind --cwd "${cwd:-$PWD}" 2>/dev/null || true)"
[[ -z "$sincronizado" && -z "$recordatorio" ]] && exit 0

node -e '
  const [sinc, rec, horas] = process.argv.slice(1);
  const r = rec ? JSON.parse(rec) : null;
  const intro = `Vuelves a esta sesión después de más de ${horas} h.`;
  const usuario = [intro, r?.usuario, sinc].filter(Boolean).join("\n\n");
  const agente = [intro, sinc, r?.agente].filter(Boolean).join("\n\n");
  process.stdout.write(JSON.stringify({
    systemMessage: usuario,
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: agente },
  }));
' "$sincronizado" "$recordatorio" "$horas"
exit 0
