#!/usr/bin/env bash

# Casos de las fricciones de portabilidad que se ven al traer proyectos a una
# máquina nueva y al crear uno en una organización. Nombres genéricos a
# propósito: el kernel no nombra proyectos reales, ni siquiera en los tests.

crux_fn() {
  # crux_fn <función> <args...> — corre una función de lib/common.sh aislada.
  local fn="$1"; shift
  bash -c 'source "$1/lib/common.sh"; "$2" "${@:3}"' _ "$CRUX_HOME" "$fn" "$@"
}

test_normalize_git_url_iguala_ssh_y_https() {
  # Declarar ssh en el contrato y clonar con gh (que deja https) no debe parecer
  # un desalineo: es el mismo repo. Y el owner es case-insensitive.
  local ssh https
  ssh="$(crux_fn normalize_git_url "git@github.com:Acme-Org/foo.git")"
  https="$(crux_fn normalize_git_url "https://github.com/acme-org/foo.git")"
  assert_eq "$https" "$ssh" \
    "ssh y https del mismo repo normalizan igual, aunque cambie mayúsculas"

  local otro
  otro="$(crux_fn normalize_git_url "git@github.com:acme-org/bar.git")"
  assert_not_contains "$ssh" "$otro" \
    "dos repos distintos no normalizan al mismo valor"
}

test_owner_from_template_extrae_el_owner() {
  assert_eq "Acme-Org" \
    "$(crux_fn owner_from_template 'git@github.com:Acme-Org/{repo}.git')" \
    "el owner sale de la plantilla ssh"
  assert_eq "acme-org" \
    "$(crux_fn owner_from_template 'https://github.com/acme-org/{repo}.git')" \
    "el owner sale de la plantilla https"
  assert_eq "" \
    "$(crux_fn owner_from_template 'git@gitlab.com:acme-org/{repo}.git')" \
    "fuera de github no se adivina owner: se deja a gh su cuenta por defecto"
}

test_init_no_deja_un_runbook_huerfano() {
  sandbox >/dev/null
  local docs; docs="$(new_project beta)"

  assert_file "$docs/operations/runbooks/README.md" \
    "la plantilla trae operations/runbooks/ como índice, no un runbook suelto"
  assert_no_file "$docs/operations/runbook.md" \
    "ya no se materializa un runbook.md que nadie enlaza"

  local out; out="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)"
  assert_not_contains "$out" "nadie enlaza operations/runbook" \
    "un proyecto recién creado no arrastra el aviso de runbook huérfano"
}
