#!/usr/bin/env bash

# El fichero que escribe este comando lo lee un agente, no una persona: si sale
# mal, nadie ve un error — el servidor simplemente no está. Por eso los casos
# que más importan son los negativos: que un contrato inválido no llegue nunca
# a escribirse y que una credencial escrita a mano pare el doctor.

mcp_declara() {
  # mcp_declara <docs> <json del bloque mcp> — lo inyecta en el contrato
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const c = JSON.parse(fs.readFileSync(f, "utf8"));
    c.mcp = JSON.parse(process.argv[2]);
    fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");
  ' "$1/crux.json" "$2"
}

mcp_run() {
  # mcp_run <docs> <acción>
  (cd "$1" && bash "$CRUX_HOME/bin/mcp.sh" "$2" 2>&1)
}

test_mcp_escribe_solo_en_el_docs_repo_por_defecto() {
  sandbox >/dev/null
  local docs; docs="$(new_project alfa --repos "api,web")"
  mcp_declara "$docs" '{"refs":{"transport":"http","url":"https://e.example/mcp"}}'

  mcp_run "$docs" install >/dev/null
  assert_file "$docs/.mcp.json" "escribe el fichero en el docs repo"
  assert_no_file "$(dirname "$docs")/api/.mcp.json" "sin repos declarado no sale del docs repo"

  local escrito; escrito="$(cat "$docs/.mcp.json")"
  assert_contains "$escrito" '"type": "http"' "traduce transport a type"
  assert_contains "$escrito" "https://e.example/mcp" "conserva la url"
}

test_mcp_reparte_a_los_repos_declarados() {
  sandbox >/dev/null
  local docs; docs="$(new_project beta --repos "api,web")"
  local raiz; raiz="$(dirname "$docs")"
  mkdir -p "$raiz/api" "$raiz/web"
  mcp_declara "$docs" '{"engine":{"transport":"stdio","command":"node","args":["./s.mjs"],"repos":"all"}}'

  mcp_run "$docs" install >/dev/null
  assert_file "$raiz/api/.mcp.json" "reparte a los repos de código con repos:all"
  assert_file "$raiz/web/.mcp.json" "reparte a todos, no solo al primero"
  assert_contains "$(cat "$raiz/api/.mcp.json")" '"command": "node"' "escribe la forma de stdio"
}

test_mcp_respeta_el_perfil_de_cliente() {
  sandbox >/dev/null
  local docs; docs="$(new_project gamma --repos "suyo" --profile client-repo)"
  local raiz; raiz="$(dirname "$docs")"
  mkdir -p "$raiz/suyo"
  mcp_declara "$docs" '{"refs":{"transport":"http","url":"https://e.example/mcp","repos":"all"}}'

  local salida; salida="$(mcp_run "$docs" install)"
  assert_no_file "$raiz/suyo/.mcp.json" "no deja configuración nuestra en el repo del cliente"
  assert_file "$docs/.mcp.json" "pero sí en el docs repo, que es nuestro"
  assert_contains "$salida" "no escribe en los repos de código" "dice por qué se ha quedado dentro"
}

test_mcp_no_escribe_un_contrato_invalido() {
  sandbox >/dev/null
  local docs; docs="$(new_project delta)"
  mcp_declara "$docs" '{"malo":{"transport":"grpc","url":"https://e.example/mcp"}}'

  assert_exit 1 "install falla con un transporte que el cliente no entiende" \
    bash -c "cd '$docs' && bash '$CRUX_HOME/bin/mcp.sh' install"
  assert_no_file "$docs/.mcp.json" "y no deja el fichero a medias"
}

test_mcp_para_una_credencial_escrita_dentro() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon)"
  mcp_declara "$docs" '{"x":{"transport":"http","url":"https://e.example/mcp","headers":{"Authorization":"Bearer abc123def456ghi"}}}'

  local salida; salida="$(mcp_run "$docs" install)"
  assert_contains "$salida" 'usa ${VARIABLE}' "exige referenciar la credencial, no escribirla"
  assert_no_file "$docs/.mcp.json" "un secreto literal no llega a git"
}

test_mcp_remove_respeta_lo_que_no_es_suyo() {
  sandbox >/dev/null
  local docs; docs="$(new_project zeta)"
  mcp_declara "$docs" '{"nuestro":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.mcpServers.ajeno = { type: "http", url: "https://otro.example/mcp" };
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$docs/.mcp.json"

  mcp_run "$docs" remove >/dev/null
  local queda; queda="$(cat "$docs/.mcp.json")"
  assert_not_contains "$queda" "nuestro" "retira lo que declara el contrato"
  assert_contains "$queda" "ajeno" "y deja lo que puso otro"
}

test_mcp_borra_el_fichero_si_solo_era_suyo() {
  sandbox >/dev/null
  local docs; docs="$(new_project eta)"
  mcp_declara "$docs" '{"solo":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null
  mcp_run "$docs" remove >/dev/null

  assert_no_file "$docs/.mcp.json" "sin nada dentro el fichero se va, no queda un esqueleto"
}

test_doctor_falla_con_un_mcp_mal_declarado() {
  sandbox >/dev/null
  local docs; docs="$(new_project theta)"
  mcp_declara "$docs" '{"roto":{"transport":"http"}}'

  local salida; salida="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$salida" "sin 'url'" "el doctor nombra el campo que falta"
  assert_exit 1 "y no da el proyecto por conforme" \
    bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_avisa_de_un_mcp_que_el_contrato_no_declara() {
  sandbox >/dev/null
  local docs; docs="$(new_project iota)"
  mcp_declara "$docs" '{"declarado":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.mcpServers.colado = { type: "http", url: "https://otro.example/mcp" };
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$docs/.mcp.json"

  assert_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "que el contrato no declara" \
    "la deriva entre el fichero y el contrato se ve"
}

test_check_secrets_mira_tambien_los_mcp_json() {
  sandbox >/dev/null
  local docs; docs="$(new_project kappa)"
  cat > "$docs/.mcp.json" <<'JSON'
{ "mcpServers": { "x": { "type": "http", "url": "https://e.example/mcp",
  "headers": { "Authorization": "Bearer ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789" } } } }
JSON

  assert_contains "$(node "$CRUX_HOME/lib/check-secrets.mjs" "$docs")" "token de GitHub" \
    "un token en el .mcp.json no se escapa por no ser markdown"
}
