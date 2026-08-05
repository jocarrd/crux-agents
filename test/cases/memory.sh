#!/usr/bin/env bash

# Escribe una memoria del agente en el sandbox y devuelve su ruta.
#   memoria <ámbito> <nombre> [tipo]   — sin tipo, la deja sin declarar
memoria() {
  local ambito="$1" nombre="$2" tipo="${3:-}" dir
  dir="$CLAUDE_CONFIG_DIR/projects/$ambito/memory"
  mkdir -p "$dir"
  {
    echo "---"
    echo "name: $nombre"
    echo "description: memoria de prueba"
    if [[ -n "$tipo" ]]; then
      echo "metadata:"
      echo "  type: $tipo"
    fi
    echo "---"
    echo
    echo "cuerpo"
  } > "$dir/$nombre.md"
  echo "$dir/$nombre.md"
}

# El ámbito con el que un agente nombra un directorio de trabajo.
ambito_de() { printf '%s' "$1" | tr '/.' '-'; }

test_memory_detecta_las_de_proyecto_sin_promover() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  memoria "$(ambito_de "$CRUX_PROJECTS_DIR/alfa")" lead-comercial project >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "lead-comercial" "nombra la memoria que falta en git"
  assert_contains "$out" "alfa-docs" "dice a qué docs repo pertenece"
  assert_exit 1 "--check falla mientras quede alguna" \
    bash "$CRUX_HOME/bin/memory.sh" --check
}

test_memory_deja_en_local_lo_que_es_de_la_persona() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  local ambito; ambito="$(ambito_de "$CRUX_PROJECTS_DIR/alfa")"
  memoria "$ambito" prefiere-espanol user >/dev/null
  memoria "$ambito" sin-comentarios-narrativos feedback >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "nada sin promover" "user y feedback no son fugas"
  assert_contains "$out" "1 user" "las cuenta como locales por diseño"
  assert_exit 0 "--check pasa" bash "$CRUX_HOME/bin/memory.sh" --check
}

test_memory_no_asume_el_tipo_que_falta() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  memoria "$(ambito_de "$CRUX_PROJECTS_DIR/alfa")" sin-declarar >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "sin tipo declarado" "reporta la que no declara tipo"
  assert_contains "$out" "sin-declarar" "y la nombra"
  assert_exit 0 "no la cuenta como fuga: no se sabe si lo es" \
    bash "$CRUX_HOME/bin/memory.sh" --check
}

test_memory_para_si_una_memoria_no_se_puede_leer() {
  # Root lee cualquier fichero, así que ahí la comprobación no prueba nada.
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0

  sandbox >/dev/null
  new_project alfa >/dev/null
  local f; f="$(memoria "$(ambito_de "$CRUX_PROJECTS_DIR/alfa")" opaca project)"
  chmod 000 "$f"

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "no se pueden leer" "lo dice en vez de contarla como cero"
  assert_contains "$out" "opaca" "y señala cuál"
  assert_exit 1 "--check tampoco da por buena una lectura que falló" \
    bash "$CRUX_HOME/bin/memory.sh" --check

  chmod 644 "$f"
}

test_memory_asigna_al_proyecto_mas_especifico() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  new_project alfa-beta >/dev/null
  memoria "$(ambito_de "$CRUX_PROJECTS_DIR/alfa-beta/api")" nota-de-api project >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "alfa-beta-docs" "gana el nombre de proyecto más largo"
  assert_not_contains "$out" " alfa-docs" "y no se la lleva el que empieza igual"
}

test_memory_sin_proyecto_dice_de_donde_sale() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  memoria "$(ambito_de "$SB/otro-sitio")" apunte-suelto reference >/dev/null

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "apunte-suelto" "la reporta igual"
  assert_contains "$out" "ámbito" "y dice de qué directorio salió"
  assert_not_contains "$out" "alfa-docs" "no la coloca en un proyecto a ojo"
}

test_memory_brief_ocupa_dos_lineas_por_muchas_que_haya() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  local ambito; ambito="$(ambito_de "$CRUX_PROJECTS_DIR/alfa")"
  local i; for i in 1 2 3 4 5; do memoria "$ambito" "nota-$i" project >/dev/null; done

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" --brief 2>&1)"
  assert_eq "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "el aviso del hook no crece"
  assert_contains "$out" "+2" "dice cuántas se dejó por nombrar"
}

test_hooks_engancha_y_retira_el_guardian_de_memoria() {
  sandbox >/dev/null
  local docs; docs="$(new_project alfa)"
  export CLAUDE_SETTINGS="$SB/settings.json"
  echo '{}' > "$CLAUDE_SETTINGS"

  ( cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1 )
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "memory-guard" \
    "install engancha el guardián al cierre de sesión"

  ( cd "$docs" && bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1 )
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "memory-guard" \
    "remove lo retira"

  unset CLAUDE_SETTINGS
}

test_el_guardian_calla_cuando_no_hay_nada_que_promover() {
  sandbox >/dev/null
  new_project alfa >/dev/null
  memoria "$(ambito_de "$CRUX_PROJECTS_DIR/alfa")" prefiere-espanol user >/dev/null

  # CRUX_HOME ya viene exportado por el runner, que es como lo ve el hook real.
  local out
  out="$(bash "$CRUX_HOME/adapters/claude/hooks/memory-guard.sh" 2>&1)"
  assert_eq "" "$out" "silencioso mientras no haya fugas"
}

test_memory_avisa_si_no_hay_raiz_de_proyectos() {
  sandbox >/dev/null
  memoria "$(ambito_de "$CRUX_PROJECTS_DIR/alfa")" nota project >/dev/null
  rm -rf "$CRUX_PROJECTS_DIR"

  local out; out="$(bash "$CRUX_HOME/bin/memory.sh" 2>&1)"
  assert_contains "$out" "raíz de proyectos no existe" "no da el destino por perdido en silencio"
  assert_contains "$out" "nota" "y sigue reportando la fuga, que no depende de eso"
}
