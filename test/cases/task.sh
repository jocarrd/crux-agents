#!/usr/bin/env bash

_proyecto_de_tareas() {
  # Un proyecto con dos repos de código y su docs repo, cada repo con un commit.
  local root="$CRUX_PROJECTS_DIR/proj"
  mkdir -p "$root/app" "$root/web" "$root/proj-docs"
  local r
  for r in app web; do
    git -C "$root/$r" init -q
    echo x > "$root/$r/f.txt"
    git -C "$root/$r" add -A
    git -C "$root/$r" commit -qm init
  done
  printf '{"crux":"0.1.0","project":"proj","profile":"%s","repos":["app","web"],"sections":[]}\n' \
    "${1:-multi-repo}" > "$root/proj-docs/crux.json"
  echo "$root"
}

test_workspace_new_registra_la_tarea() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new mapas --repo "$root/app" 2>&1)"
  assert_contains "$out" "tarea 'mapas' registrada" "abrir un espacio registra su tarea"

  local f="$SB/tasks/proj/mapas.md"
  assert_file "$f" "el registro va en el estado local, por proyecto y tarea"
  assert_contains "$(cat "$f")" "status: open" "nace abierta"
  assert_contains "$(cat "$f")" "repos: [app]" "sabe en qué repo se trabaja"
  assert_no_file "$root/app-ws-mapas/mapas.md" "y no escribe nada dentro del repo"
  assert_contains "$(cat "$CRUX_REGISTRY")" '"task": "mapas"' "el espacio apunta a su tarea"
}

test_una_tarea_de_varios_repos_comparte_registro() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"

  bash "$CRUX_HOME/bin/workspace.sh" new mapas --repo "$root/app" >/dev/null 2>&1
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new mapas-web --repo "$root/web" --task mapas 2>&1)"
  assert_contains "$out" "se une a la tarea 'mapas'" "el segundo repo se une a la misma tarea"

  local f="$SB/tasks/proj/mapas.md"
  assert_contains "$(cat "$f")" "repos: [app, web]" "un registro con los dos repos"
  assert_contains "$(cat "$f")" "workspaces: [mapas, mapas-web]" "y con los dos espacios"

  # Un paso añadido desde un espacio se ve desde el otro.
  ( cd "$root/app-ws-mapas" && bash "$CRUX_HOME/bin/task.sh" add "corregir el mapa" >/dev/null 2>&1 )
  local desde_web; desde_web="$(cd "$root/web-ws-mapas-web" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$desde_web" "T1 corregir el mapa" "lo que se anota en un repo se lee en el otro"
}

test_task_anota_pasos_evidencia_y_siguiente() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new t --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-t" f="$SB/tasks/proj/t.md"

  ( cd "$ws" || exit 1
    bash "$CRUX_HOME/bin/task.sh" goal "Que el mapa siga la ONU" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "corregir fronteras" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "regenerar el svg" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "revisar el widget" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" "done" T1 "capturas antes y después" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" note "Kosovo dentro de Serbia" >/dev/null ) 2>&1

  local t; t="$(cat "$f")"
  assert_contains "$t" "- [x] T1 corregir fronteras · evidencia: capturas antes y después" "el paso hecho lleva su evidencia"
  assert_contains "$t" "- [ ] T2 regenerar el svg
- [ ] T3 revisar el widget" "los pasos quedan seguidos, sin huecos"
  assert_contains "$t" "status: in-progress" "completar un paso la pone en marcha"
  assert_contains "$t" "- Kosovo dentro de Serbia" "la decisión queda anotada"

  local show; show="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$show" "pasos 1/3" "enseña cuánto va hecho"
  assert_contains "$show" "siguiente: T2 regenerar el svg" "sin siguiente paso escrito, propone el primer pendiente"

  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" next "probar en staging" >/dev/null 2>&1 )
  show="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$show" "siguiente: probar en staging" "el siguiente paso escrito manda"

  local sin; sin="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" "done" T2 2>&1)"
  assert_contains "$sin" "sin evidencia" "marcar sin evidencia se puede, pero se dice"
  assert_exit 1 "un paso que no existe no se inventa" \
    env -C "$ws" bash "$CRUX_HOME/bin/task.sh" "done" T9 "algo"
}

test_task_fuera_de_un_espacio_dice_que_hacer() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"

  local out; out="$(cd "$root/app" && bash "$CRUX_HOME/bin/task.sh" 2>&1)"
  assert_contains "$out" "no estás en un espacio de trabajo" "en el repo principal no hay tarea que adivinar"
  assert_exit 1 "y sale con error" env -C "$root/app" bash "$CRUX_HOME/bin/task.sh"
}

test_seal_verifica_la_tarea_y_el_estado_no_retrocede() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new v --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-v" f="$SB/tasks/proj/v.md"

  echo cambio > "$ws/g.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: cambio"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local t; t="$(cat "$f")"
  assert_contains "$t" "status: verified" "cerrar la puerta verifica la tarea"
  assert_contains "$t" "- ok · true" "y vuelca lo que se ejecutó como evidencia"
  assert_contains "$t" "Sobre $(git -C "$ws" rev-parse --short=8 HEAD)" "sobre el commit que se verificó"

  # Una tarea ya fusionada no vuelve a "verified" por repetir la puerta.
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  assert_contains "$(cat "$f")" "status: merged" "el estado solo avanza solo"
}

test_la_propuesta_sale_de_la_tarea_sin_ensenar_el_andamiaje() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas client-repo)"
  bash "$CRUX_HOME/bin/workspace.sh" new c --repo "$root/app" --force >/dev/null 2>&1
  local ws="$root/app-ws-c" f="$SB/tasks/proj/c.md"

  ( cd "$ws" || exit 1
    bash "$CRUX_HOME/bin/task.sh" goal "Borders follow the UN map" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" add "fix the world atlas" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" "done" T1 "before and after screenshots" >/dev/null
    bash "$CRUX_HOME/bin/task.sh" note "Kosovo inside Serbia, as the UN map shows" >/dev/null ) 2>&1

  local body="$SB/BODY.md"
  node "$CRUX_HOME/lib/task.mjs" body --file "$f" --lang en > "$body"
  local b; b="$(cat "$body")"
  assert_contains "$b" "## What changes" "la descripción dice qué cambia"
  assert_contains "$b" "fix the world atlas (before and after screenshots)" "lo hecho, con su evidencia entre paréntesis"
  assert_not_contains "$b" "evidencia:" "sin la etiqueta del registro, que va en otro idioma"
  assert_contains "$b" "Kosovo inside Serbia" "y lo decidido"
  assert_not_contains "$b" "T1" "sin los identificadores internos de los pasos"
  assert_not_contains "$b" ".crux" "sin rutas de nuestro estado local"

  # Lo comprobado se ejecutó en esta máquina: sus rutas no se publican.
  node "$CRUX_HOME/lib/task.mjs" set --file "$f" --section "Verificación" \
    --text "- ok · $HOME/Proyectos/tool --check (2s)" >/dev/null
  assert_not_contains "$(node "$CRUX_HOME/lib/task.mjs" body --file "$f" --lang en)" "$HOME/" \
    "sin las rutas de la máquina en lo comprobado"
  assert_exit 0 "y pasa el filtro de un repo de cliente" \
    env -C "$ws" bash "$CRUX_HOME/bin/ship.sh" body "$body"
}

test_el_hook_trae_la_tarea_una_vez_por_sesion() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new h --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-h" hook="$CRUX_HOME/adapters/claude/hooks/task-context.sh"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" next "probar el hover" >/dev/null 2>&1 )

  local primera segunda fuera
  primera="$(cd "$ws" && echo '{"session_id":"s-hook"}' | env TMPDIR="$SB" bash "$hook" 2>&1)"
  segunda="$(cd "$ws" && echo '{"session_id":"s-hook"}' | env TMPDIR="$SB" bash "$hook" 2>&1)"
  fuera="$(cd "$root/app" && echo '{"session_id":"s-hook"}' | env TMPDIR="$SB" bash "$hook" 2>&1)"

  assert_contains "$primera" "siguiente: probar el hover" "al retomar dice en qué punto quedó"
  assert_contains "$primera" "$SB/tasks/proj/h.md" "y dónde está el registro"
  assert_eq "" "$segunda" "la segunda vez en la misma sesión se calla"
  assert_eq "" "$fuera" "fuera de un espacio no dice nada"
  assert_eq 2 "$(printf '%s\n' "$primera" | wc -l | tr -d ' ')" "y cabe en dos líneas"
}

test_workspace_list_ensena_en_que_punto_quedo_cada_tarea() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new l --repo "$root/app" >/dev/null 2>&1
  ( cd "$root/app-ws-l" && bash "$CRUX_HOME/bin/task.sh" next "revisar el widget" >/dev/null 2>&1 )

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" list --all 2>&1)"
  assert_contains "$out" "tarea l: open · revisar el widget" "la lista de espacios lleva estado y siguiente paso"

  out="$(bash "$CRUX_HOME/bin/task.sh" list --all 2>&1)"
  assert_contains "$out" "proj/l" "la lista de tareas las agrupa por proyecto"
  assert_contains "$out" "revisar el widget" "con su siguiente paso"
}

test_un_registro_ilegible_se_dice_y_se_para() {
  sandbox >/dev/null
  local f="$SB/tasks/proj/rota.md"
  mkdir -p "$(dirname "$f")"
  echo "esto no tiene cabecera" > "$f"

  local out; out="$(node "$CRUX_HOME/lib/task.mjs" summary --file "$f" 2>&1)"
  assert_contains "$out" "no tiene cabecera" "un registro corrupto se nombra"
  assert_exit 1 "y no se lee como una tarea vacía" node "$CRUX_HOME/lib/task.mjs" summary --file "$f"
  assert_exit 1 "un estado inventado no se acepta" \
    node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to "casi-listo"
}

test_hooks_install_engancha_el_contexto_de_la_tarea() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "task-context.sh" "install engancha el hook de la tarea"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "task-context" "y remove lo retira"
}

test_el_ciclo_con_tarea_cabe_en_pocas_llamadas() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"

  # Objetivo al abrir y el plan de una vez: dos llamadas, no cuatro.
  bash "$CRUX_HOME/bin/workspace.sh" new p --repo "$root/app" --goal "Que el hover no tape el país" >/dev/null 2>&1
  ( cd "$root/app-ws-p" && bash "$CRUX_HOME/bin/task.sh" add "levantar el país" "zoom al seleccionar" "capturas" >/dev/null 2>&1 )

  local t; t="$(cat "$SB/tasks/proj/p.md")"
  assert_contains "$t" "Que el hover no tape el país" "el objetivo entra al abrir el espacio"
  assert_contains "$t" "- [ ] T3 capturas" "y varios pasos entran en una llamada"
}

test_workspace_list_desde_dentro_de_un_espacio_ve_los_del_repo() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new uno --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new dos --repo "$root/app" >/dev/null 2>&1

  local out; out="$(cd "$root/app-ws-uno" && bash "$CRUX_HOME/bin/workspace.sh" list 2>&1)"
  assert_contains "$out" "uno" "desde un espacio se ve a sí mismo"
  assert_contains "$out" "dos" "y a los demás del mismo repo"
  assert_not_contains "$out" "sin espacios en este repo" "sin decir que no hay nada"
}

test_cerrar_el_ultimo_espacio_de_una_tarea_fusionada_la_archiva() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new a --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new a-web --repo "$root/web" --task a >/dev/null 2>&1
  local f="$SB/tasks/proj/a.md"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm a 2>&1)"
  assert_contains "$out" "sigue en 1 espacio" "con otro espacio vivo, la tarea no se archiva"
  assert_file "$f" "y sigue en su sitio"

  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm a-web 2>&1)"
  assert_contains "$out" "tarea 'a' archivada" "al cerrar el último espacio se archiva"
  assert_no_file "$f" "sale de la lista de abiertas"
  local archivada; archivada="$(ls "$SB"/tasks/proj/done/*-a.md 2>/dev/null | head -1)"
  assert_file "$archivada" "y queda fechada en done/"
  assert_contains "$(cat "$archivada")" "status: closed" "cerrada"

  out="$(bash "$CRUX_HOME/bin/task.sh" list --all 2>&1)"
  assert_not_contains "$out" "proj/a " "la lista de abiertas ya no la enseña"
  out="$(bash "$CRUX_HOME/bin/task.sh" list --done 2>&1)"
  assert_contains "$out" "-a" "y --done sí"
}

test_una_tarea_sin_terminar_no_se_archiva_al_cerrar_su_espacio() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$root/app" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm b 2>&1)"
  assert_contains "$out" "sigue abierta (open)" "cerrar el espacio no esconde trabajo sin terminar"
  assert_contains "$out" "crux task archive --task proj/b" "y dice cómo archivarla si ya no sigue"
  assert_file "$SB/tasks/proj/b.md" "el registro se queda"

  out="$(bash "$CRUX_HOME/bin/task.sh" archive --task proj/b 2>&1)"
  assert_contains "$out" "tarea archivada" "a mano también se archiva"
  assert_no_file "$SB/tasks/proj/b.md" "y sale de las abiertas"
}

test_gc_borra_las_tareas_archivadas_que_han_caducado() {
  sandbox >/dev/null
  local done_dir="$SB/tasks/proj/done"
  mkdir -p "$done_dir"
  printf -- '---\ntask: vieja\nstatus: closed\n---\n' > "$done_dir/2020-01-01-vieja.md"
  local reciente; reciente="$(date +%Y-%m-%d)-reciente.md"
  printf -- '---\ntask: reciente\nstatus: closed\n---\n' > "$done_dir/$reciente"

  local out; out="$(env CRUX_TASKS_RETENTION_DAYS=180 bash "$CRUX_HOME/bin/workspace.sh" gc 2>&1)"
  assert_contains "$out" "2020-01-01-vieja" "enseña lo caducado"
  assert_file "$done_dir/2020-01-01-vieja.md" "sin --yes no borra nada"

  env CRUX_TASKS_RETENTION_DAYS=180 bash "$CRUX_HOME/bin/workspace.sh" gc --yes >/dev/null 2>&1
  assert_no_file "$done_dir/2020-01-01-vieja.md" "con --yes borra lo caducado"
  assert_file "$done_dir/$reciente" "y deja lo reciente"

  assert_exit 1 "una retención que no es un número se dice" \
    env CRUX_TASKS_RETENTION_DAYS=pronto bash "$CRUX_HOME/bin/workspace.sh" gc
}

test_las_decisiones_de_la_tarea_pasan_al_docs_repo_al_archivar() {
  # El registro de la tarea es local y se archiva: lo que se decidió por el
  # camino se quedaba ahí y la siguiente sesión no lo veía.
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  local docs="$root/proj-docs"
  mkdir -p "$docs/repos/app"; echo "# Notas" > "$docs/repos/app/notes.md"
  git -C "$docs" init -q; git -C "$docs" config user.email t@t; git -C "$docs" config user.name t
  git -C "$docs" add -A; git -C "$docs" commit -qm init
  bash "$CRUX_HOME/bin/workspace.sh" new dec --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-dec" out
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" note "Cache keys get a version prefix" \
    --why "changing the format broke existing keys" --where "src/cache.ts" \
    --learned "old keys expire in 24h, so no migration is needed" 2>&1)"
  assert_contains "$out" "decisión anotada" "con porqué, es una decisión"
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" note "Skipped the retry, not needed yet" 2>&1)"
  assert_contains "$out" "--why" "sin porqué, sugiere añadirlo"

  local f="$SB/tasks/proj/dec.md"
  assert_contains "$(cat "$f")" "Cache keys get a version prefix · Why: changing the format broke existing keys · Where: src/cache.ts" \
    "el registro guarda la decisión en una línea"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm dec 2>&1)"
  assert_contains "$out" "decisiones de la tarea en proj-docs/repos/app/notes.md" "al archivar lo dice"

  local notes; notes="$(cat "$docs/repos/app/notes.md")"
  assert_contains "$notes" "## Cache keys get a version prefix," "la decisión llega a las notas del repo"
  assert_contains "$notes" "- **Why**: changing the format broke existing keys" "con su porqué"
  assert_contains "$notes" "- **Learned**: old keys expire in 24h" "y lo aprendido"
  assert_not_contains "$notes" "Skipped the retry" "la desviación sin porqué se queda en la tarea"
  assert_contains "$(git -C "$docs" log -1 --format=%s)" "decisions from task dec" "y queda commiteada"
  assert_eq "" "$(git -C "$docs" status --porcelain)" "sin dejar nada suelto"
}

test_una_tarea_sin_decisiones_no_toca_el_docs_repo() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  local docs="$root/proj-docs"
  mkdir -p "$docs/repos/app"
  git -C "$docs" init -q; git -C "$docs" config user.email t@t; git -C "$docs" config user.name t
  git -C "$docs" add -A; git -C "$docs" commit -qm init
  bash "$CRUX_HOME/bin/workspace.sh" new sin --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/sin.md"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  bash "$CRUX_HOME/bin/workspace.sh" rm sin >/dev/null 2>&1
  assert_no_file "$docs/repos/app/notes.md" "no crea notas vacías"
  assert_eq "init" "$(git -C "$docs" log -1 --format=%s)" "ni commits"
}

test_wait_records_who_and_retires_an_idle_workspace() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new dominio --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/dominio.md" out rc=0
  out="$(cd "$root/app-ws-dominio" && bash "$CRUX_HOME/bin/task.sh" wait --on "Alex" --ask "¿Apuntamos el dominio: sí o no?" --ref "correo del 3 de octubre" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "wait termina bien"
  assert_contains "$(cat "$f")" "waiting_on: Alex" "apunta a quién se espera"
  assert_contains "$(cat "$f")" "waiting_ask: ¿Apuntamos el dominio: sí o no?" "y qué se le preguntó, aunque lleve dos puntos"
  assert_contains "$(cat "$f")" "waiting_ref: correo del 3 de octubre" "y dónde"
  assert_contains "$(cat "$f")" "waiting_since: " "y desde cuándo"
  assert_no_file "$root/app-ws-dominio/f.txt" "el espacio sin trabajo se retira"
  assert_eq "" "$(git -C "$root/app" branch --list ws/dominio)" "y su rama vacía también"
  assert_contains "$(cat "$f")" "retired: [app=ws/dominio]" "la rama queda apuntada como retirada"
  assert_file "$f" "la tarea no se archiva por quedarse sin espacios"
  local list; list="$(bash "$CRUX_HOME/bin/task.sh" list --all 2>&1)"
  assert_contains "$list" "proj/dominio" "sigue en la lista"
  assert_contains "$list" "waiting" "como tarea en espera"
  assert_contains "$list" "a Alex desde" "diciendo a quién espera"
}

test_wait_keeps_a_workspace_with_work_in_it() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new cambios --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-cambios" out
  echo y > "$ws/sin-commit.txt"
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" --ask "¿vale así?" 2>&1)"
  assert_contains "$out" "cambios sin commitear: se queda" "dice por qué no lo retira"
  assert_file "$ws/sin-commit.txt" "y no pierde el trabajo"

  bash "$CRUX_HOME/bin/workspace.sh" new commits --repo "$root/app" >/dev/null 2>&1
  ws="$root/app-ws-commits"
  ( cd "$ws" && echo z > z.txt && git add z.txt && git commit -qm z )
  out="$(cd "$ws" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" --ask "¿vale así?" 2>&1)"
  assert_contains "$out" "sin fusionar en ws/commits: se queda" "una rama con commits propios no se toca"
  assert_file "$ws/z.txt" "ni su espacio"
}

test_wait_needs_who_and_what() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new sin --repo "$root/app" >/dev/null 2>&1
  local out rc=0
  out="$(cd "$root/app-ws-sin" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" 2>&1)" || rc=$?
  assert_eq 1 "$rc" "sin la pregunta no se pone a esperar"
  assert_contains "$out" "uso: crux task wait" "y dice cómo se usa"
  assert_not_contains "$(cat "$SB/tasks/proj/sin.md")" "waiting_on" "ni escribe nada a medias"
}

test_waiting_tasks_get_their_own_block_in_the_reminder() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new curro --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new espera --repo "$root/web" >/dev/null 2>&1
  ( cd "$root/web-ws-espera" && bash "$CRUX_HOME/bin/task.sh" wait --on "Alex" --ask "¿Datos de la base vieja?" >/dev/null 2>&1 )
  local r; r="$(node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")"
  assert_contains "$r" "Esperando respuesta:" "las que esperan van en su propio bloque"
  assert_contains "$r" "proj/espera · a Alex, hoy: ¿Datos de la base vieja?" "con a quién, desde cuándo y qué"
  assert_not_contains "$r" "conviene insistir" "sin insistir antes de tiempo"
  local antes despues
  antes="$(printf '%s' "$r" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j.usuario.indexOf("proj/curro")))})')"
  despues="$(printf '%s' "$r" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j.usuario.indexOf("Esperando respuesta")))})')"
  assert_eq 1 "$([[ "$antes" -ge 0 && "$antes" -lt "$despues" ]] && echo 1 || echo 0)" "el trabajo propio va antes que lo que espera a otro"
  sed -i 's/^waiting_since: .*/waiting_since: 2020-01-01/' "$SB/tasks/proj/espera.md"
  r="$(node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")"
  assert_contains "$r" "conviene insistir" "pasado el plazo sugiere insistir"
  r="$(CRUX_WAIT_NUDGE_DAYS=100000 node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")"
  assert_not_contains "$r" "conviene insistir" "y el plazo se puede ajustar"
  local st; st="$(cd "$root/app" && bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$st" "esperando respuesta" "crux status les da su sección"
  assert_not_contains "$(printf '%s' "$st" | sed -n '/tareas abiertas sin espacio/,/^$/p')" "proj/espera" "y no la cuenta como abierta sin espacio"
}

test_a_merged_task_that_waits_is_not_archived() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new fusionada --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/fusionada.md"
  node "$CRUX_HOME/lib/task.mjs" status --file "$f" --to merged >/dev/null
  node "$CRUX_HOME/lib/task.mjs" wait --file "$f" --on "Alex" --ask "¿seguimos?" >/dev/null
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm fusionada 2>&1)"
  assert_contains "$out" "espera a Alex: no se archiva" "rm no archiva una tarea que espera"
  assert_file "$f" "el registro sigue"
  assert_contains "$(node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$root/app")" "proj/fusionada" "y sigue en el recordatorio aunque esté fusionada"
}

test_resume_reopens_a_retired_branch_and_stops_waiting() {
  sandbox >/dev/null
  local root; root="$(_proyecto_de_tareas)"
  bash "$CRUX_HOME/bin/workspace.sh" new vuelta --repo "$root/app" >/dev/null 2>&1
  local f="$SB/tasks/proj/vuelta.md"
  ( cd "$root/app-ws-vuelta" && bash "$CRUX_HOME/bin/task.sh" wait --on "Ana" --ask "¿sí?" >/dev/null 2>&1 )
  local out rc=0
  out="$(cd "$root/app" && bash "$CRUX_HOME/bin/workspace.sh" resume vuelta 2>&1)" || rc=$?
  assert_eq 0 "$rc" "resume abre la tarea aunque su rama se retirase"
  assert_file "$root/app-ws-vuelta/f.txt" "con un espacio nuevo desde la principal"
  assert_contains "$out" "ya no espera respuesta" "y deja de esperar"
  assert_not_contains "$(cat "$f")" "waiting_on" "sin rastro de la espera"
  assert_not_contains "$(cat "$f")" "retired:" "ni de la rama retirada"
  rc=0; out="$(cd "$root/app-ws-vuelta" && bash "$CRUX_HOME/bin/task.sh" unwait 2>&1)" || rc=$?
  assert_eq 0 "$rc" "unwait sobre una tarea que no espera no es un error"
  assert_contains "$out" "no estaba esperando" "y lo dice"
}
