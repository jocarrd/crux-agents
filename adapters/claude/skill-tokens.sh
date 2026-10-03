#!/usr/bin/env bash
# Claude adapter for `crux skill test`: how many tokens $CRUX_SKILL_FILE takes,
# with the model's real tokenizer.
#
# It is measured by difference: the same fixed prompt with and without the text.
# With the isolated context the base comes out the same on every call; with the
# normal one it fluctuated and the subtraction was worthless.
set -u
: "${CRUX_SKILL_FILE:?CRUX_SKILL_FILE is missing}"
cd "$(mktemp -d)" || exit 1
tokens() {
  claude -p --model "${CRUX_SKILL_MODEL:-haiku}" --system-prompt "Reply only OK." \
    --strict-mcp-config --tools "" --output-format json "$1" 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const u=JSON.parse(s).usage;process.stdout.write(String((u.input_tokens||0)+(u.cache_creation_input_tokens||0)+(u.cache_read_input_tokens||0)))})'
}
base="$(tokens "OK")" || exit 1
with_text="$(tokens "OK
$(cat "$CRUX_SKILL_FILE")")" || exit 1
echo $((with_text - base))
