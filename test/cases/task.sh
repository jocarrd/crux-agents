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
