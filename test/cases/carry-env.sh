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
