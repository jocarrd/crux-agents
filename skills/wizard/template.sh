#!/usr/bin/env bash
#
# Un wizard guía a una persona, paso a paso, por un procedimiento manual.
# Generado por la skill /wizard.
#
# Todo lo que hay por encima de la marca "ETAPAS" es la biblioteca: no se edita
# a mano. Lo que se escribe es la sección de etapas, debajo de la marca.
#
# Biblioteca adaptada de mattpocock/skills (MIT).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Biblioteca del wizard: la misma en todos, para que la experiencia no cambie.
# ──────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""
fi

# Lo fija el autor al principio de la sección de etapas.
TOTAL_STAGES=0

_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=()    # claves escritas en ENV_FILE en esta ejecución
WRITTEN_SECRET=() # secretos fijados en esta ejecución
SKIPPED=()        # lo que no se pudo hacer, para el resumen final

# _clear deja en pantalla solo el paso actual. No hace nada si la salida no es
# un terminal, para que un log redirigido siga siendo legible.
_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

# banner "Título" muestra la portada: qué hace este wizard.
banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s etapas%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  Tú llevas el navegador; el wizard te dice exactamente qué hacer y\n' "$DIM"
  printf '  recoge los valores que copies. Puedes cortar con Ctrl-C y volver más\n'
  printf '  tarde: recuerda lo que ya guardó.%s\n' "$RESET"
  pause "¿Empezamos?"
}

# stage "Nombre" limpia la pantalla y anuncia la etapa con su progreso.
stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Etapa %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

# say "..." imprime una línea de explicación.
say()  { printf '  %s\n' "$1"; }
# step "..." es una acción concreta que hace la persona.
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }

# open_url URL la abre en el navegador, en Linux, macOS y WSL.
open_url() {
  local url="$1"
  printf '  %s↗ abriendo%s %s\n' "$GREEN" "$RESET" "$url"
  { if   command -v wslview      >/dev/null 2>&1; then wslview "$url"
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
    elif command -v xdg-open     >/dev/null 2>&1; then xdg-open "$url"
    elif command -v open         >/dev/null 2>&1; then open "$url"
    else warn "no he podido abrir el navegador, ábrelo tú: $url"; fi
  } >/dev/null 2>&1 || warn "no he podido abrir el navegador, ábrelo tú: $url"
}

# pause "msg" espera a que la persona confirme que ya hizo la parte manual.
pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Pulsa Enter para seguir}" "$RESET"
  read -r _ || true
}

# confirm "pregunta" es una puerta s/N; devuelve éxito si contesta que sí.
confirm() {
  local reply=""
  printf '  %s? %s [s/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[SsYy] ]]
}

# _existing CLAVE: valor actual de CLAVE en ENV_FILE, si lo hay.
_existing() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line=$(grep -E "^${1}=" "$ENV_FILE" | tail -n1) || return 1
  printf '%s' "${line#*=}"
}

# ask CLAVE "Texto" lee un valor en $CLAVE. Si ya existía en .env lo ofrece
# como valor por defecto, así que en una segunda pasada basta con Enter.
ask() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter mantiene el actual]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# ask_secret CLAVE "Texto" es igual que ask, pero sin mostrar lo que se teclea.
ask_secret() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter mantiene el actual]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -rs input || true
  printf '\n'
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# write_env CLAVE VALOR mete CLAVE=VALOR en ENV_FILE, creándolo si hace falta y
# sustituyendo la línea anterior. Idempotente.
write_env() {
  local key="$1" value="$2" tmp
  touch "$ENV_FILE"
  tmp=$(mktemp)
  grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  WRITTEN_ENV+=("$key")
  printf '  %s✓ escrito%s %s → %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

# set_secret NOMBRE VALOR fija un secreto de GitHub Actions con gh. Si gh no
# está o no hay sesión, lo anota como pendiente en vez de fallar.
set_secret() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s' "$value" | gh secret set "$name" >/dev/null 2>&1; then
      WRITTEN_SECRET+=("$name")
      printf '  %s✓ fijado%s el secreto %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("secreto $name (a mano: gh secret set $name)")
  warn "me salto el secreto $name: gh no está listo, hazlo luego"
}

# set_var NOMBRE VALOR fija una variable de GitHub Actions, que no es secreta.
set_var() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh variable set "$name" --body "$value" >/dev/null 2>&1; then
      printf '  %s✓ fijada%s la variable %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("variable $name")
  warn "me salto la variable $name: gh no está listo, hazlo luego"
}

# finish limpia la pantalla y resume todo lo que quedó configurado.
finish() {
  _clear
  printf '\n%s%s  ✓ Terminado%s\n' "$BOLD" "$GREEN" "$RESET"
  (( ${#WRITTEN_ENV[@]} ))    && note "${#WRITTEN_ENV[@]} valor(es) en $ENV_FILE: ${WRITTEN_ENV[*]}"
  (( ${#WRITTEN_SECRET[@]} )) && note "${#WRITTEN_SECRET[@]} secreto(s) en GitHub: ${WRITTEN_SECRET[*]}"
  if (( ${#SKIPPED[@]} )); then
    printf '\n'; warn "queda por hacer a mano:"
    for s in "${SKIPPED[@]}"; do note "  - $s"; done
  fi
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────
# ETAPAS: esta es la parte que se escribe. Un stage() por paso de la persona.
# Sustituye el ejemplo y ajusta TOTAL_STAGES al número de etapas que escribas.
# ──────────────────────────────────────────────────────────────────────────

TOTAL_STAGES=1

banner "Configurar Stripe"

# ── Etapa de ejemplo: sustitúyela por los pasos reales ────────────────────
stage "Stripe: claves de API"
say "Vamos a coger las claves de prueba de Stripe para el entorno local y el CI."
open_url "https://dashboard.stripe.com/test/apikeys"
step "En la página de claves, copia la Publishable key (empieza por pk_test_)."
ask STRIPE_PUBLISHABLE_KEY "Pega la clave pública:"
step "Pulsa 'Reveal test key' en la fila de Secret key y cópiala."
ask_secret STRIPE_SECRET_KEY "Pega la clave secreta:"
write_env STRIPE_PUBLISHABLE_KEY "$STRIPE_PUBLISHABLE_KEY"
write_env STRIPE_SECRET_KEY "$STRIPE_SECRET_KEY"
set_secret STRIPE_SECRET_KEY "$STRIPE_SECRET_KEY"   # esta la necesita el CI
# ──────────────────────────────────────────────────────────────────────────

finish
