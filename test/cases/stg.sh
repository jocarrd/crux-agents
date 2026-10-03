#!/usr/bin/env bash

# `crux stg` talks to a server over ssh, so a fake ssh is put in front of it
# here. What has to be checked is not that a server answers: it is which block
# it writes, with which user and in which order it validates and reloads, which
# is what decides whether a demo comes out published or broken.

_stg_config() {
  # $1 = sandbox root
  mkdir -p "$1/home/.crux"
  cat > "$1/home/.crux/staging.env" <<'EOF'
CRUX_STG_SSH=fake-server
CRUX_STG_DOMAIN=stg.example.test
CRUX_STG_ROOT=/opt/staging
CRUX_STG_CONTAINER=proxy
EOF
}

_stg_fakes() {
  # An ssh that records what it is asked and returns just enough to go on, and
  # an rsync that copies nothing but leaves a record of how it was called.
  mkdir -p "$SB/bin" "$SB/remote"
  cat > "$SB/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -o|BatchMode=yes|fake-server) continue ;; esac; cmd="$a"; done
echo "$cmd" >> "$SB/remote/orders"
case "$cmd" in
  *hash-password*) echo '$2a$14$fakehash' ;;
  *"cat > "*)      cat > "$SB/remote/block.caddy" ;;
  *validate*)      echo validated >> "$SB/remote/orders" ;;
  *reload*)        echo reloaded >> "$SB/remote/orders" ;;
  *"ls -1"*)       echo demo ;;
esac
exit 0
EOF
  cat > "$SB/bin/rsync" <<'EOF'
#!/usr/bin/env bash
echo "rsync $*" >> "$SB/remote/orders"
exit 0
EOF
  chmod +x "$SB/bin/ssh" "$SB/bin/rsync"
  export PATH="$SB/bin:$PATH"
  export SB
}

_stg() {
  # HOME goes per invocation: exporting it leaks into the next case.
  env HOME="$SB/home" PATH="$PATH" SB="$SB" bash "$CRUX_HOME/bin/crux" stg "$@" 2>&1
}

test_stg_stops_and_says_so_when_there_is_no_configuration() {
  sandbox >/dev/null
  mkdir -p "$SB/home"
  local output
  output="$(env HOME="$SB/home" bash "$CRUX_HOME/bin/crux" stg list 2>&1)"
  assert_contains "$output" "staging.env" "without configuration, it says which file is missing"

  # And a half configuration does not count as a complete one either.
  mkdir -p "$SB/home/.crux"
  echo "CRUX_STG_SSH=server" > "$SB/home/.crux/staging.env"
  output="$(env HOME="$SB/home" bash "$CRUX_HOME/bin/crux" stg list 2>&1)"
  assert_contains "$output" "CRUX_STG_DOMAIN" "names the missing variable"
  teardown
}

test_stg_rejects_a_name_that_is_not_a_domain_label() {
  sandbox >/dev/null
  _stg_config "$SB"
  _stg_fakes
  mkdir -p "$SB/site"; : > "$SB/site/index.html"

  local output
  for bad_one in "UPPER" "with space" "-leading" "trailing-"; do
    output="$(_stg deploy "$bad_one" "$SB/site")"
    assert_contains "$output" "invalid name" "rejects '$bad_one'"
  done
  assert_no_file "$SB/remote/block.caddy" "a bad name never gets to write anything"
  teardown
}

test_stg_publishes_with_its_own_user_and_validates_before_reloading() {
  sandbox >/dev/null
  _stg_config "$SB"
  _stg_fakes
  mkdir -p "$SB/site"; : > "$SB/site/index.html"

  local output block orders
  output="$(_stg deploy demo "$SB/site")"
  assert_contains "$output" "https://demo.stg.example.test" "returns the link"

  assert_file "$SB/remote/block.caddy" "writes the server block"
  block="$(cat "$SB/remote/block.caddy")"
  assert_contains "$block" "demo.stg.example.test {" "the block is the demo host's"
  assert_contains "$block" "demo \$2a\$14\$fakehash" "the user is the demo name"
  assert_contains "$block" "X-Robots-Tag" "unpublished work is not indexed"
  assert_contains "$block" "/srv/staging/demo" "serves the demo folder"
  assert_not_contains "$block" "import " "does not depend on snippets from another configuration"

  # Order matters: validate and only then reload.
  orders="$(cat "$SB/remote/orders")"
  assert_contains "$orders" "validated" "validates the configuration"
  assert_contains "$orders" "reloaded" "reloads"
  local pos_validated pos_reloaded
  pos_validated="$(grep -n validated "$SB/remote/orders" | head -1 | cut -d: -f1)"
  pos_reloaded="$(grep -n reloaded "$SB/remote/orders" | head -1 | cut -d: -f1)"
  if [[ -n "$pos_validated" && -n "$pos_reloaded" && "$pos_validated" -lt "$pos_reloaded" ]]; then
    PASS=$((PASS + 1))
  else
    _fail "reloads without having validated first"
  fi

  # The plain password stays on this machine, not in the server block.
  assert_file "$SB/home/.crux/staging/demo.pass" "keeps the password where it is deployed from"
  local key
  key="$(cat "$SB/home/.crux/staging/demo.pass")"
  assert_not_contains "$block" "$key" "the server only receives the hash"

  # And repeating the link does not rotate the password.
  output="$(_stg url demo)"
  assert_contains "$output" "$key" "url repeats the same password"
  teardown
}

test_stg_removes_a_demo_leaving_the_server_without_its_block() {
  sandbox >/dev/null
  _stg_config "$SB"
  _stg_fakes
  mkdir -p "$SB/site"; : > "$SB/site/index.html"
  _stg deploy demo "$SB/site" >/dev/null

  local output orders
  output="$(_stg rm demo)"
  assert_contains "$output" "removed demo" "says it removed it"
  orders="$(cat "$SB/remote/orders")"
  assert_contains "$orders" "demo.caddy" "deletes the block"
  assert_contains "$orders" "sites/demo" "deletes the files"
  assert_no_file "$SB/home/.crux/staging/demo.pass" "and the password is no longer stored"
  teardown
}
