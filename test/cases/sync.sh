#!/usr/bin/env bash

# `crux sync` es alternar de máquina: una se queda atrás mientras se trabaja en
# la otra. Aquí las dos máquinas son dos clones del mismo remoto local, y el
# `gh` es uno de mentira sin sesión, para que nunca se vaya a GitHub de verdad.

_sin_gh() {
  mkdir -p "$SB/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/bin/gh"
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

_dos_maquinas() {
  # Un remoto con un commit, clonado en esta máquina (dentro de la raíz) y en
  # la otra (fuera). Deja OTRA con la ruta del segundo clon.
  _sin_gh
  git init -q --bare -b main "$SB/remoto.git"
  git clone -q "$SB/remoto.git" "$SB/semilla" 2>/dev/null
  git -C "$SB/semilla" commit -q --allow-empty -m "first"
  git -C "$SB/semilla" push -q origin main
  mkdir -p "$CRUX_PROJECTS_DIR/alfa"
  git clone -q "$SB/remoto.git" "$CRUX_PROJECTS_DIR/alfa/app"
  OTRA="$SB/semilla"
}

_trabajo_en_la_otra() {
  echo "$1" > "$OTRA/$1"
  git -C "$OTRA" add "$1"
  git -C "$OTRA" commit -q -m "$1"
  git -C "$OTRA" push -q origin main
}

test_sync_avanza_la_rama_que_va_por_detras() {
  sandbox >/dev/null
  _dos_maquinas
  _trabajo_en_la_otra hecho-alli

  local out
  out="$(crux sync 2>&1)"

  assert_file "$CRUX_PROJECTS_DIR/alfa/app/hecho-alli" "lo de la otra máquina llega"
  assert_contains "$out" "alfa/app" "dice qué repo avanzó"
  assert_contains "$out" "1 commit nuevo" "y cuánto"
  teardown
}

test_sync_no_toca_una_rama_con_cambios_sin_commitear() {
  sandbox >/dev/null
  _dos_maquinas
  echo "a medias" > "$CRUX_PROJECTS_DIR/alfa/app/nota"
  git -C "$CRUX_PROJECTS_DIR/alfa/app" add nota
  _trabajo_en_la_otra hecho-alli

  local out rc
  out="$(crux sync 2>&1)"; rc=$?

  assert_no_file "$CRUX_PROJECTS_DIR/alfa/app/hecho-alli" "no avanza encima de trabajo sin commitear"
  assert_contains "$out" "cambios sin commitear" "y dice por qué"
  assert_eq 1 "$rc" "sale con error: hay algo que decidir"
  teardown
}

test_sync_no_junta_ramas_separadas() {
  sandbox >/dev/null
  _dos_maquinas
  git -C "$CRUX_PROJECTS_DIR/alfa/app" commit -q --allow-empty -m "aqui"
  _trabajo_en_la_otra hecho-alli

  local out antes
  antes="$(git -C "$CRUX_PROJECTS_DIR/alfa/app" rev-parse HEAD)"
  out="$(crux sync 2>&1)"

  assert_eq "$antes" "$(git -C "$CRUX_PROJECTS_DIR/alfa/app" rev-parse HEAD)" "ni mezcla ni reescribe"
  assert_contains "$out" "se han separado" "avisa de que hay que decidir"
  teardown
}

test_sync_leave_falla_con_commits_sin_subir() {
  sandbox >/dev/null
  _dos_maquinas
  git -C "$CRUX_PROJECTS_DIR/alfa/app" commit -q --allow-empty -m "sin subir"

  local out rc
  out="$(crux sync --leave 2>&1)"; rc=$?

  assert_eq 1 "$rc" "no deja irse con commits atrapados"
  assert_contains "$out" "sin subir" "y dice cuáles"
  teardown
}

test_sync_leave_falla_con_una_rama_que_no_esta_en_el_remoto() {
  sandbox >/dev/null
  _dos_maquinas
  git -C "$CRUX_PROJECTS_DIR/alfa/app" switch -q -c solo-aqui
  git -C "$CRUX_PROJECTS_DIR/alfa/app" commit -q --allow-empty -m "local"
  git -C "$CRUX_PROJECTS_DIR/alfa/app" switch -q main

  local out
  out="$(crux sync --leave 2>&1)"

  assert_contains "$out" "solo-aqui no está en ningún remoto" "la rama local sale por su nombre"
  teardown
}

test_sync_leave_no_bloquea_por_ramas_fusionadas() {
  sandbox >/dev/null
  _dos_maquinas
  local app="$CRUX_PROJECTS_DIR/alfa/app"
  # Una propuesta fusionada con squash: su rama se borró del remoto y sus
  # commits no están en la principal. Bloquear por esto sería ruido.
  git -C "$app" switch -q -c propuesta
  git -C "$app" commit -q --allow-empty -m "cambio"
  git -C "$app" push -q -u origin propuesta 2>/dev/null
  git -C "$app" switch -q main
  git -C "$app" push -q origin --delete propuesta 2>/dev/null
  git -C "$app" fetch -q --prune

  assert_exit 0 "una rama fusionada no atrapa nada" crux sync --leave
  teardown
}

test_sync_leave_pasa_si_todo_esta_subido() {
  sandbox >/dev/null
  _dos_maquinas

  local out
  out="$(crux sync --leave 2>&1)"
  assert_contains "$out" "nada atrapado" "lo dice en claro"
  assert_exit 0 "y sale bien" crux sync --leave
  teardown
}

test_sync_hook_calla_si_todo_esta_al_dia_y_no_repite() {
  sandbox >/dev/null
  _dos_maquinas
  mkdir -p "$SB/home"

  local out
  out="$(HOME="$SB/home" crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "sin novedades no mete nada en el contexto"

  _trabajo_en_la_otra hecho-alli
  out="$(HOME="$SB/home" crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "dentro del intervalo no vuelve a sincronizar"

  out="$(HOME="$SB/home" CRUX_SYNC_EVERY_MIN=0 crux sync --hook < /dev/null 2>&1)"
  assert_contains "$out" "1 commit nuevo" "pasado el intervalo trae lo nuevo y lo cuenta"
  teardown
}

test_hooks_install_engancha_la_sincronizacion() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  ( cd "$SB" && crux hooks install ) >/dev/null 2>&1

  assert_contains "$(cat "$CLAUDE_SETTINGS")" "session-sync.sh" "install engancha el hook de inicio de sesión"
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "SessionStart" "en el evento de inicio"
  ( cd "$SB" && crux hooks remove ) >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "session-sync" "y remove lo retira"
  teardown
}

test_sync_hook_no_repite_un_remoto_que_ya_no_existe() {
  sandbox >/dev/null
  _dos_maquinas
  mkdir -p "$SB/home" "$CRUX_PROJECTS_DIR/beta"
  git init -q "$CRUX_PROJECTS_DIR/beta/huerfano"
  git -C "$CRUX_PROJECTS_DIR/beta/huerfano" remote add origin "$SB/no-existe.git"

  local out
  out="$(HOME="$SB/home" crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "un remoto borrado no se anuncia en cada sesión"
  out="$(crux sync 2>&1)"
  assert_contains "$out" "beta/huerfano" "pero a mano sí se lista"
  teardown
}

test_sync_no_trae_proyectos_que_la_maquina_no_tiene() {
  sandbox >/dev/null
  _dos_maquinas
  # Un gh con sesión que anuncia un proyecto con contrato. Cada máquina tiene
  # los suyos: sync pone al día lo que hay, no clona lo que no está.
  _maquina_lista
  _gh_falso "otro-docs" "otro"

  crux sync >/dev/null 2>&1
  assert_no_file "$CRUX_PROJECTS_DIR/otro" "un proyecto del remoto que no está aquí se queda fuera"
  teardown
}
