#!/usr/bin/env bash
# Claude Code hook (SessionStart).
#
# When a session is opened, resumed or cleared: brings the machine up to date
# with the remote —repos, contract projects, kernel and tasks— and shows the
# open tasks. On a compaction it stays quiet, because the session is halfway
# through some work.
#
# Tasks are shown as a reminder: the person sees them as is and decides. The
# agent is told they have already been seen and not to push them.
#
# It exists because when switching computers work started on the code from the
# last time that machine was used, with nothing to warn about it.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook session-sync "$@"
