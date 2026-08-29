#!/usr/bin/env bash

# `crux bootstrap` es lo que se ejecuta en una máquina donde no hay nada. Aquí se
# le pone delante un `gh` de mentira, porque lo que hay que comprobar no es que
# GitHub responda: es qué considera un proyecto y qué hace con la lista.

_maquina_lista() {
  # Las prendas mínimas que exige el doctor de máquina, dentro del sandbox.
  export CRUX_CONFIG="$SB/crux-config"
  cat > "$CRUX_CONFIG" <<EOF
CRUX_REMOTE="git@github.com:jocarrd/{repo}.git"
EOF
  mkdir -p "$CLAUDE_SKILLS_DIR/una-skill"
}

_gh_falso() {
  # $1 = lista de repos separada por espacios
  # $2 = los que tienen contrato, separados por espacios
  mkdir -p "$SB/bin"
  cat > "$SB/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  auth) exit 0 ;;
  repo) printf '%s\n' $1 ; exit 0 ;;
  api)
    case "\$2" in
      user) echo jocarrd; exit 0 ;;
      *)
        for c in $2; do
          [[ "\$2" == *"/\$c-docs/"* ]] && exit 0
        done
        exit 1 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

test_bootstrap_solo_toma_por_proyecto_lo_que_lleva_contrato() {
  sandbox >/dev/null
  _maquina_lista
  # tres repos acaban en -docs, pero solo dos llevan crux.json. El tercero es
  # documentación de algo que no es un proyecto del estándar.
  _gh_falso "alfa-docs beta-docs apuntes-docs otro-repo" "alfa beta"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run 2>&1)"

  assert_contains "$out" "alfa" "toma el que lleva contrato"
  assert_contains "$out" "beta" "toma el otro que lleva contrato"
  assert_contains "$out" "apuntes-docs sin contrato" "descarta el que no lo lleva y dice por qué"
  assert_not_contains "$out" "otro-repo" "un repo que no acaba en -docs ni se mira"
  teardown
}

test_bootstrap_only_filtra() {
  sandbox >/dev/null
  _maquina_lista
  _gh_falso "alfa-docs beta-docs" "alfa beta"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --only beta --dry-run 2>&1)"

  assert_contains "$out" "beta" "trae el pedido"
  assert_not_contains "$out" "traería 2" "y solo ese"
  teardown
}

test_bootstrap_en_seco_no_clona_nada() {
  sandbox >/dev/null
  _maquina_lista
  _gh_falso "alfa-docs" "alfa"

  crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run >/dev/null 2>&1
  assert_no_file "$CRUX_PROJECTS_DIR/alfa" "--dry-run no toca el disco"
  teardown
}

test_bootstrap_para_si_la_maquina_no_esta_lista() {
  sandbox >/dev/null
  # Sin config de máquina: clonar veinte repos para descubrir después que falta
  # algo es la peor forma de enterarse, así que ni empieza.
  export CRUX_CONFIG="$SB/no-existe"
  mkdir -p "$CLAUDE_SKILLS_DIR/una-skill"
  _gh_falso "alfa-docs" "alfa"

  assert_exit 1 "no sigue con la máquina a medias" \
    crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" --dry-run
  teardown
}

test_bootstrap_dice_que_repos_se_quedan_fuera() {
  sandbox >/dev/null
  _maquina_lista
  # Dos repos sueltos que no pertenecen a ningún proyecto. No los trae, pero
  # callárselo sería peor: te vas creyendo que está todo.
  _gh_falso "alfa-docs suelto-uno suelto-dos" "alfa"
  mkdir -p "$CRUX_PROJECTS_DIR/alfa/alfa-docs"

  local out
  out="$(crux bootstrap --owner jocarrd --parent "$CRUX_PROJECTS_DIR" 2>&1)"

  assert_contains "$out" "suelto-uno" "nombra el repo que se queda fuera"
  assert_contains "$out" "suelto-dos" "y el otro"
  teardown
}
