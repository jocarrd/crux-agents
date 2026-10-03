#!/usr/bin/env bash
# Checks that a deployment has arrived and that its routes respond.
#
#   smoke.sh [--url <base>] [--expect <text>] [--timeout <sec>] [path ...]
#
# Without --url, it reads `deploy.url` and `deploy.paths` from the project
# contract, or `deploy.repos.<repo>` if the project has several deployable repos.
#
# --expect waits until the first path contains a text only the new version has.
# Without it, a 200 says nothing: the previous version may still be answering
# while the new one builds.
#
# Exit: 0 everything responds · 1 some path fails · 3 the new version did not arrive.

set -uo pipefail

KERNEL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
source "$KERNEL/lib/common.sh"

URL=""; EXPECT=""; TIMEOUT=600; PATHS=()
INTERVAL="${CRUX_SMOKE_INTERVAL:-10}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout is whole seconds, not '$TIMEOUT'"
command -v curl >/dev/null || die "curl is required"

if [[ -z "$URL" ]]; then
  docs="$(find_docs_repo "$PWD")" || die "no --url and no crux.json to read deploy.url from"
  contract="$docs/crux.json"
  valid_json "$contract" || die "$contract cannot be read as JSON"

  repo=""
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "$common" ]] && repo="$(basename "$(cd "$(dirname "$common")" && pwd)")"

  rc=0
  block="$(node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const d = c.deploy;
    if (!d) process.exit(2);
    const b = (d.repos && d.repos[process.argv[2]]) || (d.url ? d : null);
    if (!b || !b.url) process.exit(3);
    console.log(b.url);
    for (const p of b.paths || ["/"]) console.log(p);
  ' "$contract" "$repo")" || rc=$?
  case $rc in
    0) ;;
    2) die "the contract does not declare 'deploy': pass --url or declare deploy.url in $contract" ;;
    3) die "'deploy' has no url for the repo '${repo:-?}' in $contract" ;;
    *) die "could not read 'deploy' from $contract" ;;
  esac
  URL="$(echo "$block" | sed -n 1p)"
  if [[ ${#PATHS[@]} -eq 0 ]]; then
    while IFS= read -r r; do [[ -n "$r" ]] && PATHS+=("$r"); done < <(echo "$block" | sed -n '2,$p')
  fi
fi

URL="${URL%/}"
[[ "$URL" =~ ^https?:// ]] || die "the url must start with http:// or https://, not '$URL'"
[[ ${#PATHS[@]} -gt 0 ]] || PATHS=("/")

body="$(mktemp)"; trap 'rm -f "$body"' EXIT

request() {
  # request <url>: leaves the body in $body and prints "code seconds"
  curl -sS -L --max-time 20 -o "$body" -w '%{http_code} %{time_total}' "$1" 2>/dev/null || echo "000 0"
}

if [[ -n "$EXPECT" ]]; then
  first="$URL${PATHS[0]}"
  start=$(date +%s)
  while :; do
    request "$first" >/dev/null
    grep -qF -- "$EXPECT" "$body" && { ok "the new version is already responding at $first"; break; }
    if (( $(date +%s) - start >= TIMEOUT )); then
      err "after ${TIMEOUT}s, $first still does not contain «$EXPECT»"
      info "either the deployment has not finished, or it failed and the previous version is still live"
      exit 3
    fi
    sleep "$INTERVAL"
  done
fi

failures=0
echo "paths on $URL"
for r in "${PATHS[@]}"; do
  [[ "$r" == /* ]] || r="/$r"
  read -r code seconds <<< "$(request "$URL$r")"
  ms="$(awk -v s="$seconds" 'BEGIN { printf "%d", s * 1000 }')"
  if [[ "$code" == "000" ]]; then
    err "$r does not respond"; failures=$((failures + 1)); continue
  fi
  if [[ "$code" -ge 400 ]]; then
    err "$r → $code (${ms} ms)"; failures=$((failures + 1)); continue
  fi
  # A 200 with the framework's error page inside is also a failure: some
  # serve the error with a success code.
  if grep -qiE 'Application error: a (client|server)-side exception|Internal Server Error|__NEXT_ERROR__|Traceback \(most recent call last\)' "$body"; then
    err "$r → $code but the body is an error page (${ms} ms)"; failures=$((failures + 1)); continue
  fi
  if [[ "$ms" -gt 3000 ]]; then
    warn "$r → $code, slow: ${ms} ms"
  else
    ok "$r → $code (${ms} ms)"
  fi
done

[[ $failures -eq 0 ]] || exit 1
exit 0
