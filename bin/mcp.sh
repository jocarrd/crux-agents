#!/usr/bin/env bash
# crux mcp — the MCP servers the project declares, placed where the agent
# reads them.
#
#   crux mcp status     what the contract declares, what is written and whether it responds
#   crux mcp install    writes the .mcp.json files of the repos that apply
#   crux mcp remove     removes only what the contract declares
#
# An MCP is a capability of the project, not of the machine: the one needed in
# one gets in the way in another. That is why it is declared in `crux.json` and
# travels in git, like the context pointers, and not in each laptop's local
# configuration —which is what `claude mcp add` does and what is lost when
# changing machines.
#
# The contract rules. Each repo's .mcp.json is derived: `install` rewrites it,
# `remove` removes what is declared and whatever someone put there by hand
# stays where it is.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

ADAPTER="$CRUX_HOME/adapters/claude/mcp.mjs"

DOCS="$(find_docs_repo "$PWD" 2>/dev/null)" || die "no docs repo found from here"
CONTRACT="$DOCS/crux.json"
[[ -f "$CONTRACT" ]] || die "no crux.json in $DOCS"

PROFILE="$(json_get "$CONTRACT" profile 2>/dev/null || echo "multi-repo")"
ROOT="$(dirname "$DOCS")"

# A server's name comes from a contract that travels in git, so it is never
# concatenated into an expression: `json_get` passes it through `eval`, and a
# name with a quote ran code just by reading the project. Here it goes as an
# argument, where it is not code.
mcp_field() {
  # mcp_field <name> <field> — a field of the server, or nothing if it is not there
  node -e '
    const fs = require("fs");
    const [file, name, field] = process.argv.slice(1);
    const d = ((JSON.parse(fs.readFileSync(file, "utf8")).mcp || {})[name] || {})[field];
    if (d === undefined || d === null) process.exit(2);
    process.stdout.write((Array.isArray(d) ? d.join(" ") : String(d)) + "\n");
  ' "$CONTRACT" "$1" "$2" 2>/dev/null || true
}

declared_names() {
  json_get "$CONTRACT" 'mcp && Object.keys(root.mcp)' 2>/dev/null || true
}

# A server's targets. Resolving `repos` lives in the kernel next to the
# format's, so that `doctor` knows where a file should be without deducing it
# on its own; here only what the profile allows is applied to it.
targets() {
  local name="$1" repo
  echo "$DOCS"

  # The client profile says nothing is written in their repo: no pointers, no
  # AGENTS.md, no folders. A .mcp.json is exactly the same, so the decision is
  # already made and here it is only respected.
  local writes_outside; writes_outside="$(profile_get "$PROFILE" "$DOCS" pointers.write true)"

  # With `node -e`, argv[1] is already the first argument: there is no script
  # name in front. And the error is not hidden — if this fails, the server
  # would be left without half its targets with nobody saying so.
  local requested
  requested="$(node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { reposOf } from "'"$CRUX_HOME"'/lib/mcp-format.mjs";
    const [file, name] = process.argv.slice(1);
    const contract = JSON.parse(readFileSync(file, "utf8"));
    process.stdout.write(reposOf(contract, name).join("\n"));
  ' "$CONTRACT" "$name")" || die "could not resolve the repos of '$name'"

  [[ -n "$requested" ]] || return 0
  if [[ "$writes_outside" != "true" ]]; then
    warn "$name: the '$PROFILE' profile does not write in code repos — only in the docs repo" >&2
    return 0
  fi

  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if [[ -d "$ROOT/$repo" ]]; then echo "$ROOT/$repo"
    else warn "$name: declares the repo '$repo', which is not cloned" >&2; fi
  done <<<"$requested"
}

all_targets() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] && targets "$n"
  done < <(declared_names) | sort -u
}

# --- status ------------------------------------------------------------------

cmd_status() {
  local names; names="$(declared_names)"
  if [[ -z "$names" ]]; then
    info "the contract declares no MCP server"
    return 0
  fi

  echo "declared in $(basename "$DOCS")/crux.json"
  local n transport where
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    transport="$(mcp_field "$n" transport)"; transport="${transport:-stdio}"
    if [[ "$transport" == "stdio" ]]; then where="$(mcp_field "$n" command)"
    else where="$(mcp_field "$n" url)"; fi
    info "$(printf '%-18s %-6s %s' "$n" "$transport" "${where:-?}")"
  done <<<"$names"

  echo
  echo "written in the repos"
  local dir output rc
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rc=0
    output="$(node "$ADAPTER" diff "$CONTRACT" "$dir" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      # A file that cannot be read is exactly the one that cannot vanish from
      # the report: the repo would look healthy by not appearing.
      err "$(basename "$dir") — $output"
      continue
    fi
    local line
    while IFS= read -r line; do
      case "$line" in
        ok\ *)      ok "$(basename "$dir") — ${line#ok }" ;;
        missing\ *) warn "$(basename "$dir") — missing ${line#missing }; run 'crux mcp install'" ;;
        differs\ *) warn "$(basename "$dir") — ${line#differs } differs from the contract; 'crux mcp install'" ;;
        foreign\ *) info "$(basename "$dir") — ${line#foreign } was put there by hand; crux does not touch it" ;;
      esac
    done <<<"$output"
  done < <(all_targets)

  echo
  echo "do they respond?"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    try_out "$n"
  done <<<"$names"
}

# A declared server that does not respond is the broken-hook problem: the
# project seems to have a capability it does not have. With stdio the process
# is not started —that is side effects and not a status's business— instead
# it checks that the binary exists, which is where it really fails.
try_out() {
  local n="$1" transport url cmd
  transport="$(mcp_field "$n" transport)"; transport="${transport:-stdio}"

  if [[ "$transport" == "stdio" ]]; then
    cmd="$(mcp_field "$n" command)"
    if [[ -z "$cmd" ]]; then err "$n — no 'command'"
    elif command -v "$cmd" >/dev/null 2>&1; then ok "$n — '$cmd' is on the PATH"
    else err "$n — '$cmd' is not on this machine's PATH"; fi
    return 0
  fi

  url="$(mcp_field "$n" url)"
  [[ -n "$url" ]] || { err "$n — no 'url'"; return 0; }
  command -v curl >/dev/null 2>&1 || { warn "$n — no curl, cannot check"; return 0; }

  # `-w` already writes 000 when the connection fails. Adding `|| echo 000`
  # concatenated a second one and left the most frequent case —server down—
  # without its message, falling into the wildcard with a "responds 000000".
  local answer
  answer="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"crux","version":"1"}}}' \
    2>/dev/null)" || true

  case "$answer" in
    2*) ok "$n — responds ($answer)" ;;
    401|403) warn "$n — responds but asks for credentials ($answer)" ;;
    000|"") err "$n — does not answer" ;;
    *)  err "$n — responds $answer" ;;
  esac
}

# --- install -----------------------------------------------------------------

cmd_install() {
  local names; names="$(declared_names)"
  [[ -n "$names" ]] || { info "the contract declares no MCP server"; return 0; }

  # The shape is validated before writing: nobody warns about an invalid
  # .mcp.json, the client simply does not connect.
  local problems; problems="$(node "$CRUX_HOME/lib/check-mcp.mjs" "$DOCS" | grep '^error ' || true)"
  if [[ -n "$problems" ]]; then
    while IFS= read -r line; do err "${line#error }"; done <<<"$problems"
    die "the contract has errors; nothing is written"
  fi

  local dir output rc
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rc=0
    output="$(node "$ADAPTER" write "$CONTRACT" "$dir" 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || die "$(basename "$dir") — $output"
    ok "$(basename "$dir") — $output"
  done < <(all_targets)

  echo
  info "the client asks for approval the first time it opens a project with .mcp.json"
  info "and it is turned off per project with /mcp, without touching this configuration"
}

# --- remove ------------------------------------------------------------------

cmd_remove() {
  local dir output rc
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rc=0
    output="$(node "$ADAPTER" clear "$CONTRACT" "$dir" 2>&1)" || rc=$?
    [[ $rc -eq 0 ]] || { err "$(basename "$dir") — $output"; continue; }
    ok "$(basename "$dir") — $output"
  done < <(all_targets)
  info "what the contract did not declare has been left as it was"
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) die "usage: crux mcp status|install|remove" ;;
esac
