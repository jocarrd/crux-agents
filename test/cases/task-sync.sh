#!/usr/bin/env bash

# Las tareas viajan entre máquinas en la rama crux/tasks del docs repo. Aquí
# las dos máquinas son dos raíces de proyectos con su propio estado, clonadas
# del mismo remoto local. Ver ADR-016.

_tareas_dos_maquinas() {
  git init -q --bare -b main "$SB/docs.git"
  git clone -q "$SB/docs.git" "$SB/semilla" 2>/dev/null
  git -C "$SB/semilla" commit -q --allow-empty -m "docs"
  git -C "$SB/semilla" push -q origin main
  local m
  for m in A B; do
    mkdir -p "$SB/$m/P/alfa"
    git clone -q "$SB/docs.git" "$SB/$m/P/alfa/alfa-docs" 2>/dev/null
  done
  mkdir -p "$SB/bin"
  printf '#!/bin/sh\nexit 1\n' > "$SB/bin/gh"
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

# en <máquina> <comando...> — el comando con el entorno de esa máquina.
en() {
  local m="$1"; shift
  CRUX_PROJECTS_DIR="$SB/$m/P" CRUX_TASKS_DIR="$SB/$m/tasks" CRUX_STATE_DIR="$SB/$m/state" \
    CRUX_REGISTRY="$SB/$m/registry.json" "$@"
}

motor() { local m="$1"; shift; en "$m" node "$CRUX_HOME/lib/task.mjs" "$@"; }
replica() { en "$1" node "$CRUX_HOME/lib/task-sync.mjs" sync --all; }
registro() { echo "$SB/$1/tasks/alfa/$2.md"; }

_nueva_tarea() {
  # _nueva_tarea <máquina> <tarea> <siguiente paso>
  motor "$1" ensure --file "$(registro "$1" "$2")" --task "$2" --project alfa --repo app --workspace "$2" >/dev/null
  motor "$1" set --file "$(registro "$1" "$2")" --section "Siguiente paso" --text "$3"
}

test_tareas_la_creada_en_una_maquina_llega_a_la_otra() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"

  replica A >/dev/null
  replica B >/dev/null

  assert_file "$(registro B t1)" "la tarea llega"
  assert_contains "$(cat "$(registro B t1)")" "hacer X" "con su siguiente paso"
  assert_eq "" "$(git -C "$SB/A/P/alfa/alfa-docs" status --porcelain)" "el docs repo queda limpio"
  assert_eq 1 "$(git -C "$SB/A/P/alfa/alfa-docs" rev-list --count main)" "y main no recibe ningún commit"
  assert_contains "$(git -C "$SB/semilla" ls-remote origin)" "refs/heads/crux/tasks" "viaja en su propia rama"
  teardown
}

test_tareas_un_cambio_en_la_otra_maquina_vuelve() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  replica A >/dev/null; replica B >/dev/null

  motor B set --file "$(registro B t1)" --section "Siguiente paso" --text "hacer Y"
  replica B >/dev/null
  replica A >/dev/null

  assert_contains "$(cat "$(registro A t1)")" "hacer Y" "lo cambiado en B llega a A"
  assert_no_file "$SB/A/tasks/alfa/t1.conflicto-remota.md" "sin conflicto: solo cambió en un sitio"
  teardown
}

test_tareas_si_cambia_en_las_dos_gana_la_reciente_y_la_otra_se_guarda() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "base"
  replica A >/dev/null; replica B >/dev/null

  motor B set --file "$(registro B t1)" --section "Siguiente paso" --text "version de B"
  replica B >/dev/null
  motor A set --file "$(registro A t1)" --section "Siguiente paso" --text "version de A"
  # A es la más reciente: el reloj de minutos empataría.
  sed -i 's/^updated: .*/updated: 2099-01-01T00:00/' "$(registro A t1)"

  local out
  out="$(replica A)"
  assert_contains "$(cat "$(registro A t1)")" "version de A" "se queda la más reciente"
  assert_contains "$(cat "$SB"/A/tasks/alfa/t1.conflicto-*.md 2>/dev/null)" "version de B" "la otra se guarda al lado"
  assert_contains "$out" "cambió en las dos" "y se avisa"

  replica B >/dev/null
  assert_contains "$(cat "$(registro B t1)")" "version de A" "la otra máquina acaba con la misma"
  teardown
}

test_tareas_archivar_en_una_retira_la_abierta_en_la_otra() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  replica A >/dev/null; replica B >/dev/null

  motor A archive --file "$(registro A t1)" >/dev/null
  replica A >/dev/null
  replica B >/dev/null

  assert_no_file "$(registro B t1)" "la abierta desaparece en B"
  assert_eq 1 "$(find "$SB/B/tasks/alfa/done" -name '*-t1.md' | wc -l | tr -d ' ')" "y llega la archivada"
  replica A >/dev/null
  assert_no_file "$(registro A t1)" "y B no se la devuelve a A como abierta"
  teardown
}

test_tareas_se_publican_solas_al_escribirlas() {
  sandbox >/dev/null
  _tareas_dos_maquinas

  CRUX_TASK_SYNC=1 _nueva_tarea A t1 "hacer X"
  local _
  for _ in $(seq 1 50); do
    git -C "$SB/semilla" ls-remote origin refs/heads/crux/tasks | grep -q . && break
    sleep 0.2
  done
  git -C "$SB/semilla" fetch -q origin crux/tasks 2>/dev/null
  assert_contains "$(git -C "$SB/semilla" show FETCH_HEAD:t1.md 2>/dev/null)" "t1" \
    "sin que nadie lance nada, la tarea está en el remoto"
  teardown
}

test_tareas_sin_red_quedan_pendientes_y_leave_lo_dice() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  mv "$SB/docs.git" "$SB/docs-lejos.git"

  replica A >/dev/null
  assert_contains "$(en A node "$CRUX_HOME/lib/task-sync.mjs" pending)" "alfa" "queda marcada como pendiente"
  local out rc
  out="$(en A crux sync --leave 2>&1)"; rc=$?
  assert_contains "$out" "tareas sin publicar" "--leave la cuenta como atrapada"
  assert_eq 1 "$rc" "y no deja irse"

  mv "$SB/docs-lejos.git" "$SB/docs.git"
  replica A >/dev/null
  assert_eq "" "$(en A node "$CRUX_HOME/lib/task-sync.mjs" pending)" "con red, se publica y deja de estar pendiente"
  teardown
}

test_tareas_un_proyecto_puede_quedarse_fuera() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  echo '{"tasks":{"sync":false}}' > "$SB/A/P/alfa/alfa-docs/crux.json"
  _nueva_tarea A t1 "hacer X"

  replica A >/dev/null
  assert_not_contains "$(git -C "$SB/semilla" ls-remote origin)" "crux/tasks" "con tasks.sync false no se publica nada"
  teardown
}

test_tareas_dos_maquinas_publicando_a_la_vez_no_pierden_nada() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A de-a "a"
  _nueva_tarea B de-b "b"

  replica A >/dev/null & replica B >/dev/null & wait
  replica A >/dev/null; replica B >/dev/null

  assert_file "$(registro A de-b)" "A tiene la de B"
  assert_file "$(registro B de-a)" "B tiene la de A"
  teardown
}

test_tareas_crux_sync_las_trae_al_llegar() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  replica A >/dev/null

  local out
  out="$(en B crux sync 2>&1)"
  assert_contains "$out" "alfa: 1 tarea traída" "lo cuenta"
  assert_file "$(registro B t1)" "y la trae"
  teardown
}

test_tareas_el_recordatorio_informa_sin_empujar() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea B t1 "hacer X"
  _nueva_tarea B hecha "nada"
  motor B status --file "$(registro B hecha)" --to merged

  local out
  out="$(en B node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/B/P/alfa/alfa-docs")"
  assert_contains "$out" "alfa/t1" "enseña la abierta"
  assert_not_contains "$out" "alfa/hecha" "no la que ya está fusionada"
  assert_contains "$out" "por si quieres retomar alguna" "a la persona se le ofrece"
  assert_contains "$out" "No retomes ninguna" "y al agente se le dice que no empuje"
  assert_contains "$out" "crux workspace resume t1" "con cómo retomarla aquí"

  assert_eq "" "$(en A node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/A/P")" "sin tareas, no dice nada"
  teardown
}

test_tareas_el_hook_de_inicio_las_ensena_y_calla_al_compactar() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  local hook="$CRUX_HOME/adapters/claude/hooks/session-sync.sh" out

  out="$(printf '{"source":"startup","session_id":"s1","cwd":"%s"}' "$SB/A/P/alfa" \
    | en A env HOME="$SB" bash "$hook")"
  assert_contains "$out" '"systemMessage"' "la persona lo ve directamente"
  assert_contains "$out" "alfa/t1" "con la tarea"
  assert_contains "$out" '"additionalContext"' "y el agente sabe que ya se le enseñó"

  out="$(printf '{"source":"compact","session_id":"s1","cwd":"%s"}' "$SB/A/P/alfa" \
    | en A env HOME="$SB" bash "$hook")"
  assert_eq "" "$out" "al compactar no interrumpe"
  teardown
}

test_tareas_volver_a_una_sesion_parada_las_recuerda_una_vez() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  local hook="$CRUX_HOME/adapters/claude/hooks/session-idle.sh" out
  local msg
  msg="$(printf '{"session_id":"s2","cwd":"%s"}' "$SB/A/P/alfa")"

  out="$(printf '%s' "$msg" | en A env HOME="$SB" bash "$hook")"
  assert_eq "" "$out" "el primer mensaje no dice nada: ya habló el inicio de sesión"

  touch -d "5 hours ago" "$SB/A/state/sesiones/s2"
  out="$(printf '%s' "$msg" | en A env HOME="$SB" bash "$hook")"
  assert_contains "$out" "Vuelves a esta sesión" "tras horas parada, lo dice"
  assert_contains "$out" "alfa/t1" "y recuerda la tarea"

  out="$(printf '%s' "$msg" | en A env HOME="$SB" bash "$hook")"
  assert_eq "" "$out" "el mensaje siguiente ya no repite"
  teardown
}

test_tareas_resume_abre_el_espacio_con_la_rama_y_la_tarea_de_la_otra_maquina() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  git init -q --bare -b main "$SB/app.git"
  git clone -q "$SB/app.git" "$SB/semilla-app" 2>/dev/null
  git -C "$SB/semilla-app" commit -q --allow-empty -m "app"
  git -C "$SB/semilla-app" push -q origin main
  local m
  for m in A B; do git clone -q "$SB/app.git" "$SB/$m/P/alfa/app" 2>/dev/null; done

  # En A: el espacio, un commit en su rama, subido, y el siguiente paso anotado.
  ( cd "$SB/A/P/alfa/app" && en A crux workspace new t2 ) >/dev/null 2>&1
  local ws="$SB/A/P/alfa/app-ws-t2"
  echo "a medias" > "$ws/fichero"
  git -C "$ws" add fichero && git -C "$ws" commit -q -m "wip"
  git -C "$ws" push -q -u origin HEAD 2>/dev/null
  motor A set --file "$(registro A t2)" --section "Siguiente paso" --text "seguir con el fichero"
  replica A >/dev/null

  # En B: traer las tareas y retomarla.
  replica B >/dev/null
  local out
  out="$(en B crux workspace resume t2 2>&1)"
  assert_file "$SB/B/P/alfa/app-ws-t2/fichero" "el espacio llega con el trabajo de la rama"
  assert_contains "$out" "seguir con el fichero" "y enseña el siguiente paso"
  assert_contains "$(cat "$(registro B t2)")" "seguir con el fichero" "la tarea no empieza vacía"
  assert_eq 1 "$(grep -c 'app=' "$(registro B t2)")" "la rama queda anotada una sola vez"
  teardown
}

test_tareas_resume_dice_que_hacer_si_la_tarea_no_esta() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  local out rc
  out="$(en B crux workspace resume no-existe 2>&1)"; rc=$?
  assert_eq 1 "$rc" "falla"
  assert_contains "$out" "crux sync" "y dice que traiga las tareas"
  teardown
}

test_tareas_reutilizar_el_nombre_de_una_archivada_no_la_borra() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A release "la vieja"
  sed -i 's/^created: .*/created: 2026-01-01T10:00/' "$(registro A release)"
  replica A >/dev/null; replica B >/dev/null
  motor A archive --file "$(registro A release)" >/dev/null
  replica A >/dev/null; replica B >/dev/null

  # Meses después, otra tarea con el mismo nombre.
  _nueva_tarea B release "la nueva"
  replica B >/dev/null; replica A >/dev/null
  assert_file "$(registro A release)" "la nueva llega a la otra máquina"
  assert_file "$(registro B release)" "y sigue viva donde nació"
  assert_contains "$(cat "$(registro A release)")" "la nueva" "y es la nueva, no la vieja"
  teardown
}

test_tareas_publican_con_firma_obligatoria_y_un_pre_push_que_falla() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  local docs="$SB/A/P/alfa/alfa-docs"
  git -C "$docs" config commit.gpgSign true
  git -C "$docs" config gpg.program false
  printf '#!/bin/sh\nexit 1\n' > "$docs/.git/hooks/pre-push"
  chmod +x "$docs/.git/hooks/pre-push"
  _nueva_tarea A t1 "hacer X"

  replica A >/dev/null
  assert_contains "$(git -C "$SB/semilla" ls-remote origin)" "crux/tasks" \
    "la rama interna se publica aunque el repo exija firma y su pre-push lo rechace todo"
  teardown
}

test_tareas_sin_remoto_leave_avisa_de_que_se_quedan() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  git -C "$SB/A/P/alfa/alfa-docs" remote remove origin
  _nueva_tarea A t1 "hacer X"

  local out
  out="$(en A crux sync --leave 2>&1)"
  assert_contains "$out" "las tareas se quedan en esta máquina" "lo dice"
  teardown
}

test_tareas_el_recordatorio_menciona_los_conflictos_pendientes() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "hacer X"
  echo "copia" > "$SB/A/tasks/alfa/t1.conflicto-remota.md"

  assert_contains "$(en A node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/A/P/alfa")" \
    "copia de un conflicto" "no se quedan olvidadas"
  teardown
}

test_tareas_las_ya_fusionadas_se_cierran_solas_y_no_se_recuerdan() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  # Un gh que dice que cualquier propuesta está fusionada.
  printf '#!/bin/sh\n[ "$1 $2" = "pr view" ] && echo MERGED && exit 0\nexit 1\n' > "$SB/bin/gh"
  _nueva_tarea A vieja "nada"
  motor A meta --file "$(registro A vieja)" --key pr --value "https://github.com/o/r/pull/1"
  motor A status --file "$(registro A vieja)" --to proposed

  local out
  out="$(en A crux sync 2>&1)"
  assert_contains "$out" "ya estaba fusionada" "lo cuenta"
  assert_no_file "$(registro A vieja)" "sin espacio aquí, se archiva"
  assert_eq "" "$(en A node "$CRUX_HOME/lib/task-sync.mjs" remind --cwd "$SB/A/P/alfa")" "y el recordatorio ya no la saca"

  replica B >/dev/null
  assert_no_file "$(registro B vieja)" "a la otra máquina no llega como abierta"
  teardown
}

test_tareas_no_se_publican_en_un_repo_publico() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  # El remoto parece de GitHub y gh dice que es público.
  local docs="$SB/A/P/alfa/alfa-docs"
  git -C "$docs" remote set-url origin "git@github.com:o/alfa-docs.git"
  git -C "$docs" config "url.$SB/docs.git.insteadOf" "git@github.com:o/alfa-docs.git"
  printf '#!/bin/sh\n[ "$1 $2" = "repo view" ] && echo PUBLIC && exit 0\nexit 1\n' > "$SB/bin/gh"
  _nueva_tarea A t1 "nota privada"

  local out
  out="$(en A crux sync --leave 2>&1)"
  assert_not_contains "$(git -C "$SB/semilla" ls-remote origin)" "crux/tasks" "no se publica nada"
  assert_contains "$out" "su repo es público" "y se dice por qué se quedan aquí"

  echo '{"tasks":{"sync":true}}' > "$docs/crux.json"
  replica A >/dev/null
  assert_contains "$(git -C "$SB/semilla" ls-remote origin)" "crux/tasks" "declarado en el contrato, sí"
  teardown
}

test_tareas_la_reciclada_en_el_mismo_minuto_sobrevive() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  _nueva_tarea A t1 "la vieja"
  replica A >/dev/null; replica B >/dev/null
  motor A archive --file "$(registro A t1)" >/dev/null
  replica A >/dev/null
  sleep 1
  _nueva_tarea A t1 "la nueva"
  replica A >/dev/null; replica B >/dev/null
  assert_contains "$(cat "$(registro B t1)" 2>/dev/null)" "la nueva" "una tarea nueva con el nombre de una recién archivada no se borra"
  teardown
}

test_tareas_la_fusionada_en_la_otra_maquina_se_reconcilia_al_llegar() {
  sandbox >/dev/null
  _tareas_dos_maquinas
  printf '#!/bin/sh\n[ "$1 $2" = "pr view" ] && echo MERGED && exit 0\nexit 1\n' > "$SB/bin/gh"
  _nueva_tarea A t1 "x"
  replica A >/dev/null; replica B >/dev/null
  # A la propone; B aún no lo sabe.
  motor A meta --file "$(registro A t1)" --key pr --value "https://github.com/o/r/pull/2"
  motor A status --file "$(registro A t1)" --to proposed
  replica A >/dev/null

  en B crux sync >/dev/null 2>&1
  assert_no_file "$(registro B t1)" "B la trae, ve que está fusionada y la archiva en la misma ronda"
  teardown
}
