#!/usr/bin/env bash
# Lo que pasa después de abrir la propuesta: el riesgo y los especialistas, el
# CI, el despliegue y las señales de producción.

_pm_repo_con_base() {
  # _pm_repo_con_base <dir>: repo con una rama principal y una rama de trabajo
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo "x" > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
  git -C "$1" checkout -q -b trabajo
}

_pm_commit_todo() {
  git add -A && git commit -qm cambio
}

test_review_scope_gradua_el_riesgo_segun_el_diff() {
  sandbox >/dev/null
  local repo="$SB/riesgo" out
  _pm_repo_con_base "$repo"
  cd "$repo" || return
  local script="$CRUX_HOME/skills/review-pr/scripts/review-scope.sh"

  echo "más texto" >> README.md; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "riesgo: bajo" "un cambio de solo texto es de riesgo bajo"
  assert_contains "$out" "especialistas: ninguno" "y no paga ningún especialista"
  assert_contains "$out" "puede fusionarse sin preguntar" "y en un proyecto propio puede fusionarse solo"

  git reset -q --hard main
  mkdir -p src/components
  printf 'a\nb\n' > src/components/Boton.tsx; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "riesgo: bajo" "dos líneas de interfaz no merecen especialista"
  assert_contains "$out" "fusión: decide una persona" "pero con código decide una persona"

  git reset -q --hard main
  mkdir -p src/components
  seq 1 80 | sed 's/^/const v/' > src/components/Tarjeta.tsx; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "riesgo: medio" "una pantalla es riesgo medio"
  assert_contains "$out" "especialistas: interfaz" "y pide solo el de interfaz"

  git reset -q --hard main
  mkdir -p src/auth
  seq 1 40 > src/auth/session.ts; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "riesgo: alto" "tocar la sesión es riesgo alto"
  assert_contains "$out" "seguridad" "y pide el especialista de seguridad"

  git reset -q --hard main
  mkdir -p db/migrations
  echo "ALTER TABLE users DROP COLUMN name;" > db/migrations/001.sql; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "riesgo: alto" "una migración es riesgo alto aunque sea una línea"
  assert_contains "$out" "datos" "y pide el especialista de datos"

  cd "$CRUX_HOME" || return
}

test_review_scope_en_repo_de_cliente_siempre_decide_una_persona() {
  sandbox >/dev/null
  local proyecto="$SB/cliente" out
  mkdir -p "$proyecto"
  echo '{"crux":"0.39.0","project":"cliente","profile":"client-repo"}' > "$proyecto/crux.json"
  _pm_repo_con_base "$proyecto/app"
  cd "$proyecto/app" || return

  echo "más texto" >> README.md; _pm_commit_todo
  out="$(bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" main)"
  assert_contains "$out" "fusión: decide una persona" "ni siquiera un cambio de texto se fusiona solo"

  echo '{"crux":' > "$proyecto/crux.json"
  out="$(bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" main)"
  assert_contains "$out" "no se puede leer" "un contrato roto no se lee como proyecto propio"

  cd "$CRUX_HOME" || return
}

test_review_scope_se_para_sin_base() {
  sandbox >/dev/null
  _pm_repo_con_base "$SB/sinbase"
  cd "$SB/sinbase" || return
  assert_exit 1 "una base que no existe no se convierte en 'sin cambios'" \
    bash "$CRUX_HOME/skills/review-pr/scripts/review-scope.sh" origin/no-existe
  cd "$CRUX_HOME" || return
}

_pm_gh_falso() {
  # _pm_gh_falso <dir> <rollup-json> [fichero-contador]: un gh que responde lo justo
  mkdir -p "$1"
  cat > "$1/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")
    if [[ -n "${3:-}" ]]; then
      n=\$(cat "${3:-/dev/null}" 2>/dev/null || echo 0); echo \$((n + 1)) > "${3:-/dev/null}"
      if [[ \$n -eq 0 ]]; then
        echo '{"statusCheckRollup":[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""}]}'
        exit 0
      fi
    fi
    cat <<'JSON'
$2
JSON
    ;;
  "repo view") echo "dueno/repo" ;;
  "api repos/dueno/repo/actions/jobs/22/logs")
    printf '%s\n' \
      "2026-09-16T10:00:00.0000000Z > vitest run" \
      "2026-09-16T10:00:01.0000000Z Error: la suma devuelve 5 y se esperaba 4" \
      "2026-09-16T10:00:01.0000000Z \$(printf 'x%.0s' \$(seq 1 2000))" \
      "2026-09-16T10:00:01.0000000Z     at sumar (src/sumar.ts:3:9)" \
      "2026-09-16T10:00:01.0000000Z     at a (x.js:1:1)" \
      "2026-09-16T10:00:01.0000000Z     at b (x.js:1:1)" \
      "2026-09-16T10:00:01.0000000Z     at c (x.js:1:1)" \
      "2026-09-16T10:00:02.0000000Z ##[error]Process completed with exit code 1." \
      "2026-09-16T10:00:03.0000000Z Post job cleanup." \
      "2026-09-16T10:00:03.0000000Z borrando credenciales" ;;
  *) echo "gh falso: no sé responder a \$*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$1/gh"
}

test_checks_trae_solo_el_final_del_log_que_falla() {
  sandbox >/dev/null
  local rollup='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/dueno/repo/actions/runs/11/job/22"},
    {"__typename":"StatusContext","context":"despliegue","state":"SUCCESS","targetUrl":"https://x"}]}'
  _pm_gh_falso "$SB/bin" "$rollup"

  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/checks.sh" 7 2>&1)" || rc=$?
  assert_eq "1" "$rc" "una comprobación en rojo sale en rojo"
  assert_contains "$out" "la suma devuelve 5" "trae el mensaje del error"
  assert_contains "$out" "pila de llamadas recortada" "recorta la pila en vez de llenar el contexto con ella"
  assert_not_contains "$out" "borrando credenciales" "y deja fuera la limpieza posterior al error"
  local ancha; ancha="$(echo "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  [[ "$ancha" -le 320 ]] && PASS=$((PASS + 1)) || _fail "una línea minificada llega entera al contexto ($ancha caracteres)"
  assert_contains "$out" "1 en verde u omitidas" "los estados de terceros también se leen, y lo verde se resume"
  assert_not_contains "$out" "pass      despliegue" "sin listar cada comprobación en verde"
}

test_checks_distingue_sin_comprobaciones_de_verde() {
  sandbox >/dev/null
  _pm_gh_falso "$SB/bin" '{"statusCheckRollup":[]}'
  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/checks.sh" 7 2>&1)" || rc=$?
  assert_eq "2" "$rc" "sin comprobaciones no es verde"
  assert_contains "$out" "no es lo mismo que verificada" "y lo dice"
}

test_checks_espera_a_las_pendientes() {
  sandbox >/dev/null
  _pm_gh_falso "$SB/bin" '{"statusCheckRollup":[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}' "$SB/llamadas"
  local out rc=0
  out="$(env PATH="$SB/bin:$PATH" CRUX_CHECKS_INTERVAL=0 bash "$CRUX_HOME/bin/checks.sh" 7 --wait 2>&1)" || rc=$?
  assert_eq "0" "$rc" "espera a que termine y sale en verde"
  assert_contains "$out" "todas en verde" "y lo dice"
}

test_checks_no_disimula_un_rollup_ilegible() {
  sandbox >/dev/null
  _pm_gh_falso "$SB/bin" 'esto no es json'
  local rc=0
  env PATH="$SB/bin:$PATH" bash "$CRUX_HOME/bin/checks.sh" 7 >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "una respuesta ilegible para, no se lee como sin comprobaciones"
}

_pm_servidor() {
  # _pm_servidor <dir>: levanta un servidor local y deja su puerto en <dir>/puerto
  cat > "$1/server.js" <<'JS'
const http = require("http");
const s = http.createServer((q, r) => {
  if (q.url === "/roto") { r.writeHead(500); return r.end("mal"); }
  if (q.url === "/disimulado") { r.writeHead(200); return r.end("<h1>Internal Server Error</h1>"); }
  r.writeHead(200); r.end("<html>version nueva</html>");
});
s.listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[2], String(s.address().port)));
JS
  node "$1/server.js" "$1/puerto" &
  SERVIDOR_PID=$!
  local _
  for _ in $(seq 1 50); do [[ -s "$1/puerto" ]] && break; sleep 0.1; done
}

test_smoke_ve_las_rutas_rotas_y_la_version_nueva() {
  sandbox >/dev/null
  _pm_servidor "$SB"
  local url out rc
  url="http://127.0.0.1:$(cat "$SB/puerto")"
  local script="$CRUX_HOME/skills/deploy-watch/scripts/smoke.sh"

  rc=0; out="$(cd "$SB" && bash "$script" --url "$url" / /roto /disimulado 2>&1)" || rc=$?
  assert_eq "1" "$rc" "una ruta rota sale en rojo"
  assert_contains "$out" "/roto → 500" "nombra la ruta y el código"
  assert_contains "$out" "página de error" "y caza el error servido con 200"

  rc=0; out="$(cd "$SB" && bash "$script" --url "$url" --expect "version nueva" / 2>&1)" || rc=$?
  assert_eq "0" "$rc" "con la versión nueva respondiendo, sale en verde"

  rc=0; out="$(cd "$SB" && env CRUX_SMOKE_INTERVAL=0 bash "$script" --url "$url" --expect "otra version" --timeout 0 / 2>&1)" || rc=$?
  assert_eq "3" "$rc" "si la versión nueva no llega, lo distingue de una ruta rota"

  kill "$SERVIDOR_PID" 2>/dev/null; wait "$SERVIDOR_PID" 2>/dev/null
}

test_smoke_lee_el_contrato_y_para_si_no_puede() {
  sandbox >/dev/null
  local p="$SB/proyecto" rc out
  mkdir -p "$p"
  local script="$CRUX_HOME/skills/deploy-watch/scripts/smoke.sh"

  echo '{"crux":"0.39.0","project":"p"}' > "$p/crux.json"
  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "sin 'deploy' en el contrato para"
  assert_contains "$out" "no declara 'deploy'" "y dice qué falta"

  echo '{"crux":' > "$p/crux.json"
  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "un contrato ilegible no se convierte en una url por defecto"
}

test_signals_agrupa_y_no_se_come_las_fuentes_siguientes() {
  sandbox >/dev/null
  local p="$SB/proyecto" out rc
  mkdir -p "$p"
  cat > "$p/crux.json" <<'JSON'
{"crux":"0.39.0","project":"p","observability":{"sources":[
  {"name":"lee-stdin","command":"cat; for i in 1 2 3 4 5; do echo \"2026-09-16T10:0$i:00Z ERROR timeout tras ${i}00ms\"; done; echo 'INFO todo bien'"},
  {"name":"estado","command":"echo 'worker Restarting (1) hace {since}'"}
]}}
JSON
  rc=0; out="$(cd "$p" && bash "$CRUX_HOME/skills/prod-signals/scripts/signals.sh" --since 2h 2>&1)" || rc=$?
  assert_eq "0" "$rc" "lee las fuentes"
  assert_contains "$out" "5×" "agrupa las líneas que solo cambian en fechas y números"
  assert_not_contains "$out" "todo bien" "y deja fuera lo que no parece un problema"
  assert_contains "$out" "Restarting (1) hace 2h" "una fuente que lee la entrada no se come la siguiente, y {since} se sustituye"

  # Un solo argumento no pasa de 128 KB en Linux: un log de verdad los supera.
  cat > "$p/crux.json" <<'JSON'
{"observability":{"sources":[{"name":"grande","command":"for i in $(seq 1 6000); do echo \"ERROR fallo número $i con bastante texto detrás para ocupar\"; done"}]}}
JSON
  rc=0; out="$(cd "$p" && bash "$CRUX_HOME/skills/prod-signals/scripts/signals.sh" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "un log de más de 128 KB se resume sin romper"
  assert_contains "$out" "6000×" "y agrupa todas sus líneas"
}

test_signals_distingue_sin_fuentes_de_contrato_roto() {
  sandbox >/dev/null
  local p="$SB/proyecto" rc
  mkdir -p "$p"
  local script="$CRUX_HOME/skills/prod-signals/scripts/signals.sh"

  echo '{"crux":"0.39.0","project":"p"}' > "$p/crux.json"
  rc=0; (cd "$p" && bash "$script" >/dev/null 2>&1) || rc=$?
  assert_eq "2" "$rc" "sin fuentes declaradas lo dice con su propio código"

  echo '{"observability":{"sources":[{"name":"sin-comando"}]}}' > "$p/crux.json"
  rc=0; (cd "$p" && bash "$script" >/dev/null 2>&1) || rc=$?
  assert_eq "1" "$rc" "una fuente mal declarada para"

  echo '{"crux":' > "$p/crux.json"
  rc=0; (cd "$p" && bash "$script" >/dev/null 2>&1) || rc=$?
  assert_eq "1" "$rc" "un contrato ilegible para"
}

test_signals_avisa_si_el_contrato_tiene_cambios_sin_commitear() {
  sandbox >/dev/null
  local p="$SB/docs" rc out
  mkdir -p "$p"
  git -C "$p" init -q -b main
  echo '{"observability":{"sources":[{"name":"app","command":"echo ERROR de main"}]}}' > "$p/crux.json"
  git -C "$p" add -A; git -C "$p" commit -qm init
  local script="$CRUX_HOME/skills/prod-signals/scripts/signals.sh"

  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "el contrato commiteado se lee"
  assert_not_contains "$out" "sin commitear" "y sin avisos"

  echo '{"observability":{"sources":[{"name":"app","command":"echo ERROR tocado"}]}}' > "$p/crux.json"
  rc=0; out="$(cd "$p" && bash "$script" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "con cambios sin commitear no se bloquea"
  assert_contains "$out" "cambios sin commitear" "pero se avisa antes de ejecutar"
}

test_review_scope_no_toma_dependencias_ni_tests_por_texto() {
  sandbox >/dev/null
  local repo="$SB/deps" out
  _pm_repo_con_base "$repo"
  cd "$repo" || return
  local script="$CRUX_HOME/skills/review-pr/scripts/review-scope.sh"

  echo "paquete==1.0" > requirements.txt; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "riesgo: alto" "una dependencia nueva no es texto"
  assert_contains "$out" "seguridad" "y pide el especialista de seguridad"
  assert_contains "$out" "decide una persona" "y no se fusiona sola"

  git reset -q --hard main
  mkdir -p pkg/tests
  echo "import os" > pkg/tests/conftest.py; _pm_commit_todo
  out="$(bash "$script" main)"
  assert_contains "$out" "fusión: decide una persona" "un test lo ejecuta el CI: no se fusiona sin preguntar"

  cd "$CRUX_HOME" || return
}
