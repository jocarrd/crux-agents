#!/usr/bin/env bash
# Memory adapter — Claude Code.
#
# What this file knows and the kernel does not: where this agent stores its
# memories and how it declares the type of each one.
#
# Emits one line per memory, tab-separated:
#
#   <type>	<scope>	<path>
#
# The type is the one the frontmatter declares. `?` if it declares none and `!`
# if the file is there and cannot be read: the kernel resolves both cases, and
# no default value is invented here just to carry on.
#
# The scope is emitted as the agent names it —the working path with the
# separators changed to hyphens— and undecoded. The way back is ambiguous as
# soon as a project has a hyphen in its name; the kernel is the one that knows
# which projects exist, and the conversion that is unambiguous is theirs.

set -uo pipefail

root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
[[ -d "$root" ]] || exit 0

for dir in "$root"/*/memory; do
  [[ -d "$dir" ]] || continue
  scope_name="$(basename "$(dirname "$dir")")"

  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || continue
    # The index is not a memory: it is the table of contents of the others.
    [[ "$(basename "$f")" == "MEMORY.md" ]] && continue

    if [[ ! -r "$f" ]]; then
      printf '!\t%s\t%s\n' "$scope_name" "$f"
      continue
    fi

    kind="$(awk '
      NR == 1 && $0 != "---" { exit }
      NR > 1 && $0 == "---" { exit }
      /^[[:space:]]*type:[[:space:]]*/ {
        sub(/^[[:space:]]*type:[[:space:]]*/, "")
        gsub(/[[:space:]"'"'"']/, "")
        print
        exit
      }
    ' "$f")"

    printf '%s\t%s\t%s\n' "${kind:-?}" "$scope_name" "$f"
  done
done
