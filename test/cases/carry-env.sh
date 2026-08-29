#!/usr/bin/env bash

# `carry-env` mueve ficheros con secretos dentro. Lo que hay que fijar no es que
# copie —eso es un `cp`— sino las tres cosas que lo hacen seguro de ejecutar.

_proyecto_con_entornos() {
  local raiz="$SB/proyecto"
  mkdir -p "$raiz"/{api,web/.next,api-ws-tarea,web/apps/movil}
  echo "TOKEN=valor-que-no-debe-salir-por-pantalla" > "$raiz/api/.env"
  echo "X=1" > "$raiz/web/.env.production"
  echo "X=1" > "$raiz/web/apps/movil/.env.local"
  echo "X=1" > "$raiz/api-ws-tarea/.env"          # copia de espacio de trabajo
  echo "X=1" > "$raiz/web/.next/.env.production"  # artefacto de construccion
  echo "X=1" > "$raiz/web/.env.example"           # plantilla
  echo "$raiz"
}

test_carry_env_no_imprime_el_contenido_de_ningun_fichero() {
  sandbox >/dev/null
  local raiz; raiz="$(_proyecto_con_entornos)"

  local out
  out="$(bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$raiz" --out "$SB/salida" 2>&1)"

  # La garantia de la que depende todo: un agente puede ejecutarlo sin que un
  # secreto acabe escrito en la transcripcion de la sesion.
  assert_not_contains "$out" "valor-que-no-debe-salir" "no vuelca el contenido"
  assert_file "$SB/salida/.env.api" "pero sí lo copia"
  teardown
}

test_carry_env_se_salta_lo_derivado() {
  sandbox >/dev/null
  local raiz; raiz="$(_proyecto_con_entornos)"
  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$raiz" --out "$SB/salida" >/dev/null 2>&1

  assert_file "$SB/salida/.env.api" "el del repo"
  assert_file "$SB/salida/.env.web.production" "y el de otro repo"
  assert_file "$SB/salida/.env.web.movil.local" "uno anidado, con su directorio en el nombre"
  # Restaurar una copia de espacio de trabajo encima de la buena deja un entorno
  # que parece bien y apunta a otros puertos.
  assert_no_file "$SB/salida/.env.api-ws-tarea" "no se lleva copias de espacios de trabajo"
  assert_no_file "$SB/salida/.env.web.next.production" "ni artefactos de construcción"
  assert_no_file "$SB/salida/.env.web.example" "ni plantillas"
  teardown
}

test_carry_env_deja_el_mapa_y_el_camino_de_vuelta() {
  sandbox >/dev/null
  local raiz; raiz="$(_proyecto_con_entornos)"
  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$raiz" --out "$SB/salida" >/dev/null 2>&1

  assert_file "$SB/salida/RESTAURAR.md" "el mapa"
  assert_file "$SB/salida/restaurar.sh" "el camino de vuelta"
  assert_contains "$(cat "$SB/salida/RESTAURAR.md")" "api/.env" "el mapa dice el destino"
  assert_not_contains "$(cat "$SB/salida/RESTAURAR.md")" "valor-que-no-debe-salir" \
    "y el mapa no lleva ningún valor"
  teardown
}

test_carry_env_no_sobreescribe_al_restaurar() {
  sandbox >/dev/null
  local raiz; raiz="$(_proyecto_con_entornos)"
  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$raiz" --out "$SB/salida" >/dev/null 2>&1

  # Destino con algo distinto dentro: perder un valor que solo estaba ahí es
  # peor que copiar de menos.
  local destino="$SB/destino"
  mkdir -p "$destino/api" "$destino/web"
  echo "LO-QUE-YA-HABIA=1" > "$destino/api/.env"

  bash "$SB/salida/restaurar.sh" "$destino" --hazlo >/dev/null 2>&1

  assert_eq "LO-QUE-YA-HABIA=1" "$(cat "$destino/api/.env")" "no pisa lo que ya estaba"
  assert_file "$destino/web/.env.production" "y sí pone lo que faltaba"
  teardown
}

# El ancla. Reunir apuntando a un repo dejaba un paquete que se cree un proyecto
# llamado como el repo, con rutas relativas a él: en la máquina nueva se busca
# <raíz>/<repo>, que no existe, y no hay forma de restaurarlo sin saber el porqué.
# El fallo no se ve al reunirlos sino meses después, que es cuando ya no ayuda.

_proyecto_adoptado() {
  local raiz="$SB/Proyectos/tienda"
  mkdir -p "$raiz/tienda-docs" "$raiz/tienda-api"
  echo '{"project": "tienda"}' > "$raiz/tienda-docs/crux.json"
  echo "X=1" > "$raiz/tienda-api/.env"
  echo "$raiz"
}

test_carry_env_ancla_en_la_raiz_aunque_le_apuntes_a_un_repo() {
  sandbox >/dev/null
  local raiz; raiz="$(_proyecto_adoptado)"

  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$raiz/tienda-api" --out "$SB/salida" >/dev/null 2>&1

  # La línea entera: "tienda-api" contiene "tienda", así que un contains pasaría
  # aunque el paquete se creyera el repo.
  assert_eq "# proyecto: tienda" "$(head -1 "$SB/salida/mapa.txt")" \
    "el paquete se llama como el proyecto, no como el repo"
  assert_contains "$(cat "$SB/salida/mapa.txt")" "tienda-api/.env" \
    "y las rutas son relativas a la raíz del proyecto"
  teardown
}

test_carry_env_restaura_un_paquete_reunido_como_repo() {
  sandbox >/dev/null
  local raiz; raiz="$(_proyecto_adoptado)"
  rm -f "$raiz/tienda-api/.env"

  # Un paquete como los que dejaba la versión anterior: nombrado como el repo.
  mkdir -p "$SB/viejo"
  printf '# proyecto: tienda-api\n.env|.env\n' > "$SB/viejo/mapa.txt"
  echo "X=1" > "$SB/viejo/.env"
  cp "$CRUX_HOME/skills/carry-env/scripts/restaurar.sh" "$SB/viejo/"

  CRUX_PROJECTS_DIR="$SB/Proyectos" bash "$SB/viejo/restaurar.sh" --hazlo >/dev/null 2>&1

  assert_file "$raiz/tienda-api/.env" \
    "lo encuentra un nivel más adentro en vez de rendirse"
  teardown
}

test_carry_env_nombra_los_de_la_raiz_sin_inventarse_un_repo() {
  sandbox >/dev/null
  mkdir -p "$SB/suelto"
  echo "X=1" > "$SB/suelto/.env"
  echo "X=1" > "$SB/suelto/.env.local"

  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$SB/suelto" --out "$SB/salida" >/dev/null 2>&1

  # Antes salía `.env..env.`: tomaba `.env` por nombre de repo. Un nombre que no
  # dice de dónde vino es exactamente lo que esta skill existe para evitar.
  assert_file "$SB/salida/.env" "el de la raíz se llama como es"
  assert_file "$SB/salida/.env.local" "y su variante también"
  teardown
}
