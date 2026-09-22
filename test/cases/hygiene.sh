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

test_el_guardia_cubre_las_otras_formas_de_llevarse_un_espacio() {
  # La forma canonica estaba cubierta; el resto pasaba de largo. Y al reves:
  # bloqueaba comandos que solo mencionaban las palabras en un comentario.
  sandbox >/dev/null
  local root; root="$(_proyecto_higiene)"
  bash "$CRUX_HOME/bin/workspace.sh" new variantes --repo "$root/app" >/dev/null 2>&1
  local hook="$CRUX_HOME/adapters/claude/hooks/worktree-guard.sh"
  local ws="$root/app-ws-variantes"
  _corta() {
    printf '{"tool_input":{"command":%s}}' \
      "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$1")" | bash "$hook" >/dev/null 2>&1
    echo $?
  }

  assert_eq "2" "$(_corta "rm --recursive --force $ws")" "con las banderas largas"
  assert_eq "2" "$(_corta "rm -f -r $ws")" "con las banderas separadas"
  assert_eq "2" "$(_corta "find $ws -delete")" "con find -delete"
  assert_eq "2" "$(_corta "find $ws -type f -exec rm {} ;")" "con find -exec rm"

  assert_eq "0" "$(_corta "echo listo  # ojo con rm -rf $ws")" "la ruta en un comentario no cuenta"
  assert_eq "0" "$(_corta "grep -n 'worktree remove' $ws/notas.md")" "ni mencionar las palabras"
  assert_eq "0" "$(_corta "cd $ws && rm -rf node_modules")" "ni nombrarla antes de borrar otra cosa"
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

test_hooks_install_desde_un_espacio_engancha_el_checkout_principal() {
  sandbox >/dev/null
  echo '{}' > "$CLAUDE_SETTINGS"
  local kernel="$SB/kernel" ws="$SB/kernel-ws-tarea"
  mkdir -p "$kernel"
  cp -r "$CRUX_HOME/bin" "$CRUX_HOME/lib" "$CRUX_HOME/adapters" "$kernel/"
  git -C "$kernel" init -q
  git -C "$kernel" add -A
  git -C "$kernel" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$kernel" worktree add -q "$ws" -b tarea

  local out; out="$(cd "$SB" && CRUX_HOME="$ws" bash "$ws/bin/hooks.sh" install 2>&1)"
  local ajustes; ajustes="$(cat "$CLAUDE_SETTINGS")"
  assert_contains "$ajustes" "$kernel/adapters/claude/hooks/doc-sync.sh" "engancha el checkout principal"
  assert_not_contains "$ajustes" "$ws/" "y nada del espacio, que se borra al cerrarlo"
  assert_contains "$out" "checkout principal" "y avisa del cambio"

  echo '{}' > "$CLAUDE_SETTINGS"
  ( cd "$SB" && CRUX_HOME="$kernel" bash "$kernel/bin/hooks.sh" install >/dev/null 2>&1 )
  assert_contains "$(cat "$CLAUDE_SETTINGS")" "$kernel/adapters" "desde el principal, el principal"
}

test_el_registro_no_dice_ok_si_no_pudo_escribirse() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/solectura"
  mkdir -p "$root/app" "$root/solectura-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"solectura","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/solectura-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new ro --repo "$root/app" >/dev/null 2>&1

  # El directorio, no el fichero: escribir es crear un temporal y renombrarlo,
  # y para eso basta con poder escribir en el directorio.
  chmod 500 "$(dirname "$CRUX_REGISTRY")"
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm ro 2>&1)" || rc=$?
  chmod 700 "$(dirname "$CRUX_REGISTRY")"

  assert_eq "1" "$rc" "sale en rojo si no pudo retirar la entrada"
  assert_not_contains "$out" "slot liberado" "y no dice que libero el slot"
  # El punto exacto donde falla depende de si pudo coger el cerrojo antes; lo
  # que garantiza el cambio es que no se anuncia como hecho algo que no lo esta.
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "su entrada sigue en el registro" \
    "y hay un mensaje que lo dice cuando el fallo es al retirar la entrada"
}

test_el_registro_se_escribe_de_una_pieza() {
  sandbox >/dev/null
  local reg="$SB/registry.json"
  source "$CRUX_HOME/lib/registry.sh"
  # Las lee registry_init al cargarse la libreria.
  # shellcheck disable=SC2034
  REGISTRY="$reg"
  # shellcheck disable=SC2034
  LOCK="$SB/.lock"
  registry_init
  assert_file "$reg" "registry_init lo crea"
  assert_contains "$(cat "$CRUX_HOME/lib/registry.sh")" "renameSync" \
    "se escribe a temporal y se renombra, no encima"
  assert_contains "$(cat "$CRUX_HOME/lib/registry.sh")" "registro ilegible" \
    "y un registro roto se dice en vez de pasar por vacio"
}

test_una_clave_de_staging_no_viaja_en_la_linea_de_comandos() {
  sandbox >/dev/null
  local stg; stg="$(cat "$CRUX_HOME/bin/stg.sh")"
  assert_not_contains "$stg" "hash-password --plaintext" \
    "la clave no va como argumento, que sudo deja escrito en auth.log"
  assert_contains "$stg" "docker exec -i" "entra por la entrada estandar"
}

test_una_skill_del_proyecto_no_reemplaza_la_del_kernel() {
  sandbox >/dev/null
  local mat; mat="$(cat "$CRUX_HOME/adapters/claude/materialize.sh")"
  assert_contains "$mat" "ya la trae el kernel" "se avisa en vez de reemplazar"
  assert_not_contains "$mat" 'ln -sfn "$src" "$CLAUDE_SKILLS_DIR/$name"' \
    "el enlace ya no se fuerza a ciegas"
}

test_check_secrets_ve_una_contrasena_en_una_asignacion() {
  sandbox >/dev/null
  local d="$SB/docs"; mkdir -p "$d"
  printf '# Notas\n\nDB_PASSWORD=Ab3xKq91zzTT\n' > "$d/notas.md"
  local out; out="$(node "$CRUX_HOME/lib/check-secrets.mjs" "$d" 2>&1 || true)"
  assert_contains "$out" "notas.md" "la forma CLAVE=valor ya no se descarta por el ="

  printf '# Notas\n\nDB_PASSWORD=changeme\nPORT=3000\n' > "$d/notas.md"
  local limpio; limpio="$(node "$CRUX_HOME/lib/check-secrets.mjs" "$d" 2>&1 || true)"
  assert_not_contains "$limpio" "notas.md" "y un valor de ejemplo no grita"
}

test_el_registro_de_tarea_no_pierde_lo_que_no_escribio_crux() {
  sandbox >/dev/null
  local f="$SB/t.md"
  cat > "$f" <<'MD'
---
task: t
project: p
status: open
owner-name: Jorge
---

Un parrafo de contexto.

## Desviaciones y decisiones

- El ejemplo es:

```markdown
## Cabecera de ejemplo
texto
```

- Y por eso X.
MD
  node "$CRUX_HOME/lib/task.mjs" note --file "$f" --text "decision nueva" >/dev/null 2>&1
  local tras; tras="$(cat "$f")"
  assert_contains "$tras" "owner-name: Jorge" "una clave de cabecera con guion sobrevive"
  assert_contains "$tras" "Un parrafo de contexto." "y lo escrito antes de la primera seccion"
  assert_contains "$tras" "- Y por eso X." "lo que iba tras el bloque de codigo sigue en su sitio"
  local lineas; lineas="$(grep -n 'decision nueva' "$f" | cut -d: -f1)"
  local cierre; cierre="$(grep -n '^```$' "$f" | tail -1 | cut -d: -f1)"
  [[ "$lineas" -gt "$cierre" ]] && PASS=$((PASS + 1)) \
    || _fail "la nota nueva va fuera del bloque de codigo"
}

test_la_puerta_ensena_los_comandos_del_contrato_la_primera_vez() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/puerta"
  mkdir -p "$root/app" "$root/puerta-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"puerta","profile":"multi-repo","repos":["app"],"quality":{"gate":["echo comprobando"]},"sections":[]}\n' \
    > "$root/puerta-docs/crux.json"

  local out
  out="$(cd "$root/app" && CRUX_GATE_ASSUME_YES=1 bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)" || true
  assert_contains "$out" "declarada en el contrato" "la primera vez los enseña"
  assert_contains "$out" "echo comprobando" "con el comando delante"

  # La segunda vez, con la misma huella, no vuelve a interrumpir.
  local otra
  otra="$(cd "$root/app" && CRUX_GATE_ASSUME_YES=1 bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)" || true
  assert_not_contains "$otra" "declarada en el contrato" "la segunda vez no molesta"

  # Y si cambian, lo dice.
  printf '{"crux":"0.1.0","project":"puerta","profile":"multi-repo","repos":["app"],"quality":{"gate":["echo otra cosa"]},"sections":[]}\n' \
    > "$root/puerta-docs/crux.json"
  local cambiada
  cambiada="$(cd "$root/app" && CRUX_GATE_ASSUME_YES=1 bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)" || true
  assert_contains "$cambiada" "ha cambiado desde la ultima vez" "cuando cambia, avisa"
}
