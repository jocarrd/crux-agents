#!/usr/bin/env bash
# crux skill test, con un agente de mentira: responde según lo que diga la
# skill, así la suite no depende de ningún modelo ni gasta tokens.

_skill_de_prueba() {
  # _skill_de_prueba <dir> <regla> — una skill cuyo cuerpo lleva <regla>
  mkdir -p "$1/tests"
  printf -- '---\nname: demo\ndescription: Demo. Usa cuando haga falta.\n---\n\n# demo\n\n%s\n' "$2" > "$1/SKILL.md"
  cat > "$1/tests/escenarios.md" <<'ESC'
# Escenarios

## Pregunta sobre la regla
Pregunta: ¿Qué hago con el test rojo?
Debe: no lo edites
No debe: cámbialo
ESC
}

_agente_falso() {
  # Si la skill dice "no se edita", responde bien; si no, responde mal.
  cat > "$SB/agente.sh" <<'AG'
#!/usr/bin/env bash
cat >/dev/null
if grep -q "no se edita" "$CRUX_SKILL_FILE"; then echo "No lo edites: para y avisa."; else echo "Cámbialo y sigue."; fi
AG
  chmod +x "$SB/agente.sh"
  echo "bash $SB/agente.sh"
}

test_skill_test_pasa_y_falla_con_sus_escenarios() {
  sandbox >/dev/null
  local runner; runner="$(_agente_falso)"
  _skill_de_prueba "$SB/buena" "Un test rojo no se edita."
  _skill_de_prueba "$SB/mala" "Haz lo que veas."
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="$runner" CRUX_SKILL_TOKENS="echo 123" node "$CRUX_HOME/bin/skill.mjs" test "$SB/buena" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "con la respuesta esperada sale con 0"
  assert_contains "$out" "todos los escenarios pasan" "y lo dice"
  assert_contains "$out" "123 tokens" "cuenta los tokens con el adaptador"
  rc=0; out="$(CRUX_SKILL_RUNNER="$runner" node "$CRUX_HOME/bin/skill.mjs" test "$SB/mala" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "con otra respuesta sale con 1"
  assert_contains "$out" "no dice /no lo edites/" "dice qué comprobación falló"
  assert_contains "$out" "dice /cámbialo/" "también las que no debía decir"
}

test_skill_test_marca_la_regresion_frente_a_otra_version() {
  sandbox >/dev/null
  local runner; runner="$(_agente_falso)"
  local repo="$SB/repo"; mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  _skill_de_prueba "$repo/skills/demo" "Un test rojo no se edita."
  git -C "$repo" add -A; git -C "$repo" commit -qm init
  # Se acorta la skill y se pierde el matiz
  printf -- '---\nname: demo\ndescription: Demo. Usa cuando haga falta.\n---\n\n# demo\n\nCorto.\n' > "$repo/skills/demo/SKILL.md"
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="$runner" node "$CRUX_HOME/bin/skill.mjs" test "$repo/skills/demo" --against HEAD 2>&1)" || rc=$?
  assert_eq "1" "$rc" "la versión nueva falla"
  assert_contains "$out" "REGR" "y lo marca como regresión"
  assert_contains "$out" "(HEAD: ok)" "porque la anterior pasaba"
  assert_contains "$out" "1 regresión" "con el recuento"
}

test_skill_test_sin_escenarios_dice_donde_crearlos() {
  sandbox >/dev/null
  mkdir -p "$SB/sola"
  printf -- '---\nname: sola\ndescription: X. Usa cuando haga falta.\n---\n' > "$SB/sola/SKILL.md"
  local out rc=0
  out="$(CRUX_SKILL_RUNNER="echo x" node "$CRUX_HOME/bin/skill.mjs" test "$SB/sola" 2>&1)" || rc=$?
  assert_eq "2" "$rc" "sin escenarios no hay prueba"
  assert_contains "$out" "tests/escenarios.md" "y dice dónde van"
  mkdir -p "$SB/sola/tests"; printf '## vacío\nPregunta: ¿algo?\n' > "$SB/sola/tests/escenarios.md"
  rc=0; out="$(CRUX_SKILL_RUNNER="echo x" node "$CRUX_HOME/bin/skill.mjs" test "$SB/sola" 2>&1)" || rc=$?
  assert_contains "$out" "no comprueba nada" "un escenario sin comprobaciones se rechaza"
}

test_los_escenarios_del_kernel_se_leen_bien() {
  # Todos los escenarios del kernel tienen pregunta y alguna comprobación, y sus
  # expresiones compilan: si no, el fallo saldría al usarlos, no aquí.
  local out
  out="$(node -e '
    const fs = require("fs"), path = require("path");
    import(process.argv[1] + "/bin/skill.mjs").then(({ leerEscenarios }) => {
      const dir = process.argv[1] + "/skills"; let n = 0, malos = [];
      for (const s of fs.readdirSync(dir)) {
        const f = path.join(dir, s, "tests", "escenarios.md");
        if (!fs.existsSync(f)) continue;
        for (const e of leerEscenarios(fs.readFileSync(f, "utf8"))) {
          n++;
          for (const r of [...e.debe, ...e.noDebe]) { try { new RegExp(r, "iu"); } catch { malos.push(s + ": " + r); } }
        }
      }
      console.log(n + " " + malos.join(","));
    });
  ' "$CRUX_HOME" 2>&1)"
  assert_contains "$out" " " "se pueden leer"
  assert_eq "" "${out#* }" "todas las expresiones compilan"
  [[ "${out%% *}" -ge 10 ]] && assert_eq ok ok "hay escenarios en el kernel (${out%% *})" || assert_eq ">=10" "${out%% *}" "hay escenarios en el kernel"
}
