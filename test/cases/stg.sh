#!/usr/bin/env bash

# `crux stg` habla con un servidor por ssh, así que aquí se le pone delante un
# ssh de mentira. Lo que hay que comprobar no es que un servidor responda: es
# qué bloque escribe, con qué usuario y en qué orden valida y recarga, que es
# lo que decide si una demo sale publicada o rota.

_stg_config() {
  # $1 = raíz del sandbox
  mkdir -p "$1/home/.crux"
  cat > "$1/home/.crux/staging.env" <<'EOF'
CRUX_STG_SSH=servidor-de-mentira
CRUX_STG_DOMAIN=stg.ejemplo.test
CRUX_STG_ROOT=/opt/staging
CRUX_STG_CONTAINER=proxy
EOF
}

_stg_falsos() {
  # Un ssh que anota lo que se le pide y devuelve lo justo para seguir, y un
  # rsync que no copia nada pero deja constancia de con qué se llamó.
  mkdir -p "$SB/bin" "$SB/remoto"
  cat > "$SB/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -o|BatchMode=yes|servidor-de-mentira) continue ;; esac; cmd="$a"; done
echo "$cmd" >> "$SB/remoto/ordenes"
case "$cmd" in
  *hash-password*) echo '$2a$14$hashdementira' ;;
  *"cat > "*)      cat > "$SB/remoto/bloque.caddy" ;;
  *validate*)      echo validado >> "$SB/remoto/ordenes" ;;
  *reload*)        echo recargado >> "$SB/remoto/ordenes" ;;
  *"ls -1"*)       echo demo ;;
esac
exit 0
EOF
  cat > "$SB/bin/rsync" <<'EOF'
#!/usr/bin/env bash
echo "rsync $*" >> "$SB/remoto/ordenes"
exit 0
EOF
  chmod +x "$SB/bin/ssh" "$SB/bin/rsync"
  export PATH="$SB/bin:$PATH"
  export SB
}

_stg() {
  # HOME va por invocación: exportarlo se lo lleva el caso siguiente.
  env HOME="$SB/home" PATH="$PATH" SB="$SB" bash "$CRUX_HOME/bin/crux" stg "$@" 2>&1
}

test_stg_para_y_lo_dice_cuando_no_hay_configuracion() {
  sandbox >/dev/null
  mkdir -p "$SB/home"
  local salida
  salida="$(env HOME="$SB/home" bash "$CRUX_HOME/bin/crux" stg list 2>&1)"
  assert_contains "$salida" "staging.env" "sin configuración, dice qué fichero falta"

  # Y una configuración a medias tampoco vale como una completa.
  mkdir -p "$SB/home/.crux"
  echo "CRUX_STG_SSH=servidor" > "$SB/home/.crux/staging.env"
  salida="$(env HOME="$SB/home" bash "$CRUX_HOME/bin/crux" stg list 2>&1)"
  assert_contains "$salida" "CRUX_STG_DOMAIN" "nombra la variable que falta"
  teardown
}

test_stg_rechaza_un_nombre_que_no_es_una_etiqueta_de_dominio() {
  sandbox >/dev/null
  _stg_config "$SB"
  _stg_falsos
  mkdir -p "$SB/sitio"; : > "$SB/sitio/index.html"

  local salida
  for malo in "MAYUS" "con espacio" "-delante" "detras-"; do
    salida="$(_stg deploy "$malo" "$SB/sitio")"
    assert_contains "$salida" "no válido" "rechaza '$malo'"
  done
  assert_no_file "$SB/remoto/bloque.caddy" "un nombre malo no llega a escribir nada"
  teardown
}

test_stg_publica_con_su_propio_usuario_y_valida_antes_de_recargar() {
  sandbox >/dev/null
  _stg_config "$SB"
  _stg_falsos
  mkdir -p "$SB/sitio"; : > "$SB/sitio/index.html"

  local salida bloque ordenes
  salida="$(_stg deploy demo "$SB/sitio")"
  assert_contains "$salida" "https://demo.stg.ejemplo.test" "devuelve el enlace"

  assert_file "$SB/remoto/bloque.caddy" "escribe el bloque del servidor"
  bloque="$(cat "$SB/remoto/bloque.caddy")"
  assert_contains "$bloque" "demo.stg.ejemplo.test {" "el bloque es el del host de la demo"
  assert_contains "$bloque" "demo \$2a\$14\$hashdementira" "el usuario es el nombre de la demo"
  assert_contains "$bloque" "X-Robots-Tag" "el trabajo sin publicar no se indexa"
  assert_contains "$bloque" "/srv/staging/demo" "sirve la carpeta de la demo"
  assert_not_contains "$bloque" "import " "no depende de snippets de otra configuración"

  # El orden importa: validar y sólo entonces recargar.
  ordenes="$(cat "$SB/remoto/ordenes")"
  assert_contains "$ordenes" "validado" "valida la configuración"
  assert_contains "$ordenes" "recargado" "recarga"
  local pos_validado pos_recargado
  pos_validado="$(grep -n validado "$SB/remoto/ordenes" | head -1 | cut -d: -f1)"
  pos_recargado="$(grep -n recargado "$SB/remoto/ordenes" | head -1 | cut -d: -f1)"
  if [[ -n "$pos_validado" && -n "$pos_recargado" && "$pos_validado" -lt "$pos_recargado" ]]; then
    PASS=$((PASS + 1))
  else
    _fail "recarga sin haber validado antes"
  fi

  # La clave en claro se queda en esta máquina, no en el bloque del servidor.
  assert_file "$SB/home/.crux/staging/demo.pass" "guarda la clave donde se despliega"
  local clave
  clave="$(cat "$SB/home/.crux/staging/demo.pass")"
  assert_not_contains "$bloque" "$clave" "el servidor sólo recibe el hash"

  # Y repetir el enlace no rota la clave.
  salida="$(_stg url demo)"
  assert_contains "$salida" "$clave" "url repite la misma clave"
  teardown
}

test_stg_retira_una_demo_dejando_el_servidor_sin_su_bloque() {
  sandbox >/dev/null
  _stg_config "$SB"
  _stg_falsos
  mkdir -p "$SB/sitio"; : > "$SB/sitio/index.html"
  _stg deploy demo "$SB/sitio" >/dev/null

  local salida ordenes
  salida="$(_stg rm demo)"
  assert_contains "$salida" "retirada demo" "dice que la ha retirado"
  ordenes="$(cat "$SB/remoto/ordenes")"
  assert_contains "$ordenes" "demo.caddy" "borra el bloque"
  assert_contains "$ordenes" "sites/demo" "borra los ficheros"
  assert_no_file "$SB/home/.crux/staging/demo.pass" "y la clave deja de estar guardada"
  teardown
}
