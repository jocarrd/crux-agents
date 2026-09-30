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
  export CRUX_STATE_DIR="$SB/estado"
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

test_sync_leave_ve_un_remoto_que_ya_no_existe() {
  sandbox >/dev/null
  _dos_maquinas
  # Con el remoto borrado, las referencias locales dicen que todo está subido.
  mv "$SB/remoto.git" "$SB/remoto-borrado.git"

  local out rc
  out="$(crux sync --leave 2>&1)"; rc=$?
  assert_contains "$out" "su remoto ya no existe" "lo dice"
  assert_eq 1 "$rc" "y no deja irse creyendo que está a salvo"
  teardown
}

test_sync_leave_ve_commits_con_head_separado() {
  sandbox >/dev/null
  _dos_maquinas
  git -C "$CRUX_PROJECTS_DIR/alfa/app" checkout -q --detach
  git -C "$CRUX_PROJECTS_DIR/alfa/app" commit -q --allow-empty -m "fuera de toda rama"

  local out rc
  out="$(crux sync --leave 2>&1)"; rc=$?
  assert_contains "$out" "HEAD separado" "el commit suelto sale"
  assert_eq 1 "$rc" "y bloquea"
  teardown
}

test_sync_avanza_tambien_las_ramas_que_no_estan_en_uso() {
  sandbox >/dev/null
  _dos_maquinas
  git -C "$CRUX_PROJECTS_DIR/alfa/app" switch -q -c trabajo
  _trabajo_en_la_otra hecho-alli

  local out
  out="$(crux sync 2>&1)"
  assert_eq 0 "$(git -C "$CRUX_PROJECTS_DIR/alfa/app" rev-list --count main..origin/main)" \
    "main queda al día aunque se esté en otra rama"
  assert_contains "$out" "main, 1 commit nuevo" "y lo cuenta"
  teardown
}

test_sync_dos_a_la_vez_no_se_pisan() {
  sandbox >/dev/null
  _dos_maquinas
  _trabajo_en_la_otra hecho-alli
  # Otra sincronización en marcha, representada por su candado. Lanzarlas de
  # verdad en paralelo solo choca a veces, y un test que falla a veces no sirve.
  mkdir -p "$CRUX_STATE_DIR/sync.lock"

  local out
  out="$(HOME="$SB" CRUX_SYNC_EVERY_MIN=0 crux sync --hook < /dev/null 2>&1)"
  assert_eq "" "$out" "el hook no se mete si ya hay una en marcha"
  assert_no_file "$CRUX_PROJECTS_DIR/alfa/app/hecho-alli" "ni toca nada"

  ( sleep 2; rmdir "$CRUX_STATE_DIR/sync.lock" ) &
  out="$(crux sync 2>&1)"
  wait
  assert_contains "$out" "otra sincronización en marcha" "a mano, espera y lo dice"
  assert_file "$CRUX_PROJECTS_DIR/alfa/app/hecho-alli" "y al quedar libre sincroniza"
  teardown
}

test_sync_dice_si_un_contrato_no_se_puede_leer() {
  sandbox >/dev/null
  _dos_maquinas
  mkdir -p "$CRUX_PROJECTS_DIR/alfa/alfa-docs"
  printf '{"crux":"0.60.0","repos":["app","nue' > "$CRUX_PROJECTS_DIR/alfa/alfa-docs/crux.json"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "crux.json ilegible" "un contrato roto no se toma por uno sin nada que traer"
  teardown
}

test_sync_un_remoto_secundario_caido_no_deja_el_repo_sin_respuesta() {
  sandbox >/dev/null
  _dos_maquinas
  git -C "$CRUX_PROJECTS_DIR/alfa/app" remote add viejo "$SB/no-existe.git"
  _trabajo_en_la_otra hecho-alli

  local out
  out="$(crux sync 2>&1)"
  assert_not_contains "$out" "sin respuesta" "origin respondió: el repo está al día"
  assert_file "$CRUX_PROJECTS_DIR/alfa/app/hecho-alli" "y avanza"
  teardown
}

test_sync_dice_por_que_no_puede_avanzar() {
  sandbox >/dev/null
  _dos_maquinas
  _trabajo_en_la_otra choca
  echo "mio" > "$CRUX_PROJECTS_DIR/alfa/app/choca"

  local out
  out="$(crux sync 2>&1)"
  assert_contains "$out" "choca con uno que llega" "nombra la causa"
  assert_eq "mio" "$(cat "$CRUX_PROJECTS_DIR/alfa/app/choca")" "y no pisa el fichero de aquí"
  teardown
}
