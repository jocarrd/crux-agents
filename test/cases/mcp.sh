#!/usr/bin/env bash

# The file this command writes is read by an agent, not a person: if it comes
# out wrong, nobody sees an error — the server is simply not there. That is why
# the negative cases matter most: an invalid contract must never get written,
# and a hand-written credential must stop the doctor.

mcp_declares() {
  # mcp_declares <docs> <mcp block json> — injects it into the contract
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const c = JSON.parse(fs.readFileSync(f, "utf8"));
    c.mcp = JSON.parse(process.argv[2]);
    fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");
  ' "$1/crux.json" "$2"
}

mcp_run() {
  # mcp_run <docs> <action>
  (cd "$1" && bash "$CRUX_HOME/bin/mcp.sh" "$2" 2>&1)
}

test_mcp_writes_only_in_docs_repo_by_default() {
  sandbox >/dev/null
  local docs; docs="$(new_project alfa --repos "api,web")"
  mcp_declares "$docs" '{"refs":{"transport":"http","url":"https://e.example/mcp"}}'

  mcp_run "$docs" install >/dev/null
  assert_file "$docs/.mcp.json" "writes the file in the docs repo"
  assert_no_file "$(dirname "$docs")/api/.mcp.json" "without a declared repos it stays in the docs repo"

  local written; written="$(cat "$docs/.mcp.json")"
  assert_contains "$written" '"type": "http"' "translates transport to type"
  assert_contains "$written" "https://e.example/mcp" "keeps the url"
}

test_mcp_distributes_to_declared_repos() {
  sandbox >/dev/null
  local docs; docs="$(new_project beta --repos "api,web")"
  local root; root="$(dirname "$docs")"
  mkdir -p "$root/api" "$root/web"
  mcp_declares "$docs" '{"engine":{"transport":"stdio","command":"node","args":["./s.mjs"],"repos":"all"}}'

  mcp_run "$docs" install >/dev/null
  assert_file "$root/api/.mcp.json" "distributes to the code repos with repos:all"
  assert_file "$root/web/.mcp.json" "distributes to all, not just the first"
  assert_contains "$(cat "$root/api/.mcp.json")" '"command": "node"' "writes the stdio shape"
}

test_mcp_respects_client_profile() {
  sandbox >/dev/null
  local docs; docs="$(new_project gamma --repos "theirs" --profile client-repo)"
  local root; root="$(dirname "$docs")"
  mkdir -p "$root/theirs"
  mcp_declares "$docs" '{"refs":{"transport":"http","url":"https://e.example/mcp","repos":"all"}}'

  local output; output="$(mcp_run "$docs" install)"
  assert_no_file "$root/theirs/.mcp.json" "leaves none of our configuration in the client repo"
  assert_file "$docs/.mcp.json" "but does write it in the docs repo, which is ours"
  assert_contains "$output" "does not write in code repos" "says why it stayed inside"
}

test_mcp_does_not_write_invalid_contract() {
  sandbox >/dev/null
  local docs; docs="$(new_project delta)"
  mcp_declares "$docs" '{"malo":{"transport":"grpc","url":"https://e.example/mcp"}}'

  assert_exit 1 "install fails with a transport the client does not understand" \
    bash -c "cd '$docs' && bash '$CRUX_HOME/bin/mcp.sh' install"
  assert_no_file "$docs/.mcp.json" "and does not leave the file half-written"
}

test_mcp_stops_on_inline_credential() {
  sandbox >/dev/null
  local docs; docs="$(new_project epsilon)"
  mcp_declares "$docs" '{"x":{"transport":"http","url":"https://e.example/mcp","headers":{"Authorization":"Bearer abc123def456ghi"}}}'

  local output; output="$(mcp_run "$docs" install)"
  assert_contains "$output" 'use ${VARIABLE}' "requires referencing the credential, not writing it"
  assert_no_file "$docs/.mcp.json" "a literal secret never reaches git"
}

test_mcp_remove_respects_foreign_entries() {
  sandbox >/dev/null
  local docs; docs="$(new_project zeta)"
  mcp_declares "$docs" '{"ours":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.mcpServers.foreign = { type: "http", url: "https://otro.example/mcp" };
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$docs/.mcp.json"

  mcp_run "$docs" remove >/dev/null
  local left; left="$(cat "$docs/.mcp.json")"
  assert_not_contains "$left" "ours" "removes what the contract declares"
  assert_contains "$left" "foreign" "and leaves what someone else put there"
}

test_mcp_deletes_file_if_only_its_own() {
  sandbox >/dev/null
  local docs; docs="$(new_project eta)"
  mcp_declares "$docs" '{"only":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null
  mcp_run "$docs" remove >/dev/null

  assert_no_file "$docs/.mcp.json" "with nothing inside the file goes away, no skeleton is left"
}

test_doctor_fails_on_misdeclared_mcp() {
  sandbox >/dev/null
  local docs; docs="$(new_project theta)"
  mcp_declares "$docs" '{"roto":{"transport":"http"}}'

  local output; output="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_contains "$output" "without 'url'" "the doctor names the missing field"
  assert_exit 1 "and does not call the project conformant" \
    bash "$CRUX_HOME/bin/doctor.sh" "$docs"
}

test_doctor_warns_of_mcp_the_contract_does_not_declare() {
  sandbox >/dev/null
  local docs; docs="$(new_project iota)"
  mcp_declares "$docs" '{"declared":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.mcpServers.smuggled = { type: "http", url: "https://otro.example/mcp" };
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$docs/.mcp.json"

  assert_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "which the contract does not declare" \
    "the drift between the file and the contract shows"
}

test_check_secrets_also_scans_mcp_json() {
  sandbox >/dev/null
  local docs; docs="$(new_project kappa)"
  cat > "$docs/.mcp.json" <<'JSON'
{ "mcpServers": { "x": { "type": "http", "url": "https://e.example/mcp",
  "headers": { "Authorization": "Bearer ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789" } } } }
JSON

  assert_contains "$(node "$CRUX_HOME/lib/check-secrets.mjs" "$docs")" "GitHub token" \
    "a token in the .mcp.json does not slip through for not being markdown"
}

# --- What the proposal review found ------------------------------------------

test_mcp_does_not_run_code_hidden_in_a_name() {
  sandbox >/dev/null
  local docs; docs="$(new_project lambda)"
  local marker="$SB/EXECUTED"

  # The contract travels in git: `crux clone` brings it from someone else's
  # remote. If the name ends up inside an expression that gets evaluated,
  # opening the project and asking for the status is enough to run code as
  # the user.
  node -e '
    const fs = require("fs");
    const [f, marker] = process.argv.slice(1);
    const c = JSON.parse(fs.readFileSync(f, "utf8"));
    const name = `x"];require("fs").writeFileSync(${JSON.stringify(marker)},"1");root.mcp["x`;
    c.mcp = { [name]: { transport: "stdio", command: "node" } };
    fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");
  ' "$docs/crux.json" "$marker"

  mcp_run "$docs" status >/dev/null 2>&1 || true
  assert_no_file "$marker" "a server name is not evaluated as code"

  assert_contains "$(mcp_run "$docs" install)" "is not valid as a server name" \
    "and it is also rejected on install"
}

test_mcp_stops_on_secret_in_url() {
  sandbox >/dev/null
  local docs; docs="$(new_project mu)"
  mcp_declares "$docs" '{"a":{"transport":"http","url":"https://jorge:RealSecret123@interno.example/mcp"}}'

  assert_contains "$(mcp_run "$docs" install)" "URL with a password inside" \
    "a credential in the url does not slip through for not being in a header"
  assert_no_file "$docs/.mcp.json" "and it never gets written"
}

test_mcp_stops_on_secret_in_args() {
  sandbox >/dev/null
  local docs; docs="$(new_project nu)"
  mcp_declares "$docs" '{"b":{"transport":"stdio","command":"node","args":["./s.mjs","--token","ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"]}}'

  assert_contains "$(mcp_run "$docs" install)" "GitHub token" \
    "a token passed as an argument does not slip through either"
  assert_no_file "$docs/.mcp.json" "and it never gets written"
}

test_doctor_warns_when_mcp_json_missing() {
  sandbox >/dev/null
  local docs; docs="$(new_project xi)"
  mcp_declares "$docs" '{"one":{"transport":"http","url":"https://e.example/mcp"}}'

  # Without having run install: on a freshly cloned machine there is no file,
  # and saying "ok" there is the failure that costs most to see, because it
  # looks like it works.
  assert_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "has no .mcp.json" \
    "the doctor does not accept a file that does not exist"
}

test_doctor_sees_hand_edited_mcp_json() {
  sandbox >/dev/null
  local docs; docs="$(new_project omicron)"
  mcp_declares "$docs" '{"one":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null

  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.mcpServers.one.url = "https://hijacked.example/mcp";
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$docs/.mcp.json"

  assert_contains "$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" "different from what is declared" \
    "a url changed in the file does not pass as conformant"
}

test_mcp_status_does_not_hide_unreadable_file() {
  sandbox >/dev/null
  local docs; docs="$(new_project pi)"
  mcp_declares "$docs" '{"one":{"transport":"http","url":"https://e.example/mcp"}}'
  mcp_run "$docs" install >/dev/null
  printf 'this is not json {{{' > "$docs/.mcp.json"

  assert_contains "$(mcp_run "$docs" status)" "unreadable" \
    "the repo whose file is broken does not vanish from the report"
}
