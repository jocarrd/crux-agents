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
  # Hacen falta más skills en el catálogo, y no por decorar: una palabra que
  # está en el 100% de las descripciones no distingue nada y pesa cero, así que
  # con solo las dos gemelas no puntuaría ninguna.
  skill_falsa "$CLAUDE_SKILLS_DIR" gamma "Renovar el certificado del servidor de correo. Usa cuando caduque."
  skill_falsa "$CLAUDE_SKILLS_DIR" delta "Rotar las claves de acceso del almacenamiento. Usa cada trimestre."

  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "purgar la caché del radar" 2>&1)"
  assert_contains "$out" "no se distinguen" "dos descripciones idénticas dan empate"
}

test_activacion_probe_no_puntua_lo_que_esta_en_todas() {
  sandbox >/dev/null
  skill_falsa "$CLAUDE_SKILLS_DIR" alfa "Desplegar el servicio. Usa cuando toque."
  skill_falsa "$CLAUDE_SKILLS_DIR" beta "Reiniciar el servicio. Usa cuando toque."

  # `servicio` está en las dos: no ayuda a elegir y no debe inventar un ganador.
  local out; out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" "el servicio" 2>&1)"
  assert_contains "$out" "ninguna skill comparte vocabulario" \
    "una palabra presente en todo el catálogo no decide nada"
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
  # Mide el catálogo del kernel de verdad: es la red que avisa si una descripción
  # nueva apaga una que ya se activaba. El directorio va por invocación —nunca
  # heredado— porque el caso anterior deja exportado el suyo, apuntando a un
  # sandbox ya borrado.
  #
  # Se afirma el número de casos y la identidad del fallo tolerado, no solo un
  # contador: con un contador suelto, un fichero vaciado, con los tabuladores
  # convertidos en espacios, o con un fallo distinto que sustituya al conocido,
  # pasaban los tres en verde.
  local casos="$CRUX_HOME/skills/skill-audit/casos/activacion.tsv"
  assert_file "$casos" "el fichero de casos del kernel existe"

  local esperados; esperados="$(grep -cve '^[[:space:]]*$' -e '^#' "$casos")"
  local out
  out="$(env CLAUDE_SKILLS_DIR="$CRUX_HOME/skills" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --casos "$casos" 2>&1)"

  assert_contains "$out" "$esperados casos ·" "se evalúan todos los casos del fichero"

  local fallan; fallan="$(echo "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) fallan.*/\1/p')"
  local veredicto=mal
  [[ -n "$fallan" && "$fallan" -le 1 ]] && veredicto=bien
  assert_eq "bien" "$veredicto" "no empeoran (fallan: ${fallan:-sin medir})"

  # `end-session` y `promote-to-docs` se solapan porque una contiene a la otra.
  # Es el único fallo admitido, y se nombra: si el que falla pasa a ser otro, es
  # una regresión con el contador intacto.
  if [[ "${fallan:-0}" -eq 1 ]]; then
    assert_contains "$out" "esperaba end-session" "el único fallo sigue siendo el anotado"
  fi
}

test_activacion_audit_ve_al_adaptador_que_se_parece_a_su_procedimiento() {
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
  assert_contains "$out" "parecidos a su procedimiento" "señala el par para comprobarlo"
  assert_contains "$out" "omega-render" "y nombra al adaptador"
  assert_contains "$out" "--adaptador omega-render render-loop" "y da el comando que da el veredicto"
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

test_activacion_un_adaptador_tiene_que_repartir() {
  sandbox >/dev/null
  # El procedimiento genérico y su adaptador, bien repartidos: el adaptador
  # aporta los nombres propios y no vuelve a contar el método entero.
  skill_falsa "$CLAUDE_SKILLS_DIR" metodo \
    "Probar una aplicación móvil en un dispositivo físico conectado por cable. Usa cuando haya que validar en nativo."
  skill_falsa "$CLAUDE_SKILLS_DIR" adaptador \
    "Datos de Chispas: package, deep-link y terminal de referencia. Usa junto a metodo para el QA de Chispas."
  skill_falsa "$CLAUDE_SKILLS_DIR" otra "Renovar certificados del correo. Usa cuando caduquen."

  assert_exit 0 "un adaptador que reparte pasa la prueba" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --adaptador adaptador metodo \
      "probar la aplicación en un dispositivo físico" "probar Chispas en el terminal"
}

test_activacion_un_adaptador_que_roba_lo_generico_falla() {
  sandbox >/dev/null
  skill_falsa "$CLAUDE_SKILLS_DIR" metodo \
    "Probar una aplicación móvil en un dispositivo físico. Usa cuando haya que validar en nativo."
  # Este repite el método entero y además añade lo suyo: gana las dos.
  skill_falsa "$CLAUDE_SKILLS_DIR" ladron \
    "Probar una aplicación móvil en un dispositivo físico conectado por cable, con los datos de Chispas. Usa cuando haya que validar en nativo la aplicación en el dispositivo."
  skill_falsa "$CLAUDE_SKILLS_DIR" otra "Renovar certificados del correo. Usa cuando caduquen."

  local out
  out="$(node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --adaptador ladron metodo \
    "probar la aplicación en un dispositivo físico" "probar Chispas en el terminal" 2>&1)"
  assert_contains "$out" "NO reparte" "un adaptador que gana lo genérico se reporta"
  assert_exit 1 "y el comando sale en rojo" \
    node "$CRUX_HOME/skills/skill-audit/scripts/probe.mjs" --adaptador ladron metodo \
      "probar la aplicación en un dispositivo físico" "probar Chispas en el terminal"
}
