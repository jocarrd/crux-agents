#!/usr/bin/env bash
# git hook (post-commit), installed in each repo by `crux hooks install`. A
# workspace's branch is published by `crux hook post-commit` in the
# background; the commit never waits for it nor fails because of it.
KERNEL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

crux="${CRUX_BIN:-$HOME/.local/bin/crux}"
[[ -x "$crux" ]] || crux="$KERNEL/bin/crux"
[[ -x "$crux" ]] || exit 0
"$crux" hook post-commit >/dev/null 2>&1
exit 0
