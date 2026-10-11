#!/usr/bin/env bash
# Reads the production signals the project declares and summarizes them.
#
#   signals.sh [--since <window>] [--all] [--max <n>] [source ...]
#
# Sources are declared in crux.json, under `observability.sources`: each one is
# a named read-only command. `{since}` is replaced by the window (default 1h).
#
# A production log is thousands of nearly identical lines. Read as they are
# they fit in no context, and what matters (which error, how many times, since
# when) gets lost among them. This filters what looks like a problem and groups
# the lines that only differ in numbers, dates or identifiers.
#
# Exit: 0 read (errors or not) · 1 could not read · 2 no sources.

set -uo pipefail

KERNEL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
source "$KERNEL/lib/common.sh"

SINCE="1h"; ALL=0; MAX=15; REQUESTED=()
LIMIT="${CRUX_SIGNALS_TIMEOUT:-60}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --all) ALL=1; shift ;;
    --max) MAX="${2:-}"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) REQUESTED+=("$1"); shift ;;
  esac
done
[[ "$MAX" =~ ^[0-9]+$ ]] || die "--max is an integer, not '$MAX'"
[[ "$SINCE" =~ ^[0-9]+[smhd]$ ]] || die "--since is a number with s, m, h or d (1h, 30m), not '$SINCE'"

docs="$(find_docs_repo "$PWD")" || die "cannot find the project's crux.json"
contract="$docs/crux.json"
valid_json "$contract" || die "$contract cannot be read as JSON"

# The commands run without asking. The contract belongs to the team itself, so
# it is not blocked, but if someone has touched it without committing that is
# said first.
if git -C "$docs" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && ! git -C "$docs" diff --quiet HEAD -- crux.json 2>/dev/null; then
  warn "$contract has uncommitted changes: its commands run as they are"
fi

rc=0
sources="$(node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const s = c.observability && c.observability.sources;
  if (!Array.isArray(s) || !s.length) process.exit(2);
  for (const f of s) {
    if (!f.name || !f.command) { process.stderr.write("a source without name or without command\n"); process.exit(3); }
    console.log([f.name, f.command].join("\t"));
  }
' "$contract")" || rc=$?
case $rc in
  0) ;;
  2)
    warn "the project declares no production sources"
    info "declare them in $contract → observability.sources: [{\"name\": ..., \"command\": ...}]"
    exit 2 ;;
  *) die "observability.sources in $contract is malformed" ;;
esac

read_items=0; failed=0
while IFS=$'\t' read -r name command; do
  [[ -z "$name" ]] && continue
  if [[ ${#REQUESTED[@]} -gt 0 && ! " ${REQUESTED[*]} " == *" $name "* ]]; then
    continue
  fi
  command="${command//\{since\}/$SINCE}"

  echo "${C_DIM}── $name (last $SINCE) ${C_OFF}"
  output_rc=0
  # </dev/null: an ssh would read the loop input and swallow the sources
  # still to be read.
  output="$(with_timeout "$LIMIT" bash -c "$command" </dev/null 2>&1)" || output_rc=$?
  if [[ $output_rc -eq 124 ]]; then
    err "$name did not respond in ${LIMIT}s"; failed=$((failed + 1)); continue
  fi
  if [[ $output_rc -ne 0 ]]; then
    err "$name failed with code $output_rc"
    [[ -n "${output//[[:space:]]/}" ]] && echo "$output" | tail -3 | sed 's/^/      /'
    failed=$((failed + 1)); continue
  fi
  read_items=$((read_items + 1))

  # Through stdin and not as an argument: an argument cannot exceed 128 KB on
  # Linux, and an hour of logs goes past that.
  printf '%s' "$output" | node -e '
    const text = require("fs").readFileSync(0, "utf8");
    const everything = process.argv[1] === "1";
    const max = Number(process.argv[2]);
    const lines = text.split("\n").filter((l) => l.trim());
    const keyword = /\b(error|exception|fatal|panic|critical|crit|failed|failure|refused|timeout|timed out|unhandled|traceback|restarting|unhealthy|exited|oom|killed)\b/i;
    // A 5xx only counts with HTTP context: a loose number starting with 5 is
    // a time, a coordinate or a browser version.
    const http5xx = /(HTTP\/?[\d.]*\s+5\d\d\b|\bstatus(Code)?["\x27]?\s*[:=]\s*5\d\d\b|"\s5\d\d\s)/i;
    // In a structured log its level rules: an info line that mentions the
    // word "error" in a URL is not an error.
    const level = (l) => {
      const m = l.match(/"level"\s*:\s*("?)(\w+)\1/);
      if (!m) return null;
      const v = m[2].toLowerCase();
      if (/^\d+$/.test(v)) return Number(v) >= 50 ? "error" : "info";
      return ["error", "fatal", "critical", "crit", "panic"].includes(v) ? "error" : "info";
    };
    const problem = { test: (l) => {
      const n = level(l);
      if (n) return n === "error";
      return keyword.test(l) || http5xx.test(l);
    } };
    const chosen = everything ? lines : lines.filter((l) => problem.test(l));
    if (!chosen.length) {
      console.log(`      nothing that looks like a problem in ${lines.length} lines`);
      process.exit(0);
    }
    // Two lines are the same problem if they only differ in what changes on
    // each occurrence: dates, times, numbers, identifiers and addresses.
    const shape = (l) => l
      .replace(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?Z?/g, "<date>")
      .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "<id>")
      .replace(/\b[0-9a-f]{12,}\b/gi, "<id>")
      .replace(/\b\d+(\.\d+){3}(:\d+)?\b/g, "<ip>")
      .replace(/\d+/g, "<n>")
      .trim();
    const groups = new Map();
    for (const l of chosen) {
      const k = shape(l);
      const g = groups.get(k) || { n: 0, example: l.trim(), last: l.trim() };
      g.n++; g.last = l.trim();
      groups.set(k, g);
    }
    const order = [...groups.values()].sort((a, b) => b.n - a.n);
    console.log(`      ${chosen.length} lines in ${groups.size} groups (of ${lines.length} read)`);
    for (const g of order.slice(0, max)) {
      console.log(`      ${String(g.n).padStart(5)}×  ${g.last.slice(0, 220)}`);
    }
    if (order.length > max) console.log(`      ... and ${order.length - max} more groups (--max to see them)`);
  ' "$ALL" "$MAX"
done <<< "$sources"

if [[ $read_items -eq 0 ]]; then
  [[ $failed -gt 0 ]] && exit 1
  if [[ ${#REQUESTED[@]} -gt 0 ]]; then
    die "no source is named that: ${REQUESTED[*]}"
  fi
fi
[[ $failed -eq 0 ]] || exit 1
exit 0
