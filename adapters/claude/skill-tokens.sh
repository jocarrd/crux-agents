#!/usr/bin/env bash
# Claude adapter for `crux skill test`: how many tokens $CRUX_SKILL_FILE takes,
# with the model's real tokenizer.
#
# It is measured by difference: the same fixed prompt with and without the text.
# With the isolated context the base comes out the same on every call; with the
# normal one it fluctuated and the subtraction was worthless.
set -u
: "${CRUX_SKILL_FILE:?CRUX_SKILL_FILE is missing}"
crux="$(cd "$(dirname "$0")/../.." && pwd)/bin/crux"
cd "$(mktemp -d)" || exit 1
tokens() {
  claude -p --model "${CRUX_SKILL_MODEL:-haiku}" --system-prompt "Reply only OK." \
    --strict-mcp-config --tools "" --output-format json "$1" >out.json 2>/dev/null || return 1
  local total=0 key n
  for key in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
    n="$("$crux" __fn json_get out.json "usage.$key")"
    total=$((total + ${n:-0}))
  done
  echo "$total"
}
base="$(tokens "OK")" || exit 1
with_text="$(tokens "OK
$(cat "$CRUX_SKILL_FILE")")" || exit 1
echo $((with_text - base))
