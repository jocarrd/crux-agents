#!/usr/bin/env bash
# Turn-end hook (Stop).
#
# Saves what a workspace has not committed to a hidden ref of this machine, so
# that resuming it on the other machine brings it. Silent, and detached: the
# turn does not wait for the network.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook wip-save "$@"
