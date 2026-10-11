#!/usr/bin/env bash
# crux doctor --machine — checks that this machine can run the system.
#
# Projects are checked with `crux doctor`. This checks the other thing: the
# tools, authentications and paths the skills depend on. It is the difference
# between finding out that something is missing now or in the middle of an
# incident.
#
# What is indispensable is reported as an error; what only some skills need,
# as a warning, saying what you will be unable to do.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

ERRORS=0; WARNS=0
fail() { err "$*"; ERRORS=$((ERRORS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }

has() { command -v "$1" >/dev/null 2>&1; }

needed() {
  # needed <command> <what for>
  if has "$1"; then ok "$1"; else fail "missing $1 — $2"; fi
}

optional() {
  # optional <command> <what you will be unable to do>
  if has "$1"; then ok "$1"; else note "no $1 — you will not be able to: $2"; fi
}

echo "checking the machine"
echo

# --- Indispensable ----------------------------------------------------------

needed git  "the whole system rests on git"
needed node "kernel commands read the contract with node"
needed bash "kernel commands are bash"

# --- The kernel itself --------------------------------------------------------

echo
MACHINE_CONFIG="${CRUX_CONFIG:-$HOME/.crux/config}"
[[ -f "$MACHINE_CONFIG" ]] && ok "machine config in $MACHINE_CONFIG" \
  || fail "missing $MACHINE_CONFIG — run install.sh"
has crux && ok "crux command on the PATH" || note "crux is not on the PATH — add ~/.local/bin"

SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
linked_skills="$(ls "$SKILLS_DIR" 2>/dev/null | wc -l)"
skills_kernel="$(ls "$CRUX_HOME/skills" 2>/dev/null | wc -l)"
if [[ "$linked_skills" -eq 0 ]]; then
  fail "no skill materialized — run install.sh"
else
  ok "$linked_skills skills available ($skills_kernel in the kernel)"
fi

broken_items="$(find "$SKILLS_DIR" -maxdepth 1 -xtype l 2>/dev/null | wc -l)"
[[ "$broken_items" -gt 0 ]] && fail "$broken_items broken skill links — run install.sh"

# A hook that points at a nonexistent file does not fail: it does nothing, and
# that is worse, because the system looks guarded and is not.
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
if [[ -f "$SETTINGS" ]]; then
  broken_hooks="$(node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let n = 0;
    for (const groups of Object.values(s.hooks || {}))
      for (const g of groups)
        for (const h of (g.hooks || [])) {
          const p = (h.command || "").replace(/^~/, process.env.HOME).split(" ")[0];
          if (p && !fs.existsSync(p)) n++;
        }
    process.stdout.write(String(n));
  ' "$SETTINGS" 2>/dev/null || echo 0)"
  [[ "$broken_hooks" -gt 0 ]] && fail "$broken_hooks hooks point at files that do not exist — 'crux hooks status'"

  # A broken hook was visible; none at all was not. And it is the case of a new
  # machine: the kernel is installed, the projects are fetched and nothing is
  # hooked. Everything that really sustains the standard is automatic, so a
  # machine without hooks looks healthy and is not.
  hooks_crux="$(node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let n = 0;
    for (const groups of Object.values(s.hooks || {}))
      for (const g of groups)
        for (const h of (g.hooks || []))
          if (/doc-sync|cycle-guard|memory-guard/.test(h.command || "")) n++;
    process.stdout.write(String(n));
  ' "$SETTINGS" 2>/dev/null || echo 0)"
  if [[ "${hooks_crux:-0}" -eq 0 ]]; then
    # A warning and not an error: `bootstrap` requires this check to pass, and
    # it is precisely what hooks the hooks when fetching the projects. An error
    # here would leave a new machine with no way to start.
    note "no crux hook installed — 'crux hooks install'"
  else
    ok "$hooks_crux session hooks installed"
  fi
else
  note "no $SETTINGS: no hook is installed — 'crux hooks install'"
fi

# --- What the skills need --------------------------------------------

echo
optional gh      "create repos with crux init (use --no-remote meanwhile)"
if has gh; then
  gh auth status >/dev/null 2>&1 && ok "gh authenticated" || note "gh not authenticated — 'gh auth login'"
fi

optional python3 "visual-diff, render-loop and any image analysis"
if has python3; then
  python3 -c "import numpy, PIL" 2>/dev/null \
    && ok "numpy and Pillow" \
    || note "no numpy or Pillow — you will not be able to: compare or measure images"
fi

optional pdftoppm "compare PDFs with visual-diff"
optional docker   "deploy-fallback and the per-workspace databases"
optional adb      "device-loop, testing on an Android emulator"
optional rsync    "publish a demo with crux stg"

if has google-chrome || has google-chrome-stable || has chromium; then
  ok "browser for headless"
else
  note "no Chrome or Chromium — you will not be able to: visual-test"
fi

# --- Credentials and services this machine declares --------------------------
#
# What expires on its own —an OAuth refresh token, a CLI session, a key with a
# date— belongs to the machine, not to a project, and the kernel cannot name
# it. Whoever uses it declares the check in ~/.crux/machine-checks.json:
#
#   { "checks": [ { "name": "…", "command": "…", "fix": "…" } ] }
#
# Each command is read-only and exits 0 when all is well. It runs with a time
# limit: a check that hangs is reported, it does not hang the doctor.
checks_file="${CRUX_MACHINE_CHECKS:-$HOME/.crux/machine-checks.json}"
if [[ -f "$checks_file" ]]; then
  echo
  checks="$(node -e '
    const fs = require("fs");
    let c;
    try { c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stderr.write(e.message); process.exit(1); }
    for (const k of c.checks || []) {
      if (!k.name || !k.command) { process.stderr.write("a check without name or command"); process.exit(1); }
      // The command travels in base64: one with a newline or a tab would split
      // the line it travels on.
      process.stdout.write([k.name, Buffer.from(k.command).toString("base64"), k.fix || ""].join("\t") + "\n");
    }
  ' "$checks_file" 2>&1)" || { fail "$checks_file cannot be read: $checks"; checks=""; }
  while IFS=$'\t' read -r check_name check_cmd check_fix; do
    [[ -n "$check_name" ]] || continue
    check_cmd="$(printf '%s' "$check_cmd" | base64 -d)"
    check_out="$(with_timeout "${CRUX_MACHINE_CHECK_TIMEOUT:-20}" bash -c "$check_cmd" 2>&1 < /dev/null)"
    check_rc=$?
    if [[ $check_rc -eq 0 ]]; then
      ok "$check_name"
    elif [[ $check_rc -eq 124 ]]; then
      note "$check_name: no answer in ${CRUX_MACHINE_CHECK_TIMEOUT:-20} s${check_fix:+ — $check_fix}"
    else
      # The whole output on one line: a JSON error starts with a lone "{".
      note "$check_name: $(printf '%s' "$check_out" | tr -s '[:space:]' ' ' | cut -c1-120)${check_fix:+ — $check_fix}"
    fi
  done <<<"$checks"
fi

# --- Workspaces -----------------------------------------------------

task_record="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
if [[ -f "$task_record" ]]; then
  alive_items="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const e = Object.entries(r.workspaces || {});
    const dead = e.filter(([, w]) => !fs.existsSync(w.path)).map(([n]) => n);
    process.stdout.write(`${e.length}|${dead.join(",")}`);
  ' "$task_record" 2>/dev/null || echo "0|")"
  total="${alive_items%%|*}"; dead_items="${alive_items#*|}"
  [[ "$total" -gt 0 ]] && ok "$(count "$total" "registered workspace" "registered workspaces")"
  [[ -n "$dead_items" ]] && note "workspaces in the registry without a directory: $dead_items — 'crux workspace gc'"

  # The registry and the disk also drift apart the other way round, and that is never seen.
  ws_root="$(projects_root)"
  registered="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(Object.values(r.workspaces || {}).map((w) => w.path).join("\n"));
  ' "$task_record" 2>/dev/null || true)"
  standalone_items=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\n' "$registered" | grep -qxF "$d" && continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    standalone_items=$((standalone_items + 1))
  done < <(find "$ws_root" -maxdepth 2 -type d -name '*-ws-*' 2>/dev/null)
  [[ $standalone_items -gt 0 ]] && note "$standalone_items worktrees on disk that the registry does not know — 'crux workspace gc'"
fi

# --- Resumen -----------------------------------------------------------------

echo
if [[ $ERRORS -eq 0 && $WARNS -eq 0 ]]; then
  echo "${C_GRN}ready${C_OFF} — this machine can handle everything"
else
  echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errors), $WARNS $([[ $WARNS -eq 1 ]] && echo warning || echo warnings)"
  [[ $WARNS -gt 0 && $ERRORS -eq 0 ]] && echo "Warnings do not block: they only limit which skills you can use."
fi
exit $(( ERRORS > 0 ? 1 : 0 ))
