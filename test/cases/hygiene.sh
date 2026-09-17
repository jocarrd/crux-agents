#!/usr/bin/env bash

_proyecto_higiene() {
  local root="$CRUX_PROJECTS_DIR/proj"
  mkdir -p "$root/app" "$root/proj-docs"
  git -C "$root/app" init -q
  echo x > "$root/app/f.txt"
  git -C "$root/app" add -A
  git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/proj-docs/crux.json"
  echo "$root"
}

test_el_registro_se_repara_solo_si_no_queda_ni_carpeta_ni_rama() {
  sandbox >/dev/null
  local root; root="$(_proyecto_higiene)"
  bash "$CRUX_HOME/bin/workspace.sh" new borrado --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new con-rama --repo "$root/app" >/dev/null 2>&1

  # Lo que hacían las sesiones para liberar disco: por fuera de crux.
  git -C "$root/app" worktree remove --force "$root/app-ws-borrado" >/dev/null 2>&1
  git -C "$root/app" branch -D ws/borrado >/dev/null 2>&1
  git -C "$root/app" worktree remove --force "$root/app-ws-con-rama" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" heal 2>&1)"
  assert_contains "$out" "'borrado' retirado del registro" "sin carpeta ni rama, la entrada sobra"
  assert_contains "$out" "su rama ws/con-rama sigue viva" "con la rama viva puede haber trabajo: se avisa"
  assert_not_contains "$(cat "$CRUX_REGISTRY")" '"borrado"' "la entrada desaparece"
  assert_contains "$(cat "$CRUX_REGISTRY")" '"con-rama"' "la otra se queda"

  # Y no hace falta acordarse: abrir un espacio nuevo ya repara.
  git -C "$root/app" branch -D ws/con-rama >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new otro --repo "$root/app" >/dev/null 2>&1
  assert_not_contains "$(cat "$CRUX_REGISTRY")" '"con-rama"' "workspace new repara el registro sin pedirlo"
}

test_adopt_registra_un_worktree_hecho_a_mano() {
  sandbox >/dev/null
  local root; root="$(_proyecto_higiene)"
  git -C "$root/app" worktree add -q -b fix/a-mano "$root/app-ws-a-mano" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" adopt "$root/app-ws-a-mano" 2>&1)"
  assert_contains "$out" "'a-mano' adoptado (fix/a-mano" "lo registra con su rama"
  assert_contains "$(cat "$CRUX_REGISTRY")" '"path": "'"$root"'/app-ws-a-mano"' "entra en el registro"
  assert_file "$SB/tasks/proj/a-mano.md" "y abre su tarea"

  assert_exit 1 "no se adopta dos veces" bash "$CRUX_HOME/bin/workspace.sh" adopt "$root/app-ws-a-mano"
  mkdir -p "$root/suelto"
  assert_exit 1 "ni algo que no es un worktree" bash "$CRUX_HOME/bin/workspace.sh" adopt "$root/suelto"
}

test_status_avisa_de_worktrees_desconocidos_y_espacios_ya_fusionados() {
  sandbox >/dev/null
  local root; root="$(_proyecto_higiene)"
  git -C "$root/app" worktree add -q -b fix/suelto "$root/app-ws-suelto" >/dev/null 2>&1

  # Un espacio cuya rama tuvo remoto y ya no lo tiene: fusionada y borrada.
  git init -q --bare "$SB/remoto.git"
  git -C "$root/app" remote add origin "$SB/remoto.git"
  bash "$CRUX_HOME/bin/workspace.sh" new hecho --repo "$root/app" >/dev/null 2>&1
  git -C "$root/app-ws-hecho" push -q -u origin ws/hecho >/dev/null 2>&1
  git -C "$root/app" push -q origin --delete ws/hecho >/dev/null 2>&1
  git -C "$root/app" fetch -q --prune origin >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/status.sh" 2>&1)"
  assert_contains "$out" "app-ws-suelto es un worktree que crux no conoce" "status enseña el worktree hecho a mano"
  assert_contains "$out" "crux workspace adopt" "con cómo registrarlo"
  assert_contains "$out" "'hecho': su rama ya no está en el remoto" "y el espacio que ya se fusionó"
}

test_el_guardia_para_el_borrado_a_mano_de_un_espacio_registrado() {
  sandbox >/dev/null
  local root; root="$(_proyecto_higiene)"
  bash "$CRUX_HOME/bin/workspace.sh" new guardado --repo "$root/app" >/dev/null 2>&1
  local hook="$CRUX_HOME/adapters/claude/hooks/worktree-guard.sh"
  _pide() { printf '{"tool_input":{"command":%s}}' "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" 2>&1; }

  local out; out="$(_pide "git worktree remove --force $root/app-ws-guardado")"
  assert_contains "$out" "crux workspace rm guardado" "para el atajo y dice qué usar"
  assert_exit 2 "sale con 2, que es lo que bloquea la herramienta" \
    bash -c "printf '{\"tool_input\":{\"command\":\"rm -rf $root/app-ws-guardado\"}}' | bash $hook"
  assert_eq "" "$(_pide "rm -rf $root/app-ws-guardado/node_modules")" "borrar algo dentro del espacio se deja"
  assert_eq "" "$(_pide "rm -rf $root/app-ws-guardado-otro")" "un nombre parecido no es el espacio"
  assert_eq "" "$(_pide "git worktree list")" "ni un comando que no borra"
}

test_hooks_install_engancha_el_guardia_solo_para_bash() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  bash "$CRUX_HOME/bin/hooks.sh" install >/dev/null 2>&1
  local pre; pre="$(node -e 'const s=require(process.argv[1]); console.log(JSON.stringify(s.hooks.PreToolUse||[]))' "$CLAUDE_SETTINGS")"
  assert_contains "$pre" "worktree-guard.sh" "install engancha el guardia"
  assert_contains "$pre" '"matcher":"Bash"' "solo sobre los comandos de shell"
  bash "$CRUX_HOME/bin/hooks.sh" remove >/dev/null 2>&1
  assert_not_contains "$(cat "$CLAUDE_SETTINGS")" "worktree-guard" "y remove lo retira"
}
