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
#   1. Measures the drift between code and documentation (check-doc-drift.mjs).
#   2. If the session has moved something, it BLOCKS the close once and forces
#      an answer about what of what was discussed stays in git.
#
# It blocks at most once per session: the second pass exits on its own. A hook
# that always blocks ends up uninstalled, and then it watches nothing.

set -u

entry=""
[[ ! -t 0 ]] && entry="$(cat 2>/dev/null || true)"

read_json() {
  local field="$1"
  [[ -z "$entry" ]] && return 0
  node -e '
    let d = "";
    try { d = JSON.parse(process.argv[1] || "{}"); } catch { d = {}; }
    const v = d[process.argv[2]];
    if (v !== undefined && v !== null) process.stdout.write(String(v));
  ' "$entry" "$field" 2>/dev/null || true
}

# Claude Code flags the turn that already comes from a blocked Stop this way.
# Without this, blocking on Stop is an infinite loop.
[[ "$(read_json stop_hook_active)" == "true" ]] && exit 0

session="$(read_json session_id)"
[[ -z "$session" ]] && session="no-id"

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)}"

root="${CRUX_PROJECTS_DIR:-}"
if [[ -z "$root" && -f "$HOME/.crux/config" ]]; then
  root="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  if [[ -z "$root" ]]; then
    kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
    [[ -n "$kernel" ]] && root="$(dirname "$kernel")"
  fi
fi
[[ -n "$root" ]] || exit 0

cwd="$(pwd)"
case "$cwd/" in
  "$root"/*/*) ;;
  *) exit 0 ;;
esac

rel="${cwd#"$root"/}"
project="${rel%%/*}"
rest="${rel#*/}"
repo="${rest%%/*}"

docs_root="$root/$project/$project-docs"
[[ -f "$docs_root/crux.json" ]] || exit 0

# --- 1. Measurable drift -------------------------------------------------------

drift=""
if [[ -f "$CRUX_HOME/lib/check-doc-drift.mjs" ]]; then
  drift="$(node "$CRUX_HOME/lib/check-doc-drift.mjs" "$docs_root" 2>/dev/null || true)"
fi

# --- 2. Touched files that the docs mention by name -----------------------

referenced=""
if [[ -d "$docs_root/repos/$repo" ]]; then
  modified="$(git -C "$cwd" status --porcelain 2>/dev/null | awk '$1 !~ /^\?\?$/ {print $2}')"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      *.lock|*lock.yaml|*lock.json|*tsbuildinfo|.env*|*.log) continue ;;
    esac
    base="${f##*/}"
    if grep -rqF "$f" "$docs_root/repos/$repo/" 2>/dev/null; then
      referenced+="  - $f (referenced by path)"$'\n'
    elif grep -rqF "\`$base\`" "$docs_root/repos/$repo/" 2>/dev/null; then
      referenced+="  - $f (referenced by name)"$'\n'
    fi
  done <<< "$modified"
fi

# --- 3. Has anything happened in this session? --------------------------------------
#
# If nothing has been touched in the project, there is nothing to promote and
# staying silent is right. Asking in empty sessions is the fastest way for
# someone to uninstall the hook.

had_activity=0
[[ -n "$drift" || -n "$referenced" ]] && had_activity=1
if [[ $had_activity -eq 0 ]]; then
  for d in "$root/$project"/*/; do
    [[ -d "$d/.git" ]] || continue
    if [[ -n "$(git -C "$d" log -1 --since='12 hours ago' --format=%h 2>/dev/null)" ]]; then
      had_activity=1
      break
    fi
  done
fi
[[ $had_activity -eq 1 ]] || exit 0

# --- 4. Once per session ---------------------------------------------------

status="$HOME/.crux/state"
mkdir -p "$status" 2>/dev/null || true
marker="$status/doc-gate-$(printf '%s' "$session" | tr -c 'A-Za-z0-9_.-' '_')"
if [[ -f "$marker" ]]; then
  exit 0
fi
: > "$marker" 2>/dev/null || true

# No leftovers: markers older than two days are of no use to anyone.
find "$status" -name 'doc-gate-*' -type f -mtime +2 -delete 2>/dev/null || true

# --- 5. The gate ------------------------------------------------------------

{
  echo "DOCUMENTATION GATE — project $project"
  echo
  echo "This session has moved things. Before closing, answer in one line what"
  echo "of what happened stays in $project-docs and what does not."

  if [[ -n "$drift" ]]; then
    echo
    echo "Measured drift:"
    while IFS= read -r l; do [[ -n "$l" ]] && echo "  $l"; done <<< "$drift"
  fi

  if [[ -n "$referenced" ]]; then
    echo
    echo "Touched files that the documentation mentions:"
    printf '%s' "$referenced"
  fi

  cat <<'GUIA'

Go over the conversation, not just the diff. What gets lost is not usually a
file, it is what was measured, decided or discovered and never was a file:

  - decision with discarded alternatives ........ decisions/ (ADR)
  - something measured that would be costly to repeat ... repos/<repo>/ or operations/
  - infrastructure or deployment gotcha ......... operations/
  - new risk .................................... operations/open-risks.md
  - open question that has been resolved ........ where the question was
  - state of a repo that has changed ............ repos/<repo>/notes.md

If nothing from the session fits, say so explicitly and close: the answer "there
is nothing to promote" is valid, but it has to be an answer, not an oversight.
If something fits, use /promote-to-docs now and commit before closing.
GUIA
} >&2

exit 2
