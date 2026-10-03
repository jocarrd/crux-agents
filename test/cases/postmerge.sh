#!/usr/bin/env bash
# What happens after the proposal is opened: risk and specialists, CI,
# deployment and production signals.

_pm_repo_with_base() {
  # _pm_repo_with_base <dir>: repo with a main branch and a work branch
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo "x" > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
  git -C "$1" checkout -q -b work
}

_pm_commit_all() {
  git add -A && git commit -qm change
}

test_review_scope_grades_risk_by_the_diff() {
  sandbox >/dev/null
  local repo="$SB/risk" out
  # Project registered with no declared rigor: normal.
  echo '{"crux":"0.40.0","project":"risk","profile":"multi-repo"}' > "$SB/crux.json"
  _pm_repo_with_base "$repo"
  cd "$repo" || return
  local script="$CRUX_HOME/skills/review-pr/scripts/review-scope.sh"

  echo "more text" >> README.md; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: low" "a text-only change is low risk"
  assert_contains "$out" "specialists: none" "and pays for no specialist"
  assert_contains "$out" "can be merged without asking" "and in an own project it can merge itself"

  git reset -q --hard main
  mkdir -p src/components
  printf 'a\nb\n' > src/components/Button.tsx; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: low" "two lines of interface do not deserve a specialist"
  assert_contains "$out" "merge: a person decides" "but with code a person decides"

  git reset -q --hard main
  mkdir -p src/components
  seq 1 80 | sed 's/^/const v/' > src/components/Card.tsx; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: medium" "a screen is medium risk"
  assert_contains "$out" "specialists: interface" "and asks only for the interface one"

  git reset -q --hard main
  mkdir -p src/auth
  seq 1 40 > src/auth/session.ts; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: high" "touching the session is high risk"
  assert_contains "$out" "security" "and asks for the security specialist"

  git reset -q --hard main
  mkdir -p db/migrations
  echo "ALTER TABLE users DROP COLUMN name;" > db/migrations/001.sql; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: high" "a migration is high risk even if it is one line"
  assert_contains "$out" "data" "and asks for the data specialist"

  cd "$CRUX_HOME" || return
}

test_review_scope_in_a_client_repo_a_person_always_decides() {
  sandbox >/dev/null
  local project="$SB/client" out
  mkdir -p "$project"
  echo '{"crux":"0.39.0","project":"client","profile":"client-repo"}' > "$project/crux.json"
  _pm_repo_with_base "$project/app"
  cd "$project/app" || return

  echo "more text" >> README.md; _pm_commit_all
  out="$(bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" main)"
  assert_contains "$out" "merge: a person decides" "not even a text change merges itself"

  echo '{"crux":' > "$project/crux.json"
  out="$(bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" main)"
  assert_contains "$out" "cannot be read" "a broken contract is not read as an own project"

  cd "$CRUX_HOME" || return
}

test_review_scope_stops_without_a_base() {
  sandbox >/dev/null
  _pm_repo_with_base "$SB/nobase"
  cd "$SB/nobase" || return
  assert_exit 1 "a base that does not exist does not become 'no changes'" \
    bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" origin/does-not-exist
  cd "$CRUX_HOME" || return
}

_pm_fake_gh() {
  # _pm_fake_gh <dir> <rollup-json> [counter-file]: a gh that answers just enough
  mkdir -p "$1"
  cat > "$1/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")
    if [[ -n "${3:-}" ]]; then
      n=\$(cat "${3:-/dev/null}" 2>/dev/null || echo 0); echo \$((n + 1)) > "${3:-/dev/null}"
      if [[ \$n -eq 0 ]]; then
        echo '{"statusCheckRollup":[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""}]}'
        exit 0
      fi
    fi
    cat <<'JSON'
$2
JSON
    ;;
  "repo view") echo "owner/repo" ;;
  "api repos/owner/repo/actions/jobs/22/logs")
    printf '%s\n' \
      "2026-09-16T10:00:00.0000000Z > vitest run" \
      "2026-09-16T10:00:01.0000000Z Error: the sum returns 5 and 4 was expected" \
      "2026-09-16T10:00:01.0000000Z \$(printf 'x%.0s' \$(seq 1 2000))" \
      "2026-09-16T10:00:01.0000000Z     at add (src/add.ts:3:9)" \
      "2026-09-16T10:00:01.0000000Z     at a (x.js:1:1)" \
      "2026-09-16T10:00:01.0000000Z     at b (x.js:1:1)" \
      "2026-09-16T10:00:01.0000000Z     at c (x.js:1:1)" \
      "2026-09-16T10:00:02.0000000Z ##[error]Process completed with exit code 1." \
      "2026-09-16T10:00:03.0000000Z Post job cleanup." \
      "2026-09-16T10:00:03.0000000Z removing credentials" ;;
  *) echo "fake gh: do not know how to answer \$*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$1/gh"
}

test_checks_brings_only_the_tail_of_the_failing_log() {
  sandbox >/dev/null
  local rollup='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/owner/repo/actions/runs/11/job/22"},
    {"__typename":"StatusContext","context":"deploy","state":"SUCCESS","targetUrl":"https://x"}]}'
  _pm_fake_gh "$SB/bin" "$rollup"

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/checks.sh" 7 2>&1)" || rc=$?
  assert_eq "1" "$rc" "a red check exits red"
  assert_contains "$out" "the sum returns 5" "it brings the error message"
  assert_contains "$out" "stack trace trimmed" "it trims the stack instead of filling the context with it"
  assert_not_contains "$out" "removing credentials" "and leaves out the cleanup after the error"
  local wide; wide="$(echo "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  [[ "$wide" -le 320 ]] && PASS=$((PASS + 1)) || _fail "a minified line reaches the context whole ($wide characters)"
  assert_contains "$out" "1 green or skipped" "third-party statuses are read too, and green is summarised"
  assert_not_contains "$out" "pass      deploy" "without listing every green check"
}

test_checks_tells_no_checks_from_green() {
  sandbox >/dev/null
  _pm_fake_gh "$SB/bin" '{"statusCheckRollup":[]}'
  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/checks.sh" 7 2>&1)" || rc=$?
  assert_eq "2" "$rc" "no checks is not green"
  assert_contains "$out" "is not the same as verified" "and says so"
}

test_checks_waits_for_the_pending_ones() {
  sandbox >/dev/null
  _pm_fake_gh "$SB/bin" '{"statusCheckRollup":[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}' "$SB/calls"
  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" CRUX_CHECKS_INTERVAL=0 bash "$CRUX_HOME/bin/checks.sh" 7 --wait 2>&1)" || rc=$?
  assert_eq "0" "$rc" "it waits for it to finish and exits green"
  assert_contains "$out" "all green" "and says so"
}

test_checks_does_not_hide_an_unreadable_rollup() {
  sandbox >/dev/null
  _pm_fake_gh "$SB/bin" 'this is not json'
  local rc=0
  env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/checks.sh" 7 >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "an unreadable answer stops, it is not read as no checks"
}

_pm_server() {
  # _pm_server <dir>: starts a local server and leaves its port in <dir>/port
  cat > "$1/server.js" <<'JS'
const http = require("http");
const s = http.createServer((q, r) => {
  if (q.url === "/broken") { r.writeHead(500); return r.end("bad"); }
  if (q.url === "/hidden") { r.writeHead(200); return r.end("<h1>Internal Server Error</h1>"); }
  r.writeHead(200); r.end("<html>new version</html>");
});
s.listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[2], String(s.address().port)));
JS
  node "$1/server.js" "$1/port" &
  SERVER_PID=$!
  local _
  for _ in $(seq 1 50); do [[ -s "$1/port" ]] && break; sleep 0.1; done
}

test_smoke_sees_broken_routes_and_the_new_version() {
  sandbox >/dev/null
  _pm_server "$SB"
  local url out rc
  url="http://127.0.0.1:$(cat "$SB/port")"
  local script="$CRUX_HOME/skills/deploy-watch/scripts/smoke.sh"

  rc=0; out="$(cd "$SB" && bash "$script" --url "$url" / /broken /hidden 2>&1)" || rc=$?
  assert_eq "1" "$rc" "a broken route exits red"
  assert_contains "$out" "/broken → 500" "it names the route and the code"
  assert_contains "$out" "error page" "and catches the error served with 200"

  rc=0; out="$(cd "$SB" && bash "$script" --url "$url" --expect "new version" / 2>&1)" || rc=$?
  assert_eq "0" "$rc" "with the new version answering, it exits green"

  rc=0; out="$(cd "$SB" && env CRUX_SMOKE_INTERVAL=0 bash "$script" --url "$url" --expect "other version" --timeout 0 / 2>&1)" || rc=$?
  assert_eq "3" "$rc" "if the new version does not arrive, it tells it from a broken route"

  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
}

test_smoke_reads_the_contract_and_stops_if_it_cannot() {
  sandbox >/dev/null
  local p="$SB/project" rc out
  mkdir -p "$p"
  local script="$CRUX_HOME/skills/deploy-watch/scripts/smoke.sh"

  echo '{"crux":"0.39.0","project":"p"}' > "$p/crux.json"
  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "without 'deploy' in the contract it stops"
  assert_contains "$out" "does not declare 'deploy'" "and says what is missing"

  echo '{"crux":' > "$p/crux.json"
  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "an unreadable contract does not become a default url"
}

test_signals_groups_and_does_not_swallow_the_following_sources() {
  sandbox >/dev/null
  local p="$SB/project" out rc
  mkdir -p "$p"
  cat > "$p/crux.json" <<'JSON'
{"crux":"0.39.0","project":"p","observability":{"sources":[
  {"name":"reads-stdin","command":"cat; for i in 1 2 3 4 5; do echo \"2026-09-16T10:0$i:00Z ERROR timeout after ${i}00ms\"; done; echo 'INFO all fine'"},
  {"name":"status","command":"echo 'worker Restarting (1) {since} ago'"}
]}}
JSON
  rc=0; out="$(cd "$p" && bash "$CRUX_HOME/skills/prod-signals/scripts/signals.sh" --since 2h 2>&1)" || rc=$?
  assert_eq "0" "$rc" "it reads the sources"
  assert_contains "$out" "5×" "it groups lines that only change in dates and numbers"
  assert_not_contains "$out" "all fine" "and leaves out what does not look like a problem"
  assert_contains "$out" "Restarting (1) 2h ago" "a source that reads stdin does not swallow the next one, and {since} is substituted"

  # A single argument cannot exceed 128 KB on Linux: a real log does.
  cat > "$p/crux.json" <<'JSON'
{"observability":{"sources":[{"name":"big","command":"for i in $(seq 1 6000); do echo \"ERROR failure number $i with enough text behind it to take up room\"; done"}]}}
JSON
  rc=0; out="$(cd "$p" && bash "$CRUX_HOME/skills/prod-signals/scripts/signals.sh" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "a log of more than 128 KB is summarised without breaking"
  assert_contains "$out" "6000×" "and groups all its lines"
}

test_signals_tells_no_sources_from_a_broken_contract() {
  sandbox >/dev/null
  local p="$SB/project" rc
  mkdir -p "$p"
  local script="$CRUX_HOME/skills/prod-signals/scripts/signals.sh"

  echo '{"crux":"0.39.0","project":"p"}' > "$p/crux.json"
  rc=0; (cd "$p" && bash "$script" >/dev/null 2>&1) || rc=$?
  assert_eq "2" "$rc" "with no declared sources it says so with its own code"

  echo '{"observability":{"sources":[{"name":"no-command"}]}}' > "$p/crux.json"
  rc=0; (cd "$p" && bash "$script" >/dev/null 2>&1) || rc=$?
  assert_eq "1" "$rc" "a badly declared source stops"

  echo '{"crux":' > "$p/crux.json"
  rc=0; (cd "$p" && bash "$script" >/dev/null 2>&1) || rc=$?
  assert_eq "1" "$rc" "an unreadable contract stops"
}

test_signals_warns_if_the_contract_has_uncommitted_changes() {
  sandbox >/dev/null
  local p="$SB/docs" rc out
  mkdir -p "$p"
  git -C "$p" init -q -b main
  echo '{"observability":{"sources":[{"name":"app","command":"echo ERROR from main"}]}}' > "$p/crux.json"
  git -C "$p" add -A; git -C "$p" commit -qm init
  local script="$CRUX_HOME/skills/prod-signals/scripts/signals.sh"

  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "the committed contract is read"
  assert_not_contains "$out" "uncommitted" "and without warnings"

  echo '{"observability":{"sources":[{"name":"app","command":"echo ERROR touched"}]}}' > "$p/crux.json"
  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "with uncommitted changes it is not blocked"
  assert_contains "$out" "uncommitted changes" "but it warns before running"
}

test_review_scope_does_not_take_dependencies_or_tests_as_text() {
  sandbox >/dev/null
  local repo="$SB/deps" out
  echo '{"crux":"0.40.0","project":"deps","profile":"multi-repo"}' > "$SB/crux.json"
  _pm_repo_with_base "$repo"
  cd "$repo" || return
  local script="$CRUX_HOME/skills/review-pr/scripts/review-scope.sh"

  echo "package==1.0" > requirements.txt; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: high" "a new dependency is not text"
  assert_contains "$out" "security" "and asks for the security specialist"
  assert_contains "$out" "a person decides" "and it does not merge itself"

  git reset -q --hard main
  mkdir -p pkg/tests
  echo "import os" > pkg/tests/conftest.py; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "merge: a person decides" "a test is run by CI: it does not merge without asking"

  cd "$CRUX_HOME" || return
}

test_review_scope_grades_the_ceremony_by_rigor() {
  sandbox >/dev/null
  local script="$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" out

  # Without crux.json: the project is not registered and goes in `light`.
  _pm_repo_with_base "$SB/loose"
  cd "$SB/loose" || return
  mkdir -p src/components
  seq 1 80 | sed 's/^/const v/' > src/components/Card.tsx; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "rigor: light — no crux.json" "without a contract, light and says why"
  assert_contains "$out" "specialists: none — rigor light" "a screen pays no specialist in light"
  assert_contains "$out" "can be merged without asking — rigor light" "and it merges itself"

  mkdir -p src/auth
  seq 1 40 > src/auth/session.ts; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "security" "but the session still asks for a specialist in light"
  assert_contains "$out" "merge: a person decides" "and it does not merge itself"

  # Strict: no shortcut by size and a person always decides.
  mkdir -p "$SB/serious"
  echo '{"crux":"0.40.0","project":"serious","profile":"multi-repo","rigor":"strict"}' > "$SB/serious/crux.json"
  _pm_repo_with_base "$SB/serious/app"
  cd "$SB/serious/app" || return
  mkdir -p src/components
  printf 'a\nb\n' > src/components/Button.tsx; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "risk: medium" "in strict two lines are not low risk"
  assert_contains "$out" "specialists: interface" "and they ask for their specialist"
  echo "text" >> README.md; git reset -q --soft main; git commit -qm text-only
  git reset -q --hard main; echo "more" >> README.md; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "merge: a person decides" "in strict not even text merges itself"

  # The kernel has no contract, but it is not just any repo.
  _pm_repo_with_base "$SB/kernel"
  cd "$SB/kernel" || return
  mkdir -p bin; touch STANDARD.md bin/crux
  seq 1 80 | sed 's/^/x=/' > bin/something.sh; _pm_commit_all
  out="$(bash "$script" main)"
  assert_contains "$out" "rigor: normal — the kernel itself" "the kernel goes in normal even without crux.json"
  assert_contains "$out" "merge: a person decides" "and its code does not merge itself"
  cd "$SB/serious/app" || return

  # A value that does not exist stops, it does not fall to a default level.
  echo '{"crux":"0.40.0","project":"serious","profile":"multi-repo","rigor":"strictest"}' > "$SB/serious/crux.json"
  assert_exit 1 "an unknown rigor stops" bash "$script" main

  cd "$CRUX_HOME" || return
}

test_doctor_rejects_an_unknown_rigor() {
  sandbox >/dev/null
  local docs; docs="$(new_project rigo --repos "api")"
  assert_exit 0 "with no declared rigor the project is conformant" bash "$CRUX_HOME/bin/doctor.sh" "$docs"

  node -e 'const f=process.argv[1];const j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.rigor="light";require("fs").writeFileSync(f,JSON.stringify(j,null,2))' "$docs/crux.json"
  assert_exit 0 "with a valid rigor too" bash "$CRUX_HOME/bin/doctor.sh" "$docs"

  node -e 'const f=process.argv[1];const j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.rigor="relaxed";require("fs").writeFileSync(f,JSON.stringify(j,null,2))' "$docs/crux.json"
  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "unknown rigor" "a misspelled rigor is pointed out"
  assert_exit 1 "and the project stops being conformant" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_signals_does_not_take_any_number_for_a_5xx() {
  sandbox >/dev/null
  local p="$SB/project" out
  mkdir -p "$p"
  cat > "$p/crux.json" <<'JSON'
{"observability":{"sources":[{"name":"mix","command":"printf '%s\\n' 'responseTime: 544.97' 'Mozilla/5.0 AppleWebKit/537.36' 'GET /x?radio=500' '{\"level\":30,\"msg\":\"GET /error-page 500\"}' '{\"level\":50,\"msg\":\"db down\"}' 'WMS source: HTTP 500' '\"GET / HTTP/1.1\" 502 0'"}]}}
JSON
  out="$(cd "$p" && bash "$CRUX_HOME/skills/prod-signals/scripts/signals.sh" 2>&1)"
  assert_contains "$out" "3 lines in 3 groups" "only the structured error and the two 5xx with context count"
  assert_contains "$out" "db down" "level 50 of a structured log is an error"
  assert_contains "$out" "HTTP 500" "a 5xx with HTTP in front is an error"
  assert_not_contains "$out" "544.97" "a time that starts with 5 is not"
  assert_not_contains "$out" "537.36" "nor a browser version"
  assert_not_contains "$out" "error-page" "nor an info line that mentions error in the URL"
}
