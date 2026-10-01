#!/usr/bin/env bash
# Adaptador de Codex para los hooks que dan contexto en texto plano.
#
#   contexto.sh <evento> <hook> [args...]
#
# Claude Code toma como contexto lo que un hook de UserPromptSubmit escribe en
# stdout. Codex solo lo garantiza en JSON (hookSpecificOutput.additionalContext),
# así que aquí se envuelve. El hook no cambia: es el mismo script en los dos
# agentes, y su código de salida y su stderr pasan tal cual.

set -u
evento="$1"; hook="$2"; shift 2

salida="$(bash "$hook" "$@")"
rc=$?
if [[ $rc -ne 0 ]]; then
  [[ -n "$salida" ]] && printf '%s\n' "$salida"
  exit "$rc"
fi
[[ -n "$salida" ]] || exit 0

# Si el hook ya habla JSON, se respeta.
if printf '%s' "$salida" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))' 2>/dev/null; then
  printf '%s\n' "$salida"
  exit 0
fi
node -e '
  const [evento, texto] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: evento, additionalContext: texto } }) + "\n");
' "$evento" "$salida"
