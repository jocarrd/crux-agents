#!/usr/bin/env bash
# Adaptador de Claude para `crux skill test`: responde a la pregunta que llega
# por la entrada estándar siguiendo solo la skill de $CRUX_SKILL_FILE.
#
# Contexto aislado a propósito: prompt de sistema propio, sin MCP y sin
# herramientas, y desde un directorio temporal para que no salten los hooks de
# ningún repo. Con el contexto normal, la base variaba cientos de tokens entre
# llamadas y los hooks de cierre respondían en lugar de la skill.
set -u
: "${CRUX_SKILL_FILE:?falta CRUX_SKILL_FILE}"
cd "$(mktemp -d)" || exit 1
exec claude -p --model "${CRUX_SKILL_MODEL:-haiku}" \
  --system-prompt "Sigue esta skill al pie de la letra. No ejecutas nada: solo respondes qué harías.

$(cat "$CRUX_SKILL_FILE")" \
  --strict-mcp-config --tools ""
