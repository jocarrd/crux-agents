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

  # gh de mentira: las tres constan con propuesta fusionada, sin red.
  local bin="$SB/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "test/repo" ;;
  pr) printf 'ws/uno\nws/dos\nws/tres\n' ;;
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

# Como prune, esto necesita gh y un remoto: se afirma sobre la fuente, que es lo
# que la suite puede comprobar sin red.
test_status_canta_una_propuesta_abierta_sin_recibo() {
  local src; src="$(cat "$CRUX_HOME/bin/status.sh")"
  assert_contains "$src" "no tiene recibo de la puerta" \
    "status avisa de una propuesta abierta cuya rama no pasó la puerta"
  assert_contains "$src" "command -v gh >/dev/null || break" \
    "y no lo intenta siquiera sin gh"
  assert_contains "$src" "sealed " "leyendo el sello del recibo, no un sha suelto"
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

# El doctor de máquina mira los mismos directorios que el resto del kernel, y
# como el resto los deja redirigir. Apuntarlos al home falso dice qué se está
# probando; forzar solo HOME dependía de que ningún override estuviera puesto.
_machine_en() {
  local home="$1"
  HOME="$home" \
  CRUX_CONFIG="$home/.crux/config" \
  CLAUDE_SKILLS_DIR="$home/.claude/skills" \
  CLAUDE_SETTINGS="$home/.claude/settings.json" \
    bash "$CRUX_HOME/bin/machine.sh"
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

  local out; out="$(_machine_en "$fakehome" 2>&1)"
  assert_contains "$out" "apuntan a ficheros que no existen" "detecta el hook roto"

  assert_exit 1 "un hook roto es error: parece vigilado y no lo está" \
    _machine_en "$fakehome"
}

test_machine_detecta_enlaces_de_skill_rotos() {
  sandbox >/dev/null
  local fakehome="$SB/home2"
  mkdir -p "$fakehome/.claude/skills" "$fakehome/.crux"
  echo "CRUX_HOME=\"$CRUX_HOME\"" > "$fakehome/.crux/config"
  ln -s "$SB/skill-que-se-borro" "$fakehome/.claude/skills/fantasma"

  local out; out="$(_machine_en "$fakehome" 2>&1)"
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

  # Una rama local no es documentación, y en un repo de cliente desarrollar es el
  # encargo: se avisa de a dónde va la documentación y se deja trabajar.
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" 2>&1)"
  assert_contains "$out" "documentación de vendor" "avisa de que la documentación no va al repo del cliente"
  assert_file "$root/vendor-ws-x/f.txt" "y aun así crea el espacio de trabajo"

  # La rama sí se publica en su repositorio: se avisa de que lleva nuestra
  # nomenclatura, y se puede elegir otra.
  assert_contains "$out" "se verá en su repositorio" "avisa de que la rama la verá el cliente"
  assert_contains "$out" "--branch" "y dice cómo elegirla"

  bash "$CRUX_HOME/bin/workspace.sh" rm x >/dev/null 2>&1
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" --branch fix/a-real-name 2>&1)"
  assert_eq "fix/a-real-name" "$(git -C "$root/vendor-ws-x" rev-parse --abbrev-ref HEAD)" \
    "--branch fija el nombre de la rama"
  assert_not_contains "$out" "se verá en su repositorio" "y entonces no avisa"

  bash "$CRUX_HOME/bin/workspace.sh" rm x >/dev/null 2>&1
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new x --repo "$root/vendor" --force 2>&1)"
  assert_not_contains "$out" "documentación de vendor" "con --force no repite el aviso"
  assert_file "$root/vendor-ws-x/f.txt" "y crea el espacio igual"
}

test_hooks_engancha_el_commit_msg_tambien_en_repo_de_cliente() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor" "$root/cli-docs"
  git -C "$root/vendor" init -q
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"
  git -C "$root/cli-docs" init -q

  ( cd "$root/cli-docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1

  # `.git/hooks/` no está versionado y no viaja en ningún push: engancharlo no
  # es escribir en el repo del cliente. Saltárselo dejaba sin red justo el sitio
  # donde la firma de la herramienta no puede aparecer.
  assert_file "$root/vendor/.git/hooks/commit-msg" "engancha el commit-msg en el repo del cliente"

  local f="$SB/MSG"
  printf 'feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$f"
  bash "$root/vendor/.git/hooks/commit-msg" "$f" >/dev/null 2>&1
  assert_not_contains "$(cat "$f")" "Co-Authored-By" "y el que engancha quita la firma"

  # Pero solo eso: el idioma y el formato del historial de un cliente son suyos.
  # Imponerles los nuestros sería el error que el perfil existe para evitar.
  printf 'Añadido lo que hacia falta para que esto pase de una vez\n' > "$f"
  assert_exit 0 "y no le impone nuestro idioma ni nuestro formato" \
    bash "$root/vendor/.git/hooks/commit-msg" "$f"
}

test_hooks_si_impone_las_convenciones_en_repo_propio() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/propio"
  mkdir -p "$root/app" "$root/propio-docs"
  git -C "$root/app" init -q
  git -C "$root/propio-docs" init -q
  printf '{"crux":"0.1.0","project":"propio","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/propio-docs/crux.json"

  ( cd "$root/propio-docs" && bash "$CRUX_HOME/bin/hooks.sh" install ) >/dev/null 2>&1
  assert_file "$root/app/.git/hooks/commit-msg" "engancha el commit-msg en el repo propio"

  local f="$SB/MSG" hook="$root/app/.git/hooks/commit-msg"
  printf 'feat: add the thing\n' > "$f"
  assert_exit 0 "deja pasar un mensaje conforme" bash "$hook" "$f"
  printf 'Added the thing\n' > "$f"
  assert_exit 1 "rechaza el asunto sin prefijo conventional" bash "$hook" "$f"
  printf 'feat: Add the thing\n' > "$f"
  assert_exit 1 "rechaza la mayúscula tras el prefijo" bash "$hook" "$f"
}

test_ship_gate_lee_las_comprobaciones_del_contrato() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/g"
  mkdir -p "$root/app" "$root/g-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t; git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm "feat: init"

  # Sin declararlo, la puerta dice cómo declararlo en vez de inventarse nada.
  printf '{"crux":"0.1.0","project":"g","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/g-docs/crux.json"
  local out; out="$(cd "$root/app" && bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)"
  assert_contains "$out" "no declara qué comprobar" "sin contrato, no se inventa las comprobaciones"
  assert_contains "$out" "quality" "y dice dónde declararlas"

  # Declarado por repo: las ejecuta y las anota con el comando tal cual.
  printf '{"crux":"0.1.0","project":"g","profile":"multi-repo","repos":["app"],"sections":[],
    "quality":{"repos":{"app":{"gate":["true","echo hecho"]}}}}\n' > "$root/g-docs/crux.json"
  ( cd "$root/app" && bash "$CRUX_HOME/bin/ship.sh" gate >/dev/null 2>&1 )
  assert_contains "$(cat "$root/app/.crux-ship")" "run 0 " "ejecuta y anota el resultado"
  assert_contains "$(cat "$root/app/.crux-ship")" "echo hecho" "con el comando declarado, no el envoltorio"

  # Una comprobación en rojo no cierra la puerta.
  printf '{"crux":"0.1.0","project":"g","profile":"multi-repo","repos":["app"],"sections":[],
    "quality":{"repos":{"app":{"gate":["false"]}}}}\n' > "$root/g-docs/crux.json"
  out="$(cd "$root/app" && bash "$CRUX_HOME/bin/ship.sh" gate 2>&1)"
  assert_contains "$out" "en rojo" "y una en rojo la deja abierta"
}

test_ship_body_no_deja_publicar_la_firma_ni_nuestro_andamiaje() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/cli"
  mkdir -p "$root/vendor" "$root/cli-docs"
  git -C "$root/vendor" init -q
  printf '{"crux":"0.1.0","project":"cli","profile":"client-repo","repos":["vendor"],"sections":[]}\n' \
    > "$root/cli-docs/crux.json"

  local b="$SB/BODY.md"
  printf 'Adds the thing and says why.\n' > "$b"
  assert_exit 0 "deja pasar un cuerpo limpio" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"

  printf 'Adds the thing.\n\nGenerated with Claude Code\n' > "$b"
  assert_exit 1 "para la firma de la herramienta" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"

  # En el repo de un cliente, además, no se enseña cómo trabajamos por dentro.
  printf 'Adds the thing.\n\nChecked by passing crux ship and workspace finish.\n' > "$b"
  assert_exit 1 "y nuestro tooling en un repo de cliente" \
    env -C "$root/vendor" bash "$CRUX_HOME/bin/ship.sh" body "$b"
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

  # Un sha suelto es lo que se escribía antes: no dice qué se ejecutó, así que
  # ya no cuenta como haber pasado la puerta.
  git -C "$ws" rev-parse HEAD > "$ws/.crux-ship"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_contains "$out" "ni un comando ejecutado" "un sha suelto no vale como recibo"

  # Un recibo con una comprobación en rojo tampoco.
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- false >/dev/null 2>&1 ) || true
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_contains "$out" "en rojo" "una comprobación fallida no cierra la puerta"

  # Recibo bueno, pero de un commit anterior: hay que volver a pasarla.
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  echo mas > "$ws/otro.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: mas"
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_contains "$out" "no ha pasado la puerta" "un recibo viejo no cuenta"
  assert_contains "$out" "el recibo es de" "y dice por qué no cuenta"

  # El atajo existe para obedecer a una persona, y se ve.
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea --sin-puerta 2>&1)"
  assert_contains "$out" "SIN pasar la puerta" "con --sin-puerta lo dice en voz alta"
}

_merge_escenario() {
  # Un espacio con propuesta abierta y un gh de mentira que responde lo que
  # diga $1 a 'pr view'. Devuelve la ruta del worktree por la salida.
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/mrg"
  mkdir -p "$root/app" "$root/mrg-docs" "$SB/bin"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"mrg","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/mrg-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new m --repo "$root/app" >/dev/null 2>&1
  echo cambio > "$root/app-ws-m/nuevo.txt"
  git -C "$root/app-ws-m" add -A; git -C "$root/app-ws-m" commit -qm "feat: algo"

  cat > "$SB/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")
    cat <<'JSON'
$1
JSON
    ;;
  "pr merge") echo fusionada ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$SB/bin/gh"
  echo "$root/app-ws-m"
}

test_merge_no_fusiona_con_las_comprobaciones_en_rojo() {
  sandbox >/dev/null
  _merge_escenario '{"number":7,"title":"t","url":"u","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"FAILURE"}]}' >/dev/null

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" merge m --yes 2>&1)" || rc=$?
  assert_eq "1" "$rc" "sale en rojo"
  assert_contains "$out" "comprobaciones fallan" "dice cuantas fallan"
  assert_contains "$out" "no se fusiona" "y que no fusiona"
}

test_merge_no_fusiona_con_conflictos() {
  sandbox >/dev/null
  _merge_escenario '{"number":7,"title":"t","url":"u","mergeable":"CONFLICTING","reviewDecision":"","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}' >/dev/null

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" merge m --yes 2>&1)" || rc=$?
  assert_eq "1" "$rc" "sale en rojo"
  assert_contains "$out" "conflictos que resolver" "nombra el conflicto"
}

test_merge_sin_yes_informa_y_no_toca_nada() {
  sandbox >/dev/null
  local ws; ws="$(_merge_escenario '{"number":7,"title":"t","url":"u","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}')"

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" merge m 2>&1)" || rc=$?
  assert_eq "0" "$rc" "sin --yes no es un error"
  assert_contains "$out" "todo en verde" "resume el estado"
  assert_contains "$out" "--yes" "y dice como fusionar de verdad"
  assert_file "$ws/nuevo.txt" "el worktree sigue donde estaba"
}

test_finish_sobrevive_a_una_rama_principal_que_no_es_main() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/troncal"
  mkdir -p "$root/app" "$root/troncal-docs"
  git -C "$root/app" init -q -b troncal
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"troncal","profile":"multi-repo","repos":["app"],"branch":"troncal","sections":[]}\n' \
    > "$root/troncal-docs/crux.json"

  # Un remoto de verdad, pero sin origin/HEAD: es lo que deja un remoto anadido
  # a mano, y es donde el fallback a origin/main se estrellaba.
  git init -q --bare "$SB/remoto.git"
  git -C "$root/app" remote add origin "$SB/remoto.git"
  git -C "$root/app" push -q origin troncal

  bash "$CRUX_HOME/bin/workspace.sh" new t --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-t"
  echo cambio > "$ws/nuevo.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: algo"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "un paso" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local out rc
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish t 2>&1)"; rc=$?
  assert_eq "$rc" "0" "termina bien aunque la rama principal no se llame main"
  assert_contains "$out" "subida" "sube la rama"
  # Sin gh no hay propuesta, pero tiene que llegar hasta aqui en vez de morirse
  # callado despues del push.
  assert_contains "$out" "abre la propuesta" "y llega al final del comando"
}

test_finish_avisa_si_la_tarea_se_cierra_sin_pasos() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/vacia"
  mkdir -p "$root/app" "$root/vacia-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"vacia","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/vacia-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new tarea --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-tarea"
  echo cambio > "$ws/nuevo.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: algo"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  # Sin remoto la subida falla despues, pero el aviso va antes y se ve igual.
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_contains "$out" "sin un solo paso anotado" "dice que el registro se queda vacio"
  assert_contains "$out" "no lo recupera nadie" "y dice que es lo que se pierde"
  assert_contains "$out" "aviso" "es un aviso y no un error: la propuesta sigue su curso"

  # Con un paso anotado no molesta.
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "lo que hice" >/dev/null 2>&1 )
  echo mas > "$ws/otro.txt"; git -C "$ws" add -A; git -C "$ws" commit -qm "feat: mas"
  ( cd "$ws" && bash "$CRUX_HOME/bin/ship.sh" clear >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish tarea 2>&1)"
  assert_not_contains "$out" "sin un solo paso anotado" "con pasos anotados se calla"
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

  # Un repo suelto en la raíz, sin proyecto ni docs repo, también es del
  # sistema: ADR-014. Antes quedaba fuera y era donde se colaba el trabajo
  # directo sobre la principal.
  local suelto="$CRUX_PROJECTS_DIR/suelto"
  mkdir -p "$suelto"; git -C "$suelto" init -q -b main
  git -C "$suelto" config user.email t@t; git -C "$suelto" config user.name t
  echo x > "$suelto/f"; git -C "$suelto" add -A; git -C "$suelto" commit -qm init
  out="$(_guard "$suelto" s6)"
  assert_contains "$out" "crux workspace new" "un repo suelto bajo la raíz recibe el aviso"

  # Y lo que vive ahí sin ser tuyo se excluye por configuración, no por layout.
  echo "CRUX_UNMANAGED=\"$CRUX_PROJECTS_DIR/suelto\"" >> "$fakehome/.crux/config"
  out="$(_guard "$suelto" s7)"
  assert_eq "" "$out" "un repo excluido en la configuración vuelve a callar"

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

test_ship_avisa_de_los_artefactos_que_se_cuelan_en_la_raiz() {
  sandbox >/dev/null
  local repo="$SB/repo"; mkdir -p "$repo/public/img"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  echo x > "$repo/README.md"
  git -C "$repo" add -A && git -C "$repo" commit -qm init

  # Una herramienta escribe su captura en el directorio de trabajo y un
  # `git add -A` se la lleva a la rama. No lo ve ni un test ni el linter.
  touch "$repo/captura.png" "$repo/salida.log" "$repo/public/img/logo.png"
  echo "export const a = 1" > "$repo/codigo.ts"
  git -C "$repo" add -A

  local out; out="$(cd "$repo" && bash "$CRUX_HOME/skills/ship/scripts/diff-scope.sh" 2>&1)"

  assert_contains "$out" "captura.png" "nombra la captura suelta"
  assert_contains "$out" "salida.log" "nombra el volcado suelto"
  assert_not_contains "$out" "public/img/logo.png" "un asset dentro del árbol no es un artefacto"
  assert_not_contains "$out" "codigo.ts" "el código no es un artefacto"
}

test_usage_senala_la_skill_cuyo_procedimiento_se_sigue_sin_llamarla() {
  sandbox >/dev/null
  local kernel="$SB/kernel" trans="$SB/trans/proj"
  mkdir -p "$kernel/skills/muda/scripts" "$kernel/skills/hablada/scripts" "$trans"
  touch "$kernel/skills/muda/scripts/medir.sh" "$kernel/skills/hablada/scripts/correr.sh"

  # Su procedimiento se sigue y su nombre no se invoca: la conclusión no es que
  # sobre, es que su descripción no se activa. El informe la daba por leída.
  {
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash medir.sh"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"hablada"}}]}}\n'
    printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash correr.sh"}}]}}\n'
  } > "$trans/s.jsonl"

  local usage="$CRUX_HOME/bin/usage.mjs" out
  out="$(CRUX_HOME="$kernel" CRUX_PROJECTS_DIR="$SB/vacio" CRUX_TRANSCRIPTS="$SB/trans" \
    node "$usage" 2>&1)"

  assert_contains "$out" "Se siguieron a mano" "abre la sección cuando hay alguna"
  local seccion; seccion="$(printf '%s' "$out" | sed -n '/Se siguieron a mano/,/aparece el problema/p')"
  assert_contains "$seccion" "muda" "señala la que no se llamó por su nombre"
  assert_not_contains "$seccion" "hablada" "la que sí se invocó no aparece ahí"
}

# --- Bordes medidos en una caza de fallos (v0.36.0) --------------------------

test_la_puerta_cuenta_los_fallos_de_dos_cifras() {
  sandbox >/dev/null
  local repo="$CRUX_PROJECTS_DIR/rc"
  mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m init

  # Una orden que no existe sale con 127, un tiempo agotado con 124 y un
  # proceso al que mata el sistema por memoria con 137. Contar solo los de una
  # cifra dejaba pasar justo esos tres, que son los que más aparecen.
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- bash -c 'exit 127' ) >/dev/null 2>&1
  ( cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" run -- bash -c 'exit 124' ) >/dev/null 2>&1

  local out; out="$(cd "$repo" && bash "$CRUX_HOME/bin/ship.sh" seal 2>&1)"
  assert_contains "$out" "no se cierra" "127 y 124 son fallos: la puerta no se cierra"
  assert_not_contains "$out" "puerta cerrada" "y no se declara cerrada"
  assert_not_contains "$(cat "$repo/.crux-ship")" "sealed " "ni se escribe el sello"
}

test_finish_no_publica_con_el_recibo_en_rojo_de_dos_cifras() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"
  bash "$CRUX_HOME/bin/workspace.sh" new r --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-r"
  echo cambio > "$ws/nuevo.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: algo"

  # Un recibo sellado sobre el commit, pero con una comprobación en 127.
  printf '# recibo\nrepo %s\nrun 127 1 npm test\nsealed %s x\n' \
    "$ws" "$(git -C "$ws" rev-parse HEAD)" > "$ws/.crux-ship"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" finish r 2>&1)"
  assert_contains "$out" "en rojo" "el recibo con un 127 no deja abrir la propuesta"
}

test_usage_entiende_los_dias_separados_por_espacio() {
  sandbox >/dev/null
  local t="$SB/transcripts/p"; mkdir -p "$t"
  printf '{"name":"Skill","input":{"skill":"adr"}}\n' > "$t/s.jsonl"

  local out
  out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" --days 7 2>&1)"
  assert_contains "$out" "últimos 7 días" "la forma documentada '--days N' se respeta"
  out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" --days=7 2>&1)"
  assert_contains "$out" "últimos 7 días" "y la forma con igual sigue valiendo"
  out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" --days abc 2>&1)"
  assert_contains "$out" "no es un número" "un valor que no es número se dice, no se ignora"
}

test_usage_cuenta_lo_que_hicieron_los_subagentes() {
  sandbox >/dev/null
  local t="$SB/transcripts/p"; mkdir -p "$t/sesion/subagents"
  # La sesión padre no invoca nada; su subagente sí. El trabajo se hizo.
  printf '{"type":"user"}\n' > "$t/sesion.jsonl"
  printf '{"name":"Skill","input":{"skill":"review-pr"}}\n' > "$t/sesion/subagents/a.jsonl"

  local out; out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" 2>&1)"
  assert_contains "$out" "review-pr" "lo que invoca un subagente cuenta como uso"
  assert_contains "$out" "1 sesiones revisadas" "y el subagente no infla el número de sesiones"
}

test_workspace_no_acepta_un_nombre_que_se_sale_del_arbol() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  # Con una rama válida el nombre ya no lo frena git: plantaba el worktree donde
  # apuntara el nombre, más un directorio basura 'app-ws-..' que rm no recogía.
  local out
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new '../../fuera' --repo "$root/app" --branch fix/ok 2>&1)"
  assert_contains "$out" "nombre" "un nombre con .. se rechaza"
  assert_no_file "$root/fuera" "y no se crea nada fuera del repo"
  assert_no_file "$root/app-ws-.." "ni el directorio que quedaba por el camino"
  assert_not_contains "$(cat "$CRUX_REGISTRY" 2>/dev/null || echo '')" "fuera" \
    "ni queda registrado"

  # Pedir ayuda no crea un espacio llamado '--help'.
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new --help 2>&1)"
  assert_contains "$out" "crux workspace new" "'new --help' enseña el uso"
  assert_not_contains "$(cat "$CRUX_REGISTRY" 2>/dev/null || echo '')" "help" \
    "y no registra un espacio con ese nombre"
}

test_el_cerrojo_del_registro_no_deja_el_kernel_muerto() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  # Un proceso muerto en seco —un OOM, un Ctrl-C duro— dejaba el cerrojo
  # puesto para siempre, y ningún comando sabía retirarlo.
  mkdir -p "$(dirname "$CRUX_REGISTRY")/.workspaces.lock"
  echo 999999 > "$(dirname "$CRUX_REGISTRY")/.workspaces.lock/pid"
  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new tras-el-oom --repo "$root/app" 2>&1)"
  assert_contains "$out" "listo" "un cerrojo de un proceso que ya no existe se retira solo"

  # Y dos espacios lanzados a la vez tienen que salir los dos: el cerrojo se
  # mantenía durante el setup, que puede tardar minutos, con cinco segundos de
  # espera. Se comprueba el resultado, no el mecanismo del cerrojo.
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.workspace.setup = "sleep 3";
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$root/proj-docs/crux.json"
  bash "$CRUX_HOME/bin/workspace.sh" new par-uno --repo "$root/app" >/dev/null 2>&1 &
  local primero=$!
  sleep 1
  bash "$CRUX_HOME/bin/workspace.sh" new par-dos --repo "$root/app" >/dev/null 2>&1
  local rc_dos=$?
  wait "$primero"; local rc_uno=$?

  assert_eq "0 0" "$rc_uno $rc_dos" "los dos espacios en paralelo salen bien"
  assert_eq "2" "$(node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const s = Object.entries(r.workspaces).filter(([n]) => n.startsWith("par-")).map(([, w]) => w.slot);
    process.stdout.write(String(new Set(s).size));
  ' "$CRUX_REGISTRY")" "y con un slot distinto cada uno"
}

test_dos_proyectos_no_se_reparten_el_mismo_puerto() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  # Otro proyecto, con su propia base de puertos. El slot es único en el
  # registro, pero el rango sale del portBase de cada uno: con bases distintas,
  # dos slots distintos daban el mismo rango.
  local otro="$CRUX_PROJECTS_DIR/otro"
  mkdir -p "$otro/api" "$otro/otro-docs"
  git -C "$otro/api" init -q
  git -C "$otro/api" config user.email t@t; git -C "$otro/api" config user.name t
  echo x > "$otro/api/f.txt"; git -C "$otro/api" add -A; git -C "$otro/api" commit -qm init
  printf '{"crux":"0.1.0","project":"otro","profile":"multi-repo","repos":["api"],"sections":[],
    "workspace":{"portBase":4005,"portsPerSlot":5,"envFile":".env","env":{"PORT":"{{PORT0}}"}}}\n' \
    > "$otro/otro-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new b --repo "$otro/api" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new a --repo "$root/app" >/dev/null 2>&1

  local choques
  choques="$(node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const e = Object.entries(r.workspaces);
    let n = 0;
    for (let i = 0; i < e.length; i++) for (let j = i + 1; j < e.length; j++) {
      const [, A] = e[i], [, B] = e[j];
      if (A.ports[0] <= B.ports[1] && B.ports[0] <= A.ports[1]) n++;
    }
    process.stdout.write(String(n));
  ' "$CRUX_REGISTRY")"
  assert_eq "0" "$choques" "ningún espacio se solapa con el rango de otro"
}

test_una_interrupcion_no_declara_el_espacio_listo() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.workspace.setup = "sleep 10";
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$root/proj-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new cortado --repo "$root/app" > "$SB/salida" 2>&1 &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"; local rc=$?

  assert_not_contains "$(cat "$SB/salida")" "listo" "una señal no deja declarar el espacio listo"
  assert_eq "sí" "$([[ $rc -ne 0 ]] && echo sí || echo no)" "y sale con código de error"

  # El worktree ya está en disco: la entrada se queda, porque borrarla dejaba
  # un worktree que la herramienta ya no reconocía y un slot repartido dos veces.
  if [[ -d "$root/app-ws-cortado" ]]; then
    assert_contains "$(bash "$CRUX_HOME/bin/workspace.sh" list --all)" "cortado" \
      "el espacio a medias se ve en la lista"
    assert_not_contains "$(bash "$CRUX_HOME/bin/workspace.sh" rm cortado 2>&1)" "no existe el espacio" \
      "y se puede retirar"
  fi
}

test_el_contrato_ilegible_no_se_convierte_en_puertos_por_defecto() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"
  printf '{"crux":"0.1.0","project":"proj","workspace":{"portBase":4000' \
    > "$root/proj-docs/crux.json"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" new roto --repo "$root/app" 2>&1)"
  assert_contains "$out" "ilegible" "un contrato roto se dice"
  assert_not_contains "$out" "sin configuración de workspace" "y no se pasa por 'no hay configuración'"
  assert_no_file "$root/app-ws-roto/.env.local" "el espacio no arranca con los puertos por defecto"
}

test_gc_reconcilia_el_registro_con_el_disco() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  bash "$CRUX_HOME/bin/workspace.sh" new vivo --repo "$root/app" >/dev/null 2>&1
  bash "$CRUX_HOME/bin/workspace.sh" new fantasma --repo "$root/app" >/dev/null 2>&1
  # El worktree desaparece por fuera: es como queda tras un borrado a mano.
  git -C "$root/app" worktree remove --force "$root/app-ws-fantasma" 2>/dev/null || rm -rf "$root/app-ws-fantasma"

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" gc 2>&1)"
  assert_contains "$out" "fantasma" "señala la entrada sin worktree"
  assert_not_contains "$out" "vivo " "y no toca la que sí lo tiene"
  assert_contains "$(cat "$CRUX_REGISTRY")" "fantasma" "sin --yes no borra nada"

  bash "$CRUX_HOME/bin/workspace.sh" gc --yes >/dev/null 2>&1
  assert_not_contains "$(cat "$CRUX_REGISTRY")" "fantasma" "con --yes retira la entrada"
  assert_contains "$(cat "$CRUX_REGISTRY")" "vivo" "y conserva la que está viva"
}

test_gc_ve_los_worktrees_que_el_registro_no_conoce() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"

  # Un worktree creado a mano, o el que dejó una versión con el fallo del nombre.
  git -C "$root/app" worktree add -b suelta "$root/app-ws-suelta" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" gc 2>&1)"
  assert_contains "$out" "app-ws-suelta" "ve el worktree que no está registrado"
  assert_contains "$out" "--con-disco" "y dice cómo retirarlo"

  bash "$CRUX_HOME/bin/workspace.sh" gc --yes >/dev/null 2>&1
  assert_file "$root/app-ws-suelta/f.txt" "sin --con-disco no se toca el disco"

  # Con trabajo dentro no se retira ni pidiéndolo.
  echo pendiente > "$root/app-ws-suelta/sin-commitear.txt"
  bash "$CRUX_HOME/bin/workspace.sh" gc --yes --con-disco >/dev/null 2>&1
  assert_file "$root/app-ws-suelta/sin-commitear.txt" "un worktree con cambios sin commitear se queda"

  rm -f "$root/app-ws-suelta/sin-commitear.txt"
  bash "$CRUX_HOME/bin/workspace.sh" gc --yes --con-disco >/dev/null 2>&1
  assert_no_file "$root/app-ws-suelta" "limpio y con --con-disco, se retira"
}

test_el_fichero_de_entorno_no_bloquea_el_cierre_del_espacio() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"
  bash "$CRUX_HOME/bin/workspace.sh" new conenv --repo "$root/app" >/dev/null 2>&1

  assert_file "$root/app-ws-conenv/.env.local" "el comando escribe el fichero de entorno"
  assert_eq "" "$(git -C "$root/app-ws-conenv" status --porcelain)" \
    "y no cuenta como cambio sin commitear: lo escribió crux, no tú"
  assert_contains "$(bash "$CRUX_HOME/bin/workspace.sh" rm conenv 2>&1)" "slot liberado" \
    "así que no bloquea el cierre del espacio"
}

test_list_dice_desde_cuando_esta_abierto_un_espacio() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_repo_con_config)"
  bash "$CRUX_HOME/bin/workspace.sh" new reciente --repo "$root/app" >/dev/null 2>&1

  local out; out="$(bash "$CRUX_HOME/bin/workspace.sh" list --all)"
  assert_contains "$out" "hoy" "un espacio abierto hoy se ve como tal"
}

test_el_perfil_decide_como_se_llama_la_rama() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local casa="$SB/home"; mkdir -p "$casa/.crux/profiles"
  printf '{"name":"suyo","pointers":{"write":true},"branch":{"pattern":"feature/{{name}}"}}\n' \
    > "$casa/.crux/profiles/suyo.json"
  local root; root="$(_repo_con_config)"
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8")); j.profile = "suyo";
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$root/proj-docs/crux.json"

  env HOME="$casa" bash "$CRUX_HOME/bin/workspace.sh" new algo --repo "$root/app" >/dev/null 2>&1
  assert_eq "feature/algo" "$(git -C "$root/app-ws-algo" rev-parse --abbrev-ref HEAD)" \
    "la rama sigue el patrón del perfil"
}

test_usage_dice_con_que_palabras_aparecio_el_problema() {
  sandbox >/dev/null
  local t="$SB/transcripts/p"; mkdir -p "$t"
  # El procedimiento se sigue a mano y nadie llama a la skill: lo que falta es
  # saber con qué palabras se pidió, que es lo que su descripción no lleva.
  {
    printf '{"type":"user","message":{"role":"user","content":"esto parece espagueti y da miedo tocarlo"}}\n'
    printf '{"name":"Bash","input":{"command":"node scripts/health.mjs ."}}\n'
  } > "$t/s.jsonl"

  local out; out="$(CRUX_TRANSCRIPTS="$SB/transcripts" node "$CRUX_HOME/bin/usage.mjs" 2>&1)"
  assert_contains "$out" "code-health" "señala la skill que se siguió sin llamar"
  assert_contains "$out" "espagueti" "y con qué palabras se pidió el trabajo"
  assert_not_contains "$out" "duplicación" "sin repetir lo que la descripción ya dice"
  assert_not_contains "$out" " esto" "sin las palabras vacías"
}

test_el_titulo_de_una_propuesta_no_ejecuta_comandos() {
  # El titulo sale de gh, o sea de quien pueda renombrar la propuesta. Acababa
  # en un eval entre comillas dobles, donde bash sigue expandiendo $(...).
  sandbox >/dev/null
  local testigo="$SB/RCE_TITULO"
  local estado
  estado="{\"number\":7,\"title\":\"fix: algo \$(touch $testigo)\",\"url\":\"u\",\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"\",\"statusCheckRollup\":[]}"

  # el mismo bloque que usa cmd_merge, extraido del fichero para no depender de gh
  local bloque
  bloque="$(sed -n '/^  eval "\$(node -e/,/^  '"'"' "\$estado")"/p' "$CRUX_HOME/bin/workspace.sh")"
  [[ -n "$bloque" ]] && PASS=$((PASS + 1)) || _fail "no encuentro el bloque del eval en workspace.sh"

  ( estado="$estado"; eval "$bloque" >/dev/null 2>&1 ) || true
  assert_no_file "$testigo" "el titulo de la propuesta no ejecuta nada"
  assert_contains "$(cat "$CRUX_HOME/bin/workspace.sh")" "Comillas simples, como en load_config" \
    "y queda dicho por que"
}

test_una_rama_principal_con_veneno_no_escribe_el_pre_push() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/veneno"
  mkdir -p "$root/app" "$root/veneno-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  # el campo branch acaba dentro de un heredoc sin comillas
  cat > "$root/veneno-docs/crux.json" <<'JSON'
{"crux":"0.1.0","project":"veneno","profile":"multi-repo","repos":["app"],
 "branch":"main\" ]] || { touch /tmp/CRUX_RCE_PREPUSH; }; : \"","sections":[]}
JSON
  rm -f /tmp/CRUX_RCE_PREPUSH

  git -C "$root/veneno-docs" init -q
  git -C "$root/veneno-docs" config user.email t@t
  git -C "$root/veneno-docs" config user.name t
  git -C "$root/veneno-docs" add -A; git -C "$root/veneno-docs" commit -qm init
  local out
  out="$(cd "$root/veneno-docs" && bash "$CRUX_HOME/bin/hooks.sh" install 2>&1)" || true
  assert_no_file "/tmp/CRUX_RCE_PREPUSH" "el hook generado no ejecuta lo que traiga el contrato"
  assert_contains "$out" "no validos" "y dice que la rama no vale"
  assert_no_file "$root/app/.git/hooks/pre-push" "sin instalar un hook envenenado"
}

test_un_idioma_de_commit_con_veneno_cae_al_valor_por_defecto() {
  sandbox >/dev/null
  local root="$CRUX_PROJECTS_DIR/idioma"
  mkdir -p "$root/app" "$root/idioma-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"idioma","profile":"client-repo","repos":["app"],"sections":[]}\n' \
    > "$root/idioma-docs/crux.json"
  printf '{"commit":{"language":"en}\\"; touch /tmp/CRUX_RCE_COMMITMSG; #"}}\n' \
    > "$root/idioma-docs/profile.json"
  rm -f /tmp/CRUX_RCE_COMMITMSG

  bash "$CRUX_HOME/bin/hooks.sh" install "$root/idioma-docs" >/dev/null 2>&1 || true
  local hook="$root/app/.git/hooks/commit-msg"
  if [[ -f "$hook" ]]; then
    printf 'feat: algo\n' > "$SB/msg"
    bash "$hook" "$SB/msg" >/dev/null 2>&1 || true
  fi
  assert_no_file "/tmp/CRUX_RCE_COMMITMSG" "el commit-msg no ejecuta lo que traiga el perfil"
}

test_prune_no_borra_una_rama_que_nunca_tuvo_propuesta() {
  # `git branch --merged` es cierto para cualquier rama que apunte a un
  # ancestro de la principal: una recien creada, o develop justo despues de
  # una release. Se borraban aqui y en el remoto diciendo "ya fusionada".
  sandbox >/dev/null
  local repo="$SB/repo"; mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" branch develop        # de vida larga
  git -C "$repo" branch ws/recien      # recien creada, sin un commit propio
  git -C "$repo" branch ws/hecha       # esta si tuvo propuesta

  local bin="$SB/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "test/repo" ;;
  pr) echo "ws/hecha" ;;
esac
STUB
  chmod +x "$bin/gh"

  local out; out="$(cd "$repo" && PATH="$bin:$PATH" bash "$CRUX_HOME/bin/workspace.sh" prune --yes 2>&1)"
  local quedan; quedan="$(git -C "$repo" branch --list --format='%(refname:short)' | tr '\n' ' ')"

  assert_contains "$quedan" "develop" "develop no se toca"
  assert_contains "$quedan" "ws/recien" "una rama sin propuesta tampoco"
  assert_not_contains "$quedan" "ws/hecha" "y la que si tuvo propuesta fusionada se limpia"
  assert_contains "$out" "1 de 1" "solo cuenta la que de verdad se fusiono"
}

_dos_repos() {
  local root="$CRUX_PROJECTS_DIR/dosr"
  mkdir -p "$root/app" "$root/api" "$root/dosr-docs"
  local r
  for r in app api; do
    git -C "$root/$r" init -q
    git -C "$root/$r" config user.email t@t
    git -C "$root/$r" config user.name t
    echo x > "$root/$r/f.txt"; git -C "$root/$r" add -A; git -C "$root/$r" commit -qm init
  done
  printf '{"crux":"0.1.0","project":"dosr","profile":"multi-repo","repos":["app","api"],"sections":[]}\n' \
    > "$root/dosr-docs/crux.json"
  echo "$root"
}

test_dos_espacios_con_el_mismo_nombre_no_se_pisan() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_dos_repos)"

  bash "$CRUX_HOME/bin/workspace.sh" new fix --repo "$root/app" >/dev/null 2>&1
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new fix --repo "$root/api" 2>&1)" || rc=$?

  assert_eq "1" "$rc" "el segundo se niega"
  assert_contains "$out" "ya hay un espacio llamado" "y dice por que"
  assert_contains "$out" "app-ws-fix" "señalando cual ocupa el nombre"
  assert_contains "$(cat "$CRUX_REGISTRY")" "app-ws-fix" "la entrada del primero sigue en pie"
  assert_no_file "$root/api-ws-fix/f.txt" "y el segundo no deja un worktree huerfano"
}

test_un_espacio_con_ficheros_ignorados_no_se_da_por_limpio() {
  # git status normal no los ve, pero al retirar el worktree se borran igual:
  # el .env.local y la base de datos del espacio viven ahi.
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_dos_repos)"
  printf 'data/\nnotas-privadas.md\n' > "$root/app/.gitignore"
  git -C "$root/app" add -A; git -C "$root/app" commit -qm ignora

  bash "$CRUX_HOME/bin/workspace.sh" new condatos --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-condatos"
  mkdir -p "$ws/data"
  echo "apuntes" > "$ws/notas-privadas.md"
  echo "datos" > "$ws/data/dump.sql"

  assert_eq "" "$(git -C "$ws" status --porcelain)" "para git normal el espacio esta limpio"
  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" rm condatos 2>&1)" || rc=$?
  assert_eq "1" "$rc" "pero rm se niega"
  assert_file "$ws/notas-privadas.md" "y lo escrito a mano sigue ahi"
  assert_file "$ws/data/dump.sql" "y los datos tambien"
}

test_una_base_que_no_existe_no_cae_a_head_en_silencio() {
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root; root="$(_dos_repos)"

  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" new sobrebase --repo "$root/app" --base v9-inexistente 2>&1)" || rc=$?
  assert_eq "1" "$rc" "se para"
  assert_contains "$out" "no existe" "y dice que la base no existe"
  assert_no_file "$root/app-ws-sobrebase/f.txt" "sin dejar un espacio sobre la base equivocada"
}

test_el_cuerpo_de_la_propuesta_pasa_por_el_filtro() {
  # ship body existia y no lo llamaba nadie: el cuerpo salia del registro de la
  # tarea directo a gh pr create.
  sandbox >/dev/null
  export CRUX_REGISTRY="$SB/registry.json"
  local root="$CRUX_PROJECTS_DIR/filtro"
  mkdir -p "$root/app" "$root/filtro-docs"
  git -C "$root/app" init -q
  git -C "$root/app" config user.email t@t
  git -C "$root/app" config user.name t
  echo x > "$root/app/f.txt"; git -C "$root/app" add -A; git -C "$root/app" commit -qm init
  printf '{"crux":"0.1.0","project":"filtro","profile":"multi-repo","repos":["app"],"sections":[]}\n' \
    > "$root/filtro-docs/crux.json"

  bash "$CRUX_HOME/bin/workspace.sh" new conveneno --repo "$root/app" >/dev/null 2>&1
  local ws="$root/app-ws-conveneno"
  echo cambio > "$ws/nuevo.txt"
  git -C "$ws" add -A; git -C "$ws" commit -qm "feat: algo"
  ( cd "$ws" && bash "$CRUX_HOME/bin/task.sh" add "probado con ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/task.sh" "done" T1 "en /home/otrousuario/Proyectos/otrocliente/api" >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" run -- true >/dev/null 2>&1
    bash "$CRUX_HOME/bin/ship.sh" seal >/dev/null 2>&1 )

  local out rc=0
  out="$(bash "$CRUX_HOME/bin/workspace.sh" finish conveneno 2>&1)" || rc=$?
  assert_eq "1" "$rc" "no publica un cuerpo que no pasa el filtro"
  assert_contains "$out" "no pasa el filtro" "y lo dice"
  assert_contains "$out" "credencial" "señalando el token"
}

test_las_rutas_de_la_maquina_no_salen_en_ninguna_seccion() {
  sandbox >/dev/null
  local f="$SB/t.md"
  cat > "$f" <<'MD'
---
task: t
project: p
status: open
---

## Objetivo

Lo de /home/alguien/Proyectos/cliente/api

## Pasos

- [x] T1 medir · evidencia: /home/alguien/salida.txt

## Verificación

- ok · cmd (1s)
MD
  local cuerpo; cuerpo="$(node "$CRUX_HOME/lib/task.mjs" body --file "$f" --lang es)"
  assert_not_contains "$cuerpo" "/home/alguien" "ni en el objetivo ni en la evidencia"
  # La tilde aqui es el texto que se espera en la salida, no una ruta.
  # shellcheck disable=SC2088
  assert_contains "$cuerpo" "~/Proyectos/cliente/api" "se sustituyen por la tilde"
}
