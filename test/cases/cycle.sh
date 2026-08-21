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

test_workspace_avisa_si_los_hooks_apuntan_al_espacio_que_se_borra() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new conhooks --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-conhooks"
  printf '{"hooks":{"Stop":[{"hooks":[{"command":"%s/adapters/x.sh"}]}]}}\n' "$ws" > "$CLAUDE_SETTINGS"

  rm -f "$ws/.env.local"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" rm conhooks 2>&1)"
  assert_contains "$out" "quedarán rotos" "avisa antes de dejar los hooks colgando"
  assert_contains "$out" "crux hooks install" "y dice cómo repararlos"
}

test_prune_no_se_para_en_la_primera_rama_que_falla() {
  sandbox >/dev/null
  local repo="$CRUX_PROJECTS_DIR/podado"
  git init -q "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m init
  for b in uno dos tres; do git -C "$repo" branch "ws/$b"; done

  # gh de mentira: todas las propuestas constan como fusionadas, sin red.
  local bin="$SB/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "test/repo" ;;
  pr) echo "2026-08-05T00:00:00Z" ;;
esac
STUB
  chmod +x "$bin/gh"

  # Sin remoto configurado, el borrado remoto falla en las tres: con set -e la
  # primera se llevaba la pasada entera.
  local out; out="$(cd "$repo" && PATH="$bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" prune --yes 2>&1)"

  assert_contains "$out" "3 de 3 ramas limpiadas" "las tres se borran aunque el remoto falle"
  assert_eq "" "$(git -C "$repo" branch --list 'ws/*')" "no queda ninguna"
}

test_workspace_prune_no_adivina_sin_gh() {
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" \
    "hace falta gh autenticado para saber qué propuestas se fusionaron" \
    "prune se planta si no puede consultar las propuestas"
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" \
    "la usa un worktree: se queda" "y no borra la rama de un espacio vivo"
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

test_workspace_respeta_el_perfil_de_cliente() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor" "$root/cli-docs"
  git -C "$root/vendor" init -q
  git -C "$root/vendor" config user.email t@t
  git -C "$root/vendor" config user.name t
  echo x > "$root/vendor/f.txt"; git -C "$root/vendor" add -A; git -C "$root/vendor" commit -qm init
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" 2>&1)"
  assert_contains "$out" "no se escribe en vendor" "se niega a crear un worktree en código ajeno"
  assert_no_file "$root/vendor-ws-x" "y no lo crea"

  bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" --force >/dev/null 2>&1
  assert_file "$root/vendor-ws-x/f.txt" "con --force sí, cuando el cliente lo autoriza"
}

test_finish_no_propone_codigo_sin_revisar() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/prop"
  mkdir -p "$root/app" "$root/prop-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"prop","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/prop-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new tarea --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-tarea"
  echo cambio > "$ws/nuevo.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: algo"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_contains "$out" "no ha pasado la puerta" "se niega a proponer sin revisión"
  # El error de bash por leer un fichero que no existe se colaba encima del
  # mensaje, y es la salida que ve cualquiera que aún no ha pasado la puerta.
  assert_not_contains "$out" ".crux-ship:" "sin el error crudo del shell encima"

  # Con la marca de la puerta, pero de un commit anterior: tampoco vale.
  git -C "$ws" rev-parse HEAD~0 > "$ws/.crux-ship"
  echo mas > "$ws/otro.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: mas"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_contains "$out" "no ha pasado la puerta" "una marca vieja no cuenta"
  assert_contains "$out" "lo último verificado" "y dice por qué no cuenta"
}

test_workspace_avisa_si_ya_hay_otra_sesion_en_el_repo() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/dos"
  mkdir -p "$root/app"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init

  bash "$CRUX_HOME/bin/workspace.sh" new primera --repo "$root/app" >/dev/null 2>&1
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new segunda --repo "$root/app" 2>&1)"
  assert_contains "$out" "ya hay trabajo abierto" "avisa de la otra sesión viva"
  assert_contains "$out" "primera" "y dice cuál"
}

test_workspace_instala_las_dependencias_del_espacio() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/dep"
  mkdir -p "$root/app"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  # Un lockfile reconocible y un .gitignore que deja node_modules fuera: es la
  # situación real que hace que un worktree nazca sin dependencias.
  printf 'lockfileVersion: 1\n' > "$root/app/pnpm-lock.yaml"
  printf 'node_modules/\n' > "$root/app/.gitignore"
  printf '{"name":"app"}\n' > "$root/app/package.json"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  mkdir -p "$root/app/node_modules"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/app" 2>&1)"
  assert_contains "$out" "dependencias" "detecta el gestor y lo intenta"
  assert_no_file "$root/app-ws-x/node_modules/.keep" "el worktree no hereda node_modules"
}

test_diff_scope_entiende_la_arquitectura_por_capas() {
  sandbox >/dev/null
  local repo="$SB/capas"
  mkdir -p "$repo"; cd "$repo" || return
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p src/modules/x/domain src/modules/x/infrastructure
  touch src/modules/x/domain/entidad.ts
  git add -A

  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "lógica:1" "el dominio es lógica, no 'otros'"
  assert_contains "$out" "runtime: no" "y la lógica pura no pide levantar el entorno"

  touch src/modules/x/infrastructure/repo.adapter.ts
  git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "integración:1" "la infraestructura se distingue"
  assert_contains "$out" "runtime: sí" "y sí pide probar contra el servicio real"

  cd "$CRUX_HOME" || return
}

test_el_pre_push_bloquea_la_rama_principal() {
  sandbox >/dev/null
  local repo="$SB/protegido"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  echo x > "$repo/f.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm init

  # Se comprueba el comportamiento del hook con la entrada que git le pasa.
  local hook="$repo/.git/hooks/pre-push"
  mkdir -p "$(dirname "$hook")"
  sed 's/\$principal/main/g' > "$hook" <<'HOOK'
#!/usr/bin/env bash
while read -r _ _ remote_ref _; do
  [[ "$remote_ref" == "refs/heads/main" ]] || continue
  echo "push directo a main bloqueado"
  exit 1
done
exit 0
HOOK
  chmod +x "$hook"

  local out
  out="$(echo "refs/heads/main a refs/heads/main b" | bash "$hook" origin url 2>&1)"
  assert_contains "$out" "bloqueado" "el push a la principal se detiene"

  assert_exit 0 "una rama de trabajo pasa sin problema" \
    bash -c 'echo "refs/heads/ws/x a refs/heads/ws/x b" | bash "$1" origin url' _ "$hook"
}

test_el_titulo_de_la_propuesta_sale_del_primer_commit() {
  sandbox >/dev/null
  local repo="$SB/titulos"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  echo base > "$repo/f.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm "init"

  git init -q --bare "$SB/remoto.git"
  git -C "$repo" remote add origin "$SB/remoto.git"
  git -C "$repo" push -q origin main

  git -C "$repo" checkout -q -b ws/tarea
  echo uno > "$repo/a.txt"; git -C "$repo" add -A
  git -C "$repo" commit -qm "feat: lo que se fue a hacer"
  echo dos > "$repo/b.txt"; git -C "$repo" add -A
  git -C "$repo" commit -qm "chore: remate menor"

  # La rama ya subida: es el estado real cuando se calcula el título, porque el
  # push ocurre antes de abrir la propuesta. Con --not --remotes aquí no queda
  # nada y el título se iba al último commit.
  git -C "$repo" push -q origin ws/tarea

  local primero
  primero="$(git -C "$repo" log --format='%s' "origin/main..ws/tarea" | tail -1)"
  assert_eq "feat: lo que se fue a hacer" "$primero" \
    "el título es lo que se fue a hacer, aunque la rama ya esté subida"
}

test_la_puerta_se_gradua_segun_el_diff() {
  sandbox >/dev/null
  local repo="$SB/graduada"
  mkdir -p "$repo/docs" "$repo/src/components" "$repo/src/lib"
  cd "$repo" || return
  git init -q; git config user.email t@t; git config user.name t

  touch docs/nota.md; git add -A
  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "puertas: 2,8,9" "un cambio de solo texto no paga las nueve puertas"
  assert_contains "$out" "tests: ninguno" "y no tiene tests que correr"

  git reset -q; rm -f docs/nota.md
  touch src/lib/util.ts; git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "puertas: 1,2,3,4,5,6,8,9" "el código que no se ve desde fuera se salta la 7"

  touch src/components/Card.tsx; git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "puertas: todas" "si se ve desde fuera, la 7 deja de ser opcional"

  cd "$CRUX_HOME" || return
}

test_la_puerta_1_corre_solo_lo_afectado() {
  sandbox >/dev/null
  local repo="$SB/filtrado"
  mkdir -p "$repo/src"
  cd "$repo" || return
  git init -q; git config user.email t@t; git config user.name t

  # Sin contrato: el kernel no sabe con qué se ejecutan los tests aquí, así que
  # da el filtro y dice cómo declarar el comando.
  touch src/geohash.ts; git add -A
  local out; out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "geohash" "sin contrato, al menos dice por dónde filtrar"
  assert_contains "$out" "quality.tests" "y cómo declarar el comando exacto"

  # Fuera del repo: el contrato se busca hacia arriba, y así no se cuela en el
  # propio diff que estamos clasificando.
  cat > "$SB/crux.json" <<'JSON'
{ "quality": { "tests": "pnpm test", "testsFiltered": "pnpm test {filtro}" } }
JSON
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_contains "$out" "tests: pnpm test geohash" "con contrato, el comando exacto"

  # Solo texto: no hay nada que filtrar y tampoco se propone la suite entera.
  git reset -q; rm -f src/geohash.ts
  touch LEEME.md; git add -A
  out="$(bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh")"
  assert_not_contains "$out" "pnpm test" "un cambio de texto no arrastra la suite"

  cd "$CRUX_HOME" || return
}

test_el_hook_recuerda_el_ciclo_en_la_rama_principal() {
  sandbox >/dev/null
  local hook="$CRUX_HOME/adapters/claude/hooks/cycle-guard.sh"
  local fakehome="$SB/home"
  mkdir -p "$fakehome/.crux"
  echo "CRUX_PROJECTS_DIR=\"$CRUX_PROJECTS_DIR\"" > "$fakehome/.crux/config"

  # El HOME de mentira se pasa a cada invocación, no se exporta: exportarlo se
  # lo lleva el resto de la suite, y al borrar el sandbox el siguiente caso se
  # queda sin $HOME.
  _guard() {
    (cd "$1" && echo "{\"session_id\":\"$2\"}" \
      | env HOME="$fakehome" TMPDIR="$SB" bash "$hook")
  }

  local repo="$CRUX_PROJECTS_DIR/proy/proy-app"
  mkdir -p "$repo" "$CRUX_PROJECTS_DIR/proy/proy-docs"
  echo '{"project":"proy"}' > "$CRUX_PROJECTS_DIR/proy/proy-docs/crux.json"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  echo x > "$repo/f"; git -C "$repo" add -A; git -C "$repo" commit -qm init

  local out; out="$(_guard "$repo" s1)"
  assert_contains "$out" "crux workspace new" "en la principal de un repo gestionado, recuerda el ciclo"

  # Repetirlo cada turno lo convierte en ruido, y el ruido se ignora.
  out="$(_guard "$repo" s1)"
  assert_eq "" "$out" "no lo repite en la misma sesión"
  out="$(_guard "$repo" s2)"
  assert_contains "$out" "crux workspace new" "pero sí en una sesión nueva"

  git -C "$repo" checkout -q -b ws/algo
  out="$(_guard "$repo" s3)"
  assert_eq "" "$out" "fuera de la rama principal calla"

  # El docs repo también tiene cerrada su principal: si el aviso no llega ahí,
  # el bloqueo aparece al hacer push y ya es tarde.
  local docs="$CRUX_PROJECTS_DIR/proy/proy-docs"
  git -C "$docs" init -q -b main
  git -C "$docs" config user.email t@t; git -C "$docs" config user.name t
  git -C "$docs" add -A; git -C "$docs" commit -qm init
  out="$(_guard "$docs" s5)"
  assert_contains "$out" "crux workspace new" "el docs repo también recibe el aviso"

  # Un repo cualquiera que crux no gestiona no es asunto suyo.
  local ajeno="$SB/ajeno"
  mkdir -p "$ajeno"; git -C "$ajeno" init -q -b main
  git -C "$ajeno" config user.email t@t; git -C "$ajeno" config user.name t
  echo x > "$ajeno/f"; git -C "$ajeno" add -A; git -C "$ajeno" commit -qm init
  out="$(_guard "$ajeno" s4)"
  assert_eq "" "$out" "en un repo que no gestiona, callado"

  unset -f _guard
}

test_usage_cuenta_el_procedimiento_seguido_a_mano() {
  sandbox >/dev/null
  local kernel="$SB/kernel" trans="$SB/trans/proj"
  mkdir -p "$kernel/skills/conscript/scripts" "$kernel/skills/sinscript" "$trans"
  touch "$kernel/skills/conscript/scripts/medir.sh"

  # Una skill cuyo script se ejecuta pero a la que nunca se llama por su nombre:
  # el informe la daba por muerta, y es justo la que más se estaba usando.
  {
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash skills/conscript/scripts/medir.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash medir.sh --otra-vez"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat skills/conscript/scripts/medir.sh"}}]}}\n'
  } > "$trans/s.jsonl"

  # La ruta se resuelve antes de aplicar la asignación de delante, así que sale
  # del kernel real; el CRUX_HOME de mentira es solo el catálogo que va a leer.
  local usage="$CRUX_HOME/bin/usage.mjs" out
  out="$(CRUX_HOME="$kernel" CRUX_PROJECTS_DIR="$SB/vacio" CRUX_TRANSCRIPTS="$SB/trans" \
    node "$usage" 2>&1)"

  assert_contains "$out" "conscript" "la skill sale como usada aunque nadie la llamara por su nombre"

  # Una sesión, no dos ejecuciones ni tres menciones: leer el fichero no es
  # usarlo, y llamarlo dos veces en la misma sesión sigue siendo una ocasión.
  local fila; fila="$(printf '%s' "$out" | grep conscript | head -1)"
  assert_contains "$fila" "1" "cuenta ocasiones, no ejecuciones"

  local muertas; muertas="$(printf '%s' "$out" | sed -n '/Sin usar/,$p')"
  assert_not_contains "$muertas" "conscript" "y no se la cuenta entre las muertas"
  assert_contains "$muertas" "sinscript" "la que de verdad no se usa sigue apareciendo"
}

test_usage_no_cuenta_escribir_la_skill_como_usarla() {
  sandbox >/dev/null
  local kernel="$SB/kernel" trans="$SB/trans/proj"
  mkdir -p "$kernel/skills/recien/scripts" "$kernel/skills/veterana/scripts" "$trans"
  touch "$kernel/skills/recien/scripts/medir.sh"
  touch "$kernel/skills/veterana/scripts/correr.sh"

  # La sesión en que se escribe una skill nombra su script una y otra vez. Sin
  # separarlo, lo recién parido encabeza el ranking de lo más usado.
  {
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > skills/recien/scripts/medir.sh <<EOF"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"chmod +x skills/recien/scripts/medir.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i s/a/b/ skills/recien/scripts/medir.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash correr.sh"}}]}}\n'
  } > "$trans/s.jsonl"

  local usage="$CRUX_HOME/bin/usage.mjs" out
  out="$(CRUX_HOME="$kernel" CRUX_PROJECTS_DIR="$SB/vacio" CRUX_TRANSCRIPTS="$SB/trans" \
    node "$usage" 2>&1)"

  assert_contains "$out" "veterana" "la que se ejecutó sí cuenta"
  local usadas; usadas="$(printf '%s' "$out" | sed -n '/Usadas:/,/Sin usar/p' | grep -c recien || true)"
  assert_eq "0" "$usadas" "escribir una skill no la convierte en usada"
}
