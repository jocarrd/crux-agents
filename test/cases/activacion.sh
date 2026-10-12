#!/usr/bin/env bash

# Activation is what decides whether a skill ever gets used, and it was the one
# thing in the system that was not verified. These cases build the real flaw —an
# adapter that repeats the procedure it adapts— and check that it shows.

fake_skill() {
  # fake_skill <directory> <name> <description> [body]
  local dir="$1/$2"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n\n%s\n' \
    "$2" "$3" "$2" "${4:-Procedure.}" > "$dir/SKILL.md"
}

test_activation_probe_flags_tie_between_two_descriptions() {
  needs node || return 0
  sandbox >/dev/null
  fake_skill "$CLAUDE_SKILLS_DIR" alfa "Purgar la caché del radar meteorológico. Usa cuando la caché esté sucia."
  fake_skill "$CLAUDE_SKILLS_DIR" beta "Purgar la caché del radar meteorológico. Usa cuando la caché esté sucia."
  # More skills are needed in the catalog, and not for decoration: a word that
  # is in 100% of the descriptions distinguishes nothing and weighs zero, so
  # with only the two twins nothing would score.
  fake_skill "$CLAUDE_SKILLS_DIR" gamma "Renovar el certificado del servidor de correo. Usa cuando caduque."
  fake_skill "$CLAUDE_SKILLS_DIR" delta "Rotar las claves de acceso del almacenamiento. Usa cada trimestre."

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "purgar la caché del radar" 2>&1)"
  assert_contains "$out" "not distinguishable" "two identical descriptions tie"
}

test_activation_probe_does_not_score_what_is_in_all() {
  needs node || return 0
  sandbox >/dev/null
  fake_skill "$CLAUDE_SKILLS_DIR" alfa "Desplegar el servicio. Usa cuando toque."
  fake_skill "$CLAUDE_SKILLS_DIR" beta "Reiniciar el servicio. Usa cuando toque."

  # `servicio` is in both: it does not help choose and must not invent a winner.
  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "el servicio" 2>&1)"
  assert_contains "$out" "no skill shares vocabulary" \
    "a word present in the whole catalog decides nothing"
}

test_activation_probe_distinguishes_what_is_distinguishable() {
  needs node || return 0
  sandbox >/dev/null
  fake_skill "$CLAUDE_SKILLS_DIR" alfa "Purgar la caché del radar meteorológico. Usa cuando la caché esté sucia."
  fake_skill "$CLAUDE_SKILLS_DIR" beta "Renovar el certificado del servidor de correo. Usa cuando caduque."

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "purgar la caché del radar" 2>&1)"
  assert_not_contains "$out" "not distinguishable" "different descriptions do not tie"
}

test_activation_cases_fail_when_another_wins() {
  needs node || return 0
  sandbox >/dev/null
  fake_skill "$CLAUDE_SKILLS_DIR" correcta "Renovar el certificado del servidor de correo. Usa cuando caduque."
  fake_skill "$CLAUDE_SKILLS_DIR" thiefa "Renovar el certificado caducado del correo. Usa cuando el certificado del correo esté caducado y haya que renovarlo."
  printf 'correcta\thay que renovar el certificado del correo que ha caducado\n' > "$SB/cases.tsv"

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --cases "$SB/cases.tsv" 2>&1)"
  assert_contains "$out" "FAIL" "a losing case is reported"
  assert_exit 1 "and the command exits red" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --cases "$SB/cases.tsv"
}

test_activation_kernel_cases_keep_passing() {
  needs node || return 0
  # Measures the real kernel catalog: it is the net that warns if a new
  # description switches off one that used to activate. The directory goes per
  # invocation —never inherited— because the previous case leaves its own
  # exported, pointing at a sandbox already deleted.
  #
  # What is asserted is the number of cases and the identity of the tolerated
  # failure, not just a counter: with a bare counter, an emptied file, one with
  # the tabs turned into spaces, or a different failure replacing the known
  # one all passed green.
  local cases="$CRUX_HOME/skills/skill-audit/casos/activacion.tsv"
  assert_file "$cases" "the kernel cases file exists"

  local expected_list; expected_list="$(grep -cve '^[[:space:]]*$' -e '^#' "$cases")"
  local out
  out="$(env CLAUDE_SKILLS_DIR="$CRUX_HOME/skills" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --cases "$cases" 2>&1)"

  assert_contains "$out" "$expected_list cases ·" "every case in the file is evaluated"

  local failing; failing="$(echo "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) fail .*/\1/p')"
  local verdict=bad
  [[ -n "$failing" && "$failing" -le 1 ]] && verdict=good
  assert_eq "good" "$verdict" "they do not get worse (failing: ${failing:-unmeasured})"

  # `end-session` and `promote-to-docs` overlap because one contains the other.
  # It is the only accepted failure, and it is named: if the failing one becomes
  # another, it is a regression with the counter intact.
  if [[ "${failing:-0}" -eq 1 ]]; then
    assert_contains "$out" "expected end-session" "the only failure is still the recorded one"
  fi
}

test_activation_audit_sees_adapter_resembling_its_procedure() {
  needs node || return 0
  sandbox >/dev/null
  local docs; docs="$(new_project omega --repos "web")"

  # An adapter that, instead of providing data, retells the method: it is what
  # a badly finished promotion leaves behind.
  local desc
  desc="$(awk '/^---$/{n++;next} n==1 && /^description:/{p=1} n==1 && p && /^[a-z_-]+:/ && !/^description:/{p=0} n==1 && p{print}' \
    "$CRUX_HOME/skills/render-loop/SKILL.md" | sed 's/^description: *//' | tr '\n' ' ')"
  mkdir -p "$docs/.claude/skills/project/omega-render"
  printf -- '---\nname: omega-render\ndescription: %s\n---\n\n# omega-render\n\nAdapta render-loop.\n' \
    "$desc" > "$docs/.claude/skills/project/omega-render/SKILL.md"

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/audit.mjs" "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_contains "$out" "similar to their procedure" "points at the pair to check it"
  assert_contains "$out" "omega-render" "and names the adapter"
  assert_contains "$out" "--adaptador omega-render render-loop" "and gives the command that gives the verdict"
}

test_activation_audit_sees_adapter_that_does_not_name_itself() {
  needs node || return 0
  sandbox >/dev/null
  local docs; docs="$(new_project sigma --repos "web")"
  mkdir -p "$docs/.claude/skills/project/quiet"
  printf -- '---\nname: quiet\ndescription: Comparar una salida con su referencia. Usa cuando dudes.\n---\n\n# quiet\n\nAdapta visual-diff.\n' \
    > "$docs/.claude/skills/project/quiet/SKILL.md"

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/audit.mjs" "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_contains "$out" "do not name their project in the description" "detects the indistinguishable adapter"
  assert_contains "$out" "quiet" "and names it"
}

test_activation_check_description_catches_defects() {
  sandbox >/dev/null
  local dir="$SB/catalog"
  fake_skill "$dir" mute "Ayuda con los despliegues del sistema."
  fake_skill "$dir" good "Desplegar sin CI. Usa cuando el pipeline esté caído."
  mkdir -p "$dir/broken"
  printf 'no frontmatter\n' > "$dir/broken/SKILL.md"

  local out; out="$("$CRUX_HOME/bin/crux" __check skill-description "$dir" es 2>&1)"
  assert_contains "$out" "does not say when to use it" "catches the description that does not activate"
  assert_contains "$out" "without frontmatter" "catches the skill the agent will not be able to load"
  assert_not_contains "$out" "'good'" "does not flag the one that does fire"
}

test_activation_check_description_passes_kernel_catalog() {
  local out; out="$("$CRUX_HOME/bin/crux" __check skill-description "$CRUX_HOME/skills" en 2>&1)"
  assert_eq "" "$out" "no kernel skill has a malformed description"
}

test_activation_adapter_must_split() {
  needs node || return 0
  sandbox >/dev/null
  # The generic procedure and its adapter, well split: the adapter provides
  # the proper names and does not retell the whole method.
  fake_skill "$CLAUDE_SKILLS_DIR" method \
    "Probar una aplicación móvil en un dispositivo físico conectado por cable. Usa cuando haya que validar en nativo."
  fake_skill "$CLAUDE_SKILLS_DIR" adapter \
    "Datos de Chispas: package, deep-link y terminal de referencia. Usa junto a method para el QA de Chispas."
  fake_skill "$CLAUDE_SKILLS_DIR" other "Renovar certificados del correo. Usa cuando caduquen."

  assert_exit 0 "an adapter that splits passes the test" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --adapter adapter method \
      "probar la aplicación en un dispositivo físico" "probar Chispas en el terminal"
}

test_activation_adapter_stealing_generic_fails() {
  needs node || return 0
  sandbox >/dev/null
  fake_skill "$CLAUDE_SKILLS_DIR" method \
    "Probar una aplicación móvil en un dispositivo físico. Usa cuando haya que validar en nativo."
  # This one repeats the whole method and adds its own on top: it wins both.
  fake_skill "$CLAUDE_SKILLS_DIR" greedy-adapter \
    "Probar una aplicación móvil en un dispositivo físico conectado por cable, con los datos de Chispas. Usa cuando haya que validar en nativo la aplicación en el dispositivo."
  fake_skill "$CLAUDE_SKILLS_DIR" other "Renovar certificados del correo. Usa cuando caduquen."

  local out
  out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --adapter greedy-adapter method \
    "probar la aplicación en un dispositivo físico" "probar Chispas en el terminal" 2>&1)"
  assert_contains "$out" "does NOT split" "an adapter that wins the generic one is reported"
  assert_exit 1 "and the command exits red" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --adapter greedy-adapter method \
      "probar la aplicación en un dispositivo físico" "probar Chispas en el terminal"
}

test_activation_skill_stays_under_thousand_words() {
  # It is loaded whole into the context every time it is used: what is in
  # excess is usually the why of each rule, which belongs in references/.
  sandbox >/dev/null
  local dir="$SB/catalog"
  _skill_of() {
    mkdir -p "$dir/$1"
    { printf -- '---\nname: %s\ndescription: Hacer algo. Usa cuando haga falta.\n---\n\n' "$1"
      yes word | head -n "$2" | tr '\n' ' '; } > "$dir/$1/SKILL.md"
  }
  _skill_of short 300
  _skill_of long 1200
  _skill_of old-grows 1300
  _skill_of old-fits 800
  _skill_of old-same 1100
  printf '# inherited\nold-grows 1150\nold-fits 1100\nold-same 1200\n' > "$dir/.oversized"

  local out; out="$("$CRUX_HOME/bin/crux" __check skill-description "$dir" es 2>&1)"
  assert_contains "$out" "skill 'long':" "a new one over the cap warns"
  assert_contains "$out" "references/" "and says how to fix it"
  assert_contains "$out" "skill 'old-grows': has grown" "an inherited one cannot grow"
  assert_contains "$out" "skill 'old-fits': now fits" "an inherited one that now fits has to leave the list"
  assert_not_contains "$out" "'old-same'" "an inherited one that does not grow does not bother"
  assert_not_contains "$out" "'short'" "nor one that fits"
}
