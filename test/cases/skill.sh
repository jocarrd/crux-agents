#!/usr/bin/env bash
# crux skill test, with a fake agent: it answers according to what the skill
# says, so the suite depends on no model and spends no tokens.

_test_skill() {
  # _test_skill <dir> <rule> [keywords] — a skill whose body carries <rule>.
  # Keywords are English by default; "es" writes the Spanish form that older
  # scenario files use (Pregunta:/Debe:/No debe:).
  mkdir -p "$1/tests"
  printf -- '---\nname: demo\ndescription: Demo. Use when needed.\n---\n\n# demo\n\n%s\n' "$2" > "$1/SKILL.md"
  if [[ "${3:-en}" == "es" ]]; then
    cat > "$1/tests/escenarios.md" <<'ESC'
# Escenarios

## Pregunta sobre la regla
Pregunta: ¿Qué hago con el test rojo?
Debe: no lo edites
No debe: cámbialo
ESC
  else
    cat > "$1/tests/escenarios.md" <<'ESC'
# Scenarios

## Question about the rule
Question: What do I do with the red test?
Must: do not edit it
Must not: change it
ESC
  fi
}

_fake_agent() {
  # If the skill says "is not edited", it answers right; otherwise it answers wrong.
  cat > "$SB/agent.sh" <<'AG'
#!/usr/bin/env bash
cat >/dev/null
if grep -q "is not edited" "$CRUX_SKILL_FILE"; then echo "Do not edit it: stop and report."; else echo "Change it and carry on."; fi
AG
  chmod +x "$SB/agent.sh"
  echo "bash $SB/agent.sh"
}

test_skill_test_passes_and_fails_on_its_scenarios() {
  sandbox >/dev/null
  local runner; runner="$(_fake_agent)"
  _test_skill "$SB/good" "A red test is not edited."
  _test_skill "$SB/bad" "Do what you see fit."
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="$runner" CRUX_SKILL_TOKENS="echo 123" node "$CRUX_HOME/bin/skill.mjs" test "$SB/good" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "with the expected answer it exits 0"
  assert_contains "$out" "all scenarios pass" "and says so"
  assert_contains "$out" "123 tokens" "counts the tokens with the adapter"
  rc=0; out="$(CRUX_SKILL_RUNNER="$runner" node "$CRUX_HOME/bin/skill.mjs" test "$SB/bad" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "with another answer it exits 1"
  assert_contains "$out" "does not say /do not edit it/" "says which check failed"
  assert_contains "$out" "says /change it/" "also the ones it must not have said"
}

test_skill_test_still_reads_spanish_scenario_keywords() {
  sandbox >/dev/null
  # Scenario files written before the keywords were translated keep working.
  _test_skill "$SB/legacy" "A red test is not edited." es
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="echo No lo edites: para y avisa." node "$CRUX_HOME/bin/skill.mjs" test "$SB/legacy" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "an answer that meets the Debe: and avoids the No debe: passes"
  assert_contains "$out" "all scenarios pass" "and the Spanish scenario is counted"
  rc=0; out="$(CRUX_SKILL_RUNNER="echo Cámbialo y sigue." node "$CRUX_HOME/bin/skill.mjs" test "$SB/legacy" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "an answer that misses the Debe: fails"
  assert_contains "$out" "does not say /no lo edites/" "the Debe: of the Spanish form is checked"
  assert_contains "$out" "says /cámbialo/" "and the No debe: too"
}

test_skill_test_flags_regression_against_another_version() {
  sandbox >/dev/null
  local runner; runner="$(_fake_agent)"
  local repo="$SB/repo"; mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  _test_skill "$repo/skills/demo" "A red test is not edited."
  git -C "$repo" add -A; git -C "$repo" commit -qm init
  # The skill is shortened and the nuance is lost
  printf -- '---\nname: demo\ndescription: Demo. Use when needed.\n---\n\n# demo\n\nShort.\n' > "$repo/skills/demo/SKILL.md"
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="$runner" node "$CRUX_HOME/bin/skill.mjs" test "$repo/skills/demo" --against HEAD 2>&1)" || rc=$?
  assert_eq "1" "$rc" "the new version fails"
  assert_contains "$out" "REGR" "and flags it as a regression"
  assert_contains "$out" "(HEAD: ok)" "because the previous one passed"
  assert_contains "$out" "1 regression" "with the count"
}

test_skill_test_without_scenarios_says_where_to_create_them() {
  sandbox >/dev/null
  mkdir -p "$SB/alone"
  printf -- '---\nname: alone\ndescription: X. Use when needed.\n---\n' > "$SB/alone/SKILL.md"
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="echo x" node "$CRUX_HOME/bin/skill.mjs" test "$SB/alone" 2>&1)" || rc=$?
  assert_eq "2" "$rc" "without scenarios there is no test"
  assert_contains "$out" "tests/escenarios.md" "and says where they go"
  mkdir -p "$SB/alone/tests"; printf '## empty\nQuestion: anything?\n' > "$SB/alone/tests/escenarios.md"
  rc=0; out="$(CRUX_SKILL_RUNNER="echo x" node "$CRUX_HOME/bin/skill.mjs" test "$SB/alone" 2>&1)" || rc=$?
  assert_contains "$out" "checks nothing" "a scenario without checks is rejected"
}

test_kernel_scenarios_read_correctly() {
  # Every kernel scenario has a question and at least one check, and its
  # expressions compile: otherwise the failure would show up on use, not here.
  local out
  out="$(node -e '
    const fs = require("fs"), path = require("path");
    import(process.argv[1] + "/bin/skill.mjs").then(({ readScenarios }) => {
      const dir = process.argv[1] + "/skills"; let n = 0, bad = [];
      for (const s of fs.readdirSync(dir)) {
        const f = path.join(dir, s, "tests", "escenarios.md");
        if (!fs.existsSync(f)) continue;
        for (const e of readScenarios(fs.readFileSync(f, "utf8"))) {
          n++;
          for (const r of [...e.must, ...e.mustNot]) { try { new RegExp(r, "iu"); } catch { bad.push(s + ": " + r); } }
        }
      }
      console.log(n + " " + bad.join(","));
    });
  ' "$CRUX_HOME" 2>&1)"
  assert_contains "$out" " " "they can be read"
  assert_eq "" "${out#* }" "every expression compiles"
  [[ "${out%% *}" -ge 10 ]] && assert_eq ok ok "there are scenarios in the kernel (${out%% *})" || assert_eq ">=10" "${out%% *}" "there are scenarios in the kernel"
}
