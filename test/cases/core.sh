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

# La parte auditable de §7: si el código se movió después que la documentación,
# doctor lo dice. Es lo que permite ver a posteriori si la puerta se saltó.
test_doctor_mide_la_deriva_entre_codigo_y_documentacion() {
  sandbox >/dev/null
  local docs; docs="$(new_project deriva --repos "api")"
  local repo; repo="$(dirname "$docs")/api"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'x\n' > "$repo/a.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "posterior a la doc"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "deriva código ↔ doc" "avisa de la deriva"
  assert_contains "$out" "api" "y dice en qué repo"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# El negativo: sin repos de código que se hayan movido, no inventa deriva.
test_doctor_no_inventa_deriva_cuando_no_la_hay() {
  sandbox >/dev/null
  local docs; docs="$(new_project sindeeriva)"
  git -C "$docs" add -A
  # Sin `|| true`: un commit que no se puede hacer se dice, no se disimula.
  git -C "$docs" commit -qm "documentación al día" >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "documentación al día con el código" "lo dice en positivo"
  assert_not_contains "$out" "deriva código ↔ doc" "y no levanta aviso"
}

test_doctor_detecta_carpeta_no_declarada() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon --repos "api")"
  mkdir -p "$docs/repos/fantasma"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no está declarado en crux.json" "detecta la carpeta huérfana"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# Clonar un repo en el proyecto y olvidar registrarlo es el caso real: las demás
# comprobaciones van de lo declarado a lo que hay en disco, así que este pasaba
# como conforme.
# upgrade, link y add-repo ya paraban con el motivo del parser. El que
# diagnostica era el único que seguía, inventando errores sobre lo que sí está.
test_doctor_dice_cuando_el_contrato_no_es_json_valido() {
  sandbox >/dev/null
  local docs; docs="$(new_project rota --repos "api")"
  printf '{ "crux": "0.15.0", "project": ' > "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no es JSON válido" "dice qué pasa de verdad"
  assert_not_contains "$out" "sin campo obligatorio" "y no acusa a campos que sí están"
  assert_not_contains "$out" "no está declarado" "ni inventa repos sin declarar"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_un_repo_en_disco_sin_declarar() {
  sandbox >/dev/null
  local docs; docs="$(new_project omega --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/web"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "web/ está en disco y no está declarado" "lo detecta"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

# Un espacio de trabajo es un worktree hermano del repo: avisar de él convertiría
# la comprobación en ruido cada vez que se abre uno.
test_doctor_no_confunde_un_espacio_de_trabajo_con_un_repo_sin_declarar() {
  sandbox >/dev/null
  local docs; docs="$(new_project sigma --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/api"
  ( cd "$root/api" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  git -C "$root/api" worktree add -q --detach "$root/api-ws-tarea" 2>/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "api-ws-tarea/ está en disco" "no avisa del worktree"

  git -C "$root/api" worktree remove --force "$root/api-ws-tarea" 2>/dev/null
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
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

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

# Sin nada que el agente cargue solo, trabajar en el repo del cliente no lleva al
# docs repo. El puntero local lo resuelve sin versionar nada en su repositorio.
nuevo_repo_de_cliente() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  echo x > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "chore: init"
}

test_perfil_cliente_escribe_el_puntero_local_fuera_de_git() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente5 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente5/vendor"
  nuevo_repo_de_cliente "$vendor"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_file "$vendor/CLAUDE.local.md" "link escribe el puntero local"
  assert_contains "$(cat "$vendor/CLAUDE.local.md")" "@../cliente5-docs/CLAUDE.md" "el import apunta al docs repo"
  assert_eq "" "$(git -C "$vendor" status --porcelain)" "no aparece en git status"
  assert_no_file "$vendor/AGENTS.md" "y sigue sin escribir punteros versionados"
  assert_no_file "$vendor/CLAUDE.md" "ni CLAUDE.md"
  assert_eq "" "$(tail -c1 "$vendor/CLAUDE.local.md")" "termina en salto de línea"
  local larga; larga="$(awk 'length > 80' "$vendor/CLAUDE.local.md")"
  assert_eq "" "$larga" "ninguna línea pasa de 80, que ningún formateador la reparte"
}

test_perfil_cliente_doctor_exige_el_puntero_local() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente6 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente6/vendor"
  nuevo_repo_de_cliente "$vendor"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "sin CLAUDE.local.md" "detecta que falta el puntero local"
  assert_exit 1 "y es error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  assert_exit 0 "con el puntero escrito doctor pasa" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_perfil_cliente_doctor_detecta_el_puntero_sin_excluir() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente7 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente7/vendor"
  nuevo_repo_de_cliente "$vendor"
  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  sed -i '/CLAUDE.local.md/d' "$vendor/.git/info/exclude"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "no está excluido de git" "detecta que se podría commitear"
  assert_exit 1 "y es error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_perfil_cliente_respeta_su_propio_claude_local() {
  sandbox >/dev/null
  local docs; docs="$(new_project cliente8 --repos "vendor" --profile client-repo)"
  local vendor="$CRUX_PROJECTS_DIR/cliente8/vendor"
  nuevo_repo_de_cliente "$vendor"
  echo "# del cliente" > "$vendor/CLAUDE.local.md"
  git -C "$vendor" add CLAUDE.local.md
  git -C "$vendor" -c user.email=t@t -c user.name=t commit -qm "docs: add local"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1

  assert_eq "# del cliente" "$(cat "$vendor/CLAUDE.local.md")" "no pisa el fichero versionado del cliente"
  assert_exit 0 "y doctor lo respeta" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
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

# El caso de arriba monta la estructura entera a mano, así que nunca veía lo que
# se encuentra quien adopta un proyecto anterior al kernel: una lista de errores.
test_adopt_dice_como_reponer_lo_que_falta() {
  sandbox >/dev/null
  local docs="$CRUX_PROJECTS_DIR/pelado/pelado-docs"
  mkdir -p "$docs"

  local out; out="$(bash "$CRUX_HOME/bin/adopt.sh" "$docs" 2>&1)"
  assert_contains "$out" "falta AGENTS.md" "el doctor dice qué falta"
  assert_contains "$out" "crux upgrade" "y adopt dice con qué reponerlo"
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
  # Solo el markdown: la regla es que el PROCEDIMIENTO no se ate a un agente.
  # Los scripts quedan fuera porque "cursor" es tambien una propiedad CSS, y un
  # script que lee getComputedStyle().cursor no esta nombrando a ningun editor.
  hits="$(grep -rliE '\b(claude code|codex|cursor)\b' \
    --include='*.md' "$CRUX_HOME/skills" 2>/dev/null | wc -l)"
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

test_add_repo_toma_el_remoto_del_origin() {
  sandbox >/dev/null
  local docs; docs="$(new_project tau --repos "api")"
  local repo="$CRUX_PROJECTS_DIR/tau/worker"
  git init -q "$repo"
  git -C "$repo" remote add origin "git@example.com:otra-cuenta/worker.git"

  bash "$CRUX_HOME/bin/add-repo.sh" worker "$docs" >/dev/null 2>&1

  # Sin esto, clone no sabría de dónde traer el repo recién añadido.
  assert_contains "$(cat "$docs/crux.json")" "otra-cuenta/worker.git" "apunta el remoto que ya tiene"
  assert_eq "git@example.com:otra-cuenta/worker.git" \
    "$(source "$CRUX_HOME/lib/common.sh"; remote_url "$docs/crux.json" worker)" \
    "y clone lo sabe componer"
}

test_add_repo_rechaza_duplicados() {
  sandbox >/dev/null
  local docs; docs="$(new_project rho --repos "api")"
  assert_exit 1 "no re-declara un repo existente" \
    bash "$CRUX_HOME/bin/add-repo.sh" api "$docs"
}

test_ningun_comando_disimula_un_fichero_que_no_puede_leer() {
  # Silenciar la lectura de un fichero que tiene que estar convierte su ausencia
  # en un valor vacío, y el vacío se reporta después como otra cosa: campos que
  # faltan, listas sin elementos, un consumidor que no existe.
  local hallazgos="" f
  for f in "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/lib/*.sh "$CRUX_HOME/install.sh" \
           "$CRUX_HOME"/adapters/*/*.sh; do
    [[ -f "$f" ]] || continue
    # Redirección de entrada o cat sobre una ruta, con el error tapado. La
    # redirección la resuelve el shell antes del comando, así que el 2>/dev/null
    # del comando ni siquiera la cubre: el error sale igual por pantalla.
    local sospechas
    sospechas="$(grep -nE '(<|cat) +"?\$[A-Za-z_{][^|;]*" *2>/dev/null' "$f" || true)"
    [[ -n "$sospechas" ]] && hallazgos="$hallazgos $(basename "$f")"
  done
  assert_eq "" "$hallazgos" "ningún comando lee un fichero tapando el error"
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
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["api"],"sections":[]}\n' \
    > "$raiz/proj/proj-docs/crux.json"
  # La documentación menciona el fichero, y el fichero se modifica sin commitear.
  printf 'El helper vive en `src/util.ts`.\n' > "$raiz/proj/proj-docs/repos/api/README.md"
  printf 'export const x = 2\n' > "$repo/src/util.ts"

  local out
  out="$(cd "$repo" && echo '{"session_id":"raro"}' | env HOME="$SB/hogar" CRUX_PROJECTS_DIR="$raiz" \
    bash "$CRUX_HOME/adapters/claude/hooks/doc-sync.sh" 2>&1)"
  assert_contains "$out" "PUERTA DE DOCUMENTACIÓN" "avisa aunque la raíz no sea la habitual"
  assert_contains "$out" "src/util.ts" "y dice qué fichero lo provoca"
}

# La puerta sirve si para el cierre. Un aviso que se imprime y deja cerrar es
# lo que ya había, y es lo que falló.
test_la_puerta_de_documentacion_bloquea_el_cierre_una_vez() {
  sandbox >/dev/null
  local raiz="$SB/workspace"
  local repo="$raiz/proj/api"
  mkdir -p "$repo" "$raiz/proj/proj-docs/repos/api"
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["api"],"sections":[]}\n' \
    > "$raiz/proj/proj-docs/crux.json"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'x\n' > "$repo/a.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf 'y\n' > "$repo/a.txt"

  local hook="$CRUX_HOME/adapters/claude/hooks/doc-sync.sh"

  assert_exit 2 "bloquea el cierre cuando la sesión movió cosas" \
    bash -c "cd '$repo' && echo '{\"session_id\":\"s1\"}' | env HOME='$SB/hogar' CRUX_PROJECTS_DIR='$raiz' bash '$hook' >/dev/null 2>&1"

  # Segunda pasada de la misma sesión: ya se preguntó, deja cerrar.
  assert_exit 0 "no vuelve a bloquear en la misma sesión" \
    bash -c "cd '$repo' && echo '{\"session_id\":\"s1\"}' | env HOME='$SB/hogar' CRUX_PROJECTS_DIR='$raiz' bash '$hook' >/dev/null 2>&1"

  # Y nunca bloquea el turno que ya viene de un Stop bloqueado: eso es un bucle.
  assert_exit 0 "no se encadena consigo mismo" \
    bash -c "cd '$repo' && echo '{\"session_id\":\"s2\",\"stop_hook_active\":true}' | env HOME='$SB/hogar2' CRUX_PROJECTS_DIR='$raiz' bash '$hook' >/dev/null 2>&1"
}

# Y el negativo: en un proyecto donde no se ha movido nada, callar. Preguntar
# en sesiones vacías es la forma más rápida de que alguien lo desinstale.
test_la_puerta_de_documentacion_calla_si_no_se_movio_nada() {
  sandbox >/dev/null
  local raiz="$SB/workspace"
  local repo="$raiz/proj/api"
  mkdir -p "$repo" "$raiz/proj/proj-docs/repos/api"
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["api"],"sections":[]}\n' \
    > "$raiz/proj/proj-docs/crux.json"

  local viejo="2020-01-01T00:00:00"
  local d
  for d in "$repo" "$raiz/proj/proj-docs"; do
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'x\n' > "$d/a.txt"
    git -C "$d" add -A
    env GIT_AUTHOR_DATE="$viejo" GIT_COMMITTER_DATE="$viejo" git -C "$d" commit -qm init
  done

  local out
  out="$(cd "$repo" && echo '{"session_id":"quieta"}' | env HOME="$SB/hogar" CRUX_PROJECTS_DIR="$raiz" \
    bash "$CRUX_HOME/adapters/claude/hooks/doc-sync.sh" 2>&1)"
  assert_eq "" "$out" "en un proyecto quieto no dice nada"
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

test_release_publica_las_notas_que_genera() {
  local src; src="$(cat "$CRUX_HOME/bin/release.sh")"
  assert_contains "$src" "gh release create" "las notas no se quedan en la etiqueta"
  assert_contains "$src" "sin gh autenticado" "y sin gh lo dice en vez de fallar"
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

test_el_hook_quita_la_firma_de_la_herramienta() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/git/commit-msg.sh"
  local f="$SB/MSG"

  # El agente la añade porque su propio entorno se lo pide: la regla escrita
  # compite con una instrucción viva y pierde, así que se borra sola.
  printf 'feat: add the why we measure column\n\nExplains each indicator.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01ABC\n' > "$f"
  assert_exit 0 "no rechaza el commit por llevar firma" bash "$hook" "$f"
  assert_not_contains "$(cat "$f")" "Co-Authored-By" "quita el trailer de co-autoría"
  assert_not_contains "$(cat "$f")" "Claude-Session" "y el enlace de sesión"
  assert_contains "$(cat "$f")" "Explains each indicator." "sin tocar el cuerpo"

  # La otra forma de la firma: el pie de "generado con" y su emoji.
  printf 'fix: correct the partner logo\n\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$f"
  bash "$hook" "$f" >/dev/null 2>&1
  assert_not_contains "$(cat "$f")" "Claude Code" "quita el pie de generado con"
  assert_contains "$(cat "$f")" "fix: correct the partner logo" "y deja el asunto"

  # Un co-autor humano es información real del repo y no se toca.
  printf 'feat: add the reviewed copy\n\nCo-Authored-By: A Reviewer <reviewer@example.org>\n' > "$f"
  bash "$hook" "$f" >/dev/null 2>&1
  assert_contains "$(cat "$f")" "reviewer@example.org" "respeta un co-autor humano"
}

test_init_andamia_el_bloque_de_la_puerta() {
  sandbox >/dev/null
  local docs; docs="$(new_project puerta --repos "app")"
  # Un proyecto nuevo nacía sin quality, así que `ship gate` no servía hasta que
  # alguien supiera que el campo existe.
  assert_contains "$(cat "$docs/crux.json")" '"quality"' "el contrato nuevo trae el bloque de la puerta"
  assert_contains "$(cat "$docs/crux.json")" '"gate"' "con el hueco donde declarar los comandos"
}

test_la_maquina_detecta_que_no_hay_hooks() {
  sandbox >/dev/null
  local vacio="$SB/settings-vacios.json"; echo '{}' > "$vacio"
  # Un hook roto se veía; ninguno, no. Y ese es el caso de una máquina nueva.
  local out; out="$(CLAUDE_SETTINGS="$vacio" bash "$CRUX_HOME/bin/machine.sh" 2>&1 || true)"
  assert_contains "$out" "ningún hook de crux enganchado" "avisa de una máquina sin hooks"

  out="$(CLAUDE_SETTINGS="$SB/no-existe.json" bash "$CRUX_HOME/bin/machine.sh" 2>&1 || true)"
  assert_contains "$out" "no hay ningún hook enganchado" "y de una sin ajustes siquiera"
}

test_los_repos_de_codigo_tambien_protegen_su_rama_principal() {
  # Se protegía el kernel y el docs repo, y no los repos de código, que es
  # donde se hace casi todo el trabajo.
  local src; src="$(cat "$CRUX_HOME/bin/hooks.sh")"
  assert_contains "$src" 'instalar_pre_push "$raiz/$repo"' "pre-push también en los repos de código"
}

test_traer_un_proyecto_deja_sus_hooks_puestos() {
  # Una máquina nueva se monta con bootstrap o clonando proyecto a proyecto. Por
  # las dos vías quedaba sin un solo hook, y sin ellos no queda nada automático.
  assert_contains "$(cat "$CRUX_HOME/bin/bootstrap.sh")" "hooks.sh\" install" \
    "bootstrap engancha los hooks de cada proyecto que trae"
  assert_contains "$(cat "$CRUX_HOME/bin/clone.sh")" "hooks.sh\" install" \
    "y clone los del proyecto que clona"
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

test_doctor_no_avisa_por_una_diferencia_de_patch() {
  sandbox >/dev/null
  local docs; docs="$(new_project alpatch)"
  local kernel; kernel="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  local otro_patch="${kernel%.*}.99"
  [[ "$otro_patch" == "$kernel" ]] && otro_patch="${kernel%.*}.98"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = process.argv[2];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json" "$otro_patch"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "crux upgrade" "un patch de diferencia no manda a actualizar"
  assert_not_contains "$out" "va por delante" "ni en la dirección contraria"
}

test_doctor_avisa_por_un_salto_de_serie() {
  sandbox >/dev/null
  local docs; docs="$(new_project deserie)"
  local kernel; kernel="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); o.crux = process.argv[2];
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json" "${kernel%%.*}.0.0"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "crux upgrade" "un minor por detrás sí se avisa"
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

test_review_reune_el_material_de_la_propuesta() {
  sandbox >/dev/null
  local repo="$SB/proyecto"
  mkdir -p "$repo/src" && git -C "$repo" init -q -b main
  echo "uno" > "$repo/src/app.sh"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "init"

  git -C "$repo" checkout -q -b ws/tarea
  printf 'dos\nconsole.log("x")\n# TODO: acabar\n' >> "$repo/src/app.sh"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "feat: algo"

  local out; out="$(bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main 2>&1)"
  assert_contains "$out" "ws/tarea" "dice qué rama revisa"
  assert_contains "$out" "src/app.sh" "y qué ficheros toca"
  assert_contains "$out" "no toca ningún test" "avisa de que no hay tests"
  assert_contains "$out" "marcadores de trabajo a medias" "y de lo que quedó a medias"
  assert_exit 0 "termina limpio" bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main
}

test_review_no_inventa_una_revision_sin_cambios() {
  sandbox >/dev/null
  local repo="$SB/vacio"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"

  local out; out="$(bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main 2>&1)"
  assert_contains "$out" "no hay nada que revisar" "lo dice en vez de imprimir sección vacía"
  assert_exit 1 "y sale con error" bash "$CRUX_HOME/bin/review.sh" --repo "$repo" --base main
}

test_el_docs_repo_nace_en_main() {
  sandbox >/dev/null
  local docs; docs="$(new_project rama)"
  assert_eq "main" "$(git -C "$docs" rev-parse --abbrev-ref HEAD)" "la rama no depende de la máquina"
}

# Si el hook mira una rama que no existe, no bloquea nada y nadie se entera.
test_el_hook_protege_la_rama_que_declara_el_proyecto() {
  sandbox >/dev/null
  local docs; docs="$(new_project heredado --branch master)"
  assert_eq "master" "$(git -C "$docs" rev-parse --abbrev-ref HEAD)" "el repo nace en la declarada"

  ( cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )
  local hook="$docs/.git/hooks/pre-push"
  assert_contains "$(cat "$hook")" "refs/heads/master" "y el hook vigila esa"
  assert_not_contains "$(cat "$hook")" "refs/heads/main" "no una que no existe"
}

# Un proyecto anterior al campo no declara nada: manda lo que el repo usa.
test_sin_rama_declarada_se_usa_la_real() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local docs; docs="$(new_project sindeclarar)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const o = JSON.parse(fs.readFileSync(f, "utf8")); delete o.branch;
    fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");
  ' "$docs/crux.json"
  git -C "$docs" branch -m main troncal

  assert_eq "troncal" "$(rama_principal "$docs")" "cae en la rama real del repo"
}

# La marca que deja la puerta bloqueaba el comando siguiente del propio ciclo.
test_la_marca_de_la_puerta_no_bloquea_la_propuesta() {
  sandbox >/dev/null
  local repo="$SB/app"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"

  bash "$CRUX_HOME/bin/workspace.sh" new tarea --repo "$repo" >/dev/null 2>&1
  local ws="$SB/app-ws-tarea"
  assert_file "$ws/../app/.git/info/exclude" "el exclude existe"
  printf 'abc\n' > "$ws/.crux-ship"
  assert_eq "" "$(git -C "$ws" status --porcelain)" "la marca no ensucia el estado"
}

test_el_contrato_declara_la_rama_principal() {
  sandbox >/dev/null
  local docs; docs="$(new_project declarada --branch troncal)"
  assert_eq "troncal" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).branch)' "$docs/crux.json")" \
    "queda escrita en el contrato"
  assert_eq "troncal" "$(git -C "$docs" rev-parse --abbrev-ref HEAD)" "y es la del repo"
}

# Desde un worktree, la rama actual es la de trabajo: tomarla por principal deja
# el hook bloqueando justo la rama que hay que subir.
test_la_rama_principal_no_es_la_del_worktree() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  local repo="$SB/app"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$repo" worktree add -q -b ws/tarea "$SB/app-ws-tarea" >/dev/null 2>&1

  assert_eq "main" "$(rama_principal "$SB/app-ws-tarea")" "resuelve la troncal, no la de trabajo"
}

test_las_preferencias_del_usuario_se_leen_de_su_config() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  mkdir -p "$SB/home/.crux"
  printf 'CRUX_RM_DELETE_BRANCH=true\nCRUX_MERGE_CLOSE_WORKSPACE="true"\n' > "$SB/home/.crux/config"

  assert_eq "true" "$(HOME=$SB/home preferencia CRUX_RM_DELETE_BRANCH false)" "lee la preferencia"
  assert_eq "true" "$(HOME=$SB/home preferencia CRUX_MERGE_CLOSE_WORKSPACE false)" "y quita las comillas"
  assert_eq "false" "$(HOME=$SB/home preferencia CRUX_NO_DECLARADA false)" "y respeta el defecto"
}

# Una rama con trabajo que no está integrado no se borra por una preferencia.
test_la_rama_solo_se_borra_si_esta_integrada() {
  sandbox >/dev/null
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "branch --merged" "rm comprueba la integración antes de borrar"
}

# adopt escribe la versión actual sobre un repo sin estructura: si upgrade sale
# antes de mirar, el comando que debía completarla no completa nada.
test_upgrade_completa_un_proyecto_adoptado() {
  sandbox >/dev/null
  local docs="$CRUX_PROJECTS_DIR/heredado/heredado-docs"
  mkdir -p "$docs" && git -C "$docs" init -q -b main
  echo "# heredado" > "$docs/README.md"
  git -C "$docs" add -A
  git -C "$docs" -c user.email=t@t -c user.name=t commit -qm "docs: init"
  ( cd "$docs" && bash "$CRUX_HOME/bin/adopt.sh" . >/dev/null 2>&1 )

  bash "$CRUX_HOME/bin/upgrade.sh" "$docs" >/dev/null 2>&1
  for f in AGENTS.md decisions/README.md decisions/index.md repos/README.md; do
    assert_file "$docs/$f" "upgrade repone $f"
  done
  assert_symlink "$docs/CLAUDE.md" "AGENTS.md" "y el symlink que no es una plantilla"
}

# El kernel se instala en cualquier máquina, y macOS trae bash 3.2 de serie.
test_el_kernel_no_usa_bash_4() {
  sandbox >/dev/null
  local usos=""
  for f in "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/bin/crux "$CRUX_HOME"/lib/*.sh \
           "$CRUX_HOME/install.sh" "$CRUX_HOME"/test/*.sh "$CRUX_HOME"/adapters/*/*.sh; do
    [[ -f "$f" ]] || continue
    # Sin anclar al principio de linea: la expansion en minusculas de bash 4
    # aparece dentro de una tuberia o de un [[ ]], y con el ancla las dos que
    # habia pasaban desapercibidas. Los comentarios se quitan antes de mirar,
    # porque esta misma nota las nombra.
    sed 's/#.*$//' "$f" |
      grep -qE '(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]|declare -A|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^)\}' \
      && usos+=" $(basename "$f")"
  done
  assert_eq "" "$usos" "ningún script depende de bash 4"
}

# La raíz mal deducida no rompe nada de forma visible: hace que `crux release`
# no encuentre consumidores y publique diciendo que no hay nada que verificar.
# El resto de los tests de install pasan --projects-dir, así que ninguno miraba
# la deducción.
test_install_deduce_la_raiz_del_clon_no_del_directorio_de_kernels() {
  sandbox >/dev/null
  local casa="$SB/casa-raiz"; mkdir -p "$casa"
  # El clon vive en <raiz>/crux, como en una máquina real.
  local raiz="$SB/proyectos-raiz"; local kernel="$raiz/crux"
  mkdir -p "$kernel"
  ( cd "$CRUX_HOME" && tar cf - bin lib skills templates profiles adapters VERSION install.sh ) \
    | ( cd "$kernel" && tar xf - )

  env HOME="$casa" bash "$kernel/install.sh" >/dev/null 2>&1

  assert_contains "$(cat "$casa/.crux/config")" "CRUX_PROJECTS_DIR=\"$raiz\"" \
    "la raíz es el directorio del clon, no el de los kernels"
}

# Conservar la raíz arregla el caso nuevo pero no la máquina que ya tiene el
# valor malo escrito, que es justo la que sufre el fallo.
test_install_corrige_la_raiz_heredada_del_directorio_de_kernels() {
  sandbox >/dev/null
  local casa="$SB/casa-raiz3"; mkdir -p "$casa/.crux"
  printf 'CRUX_PROJECTS_DIR="%s"\n' "$casa/.crux/kernel" > "$casa/.crux/config"

  local raiz="$SB/proyectos-heredada"; local kernel="$raiz/crux"
  mkdir -p "$kernel"
  ( cd "$CRUX_HOME" && tar cf - bin lib skills templates profiles adapters VERSION install.sh ) \
    | ( cd "$kernel" && tar xf - )

  env HOME="$casa" bash "$kernel/install.sh" >/dev/null 2>&1

  assert_contains "$(cat "$casa/.crux/config")" "CRUX_PROJECTS_DIR=\"$raiz\"" \
    "la raíz heredada del directorio de kernels se descarta y se vuelve a deducir"
}

test_install_no_pisa_la_raiz_ya_declarada() {
  sandbox >/dev/null
  local casa="$SB/casa-raiz2"; mkdir -p "$casa"
  env HOME="$casa" bash "$CRUX_HOME/install.sh" --projects-dir "$casa/elegida" >/dev/null 2>&1
  # Reinstalar sin la bandera: lo que se declaró una vez debe seguir ahí.
  env HOME="$casa" bash "$CRUX_HOME/install.sh" >/dev/null 2>&1

  assert_contains "$(cat "$casa/.crux/config")" "CRUX_PROJECTS_DIR=\"$casa/elegida\"" \
    "la raíz declarada sobrevive a la reinstalación"
}

# Enlazados al working copy, los proyectos usan lo que haya en él en cada
# momento: una rama a medias les cambia el comportamiento sin tocarlos.
test_install_deja_una_copia_por_version() {
  sandbox >/dev/null
  local casa="$SB/casa"; mkdir -p "$casa"
  env HOME="$casa" bash "$CRUX_HOME/install.sh" --projects-dir "$casa/proyectos" >/dev/null 2>&1

  local version; version="$(tr -d '[:space:]' < "$CRUX_HOME/VERSION")"
  assert_file "$casa/.crux/kernel/$version/bin/crux" "la copia de la versión existe"
  assert_contains "$(readlink "$casa/.local/bin/crux")" ".crux/kernel/$version" "el comando apunta a la copia"
  assert_contains "$(readlink "$CLAUDE_SKILLS_DIR/ship")" ".crux/kernel/$version" "y las skills también"
  assert_contains "$(cat "$casa/.crux/config")" 'CRUX_MODE="release"' "queda registrado el modo"
}

test_install_dev_enlaza_al_working_copy() {
  sandbox >/dev/null
  local casa="$SB/casa2"; mkdir -p "$casa"
  # Copia fuera de git: en dev el instalador rechaza un worktree, y la suite
  # corre desde uno cuando se desarrolla el kernel.
  local kernel="$SB/kernel"
  mkdir -p "$kernel"
  ( cd "$CRUX_HOME" && tar cf - bin lib skills templates profiles adapters VERSION install.sh ) \
    | ( cd "$kernel" && tar xf - )

  env HOME="$casa" bash "$kernel/install.sh" --dev --projects-dir "$casa/proyectos" >/dev/null 2>&1

  assert_eq "$kernel/bin/crux" "$(readlink "$casa/.local/bin/crux")" "el comando apunta al repo"
  assert_contains "$(cat "$casa/.crux/config")" 'CRUX_MODE="dev"' "y el modo lo dice"
}

test_install_dev_rechaza_un_worktree() {
  sandbox >/dev/null
  local wt="$SB/kernel-wt"
  git -C "$CRUX_HOME" worktree add -q --detach "$wt" 2>/dev/null || return 0
  cp "$CRUX_HOME/install.sh" "$wt/install.sh"

  local casa="$SB/casa3"; mkdir -p "$casa"
  local out; out="$(env HOME="$casa" bash "$wt/install.sh" --dev --projects-dir "$casa/p" 2>&1)"
  assert_contains "$out" "worktree del kernel" "lo detecta"
  assert_no_file "$casa/.local/bin/crux" "y no instala nada"

  git -C "$CRUX_HOME" worktree remove --force "$wt" 2>/dev/null
}

# Con el kernel instalado como copia, CRUX_HOME no es un repo: publicar desde
# ahí fallaba con "no es un repositorio git" en vez de decir qué hacer.
test_release_se_ejecuta_desde_el_repo_del_kernel() {
  sandbox >/dev/null
  local fuera="$SB/fuera"; mkdir -p "$fuera"
  local out; out="$( cd "$fuera" && bash "$CRUX_HOME/bin/release.sh" 9.9.9 2>&1 )"
  assert_contains "$out" "desde el repositorio del kernel" "dice dónde hay que ejecutarlo"
}

test_status_reune_proyectos_espacios_y_lo_que_no_esta_subido() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local docs; docs="$(new_project mirador --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/api"
  git -C "$root/api" config user.email t@t
  git -C "$root/api" config user.name t
  git -C "$root/api" commit -q --allow-empty -m init
  git -C "$root/api" commit -q --allow-empty -m "feat: sin subir"
  echo suelto > "$root/api/pendiente.txt"

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "mirador" "lista el proyecto"
  assert_contains "$out" "1 repos" "y cuántos repos declara"
  assert_contains "$out" "mirador/api" "señala el repo con trabajo pendiente"
  assert_contains "$out" "1 fichero tocado" "y qué tiene pendiente, en singular si es uno"
}

test_status_no_confunde_un_espacio_con_trabajo_perdido() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local docs; docs="$(new_project espacios --repos "api")"
  local root; root="$(dirname "$docs")"
  git init -q "$root/api"
  git -C "$root/api" config user.email t@t
  git -C "$root/api" config user.name t
  git -C "$root/api" commit -q --allow-empty -m init
  bash "$CRUX_HOME/bin/workspace.sh" new tarea --repo "$root/api" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "ws/tarea" "el espacio aparece como espacio"
  assert_not_contains "$out" "api-ws-tarea " "y su worktree no se cuenta como repo con pendientes"
}

test_release_no_publica_con_una_copia_instalada_vieja() {
  sandbox >/dev/null
  local casa="$SB/casa-release"; mkdir -p "$casa/.crux"
  local viejo="$SB/kernel-viejo"; mkdir -p "$viejo"
  echo "0.0.1" > "$viejo/VERSION"
  echo "CRUX_HOME=\"$viejo\"" > "$casa/.crux/config"

  local out; out="$(cd "$CRUX_HOME" && HOME="$casa" bash "$CRUX_HOME/bin/release.sh" 99.0.0 2>&1)"
  assert_contains "$out" "el kernel instalado es 0.0.1" "avisa de que publicaría con el publicador viejo"
  assert_contains "$out" "install.sh" "y dice cómo alinearlo"
}

test_doctor_rechaza_un_estado_de_adr_que_no_existe() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: Una decisión con el estado inventado

- **Date**: 2026-01-01
- **Status**: Casi aceptada
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "Status no reconocido" "nombra el estado inválido"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_exige_que_superseded_diga_por_quien() {
  sandbox >/dev/null
  local docs; docs="$(new_project zeta)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: Una decisión superada sin decir por quién

- **Date**: 2026-01-01
- **Status**: Superseded
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "la cadena se corta" "explica por qué importa"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_detecta_una_referencia_a_un_adr_que_no_esta() {
  sandbox >/dev/null
  local docs; docs="$(new_project eta)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: Apunta a uno que no existe

- **Date**: 2026-01-01
- **Status**: Superseded by ADR-099
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual
ADR

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "ahí no está" "detecta la referencia rota"
  assert_exit 1 "sale con error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_admite_los_siete_estados_del_vocabulario() {
  sandbox >/dev/null
  local docs; docs="$(new_project theta)"
  cat >> "$docs/decisions/index.md" <<'ADR'

### ADR-001: La que reemplaza

- **Date**: 2026-01-01
- **Status**: Accepted
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual

### ADR-002: Heredada del código del cliente

- **Date**: 2026-01-01
- **Status**: Inherited
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual

### ADR-003: Sin decidir todavía

- **Date**: 2026-01-01
- **Status**: Open
- **Context**: da igual
- **Decision**: ninguna
- **Consequences**: da igual

### ADR-004: Vigente con una parte cambiada

- **Date**: 2026-01-01
- **Status**: Amended by ADR-001
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual

### ADR-005: Superada por dos a la vez

- **Date**: 2026-01-01
- **Status**: Superseded by ADR-001, ADR-004
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual

### ADR-006: Retirada sin reemplazo

- **Date**: 2026-01-01
- **Status**: Deprecated
- **Context**: da igual
- **Decision**: da igual
- **Consequences**: da igual
ADR

  assert_exit 0 "el vocabulario completo pasa" \
    bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_avisa_de_una_doc_que_no_enlaza_nadie() {
  sandbox >/dev/null
  local docs; docs="$(new_project iota)"
  mkdir -p "$docs/operations"
  echo "# Algo que nadie menciona" > "$docs/operations/perdida.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "nadie enlaza operations/perdida.md" "nombra el documento huérfano"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_ve_el_repo_que_solo_existe_en_el_remoto() {
  sandbox >/dev/null
  local docs; docs="$(new_project kappa --repos "api")"
  git -C "$docs" remote add origin "https://github.com/alguien/kappa-docs.git" 2>/dev/null || \
    git -C "$docs" remote set-url origin "https://github.com/alguien/kappa-docs.git"

  # Un repo del proyecto que nadie clonó en esta máquina es invisible al bucle
  # que recorre el disco: así estuvo uno 185 días fuera del contrato.
  local fake="$SB/bin"; mkdir -p "$fake"
  cat > "$fake/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo list") printf 'kappa-docs\nkappa-olvidado\napi\notra-cosa\n' ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$fake/gh"

  local out
  out="$(PATH="$fake:$PATH" bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_contains "$out" "kappa-olvidado está en el remoto" "nombra el repo que solo vive en el remoto"
  assert_not_contains "$out" "otra-cosa está en el remoto" "el resto de la cuenta no es asunto suyo"
  assert_not_contains "$out" "kappa-docs está en el remoto" "el propio docs repo no se reporta"
  assert_exit 0 "es aviso, no error" env PATH="$fake:$PATH" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_avisa_de_credenciales_en_la_documentacion() {
  sandbox >/dev/null
  local docs; docs="$(new_project lambda)"
  mkdir -p "$docs/operations"
  cat > "$docs/operations/acceso.md" <<'DOC'
# Acceso

Entrar con:

```
admin@ejemplo.test
Xk7pQm2ZrT9wLb4V
```

Token de despliegue: `ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
DOC

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_contains "$out" "posible contraseña suelta" "ve la contraseña dentro del bloque"
  assert_contains "$out" "token de GitHub" "ve el token por su formato"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_no_confunde_configuracion_con_credenciales() {
  sandbox >/dev/null
  local docs; docs="$(new_project mu)"
  mkdir -p "$docs/operations"
  cat > "$docs/operations/servicio.md" <<'DOC'
# Servicio

```
Restart=always
RestartSec=10
EnvironmentFile=/opt/servicio/.env
```

```
postgres://usuario:devpass@127.0.0.1:5432/base
```

```
La contraseña de ejemplo es changeme-dev
```
DOC

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_not_contains "$out" "credencial en la documentación" "la sintaxis y los ejemplos no son secretos"
}

test_merge_no_toca_la_propuesta_de_otro_repositorio() {
  sandbox >/dev/null
  local repo="$SB/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "https://github.com/alguien/proyecto-a.git"

  # gh resuelve el repositorio por el directorio: un número correcto en el sitio
  # equivocado mergea lo de otro proyecto sin preguntar.
  local fake="$SB/bin"; mkdir -p "$fake"
  cat > "$fake/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view") exit 1 ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$fake/gh"

  local out rc=0
  out="$(cd "$repo" && PATH="$fake:$PATH" bash "$CRUX_HOME/bin/merge.sh" 7 2>&1)" || rc=$?

  assert_contains "$out" "no existe en alguien/proyecto-a" "dice en qué repositorio miró"
  assert_eq "1" "$rc" "para en vez de mergear a ciegas"
}

test_merge_exige_un_numero() {
  sandbox >/dev/null
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/merge.sh" rama-cualquiera 2>&1)" || rc=$?
  assert_contains "$out" "entero" "rechaza lo que no es un número"
  assert_eq "1" "$rc" "sale con error"
}

test_doctor_avisa_del_runbook_que_lleva_medio_ano_sin_verificar() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu)"
  mkdir -p "$docs/operations"
  printf '# Reiniciar el servicio\n\n> Última verificación: 2020-01-15\n\nPasos.\n' \
    > "$docs/operations/viejo.md"
  printf '# Purgar la caché\n\n> Última verificación: %s\n\nPasos.\n' "$(date +%%F)" \
    > "$docs/operations/reciente.md"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"

  assert_contains "$out" "operations/viejo.md sin verificar" "nombra el que caducó"
  assert_not_contains "$out" "operations/reciente.md sin verificar" "el recién comprobado no molesta"
  assert_exit 0 "es aviso, no error" bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_status_distingue_el_contrato_ilegible_de_la_ausencia() {
  sandbox >/dev/null
  local docs; docs="$(new_project s)"
  # Truncado a la mitad: ni está ausente ni se puede leer.
  printf '{\n  "crux": "0.36.0",\n  "project": "s",\n  "profile": "mul' > "$docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "ilegible" "un contrato roto se dice, no se cuenta como cero repos"
  assert_not_contains "$out" "0 repos" "cero parecía un dato y no lo era"

  assert_exit 1 "y --check sale 1, como el de memory" bash "$CRUX_HOME/bin/status.sh" --check
}

test_un_perfil_propio_sobrevive_al_kernel() {
  sandbox >/dev/null
  local casa="$SB/home"; mkdir -p "$casa/.crux/profiles"
  # Un perfil entero del usuario, que el kernel no trae.
  printf '{"name":"solo","description":"mío","pointers":{"write":false},"rules":["la mía"]}\n' \
    > "$casa/.crux/profiles/solo.json"

  local docs="$CRUX_PROJECTS_DIR/mp/mp-docs"
  env HOME="$casa" bash "$CRUX_HOME/bin/init.sh" mp --no-remote \
    --parent "$CRUX_PROJECTS_DIR" --profile solo >/dev/null 2>&1
  assert_file "$docs/crux.json" "init acepta un perfil que solo existe en ~/.crux/profiles"

  local out; out="$(env HOME="$casa" bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "perfil desconocido" "y doctor lo reconoce"
  assert_contains "$out" "perfil solo" "por su nombre"
}

test_el_proyecto_puede_solapar_un_campo_del_perfil() {
  sandbox >/dev/null
  local docs; docs="$(new_project sp)"
  # El proyecto no redefine el perfil entero: cambia un campo.
  printf '{"pointers":{"write":false}}\n' > "$docs/profile.json"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "perfil multi-repo" "sigue siendo su perfil"
  # multi-repo escribe punteros; con el solapado, no.
  mkdir -p "$(dirname "$docs")/app" && git -C "$(dirname "$docs")/app" init -q
  printf '# ajeno\n' > "$(dirname "$docs")/app/AGENTS.md"
  git -C "$(dirname "$docs")/app" add -A
  git -C "$(dirname "$docs")/app" commit -qm init
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8")); j.repos = ["app"];
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$docs/crux.json"
  out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$out" "es del cliente" "el campo solapado manda sobre el del kernel"
}

test_un_directorio_que_no_existe_no_cuelga_los_comandos() {
  sandbox >/dev/null
  # find_docs_repo dejaba la ruta vacía y dirname "" devuelve "." para siempre.
  local out
  out="$(timeout 10 bash "$CRUX_HOME/bin/doctor.sh" "$SB/no-existe" 2>&1)"
  local rc=$?
  assert_eq "sí" "$([[ $rc -ne 124 ]] && echo sí || echo no)" "doctor no se queda colgado"
  assert_contains "$out" "no" "y dice que no encuentra nada ahí"

  out="$(timeout 10 bash "$CRUX_HOME/bin/link.sh" "$SB/no-existe" 2>&1)"
  rc=$?
  assert_eq "sí" "$([[ $rc -ne 124 ]] && echo sí || echo no)" "link tampoco"
}

test_las_reglas_del_perfil_se_escriben_y_se_verifican() {
  sandbox >/dev/null
  local docs; docs="$(new_project rp)"

  bash "$CRUX_HOME/bin/link.sh" "$docs" >/dev/null 2>&1
  local agents; agents="$(cat "$docs/AGENTS.md")"
  assert_contains "$agents" "crux:begin perfil" "link escribe el bloque de las reglas del perfil"
  assert_contains "$agents" "La documentación específica de un repo vive" \
    "con las reglas que declara el perfil, no copiadas a mano"
  assert_contains "$agents" "que estén" "y dice qué comprueba doctor: que estén, no que se cumplan"

  # Si alguien las borra, doctor lo dice en vez de callar.
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace(/<!-- crux:begin perfil[\s\S]*?crux:end -->/, ""));
  ' "$docs/AGENTS.md"
  assert_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "reglas del perfil" \
    "doctor avisa cuando el bloque no está"
}

test_un_crux_json_en_el_repo_de_codigo_no_es_el_contrato() {
  # Quien manda una propuesta puede añadir un crux.json en la raiz. Si ganara,
  # decidiria la rama que vigila el hook y los comandos de la puerta.
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/suplanta"
  mkdir -p "$root/app" "$root/suplanta-docs"
  git -C "$root/app" init -q
  printf '{"crux":"0.1.0","project":"suplanta","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/suplanta-docs/crux.json"
  printf '{"crux":"0.1.0","project":"malo","profile":"multi-repo","branch":"suya","sections":[]}\n' \
    > "$root/app/crux.json"

  source "$CRUX_HOME/lib/common.sh"
  local encontrado; encontrado="$(find_docs_repo "$root/app")"
  assert_eq "$root/suplanta-docs" "$encontrado" "manda el docs repo, no el crux.json del repo de codigo"
  assert_eq "main" "$(rama_principal "$root/app")" "y la rama principal no sale del contrato suplantado"
}

test_install_no_acepta_una_version_que_sea_una_ruta() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  assert_exit 1 "una version con travesia no pasa" es_semver "../../algo"
  assert_exit 1 "ni una vacia" es_semver ""
  assert_exit 0 "y una normal si" es_semver "1.2.3"
  assert_contains "$(cat "$CRUX_HOME/install.sh")" 'es_semver "$VERSION_INSTALADA"' \
    "install.sh la comprueba antes de componer la ruta que borra"
}

test_upgrade_no_se_abre_con_una_version_que_no_sabe_comparar() {
  sandbox >/dev/null
  source "$CRUX_HOME/lib/common.sh"
  assert_exit 1 "0.28 no es semver" es_semver "0.28"
  assert_exit 1 "unknown tampoco" es_semver "unknown"
  local up; up="$(cat "$CRUX_HOME/bin/upgrade.sh")"
  assert_contains "$up" 'es_semver "$TO"' "upgrade comprueba la del kernel"
  assert_contains "$up" 'es_semver "$FROM"' "y la del contrato"
}
