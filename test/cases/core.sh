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

# El repo ajeno puede traer su propio AGENTS.md, versionado por el cliente. No es
# una intrusión nuestra y el perfil prohíbe tocarlo: doctor no puede pedir que se
# borre lo que no hemos escrito.
test_perfil_cliente_respeta_el_agents_del_cliente() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente3 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente3/vendor"
  mkdir -p "$vendor"
  echo "# instrucciones del cliente" > "$vendor/AGENTS.md"
  git -C "$vendor" init -q
  git -C "$vendor" add AGENTS.md
  git -C "$vendor" -c user.email=t@t -c user.name=t commit -qm "docs: add agents"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "no debería existir" "el AGENTS.md del cliente no es intrusión"
  assert_contains "$out" "es del cliente" "lo reporta como respetado"
  assert_exit 0 "doctor pasa con el fichero del cliente" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# Pero un puntero nuestro sí lo es, aunque alguien lo haya commiteado en el repo
# ajeno: lo delata el bloque gestionado.
test_perfil_cliente_detecta_el_puntero_commiteado() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente4 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente4/vendor"
  mkdir -p "$vendor"
  printf '<!-- crux:begin -->\n@../cliente4-docs/AGENTS.md\n' > "$vendor/AGENTS.md"
  git -C "$vendor" init -q
  git -C "$vendor" add AGENTS.md
  git -C "$vendor" -c user.email=t@t -c user.name=t commit -qm "docs: add pointer"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no debería existir" "el bloque gestionado delata el puntero"
  assert_exit 1 "sigue siendo error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
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

test_link_no_pisa_un_puntero_anterior_al_bloque() {
  sandbox >/dev/null
  local docs; docs="$(new_project lambda --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/lambda/api"
  mkdir -p "$repo"
  printf '# api\n\nContexto propio escrito a mano.\n' > "$repo/CLAUDE.md"

  local out; out="$(bash "$CRUX_HOME/bin/link.sh" "$docs" 2>&1)"
  assert_contains "$out" "anteriores al bloque gestionado" "avisa en vez de pisar"
  assert_contains "$(cat "$repo/CLAUDE.md")" "Contexto propio escrito a mano" \
    "no toca el fichero sin que se lo pidan"

  bash "$CRUX_HOME/bin/link.sh" "$docs" --refresh >/dev/null 2>&1
  local ahora; ahora="$(cat "$repo/CLAUDE.md")"
  assert_contains "$ahora" "crux:begin" "con --refresh inserta el bloque"
  assert_contains "$ahora" "Contexto propio escrito a mano" "y conserva lo que había"
}

test_link_actualiza_el_bloque_sin_tocar_lo_de_alrededor() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/omega/api"
  mkdir -p "$repo"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  printf '\n## Notas del repo\n\nAlgo que solo importa aquí.\n' >> "$repo/CLAUDE.md"
  # Simula que el kernel cambió la plantilla
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("## Cómo se trabaja aquí", "## Cómo se trabajaba antes"));
  ' "$repo/CLAUDE.md"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  local ahora; ahora="$(cat "$repo/CLAUDE.md")"
  assert_contains "$ahora" "## Cómo se trabaja aquí" "el bloque vuelve a la plantilla"
  assert_contains "$ahora" "Algo que solo importa aquí" "lo de fuera del bloque sobrevive"
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

test_la_libreria_no_pisa_las_opciones_del_shell() {
  # Un `set -e` dentro de la librería mata en silencio a quien la carga con
  # otras opciones. Pasó dos veces: en la suite y en doctor.
  local out
  out="$(bash -c '
    set +e
    source "$1/lib/common.sh"
    false
    echo SOBREVIVE
  ' _ "$CRUX_HOME" 2>&1)"
  assert_contains "$out" "SOBREVIVE" "cargar la librería no activa set -e"

  assert_eq "0" "$(grep -c '^set -' "$CRUX_HOME/lib/common.sh")" \
    "la librería no fija opciones del shell"
}

test_doctor_detecta_adr_duplicados() {
  sandbox >/dev/null
  local docs; docs="$(new_project sigma)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: Primera
- **Status**: Accepted

### ADR-001: Otra sesión eligió el mismo número
- **Status**: Accepted
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "ADR duplicado" "detecta la colisión de numeración"
  assert_exit 1 "es error, no aviso" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_una_descripcion_que_no_activa() {
  sandbox >/dev/null
  local docs; docs="$(new_project tau)"
  mkdir -p "$docs/.claude/skills/project/muda"
  printf -- '---\nname: muda\ndescription: Ayuda con los despliegues del sistema.\n---\n\n# muda\n\nUsa esto cuando quieras.\n' \
    > "$docs/.claude/skills/project/muda/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no dice cuándo usarla" "detecta la descripción muda"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"

  # El "Usa esto" del cuerpo no debe contar: si se lee de más, esto no detecta nada.
  mkdir -p "$docs/.claude/skills/project/buena"
  printf -- '---\nname: buena\ndescription: Hace algo concreto. Usa cuando pase X.\n---\n\n# buena\n' \
    > "$docs/.claude/skills/project/buena/SKILL.md"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "'buena'" "no marca una descripción que sí dispara"
}

test_doctor_detecta_punteros_anteriores_al_bloque() {
  sandbox >/dev/null
  local docs; docs="$(new_project upsilon --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/upsilon/api"
  mkdir -p "$repo"
  printf '# api\n\nPuntero viejo.\n' > "$repo/CLAUDE.md"
  printf '# api\n\nPuntero viejo.\n' > "$repo/AGENTS.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "anterior al bloque gestionado" "avisa de los punteros desfasados"
}

test_la_descripcion_del_indice_llega_al_puntero_del_repo() {
  sandbox >/dev/null
  local docs; docs="$(new_project psi --repos "web,api")"
  mkdir -p "$CRUX_PROJECTS_DIR/psi/web" "$CRUX_PROJECTS_DIR/psi/api"

  assert_contains "$(cat "$docs/repos/README.md")" '`web/`' "init rellena la tabla del índice"

  # Editar el índice es lo que hace un humano; el puntero debe seguirlo.
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8")
      .replace("| `web/` | `psi/web` | Qué hace este repo, en una línea |",
               "| `web/` | `psi/web` | Front público en Next |"));
  ' "$docs/repos/README.md"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_contains "$(head -1 "$CRUX_PROJECTS_DIR/psi/web/CLAUDE.md")" "Front público en Next" \
    "el puntero recoge la descripción del índice"
  assert_not_contains "$(head -1 "$CRUX_PROJECTS_DIR/psi/api/CLAUDE.md")" "Front público" \
    "cada repo coge la suya, no la del vecino"
}

test_el_proyecto_nuevo_nace_sabiendo_que_existe_workspace() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron2)"
  local cfg; cfg="$(cat "$docs/crux.json")"
  assert_contains "$cfg" '"workspace"' "el contrato incluye la sección"
  assert_contains "$cfg" '"portBase"' "con los valores por defecto a la vista"
}

test_doctor_detecta_una_descripcion_en_otro_idioma() {
  sandbox >/dev/null
  local docs; docs="$(new_project chi)"
  mkdir -p "$docs/.claude/skills/project/mezclada"
  printf -- '---\nname: mezclada\ndescription: Purge the cache when the CDN is serving stale content after a deploy that changed the static assets.\n---\n\n# mezclada\n' \
    > "$docs/.claude/skills/project/mezclada/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "parece estar en inglés" "detecta la descripción en otro idioma"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_el_contrato_declara_el_idioma() {
  sandbox >/dev/null
  local docs; docs="$(new_project phi)"
  assert_contains "$(cat "$docs/crux.json")" '"language": "es"' "por defecto, español"

  local otro; otro="$(new_project phi2 --language en)"
  assert_contains "$(cat "$otro/crux.json")" '"language": "en"' "se puede declarar otro"
}

test_link_mantiene_el_catalogo_del_kernel_en_el_indice() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega2)"

  assert_contains "$(cat "$docs/AGENTS.md")" "crux:skills" "el índice nace con el hueco"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  local idx; idx="$(cat "$docs/AGENTS.md")"
  assert_contains "$idx" "\`end-session\`" "lo rellena con las skills del kernel"
  assert_contains "$idx" "\`ship\`" "con todas, no con una lista escrita a mano"

  # Regenerar no duplica: es lo que pasa cuando se sustituye mal el bloque.
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_eq "1" "$(grep -c '^<!-- crux:skills -->$' "$docs/AGENTS.md")" "el marcador de apertura sigue siendo único"
}

test_clone_no_adivina_de_donde_traer_las_cosas() {
  sandbox >/dev/null
  # Sin plantilla ni valor por defecto, se planta en vez de asumir un proveedor.
  local out
  out="$(HOME="$SB/home-sin-config" bash "$CRUX_HOME/bin/clone.sh" x --parent "$SB/vacio" 2>&1)"
  assert_contains "$out" "no sé de dónde traer" "sin remoto no inventa una URL"

  # Con docs repo presente pero sin contrato, tampoco sabe qué más clonar.
  local conDocs="$SB/con-docs"
  mkdir -p "$conDocs/x/x-docs"; git init -q "$conDocs/x/x-docs"
  out="$(bash "$CRUX_HOME/bin/clone.sh" x --parent "$conDocs" 2>&1)"
  assert_contains "$out" "sin crux.json" "sin contrato no sabe qué repos trae el proyecto"
}

test_el_remoto_admite_override_por_repo() {
  sandbox >/dev/null
  local cfg="$SB/crux.json"
  cat > "$cfg" <<'JSON'
{"remote":{"url":"git@github.com:mio/{repo}.git",
           "repos":{"ajeno":"https://otro-host.com/equipo/ajeno.git"}}}
JSON

  local propio ajeno
  propio="$(bash -c 'source "$1/lib/common.sh"; remote_url "$2" propio' _ "$CRUX_HOME" "$cfg")"
  ajeno="$(bash -c 'source "$1/lib/common.sh"; remote_url "$2" ajeno' _ "$CRUX_HOME" "$cfg")"

  assert_eq "git@github.com:mio/propio.git" "$propio" "lo tuyo sale de la plantilla"
  assert_eq "https://otro-host.com/equipo/ajeno.git" "$ajeno" "lo ajeno, de su override"
}

test_el_remoto_se_compone_tambien_con_el_atajo() {
  sandbox >/dev/null
  local cfg="$SB/atajo.json"
  printf '{"remote":{"host":"gitlab.empresa.com","owner":"equipo/sub","protocol":"ssh"}}\n' > "$cfg"
  local url
  url="$(bash -c 'source "$1/lib/common.sh"; remote_url "$2" api' _ "$CRUX_HOME" "$cfg")"
  assert_eq "git@gitlab.empresa.com:equipo/sub/api.git" "$url" "el atajo compone la URL"
}

test_la_deduccion_no_se_confunde_con_nombres_repetidos() {
  sandbox >/dev/null
  local repo="$SB/demo"
  mkdir -p "$repo"; git init -q "$repo"
  # El propietario se llama igual que el repo: sustituir todas las apariciones
  # produciría "git@host:{repo}/{repo}.git", que no sirve para ningún otro repo.
  git -C "$repo" remote add origin "git@host.com:demo/demo.git"

  local tmpl
  tmpl="$(bash -c 'source "$1/lib/common.sh"; remote_desde_git "$2"' _ "$CRUX_HOME" "$repo")"
  assert_eq "git@host.com:demo/{repo}.git" "$tmpl" "solo sustituye la última aparición"
}

test_doctor_avisa_si_el_remoto_declarado_no_es_el_real() {
  sandbox >/dev/null
  local docs; docs="$(new_project rho2 --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/rho2/api"
  mkdir -p "$repo"; git init -q "$repo"
  git -C "$repo" remote add origin "git@donde-sea.com:otro/api.git"

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8"));
    o.remote = { url: "git@github.com:mio/{repo}.git" };
    fs.writeFileSync(f, JSON.stringify(o, null, 2));
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "el contrato dice" "detecta la divergencia entre contrato y origin"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_init_no_asume_donde_subir_el_repo() {
  sandbox >/dev/null
  local out
  out="$(HOME="$SB/limpio" bash "$CRUX_HOME/bin/init.sh" sigma2 --parent "$CRUX_PROJECTS_DIR" 2>&1)"
  assert_contains "$out" "no sé dónde subir" "sin --remote no elige proveedor por ti"

  # Con un remoto que no es GitHub: deja el repo listo y dice qué falta.
  out="$(HOME="$SB/limpio" bash "$CRUX_HOME/bin/init.sh" sigma3 --parent "$CRUX_PROJECTS_DIR" \
    --remote 'git@gitlab.empresa.com:equipo/{repo}.git' 2>&1)"
  assert_contains "$out" "no existe todavía" "avisa de que hay que crearlo en el proveedor"

  local docs="$CRUX_PROJECTS_DIR/sigma3/sigma3-docs"
  assert_eq "git@gitlab.empresa.com:equipo/sigma3-docs.git" \
    "$(git -C "$docs" remote get-url origin)" "y deja el origin configurado"
  assert_contains "$(cat "$docs/crux.json")" "gitlab.empresa.com" "el contrato declara el remoto"
}

test_init_deja_la_visibilidad_dicha_cuando_no_la_puede_aplicar() {
  sandbox >/dev/null
  local out
  out="$(HOME="$SB/limpio2" bash "$CRUX_HOME/bin/init.sh" tau2 --parent "$CRUX_PROJECTS_DIR" \
    --remote 'git@gitlab.empresa.com:equipo/{repo}.git' --visibility private 2>&1)"

  # Fuera de GitHub el repo lo crea una persona: si crux no lo dice, se crea
  # público sin querer y con documentación interna dentro.
  assert_contains "$out" "como **private**" "dice con qué visibilidad crearlo"
  assert_contains "$out" "no la puede aplicar crux" "y avisa de que no la controla"

  assert_contains "$(cat "$CRUX_PROJECTS_DIR/tau2/tau2-docs/crux.json")" '"visibility": "private"' \
    "el contrato guarda la visibilidad prevista, para poder verificarla luego"
}

test_el_kernel_documenta_su_propio_contexto() {
  assert_file "$CRUX_HOME/AGENTS.md" "el kernel tiene contexto para quien venga a tocarlo"
  assert_symlink "$CRUX_HOME/CLAUDE.md" "AGENTS.md" "y un solo fichero, no dos que divergen"

  # AGENTS.md cita por nombre los tests que vigilan sus reglas duras. Si alguien
  # renombra uno, la documentación pasa a mentir sin que nadie se entere.
  local citados faltan=0
  citados="$(grep -oE 'test_[a-z_]+' "$CRUX_HOME/AGENTS.md" | sort -u)"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    grep -rq "^$t()" "$CRUX_HOME/test/cases/" || { faltan=$((faltan + 1)); echo "      falta: $t"; }
  done <<< "$citados"
  assert_eq "0" "$faltan" "los tests que cita AGENTS.md existen"
}

test_link_no_pelea_con_el_formateador_del_repo() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu2 --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/nu2/api"
  mkdir -p "$repo"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  # Simula lo que hace un formateador: alinear las columnas de las tablas.
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8")
      .replace(/\| Momento \| Qué invocar \|/, "| Momento                     | Qué invocar |"));
  ' "$repo/CLAUDE.md"
  local formateado; formateado="$(cat "$repo/CLAUDE.md")"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_eq "$formateado" "$(cat "$repo/CLAUDE.md")" \
    "no revierte el formateo: si no, link y el formateador se pelean sin fin"
}

test_la_raiz_de_proyectos_no_se_asume() {
  sandbox >/dev/null
  # Un kernel instalado en una ruta que no es ~/Proyectos: su padre es la raíz.
  local raiz="$SB/dev"
  mkdir -p "$raiz/crux"
  cp -r "$CRUX_HOME/lib" "$CRUX_HOME/VERSION" "$raiz/crux/"

  local deducida
  deducida="$(env -u CRUX_PROJECTS_DIR CRUX_HOME="$raiz/crux" HOME="$SB/vacio" \
    bash -c 'source "$1/lib/common.sh"; projects_root' _ "$raiz/crux")"
  assert_eq "$raiz" "$deducida" "la raíz sale del sitio donde vive el kernel"

  # Lo declarado gana sobre lo deducido.
  mkdir -p "$SB/otro/.crux"
  printf 'CRUX_PROJECTS_DIR="/donde/sea"\n' > "$SB/otro/.crux/config"
  deducida="$(env -u CRUX_PROJECTS_DIR CRUX_HOME="$raiz/crux" HOME="$SB/otro" \
    bash -c 'source "$1/lib/common.sh"; projects_root' _ "$raiz/crux")"
  assert_eq "/donde/sea" "$deducida" "lo declarado en la config manda"
}

test_el_hook_de_deriva_funciona_fuera_de_la_ruta_habitual() {
  sandbox >/dev/null
  local raiz="$SB/workspace"
  local repo="$raiz/proj/api"
  mkdir -p "$repo/src" "$raiz/proj/proj-docs/repos/api"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'export const x = 1\n' > "$repo/src/util.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  # La documentación menciona el fichero, y el fichero se modifica sin commitear.
  printf 'El helper vive en `src/util.ts`.\n' > "$raiz/proj/proj-docs/repos/api/README.md"
  printf 'export const x = 2\n' > "$repo/src/util.ts"

  local out
  out="$(cd "$repo" && CRUX_PROJECTS_DIR="$raiz" bash "$CRUX_HOME/adapters/claude/hooks/doc-sync.sh" 2>&1)"
  assert_contains "$out" "sync discipline" "avisa aunque la raíz no sea la habitual"
  assert_contains "$out" "src/util.ts" "y dice qué fichero lo provoca"
}

test_las_herramientas_de_inventario_respetan_la_raiz() {
  sandbox >/dev/null
  local raiz="$SB/mis-cosas"
  mkdir -p "$raiz/uno/uno-docs/.claude/skills/project/algo"
  printf '{"crux":"0.1.0","project":"uno","profile":"multi-repo","repos":[],"sections":[]}\n' \
    > "$raiz/uno/uno-docs/crux.json"
  printf -- '---\nname: algo\ndescription: Hace algo. Usa cuando toque.\n---\n# algo\n' \
    > "$raiz/uno/uno-docs/.claude/skills/project/algo/SKILL.md"

  local out
  out="$(CRUX_PROJECTS_DIR="$raiz" node "$CRUX_HOME/skills/skill-audit/scripts/audit.mjs" 2>&1)"
  assert_contains "$out" "1 proyectos" "encuentra el proyecto fuera de la ruta habitual"
}

test_cada_comando_esta_documentado() {
  # Añadir un comando y olvidar documentarlo ya pasó con `clone`, y no lo vio
  # nadie hasta que se buscó a mano.
  local faltan=0
  for f in "$CRUX_HOME"/bin/*.sh; do
    local cmd; cmd="$(basename "$f" .sh)"
    # Los que no son subcomandos del despachador
    case "$cmd" in machine|release) continue ;; esac

    grep -q "  $cmd)" "$CRUX_HOME/bin/crux" || { echo "      $cmd no está en el despachador"; faltan=$((faltan+1)); }
    grep -q "crux $cmd" "$CRUX_HOME/bin/crux" || { echo "      $cmd no está en la ayuda"; faltan=$((faltan+1)); }
    grep -q "crux $cmd" "$CRUX_HOME/README.md" || { echo "      $cmd no está en el README"; faltan=$((faltan+1)); }
    grep -q "crux $cmd" "$CRUX_HOME/STANDARD.md" || { echo "      $cmd no está en STANDARD.md"; faltan=$((faltan+1)); }
  done
  assert_eq "0" "$faltan" "todos los comandos están en el despachador, la ayuda, el README y el estándar"
}

test_cada_skill_del_kernel_esta_en_el_catalogo() {
  local faltan=0
  for d in "$CRUX_HOME"/skills/*/; do
    local n; n="$(basename "$d")"
    grep -q "\`$n\`" "$CRUX_HOME/STANDARD.md" || { echo "      $n no aparece en el catálogo"; faltan=$((faltan+1)); }
  done
  assert_eq "0" "$faltan" "el catálogo del estándar cubre todas las skills del kernel"
}

test_release_exige_que_la_version_venga_por_propuesta() {
  sandbox >/dev/null
  local out

  out="$(bash "$CRUX_HOME/bin/release.sh" uno.dos 2>&1)"
  assert_contains "$out" "debe ser semver" "exige semver"

  # El número de versión se sube en VERSION por propuesta; el release solo
  # etiqueta. Si VERSION no coincide, falta esa propuesta.
  out="$(bash "$CRUX_HOME/bin/release.sh" 99.0.0 2>&1)"
  assert_contains "$out" "súbelo a 99.0.0 por propuesta" "no commitea la versión por su cuenta"
}

test_release_verifica_a_quien_consume_el_kernel() {
  sandbox >/dev/null
  # Un consumidor que ha dejado de cumplir el estándar: el release tiene que
  # detenerse, que es lo que lo distingue de un `git tag`.
  local raiz="$SB/consumidores"
  local docs="$raiz/roto/roto-docs"
  mkdir -p "$docs"
  printf '{"crux":"0.1.0","project":"roto","profile":"multi-repo","repos":["falta"],"sections":[]}\n' \
    > "$docs/crux.json"

  local out
  out="$(CRUX_PROJECTS_DIR="$raiz" bash "$CRUX_HOME/bin/release.sh" 99.0.0 2>&1)"
  assert_contains "$out" "deja de cumplir el estándar" "detecta al consumidor roto"
  assert_contains "$out" "no se publica" "y se detiene"
  assert_exit 1 "sale con error" \
    env CRUX_PROJECTS_DIR="$raiz" bash "$CRUX_HOME/bin/release.sh" 99.0.0
}

test_el_kernel_no_referencia_skills_que_no_existen() {
  # Una skill anunciada y ausente no falla: se invoca, no pasa nada y el
  # procedimiento se da por hecho. Ese silencio es el problema.
  local rotas=""
  local ref
  while IFS= read -r ref; do
    [[ -d "$CRUX_HOME/skills/$ref" ]] || rotas+="$ref "
  done < <(grep -rhoE '`/[a-z][a-z0-9-]+`' \
             "$CRUX_HOME/skills" "$CRUX_HOME"/*.md 2>/dev/null \
           | tr -d '`/' | sort -u)

  assert_eq "" "$rotas" "toda skill referenciada en el kernel existe"
}

test_el_hook_rechaza_un_mensaje_de_commit_en_espanol() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/git/commit-msg.sh"
  local f="$SB/MSG"

  # Del historial real de este repo, escrito antes de que nadie comprobase nada.
  echo "fix(workspace): el titulo de la propuesta sale del primer commit" > "$f"
  assert_exit 1 "rechaza un mensaje en español" bash "$hook" "$f"

  echo "fix(workspace): take the proposal title from the first commit" > "$f"
  assert_exit 0 "deja pasar el mismo mensaje en inglés" bash "$hook" "$f"

  # Una sola pista no basta: un nombre propio no convierte el mensaje en
  # español, y un hook que se equivoca se desactiva a la semana.
  echo "feat(stations): add Los Angeles network ids" > "$f"
  assert_exit 0 "un nombre propio español no dispara el rechazo" bash "$hook" "$f"
  echo "fix(tz): correct Los Angeles offset" > "$f"
  assert_exit 0 "ni un topónimo con artículo" bash "$hook" "$f"

  # Lo que va en backticks es código, no idioma.
  printf 'refactor: rename `esta_lista` and `el_valor` helpers\n' > "$f"
  assert_exit 0 "los identificadores en backticks no cuentan" bash "$hook" "$f"

  # Las líneas de comentario son de git.
  printf 'chore: bump deps\n\n# Por favor escribe el mensaje para tu commit\n' > "$f"
  assert_exit 0 "los comentarios de git tampoco" bash "$hook" "$f"

  echo "feat: la puerta se gradua segun lo que toca el diff" > "$f"
  local out; out="$(bash "$hook" "$f" 2>&1)"
  assert_contains "$out" "no-verify" "y dice cómo saltarlo cuando de verdad haga falta"
  assert_contains "$out" "pistas:" "y enseña por qué lo ha rechazado"
}

# Escribía la carpeta fuera del docs repo y doctor daba el contrato por bueno.
test_add_repo_rechaza_un_nombre_que_escapa_de_la_carpeta() {
  sandbox >/dev/null
  local docs; docs="$(new_project traversal --repos "api")"

  for malo in "../fuera" "../../lejos" "con espacio" "sub/dir" ".oculto" "/abs"; do
    assert_exit 1 "rechaza '$malo'" bash "$CRUX_HOME/bin/add-repo.sh" "$malo" "$docs"
  done

  assert_no_file "$(dirname "$docs")/fuera" "no crea nada fuera del docs repo"
  assert_eq "api" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).repos.join(","))' "$docs/crux.json")" \
    "el contrato queda intacto"

  assert_exit 0 "y sigue aceptando un nombre válido" \
    bash "$CRUX_HOME/bin/add-repo.sh" "web-front" --description "x" "$docs"
  # Hay repos reales en CamelCase: la validación va contra el daño, no el estilo.
  assert_exit 0 "acepta CamelCase" \
    bash "$CRUX_HOME/bin/add-repo.sh" "MiApp" --description "x" "$docs"
}

test_add_repo_escapa_las_barras_de_la_descripcion() {
  sandbox >/dev/null
  local docs; docs="$(new_project barras)"
  bash "$CRUX_HOME/bin/add-repo.sh" web --description "front | back" "$docs" >/dev/null 2>&1

  local fila; fila="$(grep '^| `web/`' "$docs/repos/README.md")"
  assert_contains "$fila" '\|' "la barra va escapada"
  local columnas; columnas="$(sed 's/\\|//g' <<< "$fila" | awk -F'|' '{print NF-2}')"
  assert_eq "3" "$columnas" "la fila conserva tres columnas"
}

# "${declared[@]:-}" con el array vacío expande a un elemento vacío.
test_doctor_no_inventa_un_repo_cuando_no_hay_ninguno() {
  sandbox >/dev/null
  local docs; docs="$(new_project sinrepos)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.repos = [];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "/ sin AGENTS.md" "no avisa por un repo que no existe"
  assert_contains "$out" "repos: 0 declarados" "y cuenta cero"
  assert_exit 0 "sin errores" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# La máquina con el kernel viejo degradaba el contrato del proyecto sin avisar.
test_upgrade_no_degrada_el_contrato_de_un_proyecto_mas_nuevo() {
  sandbox >/dev/null
  local docs; docs="$(new_project adelantado)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = "99.0.0";
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/upgrade.sh" "$docs" 2>&1)"
  assert_contains "$out" "actualiza el kernel" "dice qué hacer en vez de degradar"
  assert_exit 1 "y no lo da por bueno" bash "$CRUX_HOME/bin/upgrade.sh" "$docs"
  assert_eq "99.0.0" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).crux)' "$docs/crux.json")" \
    "el contrato no se toca"

  local aviso; aviso="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$aviso" "por delante del kernel" "y doctor no empuja al downgrade"
}

# Un dry-run que sale con error rompe cualquier uso encadenado o en CI.
test_upgrade_en_dry_run_no_reporta_fallo() {
  sandbox >/dev/null
  local docs; docs="$(new_project seco)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = "0.0.1";
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"

  assert_exit 0 "dry-run con trabajo pendiente sale limpio" \
    bash "$CRUX_HOME/bin/upgrade.sh" "$docs" --dry-run
  assert_eq "0.0.1" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).crux)' "$docs/crux.json")" \
    "y no escribe nada"
}

# Una plantilla sin bloque gestionado se reportaba como escrita sin tocar nada.
test_render_managed_distingue_la_plantilla_sin_bloque() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local dir="$SB/rm"; mkdir -p "$dir"
  printf 'plantilla sin bloque\n' > "$dir/tpl.md"
  printf '<!-- crux:begin -->\nviejo\n<!-- crux:end -->\n' > "$dir/dst.md"

  local rc=0
  render_managed "$dir/tpl.md" "$dir/dst.md" || rc=$?
  assert_eq "4" "$rc" "devuelve su propio código, no el de actualizado"
  assert_contains "$(cat "$dir/dst.md")" "viejo" "y el destino queda intacto"
}

# Sin repo no se puede afirmar que el remoto coincida con el contrato.
test_doctor_detecta_un_docs_repo_fuera_de_git() {
  sandbox >/dev/null
  local docs; docs="$(new_project singit)"
  rm -rf "$docs/.git"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no está en git" "lo reporta"
  assert_not_contains "$out" "remoto coherente con el contrato" "y no afirma lo que no puede saber"
  assert_exit 1 "es error, no aviso" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# Un contrato sin campo 'crux' deja "?", y sort -V lo ponía por encima de todo.
test_la_comparacion_de_versiones_ignora_lo_que_no_es_semver() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"

  assert_exit 1 "'?' no es mayor que una versión" version_mayor_que "?" "0.6.0"
  assert_exit 1 "ni 'unknown'" version_mayor_que "unknown" "0.6.0"
  assert_exit 0 "0.10.0 sí es mayor que 0.9.0" version_mayor_que "0.10.0" "0.9.0"
  assert_exit 1 "y 0.9.0 no lo es de 0.10.0" version_mayor_que "0.9.0" "0.10.0"
}

# Sin cierre, el frontmatter no es YAML válido y la skill no se activa.
test_doctor_detecta_el_frontmatter_sin_cerrar() {
  sandbox >/dev/null
  local docs; docs="$(new_project frontmatter)"
  mkdir -p "$docs/.claude/skills/project/rota"
  printf -- '---\nname: rota\ndescription: usa cuando pase algo\n\n# cuerpo\n' \
    > "$docs/.claude/skills/project/rota/SKILL.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "frontmatter sin cerrar" "lo detecta"
  assert_exit 1 "y es error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# clone terminaba en un condicional, así que salía con 1 tras haber ido bien.
test_los_comandos_no_terminan_en_un_condicional() {
  sandbox >/dev/null
  local malos=""
  for f in "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/lib/*.sh "$CRUX_HOME/install.sh"; do
    local ultima; ultima="$(grep -vE '^\s*(#|$)' "$f" | tail -1)"
    [[ "$ultima" == *"]]"*"&&"* || "$ultima" == *"]"*"&&"* ]] && malos+=" $(basename "$f")"
  done
  assert_eq "" "$malos" "ningún comando deja el código de salida en manos de su última condición"
}

# El mismo escape que en add-repo, por la puerta de init.
test_init_rechaza_un_repo_que_escapa_de_la_carpeta() {
  sandbox >/dev/null
  assert_exit 1 "rechaza el repo con ruta" \
    bash "$CRUX_HOME/bin/init.sh" fuga --no-remote --parent "$CRUX_PROJECTS_DIR" --repos "../../ESCAPE,ok"
  assert_no_file "$CRUX_PROJECTS_DIR/ESCAPE" "no crea nada fuera"
  assert_no_file "$CRUX_PROJECTS_DIR/fuga/ESCAPE" "tampoco dentro del proyecto"
}

# Instalar desde un worktree dejaba ~/.claude/skills apuntando a un directorio
# que desaparece al cerrarlo, y con él todas las skills de la máquina.
test_se_distingue_un_worktree_de_su_repo_principal() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local repo="$SB/repo"
  mkdir -p "$repo" && git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$repo" worktree add -q --detach "$SB/wt" >/dev/null 2>&1

  assert_exit 1 "el repo principal no es un worktree" es_worktree "$repo"
  assert_exit 0 "el worktree sí lo es" es_worktree "$SB/wt"
  assert_eq "$repo" "$(repo_principal "$SB/wt")" "y sabe de quién cuelga"

  assert_contains "$(cat "$CRUX_HOME/install.sh")" "es_worktree" "install.sh lo comprueba antes de tocar nada"
}

# El ciclo se rompe en silencio si el paso existe en la skill pero el comando
# que abre la propuesta no lo menciona: nadie lo invoca.
test_el_ciclo_lleva_a_revisar_la_propuesta() {
  sandbox >/dev/null
  local skill="$CRUX_HOME/skills/review-pr/SKILL.md"
  assert_file "$skill" "la skill existe"
  assert_contains "$(head -1 "$skill")" "---" "con frontmatter"
  assert_contains "$(cat "$skill")" "name: review-pr" "y su nombre"

  assert_contains "$(cat "$CRUX_HOME/skills/flow/SKILL.md")" "/review-pr" "el ciclo la encadena"
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "/review-pr" "y finish la recuerda"
}
