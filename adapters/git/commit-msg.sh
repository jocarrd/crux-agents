#!/usr/bin/env bash
# git hook (commit-msg), installed in each repo by `crux hooks install`. The
# checks are crux's: `crux hook commit-msg`. The installer writes the scope and
# language the project's profile asks for, and the kernel it was installed
# from, which serves when crux is not on this machine's PATH.
SCOPE="${CRUX_COMMIT_MSG_SCOPE:-full}"
COMMIT_LANG="${CRUX_COMMIT_MSG_LANG:-en}"
KERNEL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

# The binary named by CRUX_BIN, as everywhere in crux; then the installed one,
# which is always the current version; then the kernel it was installed from.
crux="${CRUX_BIN:-$HOME/.local/bin/crux}"
[[ -x "$crux" ]] || crux="$KERNEL/bin/crux"
[[ -x "$crux" ]] || { echo "crux: commit message not checked, crux is not installed" >&2; exit 0; }
CRUX_COMMIT_MSG_SCOPE="$SCOPE" CRUX_COMMIT_MSG_LANG="$COMMIT_LANG" exec "$crux" hook commit-msg "$@"
