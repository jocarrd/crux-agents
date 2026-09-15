#!/usr/bin/env bash

# La activación es lo que decide si una skill llega a usarse, y era lo único del
# sistema que no se verificaba. Estos casos montan el defecto real —un adaptador
# que repite el procedimiento que adapta— y comprueban que se ve.

skill_falsa() {
  # skill_falsa <directorio> <nombre> <descripción> [cuerpo]
  local dir="$1/$2"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n\n%s\n' \
    "$2" "$3" "$2" "${4:-Procedimiento.}" > "$dir/SKILL.md"
}

test_activacion_probe_senala_el_empate_entre_dos_descripciones() {
  sandbox >/dev/null
  skill_falsa "$CLAUDE_SKILLS_DIR" alfa "Purgar la caché del radar meteorológico. Usa cuando la caché esté sucia."
  skill_falsa "$CLAUDE_SKILLS_DIR" beta "Purgar la caché del radar meteorológico. Usa cuando la caché esté sucia."

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "purgar la caché del radar" 2>&1)"
  assert_contains "$out" "no se distinguen" "dos descripciones idénticas dan empate"
}

test_activacion_probe_distingue_lo_que_si_se_distingue() {
  sandbox >/dev/null
  skill_falsa "$CLAUDE_SKILLS_DIR" alfa "Purgar la caché del radar meteorológico. Usa cuando la caché esté sucia."
  skill_falsa "$CLAUDE_SKILLS_DIR" beta "Renovar el certificado del servidor de correo. Usa cuando caduque."

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "purgar la caché del radar" 2>&1)"
  assert_not_contains "$out" "no se distinguen" "descripciones distintas no dan empate"
}

test_activacion_los_casos_fallan_cuando_gana_otra() {
  sandbox >/dev/null
  skill_falsa "$CLAUDE_SKILLS_DIR" correcta "Renovar el certificado del servidor de correo. Usa cuando caduque."
  skill_falsa "$CLAUDE_SKILLS_DIR" ladrona "Renovar el certificado caducado del correo. Usa cuando el certificado del correo esté caducado y haya que renovarlo."
  printf 'correcta\thay que renovar el certificado del correo que ha caducado\n' > "$SB/casos.tsv"

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --casos "$SB/casos.tsv" 2>&1)"
  assert_contains "$out" "FALLA" "un caso que pierde se reporta"
  assert_exit 1 "y el comando sale en rojo" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --casos "$SB/casos.tsv"
}

test_activacion_los_casos_del_kernel_siguen_pasando() {
  # Mide el catálogo del kernel de verdad, no uno de mentira: es la red que
  # avisa si una descripción nueva apaga una que ya se activaba. El directorio
  # va por invocación —nunca heredado— porque el caso anterior deja exportado
  # el suyo y apunta a un sandbox ya borrado.
  local casos="$CRUX_HOME/skills/skill-audit/casos/activacion.tsv"
  assert_file "$casos" "el fichero de casos del kernel existe"

  local out
  out="$(env CLAUDE_SKILLS_DIR="$CRUX_HOME/skills" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --casos "$casos" 2>&1)"
  local fallan; fallan="$(echo "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) fallan.*/\1/p')"
  # Uno conocido y anotado: `end-session` y `promote-to-docs` se solapan porque
  # una contiene a la otra. Si sube de ahí, algo ha apagado una skill.
  local veredicto=mal
  [[ -n "$fallan" && "$fallan" -le 1 ]] && veredicto=bien
  assert_eq "bien" "$veredicto" "los casos del kernel no empeoran (fallan: ${fallan:-sin medir})"
}

test_activacion_audit_ve_al_adaptador_que_repite_el_procedimiento() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega --repos "web")"

  # Un adaptador que, en vez de aportar datos, vuelve a contar el método: es lo
  # que deja una promoción mal rematada.
  local desc
  desc="$(awk '/^---$/{n++;next} n==1 && /^description:/{p=1} n==1 && p && /^[a-z_-]+:/ && !/^description:/{p=0} n==1 && p{print}' \
    "$CRUX_HOME/skills/render-loop/SKILL.md" | sed 's/^description: *//' | tr '\n' ' ')"
  mkdir -p "$docs/.claude/skills/project/omega-render"
  printf -- '---\nname: omega-render\ndescription: %s\n---\n\n# omega-render\n\nAdapta render-loop.\n' \
    "$desc" > "$docs/.claude/skills/project/omega-render/SKILL.md"

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/audit.mjs" "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_contains "$out" "compiten con el procedimiento" "detecta la colisión con lo que adapta"
  assert_contains "$out" "omega-render" "y nombra al adaptador"
}

test_activacion_audit_ve_al_adaptador_que_no_se_nombra() {
  sandbox >/dev/null
  local docs; docs="$(new_project sigma --repos "web")"
  mkdir -p "$docs/.claude/skills/project/callado"
  printf -- '---\nname: callado\ndescription: Comparar una salida con su referencia. Usa cuando dudes.\n---\n\n# callado\n\nAdapta visual-diff.\n' \
    > "$docs/.claude/skills/project/callado/SKILL.md"

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/audit.mjs" "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_contains "$out" "no nombran su proyecto en la descripción" "detecta al adaptador indistinguible"
  assert_contains "$out" "callado" "y lo nombra"
}

test_activacion_check_descripcion_caza_los_defectos() {
  sandbox >/dev/null
  local dir="$SB/catalogo"
  skill_falsa "$dir" muda "Ayuda con los despliegues del sistema."
  skill_falsa "$dir" buena "Desplegar sin CI. Usa cuando el pipeline esté caído."
  mkdir -p "$dir/rota"
  printf 'sin frontmatter\n' > "$dir/rota/SKILL.md"

  local out; out="$(node "$CRUX_HOME/lib/check-skill-description.mjs" "$dir" es 2>&1)"
  assert_contains "$out" "no dice cuándo usarla" "caza la descripción que no se activa"
  assert_contains "$out" "sin frontmatter" "caza la skill que el agente no podrá cargar"
  assert_not_contains "$out" "'buena'" "no marca la que sí dispara"
}

test_activacion_check_descripcion_pasa_el_catalogo_del_kernel() {
  local out; out="$(node "$CRUX_HOME/lib/check-skill-description.mjs" "$CRUX_HOME/skills" es 2>&1)"
  assert_eq "" "$out" "ninguna skill del kernel tiene la descripción mal formada"
}
