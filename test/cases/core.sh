#!/usr/bin/env bash

test_init_crea_una_estructura_conforme() {
  sandbox >/dev/null
  local docs; docs="$(new_project alfa --repos "api,web")"

  for f in README.md AGENTS.md crux.json decisions/README.md decisions/index.md repos/README.md; do
    assert_file "$docs/$f" "estructura obligatoria"
  done
  assert_symlink "$docs/CLAUDE.md" "AGENTS.md" "CLAUDE.md enlaza a AGENTS.md"
  assert_file "$docs/repos/api/README.md" "carpeta del repo declarado"
  assert_file "$docs/.gitignore" "gitignore materializado"

  assert_not_contains "$(cat "$docs/README.md")" "{{" "placeholders sustituidos"
  assert_not_contains "$(cat "$docs/AGENTS.md")" "{{" "placeholders sustituidos"

  assert_exit 0 "doctor pasa sobre un proyecto recién creado" \
    bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_init_es_determinista() {
  sandbox >/dev/null
  local a b
  a="$(new_project uno --repos "api")"
  b="$(new_project dos --repos "api")"

  local diff_out
  diff_out="$(diff \
    <(cd "$a" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sort) \
    <(cd "$b" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sort) 2>&1)"
  assert_eq "" "$diff_out" "dos inits producen el mismo árbol de ficheros"
}

test_init_rechaza_nombres_invalidos() {
  sandbox >/dev/null
  assert_exit 1 "rechaza CamelCase" \
    bash "$CRUX_HOME/bin/init.sh" MiProyecto --no-remote --parent "$CRUX_PROJECTS_DIR"
  assert_exit 1 "rechaza perfil inexistente" \
    bash "$CRUX_HOME/bin/init.sh" beta --no-remote --parent "$CRUX_PROJECTS_DIR" --profile inventado
}

test_doctor_falla_sin_contrato() {
  sandbox >/dev/null
  local docs; docs="$(new_project gamma)"
  rm "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "falta crux.json" "reporta el contrato ausente"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_repo_declarado_sin_carpeta_de_doc() {
  sandbox >/dev/null
  local docs; docs="$(new_project delta --repos "api")"
  rm -rf "$docs/repos/api"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "repo declarado sin carpeta de doc" "detecta la carpeta ausente"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_carpeta_no_declarada() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon --repos "api")"
  mkdir -p "$docs/repos/fantasma"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no está declarado en crux.json" "detecta la carpeta huérfana"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_claude_md_divergente() {
  sandbox >/dev/null
  local docs; docs="$(new_project zeta)"
  rm "$docs/CLAUDE.md"
  echo "copia manual" > "$docs/CLAUDE.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no un symlink" "detecta las dos fuentes que divergen"
}

test_doctor_detecta_enlaces_markdown_rotos() {
  sandbox >/dev/null
  local docs; docs="$(new_project eta)"
  echo "Ver [esto](./no-existe.md)." >> "$docs/README.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "enlaces markdown rotos" "detecta el enlace roto"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_skill_sin_frontmatter() {
  sandbox >/dev/null
  local docs; docs="$(new_project theta)"
  mkdir -p "$docs/.claude/skills/project/rota"
  echo "# sin frontmatter" > "$docs/.claude/skills/project/rota/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "skill sin frontmatter" "detecta la skill mal formada"
}

test_perfil_cliente_no_escribe_en_el_repo_ajeno() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente/vendor"
  mkdir -p "$vendor"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_no_file "$vendor/AGENTS.md" "link no crea punteros con perfil de cliente"
  assert_no_file "$vendor/CLAUDE.md" "link no crea punteros con perfil de cliente"
  assert_eq "0" "$(ls -A "$vendor" | wc -l)" "el repo del cliente queda intacto"
}

test_perfil_cliente_detecta_intrusion() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente2 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente2/vendor"
  mkdir -p "$vendor"
  echo "x" > "$vendor/AGENTS.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no debería existir" "detecta la escritura en código ajeno"
  assert_exit 1 "la intrusión es error, no aviso" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_link_crea_punteros_con_el_import() {
  sandbox >/dev/null
  local docs; docs="$(new_project iota --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/iota/api"
  mkdir -p "$repo"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_file "$repo/AGENTS.md" "AGENTS.md generado"
  assert_file "$repo/CLAUDE.md" "CLAUDE.md generado"
  assert_contains "$(cat "$repo/CLAUDE.md")" "@../iota-docs/CLAUDE.md" "el import apunta al docs repo"
  assert_not_contains "$(cat "$repo/AGENTS.md")" "{{" "placeholders sustituidos"
}

test_link_es_idempotente() {
  sandbox >/dev/null
  local docs; docs="$(new_project kappa --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/kappa/api"
  mkdir -p "$repo"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  echo "contexto propio del repo" >> "$repo/AGENTS.md"
  local before; before="$(cat "$repo/AGENTS.md")"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_eq "$before" "$(cat "$repo/AGENTS.md")" "no pisa lo que el repo ya tenía"
}

test_link_avisa_si_falta_el_import() {
  sandbox >/dev/null
  local docs; docs="$(new_project lambda --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/lambda/api"
  mkdir -p "$repo"
  echo "# api" > "$repo/CLAUDE.md"

  local out; out="$(bash "$CRUX_HOME/bin/link.sh" "$docs" 2>&1)"
  assert_contains "$out" "no importan la doc transversal" "avisa del import ausente"
}

test_adopt_registra_un_docs_repo_existente() {
  sandbox >/dev/null
  local docs="$CRUX_PROJECTS_DIR/legado/legado-docs"
  mkdir -p "$docs/repos/servicio" "$docs/decisions" "$docs/operations" "$CRUX_PROJECTS_DIR/legado/servicio"
  : > "$docs/README.md"; : > "$docs/AGENTS.md"
  ln -s AGENTS.md "$docs/CLAUDE.md"
  : > "$docs/decisions/README.md"; : > "$docs/decisions/index.md"
  : > "$docs/repos/README.md"; : > "$docs/repos/servicio/README.md"

  bash "$CRUX_HOME/bin/adopt.sh" "$docs" >/dev/null 2>&1

  assert_file "$docs/crux.json" "escribe el contrato"
  local cfg; cfg="$(cat "$docs/crux.json")"
  assert_contains "$cfg" '"project": "legado"' "deduce el proyecto del nombre de la carpeta"
  assert_contains "$cfg" '"servicio"' "declara los repos que ya tenían doc"
  assert_contains "$cfg" '"operations"' "declara las secciones activas"
}

test_adopt_no_pisa_un_proyecto_ya_adoptado() {
  sandbox >/dev/null
  local docs; docs="$(new_project mu)"
  assert_exit 1 "se niega a re-adoptar" bash "$CRUX_HOME/bin/adopt.sh" "$docs"
}

test_upgrade_actualiza_la_version_declarada() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu)"
  node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    o.crux = "0.0.1";
    fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2));
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "el kernel es" "doctor avisa del desfase de versión"

  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1
  assert_contains "$(cat "$docs/crux.json")" "\"crux\": \"$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")\"" \
    "upgrade alinea la versión"
}

test_upgrade_repone_piezas_ausentes_sin_pisar_contenido() {
  sandbox >/dev/null
  local docs; docs="$(new_project xi)"
  echo "contenido propio del proyecto" > "$docs/README.md"
  rm "$docs/decisions/README.md"

  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" --force >/dev/null 2>&1 || true
  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1

  assert_file "$docs/decisions/README.md" "repone la pieza que faltaba"
}

test_json_get_devuelve_el_array_completo() {
  sandbox >/dev/null
  local f="$SB/x.json"
  echo '{"repos": ["uno", "dos", "tres"]}' > "$f"

  local count
  count="$(bash -c 'source "$1/lib/common.sh"; json_get "$2" repos' _ "$CRUX_HOME" "$f" | wc -l)"
  assert_eq "3" "$count" "no se pierde el último elemento del array"
}

test_las_skills_se_materializan_para_los_dos_agentes() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron)"
  mkdir -p "$docs/.claude/skills/project/hacer-algo"
  cat > "$docs/.claude/skills/project/hacer-algo/SKILL.md" <<'EOF'
---
name: hacer-algo
description: Procedimiento de prueba.
---
# hacer algo
EOF

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_symlink "$CLAUDE_SKILLS_DIR/hacer-algo" \
    "$docs/.claude/skills/project/hacer-algo" "Claude recibe el enlace a la skill"
  assert_file "$CODEX_PROMPTS_DIR/hacer-algo.md" "Codex recibe su stub"
  assert_contains "$(cat "$CODEX_PROMPTS_DIR/hacer-algo.md")" \
    "$docs/.claude/skills/project/hacer-algo/SKILL.md" "el stub apunta a la fuente, no la duplica"
}

test_ninguna_skill_del_kernel_nombra_herramientas_de_un_agente() {
  local hits
  hits="$(grep -rlriE '\b(claude code|codex|cursor)\b' "$CRUX_HOME/skills" 2>/dev/null | wc -l)"
  assert_eq "0" "$hits" "las skills del kernel no se atan a un agente concreto"
}

test_el_kernel_no_nombra_proyectos_concretos() {
  local hits
  hits="$(grep -rliE 'acme|demo-co|client|weather-app' \
    "$CRUX_HOME/skills" "$CRUX_HOME/templates" "$CRUX_HOME/profiles" \
    "$CRUX_HOME/bin" "$CRUX_HOME/lib" 2>/dev/null | wc -l)"
  assert_eq "0" "$hits" "el kernel está limpio de nombres de proyecto"
}

test_add_repo_registra_todo_de_una_vez() {
  sandbox >/dev/null
  local docs; docs="$(new_project pi --repos "api")"
  mkdir -p "$CRUX_PROJECTS_DIR/pi/worker"

  bash "$CRUX_HOME/bin/add-repo.sh" worker --description "Procesa la cola." "$docs" >/dev/null 2>&1

  assert_file "$docs/repos/worker/README.md" "crea la carpeta de documentación"
  assert_contains "$(cat "$docs/crux.json")" '"worker"' "declara el repo en el contrato"
  assert_contains "$(cat "$docs/repos/README.md")" "worker" "lo registra en el índice"
  assert_contains "$(cat "$docs/repos/worker/README.md")" "Procesa la cola." "usa la descripción dada"
  assert_file "$CRUX_PROJECTS_DIR/pi/worker/AGENTS.md" "genera los punteros del repo"
  assert_exit 0 "el proyecto sigue conforme" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_add_repo_rechaza_duplicados() {
  sandbox >/dev/null
  local docs; docs="$(new_project rho --repos "api")"
  assert_exit 1 "no re-declara un repo existente" \
    bash "$CRUX_HOME/bin/add-repo.sh" api "$docs"
}
