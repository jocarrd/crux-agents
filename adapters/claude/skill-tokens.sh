#!/usr/bin/env bash
# Adaptador de Claude para `crux skill test`: cuántos tokens ocupa
# $CRUX_SKILL_FILE, con el tokenizador real del modelo.
#
# Se mide por diferencia: el mismo prompt fijo con y sin el texto. Con el
# contexto aislado la base sale igual en cada llamada; con el normal bailaba
# y la resta no valía.
set -u
: "${CRUX_SKILL_FILE:?falta CRUX_SKILL_FILE}"
cd "$(mktemp -d)" || exit 1
tokens() {
  claude -p --model "${CRUX_SKILL_MODEL:-haiku}" --system-prompt "Responde solo OK." \
    --strict-mcp-config --tools "" --output-format json "$1" 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const u=JSON.parse(s).usage;process.stdout.write(String((u.input_tokens||0)+(u.cache_creation_input_tokens||0)+(u.cache_read_input_tokens||0)))})'
}
base="$(tokens "OK")" || exit 1
con="$(tokens "OK
$(cat "$CRUX_SKILL_FILE")")" || exit 1
echo $((con - base))
