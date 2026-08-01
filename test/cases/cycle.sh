#!/usr/bin/env bash

_repo_con_config() {
  # Crea un repo git con un docs repo hermano que declara reparto de workspace.
  local root="$CRUX_PROJECTS_DIR/proj"
  mkdir -p "$root/app" "$root/proj-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo contenido > "$root/app/f.txt"
  git -C "$root/app" add -A
  git -C "$root/app" commit -qm init
  cat > "$root/proj-docs/crux.json" <<'EOF'
{"crux":"0.1.0","project":"proj","profile":"multi-repo","repos":["app"],"sections":[],
 "workspace":{"portBase":4000,"portsPerSlot":5,"envFile":".env.local",
   "env":{"PORT":"{{PORT0}}","API_PORT":"{{PORT1}}","DATABASE_URL":"postgres://localhost/app_ws{{SLOT}}"}}}
EOF
  echo "$root"
}

test_workspace_aisla_puertos_y_base_de_datos() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new uno --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new dos --repo "$root/app" >/dev/null 2>&1

  local a b
  a="$(cat "$root/app-ws-uno/.env.local")"
  b="$(cat "$root/app-ws-dos/.env.local")"

  assert_contains "$a" "PORT=4000" "el primer espacio arranca en el puerto base"
  assert_contains "$b" "PORT=4005" "el segundo coge el siguiente rango"
  assert_contains "$a" "app_ws0" "cada espacio tiene su base de datos"
  assert_contains "$b" "app_ws1" "cada espacio tiene su base de datos"
  assert_not_contains "$b" "PORT=4000" "los rangos no se solapan"
}

test_workspace_deja_resolver_los_punteros_relativos() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new rel --repo "$root/app" >/dev/null 2>&1

  # El worktree va como hermano justamente para esto: si viviera fuera del
  # proyecto, el @-import de ../<project>-docs/ dejaría de resolver.
  assert_file "$root/app-ws-rel/../proj-docs/crux.json" \
    "el docs repo sigue siendo alcanzable en ../ desde el espacio"
}

test_workspace_no_borra_trabajo_sin_commitear() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new wip --repo "$root/app" >/dev/null 2>&1
  echo "cambio a medias" >> "$root/app-ws-wip/f.txt"

  assert_exit 1 "se niega a borrar un espacio con cambios" \
    bash "$CRUX_HOME/bin/workspace.sh" rm wip
  assert_file "$root/app-ws-wip/f.txt" "el trabajo sigue ahí"
}

test_workspace_libera_y_reutiliza_el_slot() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new a --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$root/app" >/dev/null 2>&1
  rm -f "$root/app-ws-a/.env.local"
  bash "$CRUX_HOME/bin/workspace.sh" rm a >/dev/null 2>&1

  bash "$CRUX_HOME/bin/workspace.sh" new c --repo "$root/app" >/dev/null 2>&1
  assert_contains "$(cat "$root/app-ws-c/.env.local")" "PORT=4000" \
    "el slot liberado se reutiliza en vez de crecer sin fin"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" list)"
  assert_not_contains "$out" "app-ws-a " "el espacio borrado desaparece del registro"
}

test_ship_distingue_lo_que_necesita_entorno() {
  sandbox >/dev/null
  local root; root="$(_repo_con_config)"
  cd "$root/app" || return

  mkdir -p src/components db/migrations docs
  touch src/components/Card.tsx
  git add -A
  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "runtime: sí" "un cambio de interfaz pide validación real"
  assert_contains "$out" "revisión visual" "y dice qué validar"

  git reset -q; rm -rf src
  touch docs/nota.md
  git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "runtime: no" "un cambio de documentación no lo pide"

  cd "$CRUX_HOME" || return
}

test_workspace_admite_configuracion_por_repo() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/multi"
  mkdir -p "$root/front" "$root/back" "$root/multi-docs"
  for r in front back; do
    git -C "$root/$r" init -q
    git -C "$root/$r" config user.email t@t
    git -C "$root/$r" config user.name t
    echo x > "$root/$r/f.txt"
    git -C "$root/$r" add -A
    git -C "$root/$r" commit -qm init
  done
  cat > "$root/multi-docs/crux.json" <<'JSON'
{"crux":"0.1.0","project":"multi","profile":"multi-repo","repos":["front","back"],"sections":[],
 "workspace":{"portBase":5000,"portsPerSlot":10,"envFile":".env.local",
   "env":{"COMUN":"si"},
   "repos":{
     "front":{"env":{"PORT":"{{PORT0}}","API":"http://localhost:{{PORT1}}"}},
     "back":{"env":{"PORT":"{{PORT1}}","DB":"db_{{SLOT}}"},
             "setup":"echo creada db_{{SLOT}} > $CRUX_PROJECTS_DIR/setup-ran.txt"}}}}
JSON

  bash "$CRUX_HOME/bin/workspace.sh" new f --repo "$root/front" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$root/back" >/dev/null 2>&1

  local f b
  f="$(cat "$root/front-ws-f/.env.local")"
  b="$(cat "$root/back-ws-b/.env.local")"

  assert_contains "$f" "PORT=5000" "el front recibe su puerto"
  assert_contains "$f" "API=http://localhost:5001" "y sabe dónde está el backend de su slot"
  assert_contains "$b" "PORT=5011" "el backend en otro slot no colisiona"
  assert_contains "$b" "DB=db_1" "cada slot tiene su base"
  assert_contains "$f" "COMUN=si" "las variables comunes se heredan"
  assert_not_contains "$f" "DB=" "las de otro repo no se cuelan"

  assert_file "$CRUX_PROJECTS_DIR/setup-ran.txt" "el hook de setup se ejecuta"
}

test_machine_detecta_un_hook_roto() {
  sandbox >/dev/null
  local fakehome="$SB/home"
  mkdir -p "$fakehome/.claude/skills" "$fakehome/.crux"
  echo "CRUX_HOME=\"$CRUX_HOME\"" > "$fakehome/.crux/config"
  ln -s "$CRUX_HOME/skills/end-session" "$fakehome/.claude/skills/end-session"
  cat > "$fakehome/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/ruta/que/no/existe.sh"}]}]}}
JSON

  local out; out="$(HOME="$fakehome" bash "$CRUX_HOME/bin/machine.sh" 2>&1)"
  assert_contains "$out" "apuntan a ficheros que no existen" "detecta el hook roto"

  assert_exit 1 "un hook roto es error: parece vigilado y no lo está" \
    env HOME="$fakehome" bash "$CRUX_HOME/bin/machine.sh"
}

test_machine_detecta_enlaces_de_skill_rotos() {
  sandbox >/dev/null
  local fakehome="$SB/home2"
  mkdir -p "$fakehome/.claude/skills" "$fakehome/.crux"
  echo "CRUX_HOME=\"$CRUX_HOME\"" > "$fakehome/.crux/config"
  ln -s "$SB/skill-que-se-borro" "$fakehome/.claude/skills/fantasma"

  local out; out="$(HOME="$fakehome" bash "$CRUX_HOME/bin/machine.sh" 2>&1)"
  assert_contains "$out" "enlaces de skill rotos" "detecta el enlace muerto"
}

test_usage_no_reporta_cero_como_si_fuera_un_dato() {
  sandbox >/dev/null
  local vacio="$SB/sin-transcripciones"
  mkdir -p "$vacio"

  local out
  out="$(CRUX_TRANSCRIPTS="$vacio" node "$CRUX_HOME/bin/usage.mjs" 2>&1)"
  assert_contains "$out" "Sin datos, no sin uso" "distingue ausencia de datos de ausencia de uso"
}

test_code_health_separa_lo_real_del_ruido() {
  sandbox >/dev/null
  local repo="$SB/proyecto"
  mkdir -p "$repo/src" "$repo/src/__tests__"

  # Lógica genuinamente duplicada en dos ficheros
  for n in a b; do
    cat > "$repo/src/$n.ts" <<'TS'
export function calcular(items: Item[], factor: number) {
  const filtrados = items.filter((x) => x.activo && x.valor > 0)
  const total = filtrados.reduce((acc, x) => acc + x.valor * factor, 0)
  if (total > LIMITE) {
    throw new Error('supera el limite permitido para el calculo')
  }
  return Math.round(total * 100) / 100
}
TS
  done

  # Ruido que NO debe contarse: import multilínea y catálogo de datos
  cat > "$repo/src/catalogo.ts" <<'TS'
import {
  PrimeraCosaMuyLarga,
  SegundaCosaMuyLarga,
  TerceraCosaMuyLarga,
  CuartaCosaMuyLarga,
} from './tipos'
TS
  cat > "$repo/src/__tests__/a.test.ts" <<'TS'
export function calcular(items: Item[], factor: number) {
  const filtrados = items.filter((x) => x.activo && x.valor > 0)
  const total = filtrados.reduce((acc, x) => acc + x.valor * factor, 0)
  if (total > LIMITE) {
    throw new Error('supera el limite permitido para el calculo')
  }
  return Math.round(total * 100) / 100
}
TS

  local out; out="$(node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" 2>&1)"
  assert_contains "$out" "src/a.ts" "detecta la duplicación real"
  assert_contains "$out" "src/b.ts" "y su pareja"
  assert_not_contains "$out" "PrimeraCosaMuyLarga" "no cuenta el import multilínea"
  assert_not_contains "$out" "__tests__" "los tests quedan fuera por defecto"

  out="$(node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" --tests 2>&1)"
  assert_contains "$out" "__tests__" "con --tests sí entran"
}

test_code_health_compara_contra_la_linea_base() {
  sandbox >/dev/null
  local repo="$SB/base"
  mkdir -p "$repo/src"
  printf 'export const x = 1\n' > "$repo/src/a.ts"

  node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" --save >/dev/null 2>&1
  assert_file "$repo/.crux-health.json" "guarda la línea base"

  local out; out="$(node "$CRUX_HOME/skills/code-health/scripts/health.mjs" "$repo" 2>&1)"
  assert_contains "$out" "línea base" "compara contra ella"
  assert_not_contains "$out" "Sin línea base" "y ya no dice que no la hay"
}
