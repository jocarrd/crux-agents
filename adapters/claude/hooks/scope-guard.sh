#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash, file tools and connectors).
#
# Keeps a session inside the work scope it is pinned to (ADR-025): another
# scope, an isolated project, a secret declared elsewhere or a private note of
# the profile need a new session. Without scopes declared it does nothing.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook scope-guard "$@"
