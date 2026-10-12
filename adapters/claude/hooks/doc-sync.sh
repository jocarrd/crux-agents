#!/usr/bin/env bash
# Claude Code hook (Stop) — the documentation gate.
#
# It used to watch a single thing: that you did not close with uncommitted
# files that the docs mention by name. That left out the case that really does
# harm, which was verified on 2026-09-02: a session that measures things,
# discovers a risk and resolves an open question, commits clean, and closes
# without any of that knowledge reaching the docs repo. With a clean tree the
# hook exited at the first check and the system looked watched without being so.
#
# Now it does two things:
#
#   1. Measures the drift between code and documentation (crux __check drift).
#   2. If the session has moved something, it BLOCKS the close once and forces
#      an answer about what of what was discussed stays in git.
#
# It blocks at most once per session: the second pass exits on its own. A hook
# that always blocks ends up uninstalled, and then it watches nothing.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook doc-sync "$@"
