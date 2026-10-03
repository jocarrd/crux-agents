#!/usr/bin/env bash
# Session-end hook (Stop).
#
# Warns about the memories that the standard keeps in git and that are still
# only local. Silent as long as there are none.
#
# It lives in a hook and not in the closing ritual because the ritual was
# invoked in 2 of 46 sessions: the rule existed, the check depended on someone
# remembering, and project memories stayed on one machine.

set -u

kernel="${CRUX_HOME:-}"
if [[ -z "$kernel" && -f "$HOME/.crux/config" ]]; then
  kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
fi
[[ -n "$kernel" && -f "$kernel/bin/memory.sh" ]] || exit 0

# One line, not the whole report: this fires at every session close, and a
# warning that takes up half the screen is learned to be ignored in two days.
bash "$kernel/bin/memory.sh" --brief 2>&1

exit 0
