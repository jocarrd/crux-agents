#!/usr/bin/env bash
# crux checks — waits for a proposal's checks and says why it fails.
#
#   crux checks [<number>] [--wait] [--timeout <seconds>] [--lines <n>]
#
# Opening the proposal is not finishing it: CI runs afterwards, and if nobody
# looks at it the red is discovered when someone goes to merge. This waits,
# and when something fails it brings only the tail of the failed job's log:
# a CI's whole log is thousands of lines, and reading it costs more than
# fixing the failure.
#
# --wait takes as long as the CI takes. Launch it in the background and carry
# on with something else: watching the wait does not speed up the CI and
# stops whoever is at the other side of the session.
#
# Exit: 0 all green · 1 something fails · 2 no checks · 3 time ran out with
# checks still pending.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

NUM=""; WAIT_SECONDS=0; TIMEOUT=900; LINES=60
INTERVAL="${CRUX_CHECKS_INTERVAL:-15}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT_SECONDS=1; shift ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --lines) LINES="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) NUM="$1"; shift ;;
  esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout is whole seconds, not '$TIMEOUT'"
[[ "$LINES" =~ ^[0-9]+$ ]] || die "--lines is an integer, not '$LINES'"
[[ -z "$NUM" || "$NUM" =~ ^[0-9]+$ ]] || die "the proposal number is an integer, not '$NUM'"

command -v gh >/dev/null || die "gh is needed to read the checks"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

if [[ -z "$NUM" ]]; then
  NUM="$(gh pr view --json number -q .number 2>/dev/null || true)"
  [[ -n "$NUM" ]] || die "no open proposal for this branch — pass the number"
fi

read_checks() {
  # It is read from the proposal's rollup and not from `gh pr checks --json`,
  # which does not exist in the gh versions still in circulation. The rollup
  # mixes two shapes —CI jobs and third-party statuses— and here they are
  # turned into one.
  local output rc=0
  output="$(gh pr view "$NUM" --json statusCheckRollup 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    err "could not read the checks of #$NUM (code $rc)" >&2
    echo "$output" | head -5 | sed 's/^/      /' >&2
    return 1
  fi
  printf '%s' "$output" | node -e '
    let d;
    try { d = JSON.parse(require("fs").readFileSync(0, "utf8")).statusCheckRollup; } catch { process.exit(3); }
    if (!Array.isArray(d)) process.exit(3);
    const bucket = (c) => {
      const s = String(c.status || "").toUpperCase();
      const r = String(c.conclusion || c.state || "").toUpperCase();
      if (c.__typename === "CheckRun" || c.status) {
        if (s && s !== "COMPLETED") return "pending";
        if (["SUCCESS"].includes(r)) return "pass";
        if (["SKIPPED", "NEUTRAL"].includes(r)) return "skipping";
        if (["CANCELLED", "STALE"].includes(r)) return "cancel";
        return "fail";
      }
      if (r === "SUCCESS") return "pass";
      if (r === "PENDING" || r === "EXPECTED") return "pending";
      return "fail";
    };
    const out = d.map((c) => ({ name: c.name || c.context || "?", bucket: bucket(c), link: c.detailsUrl || c.targetUrl || "" }));
    process.stdout.write(JSON.stringify(out));
  ' || { err "gh returned something that is not the rollup of #$NUM" >&2; return 1; }
}

summary() {
  node -e '
    const d = JSON.parse(process.argv[1]);
    const count = (b) => d.filter((c) => c.bucket === b).length;
    process.stdout.write([d.length, count("pass") + count("skipping"), count("fail") + count("cancel"), count("pending")].join(" "));
  ' "$1"
}

failure_log() {
  # `gh run view --log-failed` comes out empty in gh versions that are still in
  # distributions, so the job's log is requested from the API and trimmed here:
  # what precedes the last error, without the cleanup at the end.
  local job="$1" repo log
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || { echo "(could not determine the repository to request the log)"; return 0; }
  log="$(gh api "repos/$repo/actions/jobs/$job/logs" 2>/dev/null)" \
    || { echo "(the log is no longer available)"; return 0; }
  # Through stdin and not as an argument: an argument cannot exceed 128 KB on
  # Linux, and a CI log exceeds that easily.
  printf '%s' "$log" | node -e '
    const lines = require("fs").readFileSync(0, "utf8").split("\n").map((l) => l.replace(/^\S+Z /, ""));
    const n = Number(process.argv[1]);
    let last = -1;
    lines.forEach((l, i) => { if (l.includes("##[error]")) last = i; });
    if (last < 0) {
      const cleanup = lines.findIndex((l) => l.startsWith("Post job cleanup"));
      last = (cleanup > 0 ? cleanup : lines.length) - 1;
    }
    // Stack traces eat the trim and the message ends up outside: two lines of
    // each stack are kept and the rest is counted.
    const compact = [];
    let stack = 0;
    for (let i = last; i >= 0 && compact.length < n; i--) {
      if (/^\s*at /.test(lines[i])) {
        stack++;
        if (stack === 3) compact.push(`    … (stack trace trimmed)`);
        if (stack > 2) continue;
      } else {
        stack = 0;
      }
      // A minified line can have thousands of characters: without trimming the
      // width, sixty lines turn into tens of thousands of tokens.
      compact.push(lines[i].length > 300 ? lines[i].slice(0, 300) + " …" : lines[i]);
    }
    console.log(compact.reverse().join("\n"));
  ' "$LINES"
}

start=$(date +%s)
empty_items=0
while :; do
  data="$(read_checks)" || exit 1
  read -r total _ failing pending_items <<< "$(summary "$data")"

  if [[ $total -eq 0 ]]; then
    # Just opened or just pushed, the proposal takes a while to show the CI
    # even if it is already queued: with a one-minute margin it gave up before seeing it.
    if [[ $WAIT_SECONDS -eq 1 && $empty_items -lt 12 ]]; then
      empty_items=$((empty_items + 1)); sleep "$INTERVAL"; continue
    fi
    warn "#$NUM has no automatic checks"
    info "nothing blocking it is not the same as verified"
    exit 2
  fi

  [[ $WAIT_SECONDS -eq 1 && $pending_items -gt 0 && $failing -eq 0 ]] || break
  if (( $(date +%s) - start >= TIMEOUT )); then break; fi
  sleep "$INTERVAL"
done

echo "checks of #$NUM"
node -e '
  const d = JSON.parse(process.argv[1]);
  const order = { fail: 0, cancel: 1, pending: 2, pass: 3, skipping: 4 };
  d.sort((a, b) => (order[a.bucket] ?? 5) - (order[b.bucket] ?? 5));
  // What is green does not need to be read one by one: with hundreds of
  // checks, listing them was almost all the output.
  const green = d.filter((c) => c.bucket === "pass" || c.bucket === "skipping").length;
  for (const c of d.filter((c) => c.bucket !== "pass" && c.bucket !== "skipping")) {
    console.log(`      ${c.bucket.padEnd(9)} ${c.name}`);
  }
  if (green) console.log(`      ${green} green or skipped`);
' "$data"

if [[ $failing -gt 0 ]]; then
  echo
  # Only GitHub Actions jobs give their log through gh. For the rest —a
  # third party's deployment— the link is given, which is where the reason is.
  failures=()
  while IFS= read -r line; do [[ -n "$line" ]] && failures+=("$line"); done < <(node -e '
    const d = JSON.parse(process.argv[1]);
    for (const c of d.filter((c) => c.bucket === "fail" || c.bucket === "cancel")) {
      console.log([c.name, c.link || ""].join("\t"));
    }
  ' "$data")
  shown=0
  for f in "${failures[@]}"; do
    name="${f%%$'\t'*}"; link="${f#*$'\t'}"
    if [[ "$link" =~ /actions/runs/([0-9]+)/job/([0-9]+) && $shown -lt 2 ]]; then
      shown=$((shown + 1))
      echo "${C_DIM}── $name: last $LINES lines of the log ${C_OFF}"
      failure_log "${BASH_REMATCH[2]}" | sed 's/^/      /'
    else
      err "$name"
      [[ -n "$link" ]] && info "$link"
    fi
  done
  exit 1
fi

if [[ $pending_items -gt 0 ]]; then
  warn "$(count "$pending_items" "check is still pending" "checks are still pending")"
  [[ $WAIT_SECONDS -eq 1 ]] && info "the ${TIMEOUT}s wait ran out"
  exit 3
fi

ok "all green"
exit 0
