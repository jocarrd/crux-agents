#!/usr/bin/env bash
# Claude Code hook (PreToolUse, Bash and file tools).
#
# Stops commands that destroy work irreversibly and the reading of private keys
# and credentials. With the agent permissions skipped, it is the only brake left
# between a wrong deduction and a `reset --hard`.
#
# It does not replace a person: if someone really wants it, they run it
# themselves with `! <command>` in the conversation, and then it is a decision.
# Adapted from the Gentle Shell guard policy.

exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/bin/crux" hook destructive-guard "$@"
