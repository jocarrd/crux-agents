#!/usr/bin/env bash
# Hook de Claude Code (SessionStart).
#
# Al abrir, retomar o limpiar una sesión: pone la máquina al día con el remoto
# —repos, proyectos del contrato, kernel y tareas— y enseña las tareas abiertas.
# En una compactación calla, porque la sesión está a mitad de trabajo.
#
# Las tareas se enseñan como recordatorio: la persona las ve tal cual y decide.
# Al agente le llega que ya las ha visto y que no las empuje.
#
# Existe porque al alternar de ordenador se empezaba a trabajar sobre el código
# de la última vez que se usó esa máquina, sin que nada lo advirtiera.

set -u

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/bin/sync.sh" ]] || exit 0

entrada="$(cat 2>/dev/null || true)"
campo() {
  printf '%s' "$entrada" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d));
    process.stdin.on("end", () => {
      try { process.stdout.write(String(JSON.parse(s)[process.argv[1]] ?? "")); } catch {}
    });' "$1" 2>/dev/null
}
origen="$(campo source)"
cwd="$(campo cwd)"
sesion="$(campo session_id)"
[[ "$origen" == "compact" ]] && exit 0

# La hora de la última actividad de la sesión, para el hook que avisa al volver
# a una sesión que llevaba horas parada.
estado="${CRUX_STATE_DIR:-$HOME/.crux/state}/sesiones"
if [[ -n "$sesion" ]]; then
  ( umask 077 && mkdir -p "$estado" ) 2>/dev/null && : > "$estado/$(printf '%s' "$sesion" | tr -c 'A-Za-z0-9-' '_')"
fi

sincronizado="$(bash "$kernel/bin/sync.sh" --hook < /dev/null 2>/dev/null || true)"
recordatorio="$(node "$kernel/lib/task-sync.mjs" remind --cwd "${cwd:-$PWD}" 2>/dev/null || true)"
[[ -z "$sincronizado" && -z "$recordatorio" ]] && exit 0

node -e '
  const [sinc, rec] = process.argv.slice(1);
  const r = rec ? JSON.parse(rec) : null;
  // Con el mod de Claude Code activo, el recordatorio lo pinta él como panel;
  // al modelo le sigue llegando igual. Sin el mod (Codex, la web, el móvil),
  // la persona lo lee aquí.
  const panel = process.env.CRUX_REMINDER_UI === "panel";
  const usuario = [panel ? null : r?.usuario, sinc].filter(Boolean).join("\n\n");
  const agente = [sinc, r?.agente].filter(Boolean).join("\n\n");
  process.stdout.write(JSON.stringify({
    ...(usuario ? { systemMessage: usuario } : {}),
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: agente },
  }));
' "$sincronizado" "$recordatorio"
exit 0
