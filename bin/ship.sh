#!/usr/bin/env bash
# crux ship — the quality gate, with a receipt.
#
#   crux ship run -- <command...>   runs the command and records its result
#   crux ship seal                  closes the receipt with the HEAD sha
#   crux ship show                  shows the receipt
#   crux ship clear                 discards it and starts over
#
# The mark used to be a bare sha that the agent itself wrote after saying it
# had verified. That does not prove anything was verified: it proves someone
# wrote a sha. `run` really executes and records the exit code, so the
# receipt is evidence and not a statement.
#
# The shortcut still exists —`finish --skip-gate`— because sometimes it is
# needed. What cannot happen is for it to be taken silently and leave no trace.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "this is not a git repository"
RECEIPT="$REPO/.crux-ship"

# A mark in the old format —a bare sha— is not valid as a receipt: it does not
# say what was run. It is treated as if it were not there.
is_stale_receipt() {
  [[ -f "$RECEIPT" ]] && ! grep -q '^run ' "$RECEIPT" 2>/dev/null
}

cmd_run() {
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || die "usage: crux ship run -- <command...>"

  # A receipt that is already closed belongs to another pass: the next one starts clean.
  if [[ -f "$RECEIPT" ]] && { grep -q '^sealed ' "$RECEIPT" 2>/dev/null || is_stale_receipt; }; then
    rm -f "$RECEIPT"
  fi
  [[ -f "$RECEIPT" ]] || printf '# quality gate receipt — crux\nrepo %s\n' "$REPO" > "$RECEIPT"

  local start end rc
  start=$(date +%s)
  "$@"; rc=$?
  end=$(date +%s)

  # The receipt records the command as declared, not the wrapper.
  local label="${LABEL:-$*}"
  printf 'run %s %s %s\n' "$rc" "$((end - start))" "$label" >> "$RECEIPT"
  if [[ $rc -eq 0 ]]; then ok "$label — $((end - start))s"; else err "$label — exit $rc"; fi
  return $rc
}

cmd_seal() {
  [[ -f "$RECEIPT" ]] && ! is_stale_receipt || die "no receipt: pass the gate with 'crux ship run -- <command>'"

  local total failures
  total="$(receipt_commands "$RECEIPT")"
  failures="$(receipt_failures "$RECEIPT")"
  [[ "${total:-0}" -gt 0 ]] || die "the receipt has not a single command run"
  if [[ "${failures:-0}" -gt 0 ]]; then
    err "$failures of $total commands failed: the gate does not close"
    receipt_failed "$RECEIPT" | sed 's/^/      /'
    exit 1
  fi

  # The gate's behaviour belongs to the kernel that runs it, not to the repo:
  # without the version, a sealed receipt does not say which rules it was won under.
  local kernel pinned
  kernel="$(crux_version)"
  pinned="$(pinned_version "$REPO")"
  grep -vE '^(sealed|kernel) ' "$RECEIPT" > "$RECEIPT.tmp" && mv "$RECEIPT.tmp" "$RECEIPT"
  printf 'kernel %s\n' "$kernel" >> "$RECEIPT"
  printf 'sealed %s %s\n' "$(git -C "$REPO" rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RECEIPT"
  ok "gate closed on $(git -C "$REPO" rev-parse --short HEAD) with $(count "$total" check checks) (crux $kernel)"
  if [[ -n "$pinned" && "$pinned" != "$kernel" ]]; then
    warn "the project pins crux $pinned and the gate was passed with $kernel"
    info "align it with: crux upgrade"
  fi

  # What was checked goes into the task as evidence: it is what the proposal
  # says afterwards, so it is not rewritten from memory.
  local task_record_file
  task_record_file="$(task_file_for_path "${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}" "$REPO" 2>/dev/null || echo "")"
  if [[ -n "$task_record_file" && -f "$task_record_file" ]]; then
    node "$CRUX_HOME/lib/task.mjs" verify --file "$task_record_file" --receipt "$RECEIPT" \
      --sha "$(git -C "$REPO" rev-parse HEAD)" >/dev/null 2>&1 \
      && info "task verified: $task_record_file" \
      || warn "could not record the verification in $task_record_file"
  fi
}

cmd_show() {
  [[ -f "$RECEIPT" ]] || die "no receipt in $REPO"
  if is_stale_receipt; then
    warn "receipt in the old format (a bare sha): it does not say what was run"
    sed 's/^/      /' "$RECEIPT"
    return 0
  fi
  local head sealed
  head="$(git -C "$REPO" rev-parse HEAD)"
  sealed="$(awk '/^sealed /{print $2}' "$RECEIPT" | tail -1)"
  sed 's/^/  /' "$RECEIPT"
  echo
  local kernel_receipt
  kernel_receipt="$(receipt_kernel "$RECEIPT")"
  if [[ -n "$sealed" && -z "$kernel_receipt" ]]; then
    warn "sealed without a crux version: the receipt does not say which rules it was passed under"
  elif [[ -n "$kernel_receipt" && "$kernel_receipt" != "$(crux_version)" ]]; then
    warn "sealed with crux $kernel_receipt, and now $(crux_version) is running"
  fi
  if [[ -z "$sealed" ]]; then
    info "not closed: 'crux ship seal'"
  elif [[ "$sealed" != "$head" ]]; then
    warn "closed on ${sealed:0:8}, and HEAD is ${head:0:8}: it has to be passed again"
  else
    ok "current on ${head:0:8}"
  fi
}

cmd_clear() { rm -f "$RECEIPT"; ok "receipt discarded"; }

# A proposal's body was the only artifact in the flow left unchecked, and it
# is the one that gets published. The tool's signature slipped in through there.
cmd_body() {
  local file="${1:-}"
  [[ -f "$file" ]] || die "usage: crux ship body <file with the body>"

  local failures=0
  report() { err "$1"; shift; printf '%s\n' "$@" | sed 's/^/      /'; failures=$((failures+1)); }

  local signature
  signature="$(grep -inE 'co-authored-by:[[:space:]]*(claude|ona|copilot|cursor|devin|gemini)|claude-session:|(generated|generado) with|🤖' "$file" || true)"
  [[ -n "$signature" ]] && report "the tool's signature does not belong in a proposal" "$signature"

  # The same fingerprints as the documentation and the .mcp.json files. This
  # is published outside, so it is the last place to look, not the first one skipped.
  local credentials
  credentials="$(node -e '
    import("file://" + process.argv[1] + "/lib/credential-prints.mjs").then((m) => {
      const fs = require("fs");
      const t = fs.readFileSync(process.argv[2], "utf8");
      for (const h of m.fingerprintsIn(t)) console.log(h);
    });
  ' "$CRUX_HOME" "$file" 2>/dev/null || true)"
  [[ -n "$credentials" ]] && report "something that looks like a credential" "$credentials"

  # The machine's path tells the proposal's reader nothing, and says too much
  # about how we work and for whom.
  local paths
  paths="$(grep -nE "(^|[^A-Za-z0-9_])($HOME|/home/[a-z_][a-z0-9_-]*|/Users/[A-Za-z0-9_-]+)/" "$file" || true)"
  [[ -n "$paths" ]] && report "machine paths in the body" "$paths"

  # The rest is declared by the profile, which is up to whoever depends on it:
  # in a client's repo our scaffolding is not shown, and in another it may be
  # their name.
  local docs profile=""
  docs="$(find_docs_repo "$REPO" 2>/dev/null || echo "")"
  [[ -n "$docs" && -f "$docs/crux.json" ]] &&
    profile="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"
  # Those rules protect the client's code repos. The docs repo is ours, and
  # what it documents is precisely our tooling: there they do not apply.
  local in_docs=0
  if [[ -n "$docs" ]] && [[ "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == \
       "$(git -C "$docs" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]]; then
    in_docs=1
  fi
  if [[ $in_docs -eq 1 ]]; then
    :
  elif [[ -n "$profile" ]]; then
    local pattern reason found_one
    while IFS=$'\t' read -r pattern reason; do
      [[ -n "$pattern" ]] || continue
      found_one="$(grep -inE "$pattern" "$file" || true)"
      [[ -n "$found_one" ]] && report "profile $profile: $reason" "$found_one"
    done < <(profile_forbid "$profile" "$docs")
    # The docs repo name is per project, so it does not fit in a fixed profile
    # pattern: a path to it in the proposal shows where we keep the client's
    # notes.
    if [[ "$(profile_get "$profile" "$docs" propose.hideDocsRepo false)" == "true" ]]; then
      local docs_name
      docs_name="$(basename "$docs")"
      found_one="$(grep -inF "$docs_name" "$file" || true)"
      [[ -n "$found_one" ]] && report "profile $profile: names our documentation repo" "$found_one"
    fi
  else
    # Without a profile, what the profile forbids is not checked, and a
    # client's repo cloned outside the convention is exactly the one that
    # needs it most. Saying "ok" here was the worst place to fail open.
    warn "no contract in sight: what the profile forbids was not checked"
    info "if it is a client's repo, review the body by hand"
  fi

  if [[ $failures -gt 0 ]]; then
    echo
    info "the body says what changes, what is added and why; see STANDARD.md §8"
    exit 1
  fi
  ok "the proposal body shows nothing it should not"
}

# The kernel does not know the checks: the project declares them in
# `quality.gate` of its crux.json, with a per-repo override. Without this the
# gate was four invocations to remember one by one, and what was measured says
# that what gets skipped is exactly what has to be remembered.
cmd_gate() {
  local docs; docs="$(find_docs_repo "$REPO" 2>/dev/null || echo "")"
  [[ -n "$docs" && -f "$docs/crux.json" ]] \
    || die "cannot find the project's crux.json: declare quality.gate there"

  local repo_name; repo_name="$(basename "$REPO")"
  # In a worktree the name carries the workspace suffix; the contract talks about the repo.
  repo_name="${repo_name%%-ws-*}"

  local commands; commands="$(node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    const q = (JSON.parse(fs.readFileSync(file, "utf8")).quality) || {};
    const r = (q.repos || {})[repo] || {};
    const g = r.gate || q.gate || [];
    process.stdout.write((Array.isArray(g) ? g : [g]).join("\n"));
  ' "$docs/crux.json" "$repo_name" 2>/dev/null)"

  if [[ -z "$commands" ]]; then
    err "the contract does not declare what to check in $repo_name"
    info "declare it in $docs/crux.json:"
    info '  "quality": { "gate": ["<command>", "<command>"] }'
    info "or per repo:  \"quality\": { \"repos\": { \"$repo_name\": { \"gate\": [...] } } }"
    exit 1
  fi

  # These commands come from a versioned file, so they change with the branch
  # you have checked out. Their fingerprint is remembered: while it is the same
  # nothing is asked, and when it changes what is about to run is shown before
  # running it. A contract that arrives in a proposal does not execute silently.
  local fingerprint_dir="$HOME/.crux/state"
  ( umask 077 && mkdir -p "$fingerprint_dir" ) 2>/dev/null || true
  local fingerprint_f fingerprint_now fingerprint_before=""
  fingerprint_f="$fingerprint_dir/gate-$(printf '%s' "$docs/$repo_name" | cksum | tr -d ' ' | tr -c 'A-Za-z0-9' '_')"
  fingerprint_now="$(printf '%s' "$commands" | cksum | tr -d ' ')"
  [[ -f "$fingerprint_f" ]] && fingerprint_before="$(cat "$fingerprint_f")"

  if [[ "$fingerprint_now" != "$fingerprint_before" ]]; then
    if [[ -n "$fingerprint_before" ]]; then
      warn "the quality gate of $repo_name has changed since last time"
    else
      info "the quality gate of $repo_name, declared in the contract:"
    fi
    printf '%s\n' "$commands" | sed 's/^/      /'
    if [[ "${CRUX_GATE_ASSUME_YES:-0}" != "1" && -t 0 ]]; then
      local answer
      read -r -p "      Run them? [y/N] " answer
      case "$answer" in
        s|S|y|Y) : ;;
        *) die "gate cancelled" ;;
      esac
    fi
    printf '%s' "$fingerprint_now" > "$fingerprint_f" 2>/dev/null || true
  fi

  cmd_clear >/dev/null
  local failures=0
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    LABEL="$c" cmd_run -- bash -c "$c" || failures=$((failures+1))
  done <<< "$commands"

  [[ $failures -eq 0 ]] || { err "$(count "$failures" "check" "checks") failing: the gate does not close"; exit 1; }
  info "commit and close with: crux ship seal"
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  gate)  cmd_gate ;;
  seal)  cmd_seal ;;
  show)  cmd_show ;;
  clear) cmd_clear ;;
  body)  shift; cmd_body "$@" ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
