#!/usr/bin/env bash
# Session-end hook (Stop).
#
# Warns about the memories that the standard keeps in git and that are still
# only local. Silent as long as there are none.
#
# It lives in a hook and not in the closing ritual because the ritual was
# invoked in 2 of 46 sessions: the rule existed, the check depended on someone
# remembering, and project memories stayed on one machine.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook memory-guard "$@"
