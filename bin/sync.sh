#!/usr/bin/env bash
# crux sync — trabajar en dos máquinas sin que ninguna se quede atrás.
#
#   crux sync            al llegar: lo que hay en esta máquina, al día, y el kernel
#   crux sync --leave    al irte: falla si algo se quedaría solo en esta máquina
#   crux sync --hook     lo mismo que al llegar, en silencio salvo novedades;
#                        es lo que corre el hook de inicio de sesión
#
# `bootstrap` monta una máquina vacía y `clone` trae un proyecto que no está,
# pero ninguno actualiza lo que ya hay: al volver a un ordenador después de un
# mes, los dos decían "ya está" y dejaban el código de hace un mes. Esto cubre
# el caso de alternar, que es el de todos los días.
#
# Trabaja sobre lo que ya hay en la raíz de proyectos. No trae proyectos que no
# estén: cada máquina tiene los suyos, y para traer uno está `crux clone`.
#
# Al llegar solo avanza lo que se puede avanzar sin decidir nada: una rama
# limpia que va por detrás de su remoto. Si hay cambios sin commitear o las
# ramas se han separado, lo dice y no toca nada. Nunca mezcla ni reescribe.
#
# Lo que NO sincroniza, y a propósito: las credenciales (ver `carry-env`) y las
# memorias personales del agente, que son de cada máquina.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

MODO="llegar"
case "${1:-}" in
  "")      ;;
  --leave) MODO="irse" ;;
  --hook)  MODO="hook" ;;
  *) die "uso: crux sync [--leave|--hook]" ;;
esac

RAIZ="$(projects_root)"
[[ -d "$RAIZ" ]] || die "la raíz de proyectos no existe: $RAIZ"

# Los repos de la raíz y los de dentro de cada proyecto. Los worktrees se
# devuelven aparte: al llegar no se tocan, porque su rama es trabajo en curso;
# al irse cuentan igual que cualquier otro.
repos_principales() {
  local d
  for d in "$RAIZ"/*/ "$RAIZ"/*/*/; do
    d="${d%/}"
    [[ -e "$d/.git" ]] || continue
    es_worktree "$d" && continue
    echo "$d"
  done
}

worktrees() {
  local d
  for d in "$RAIZ"/*/ "$RAIZ"/*/*/; do
    d="${d%/}"
    [[ -e "$d/.git" ]] || continue
    es_worktree "$d" && echo "$d"
  done
}

nombre_de() { local r="${1#"$RAIZ"/}"; echo "$r"; }

# --- Al irse ------------------------------------------------------------------

sincronizar_salida() {
  local atrapado=0 avisos=0 repo nombre b up delante sucio stash
  echo "lo que se quedaría solo en esta máquina"
  echo

  while IFS= read -r repo; do
    nombre="$(nombre_de "$repo")"
    [[ -n "$(git -C "$repo" remote)" ]] || {
      warn "$nombre: sin remoto, todo lo que tiene vive solo aquí"
      atrapado=$((atrapado + 1)); continue
    }

    sucio="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$sucio" -gt 0 ]]; then
      err "$nombre: $(cuenta "$sucio" "fichero sin commitear" "ficheros sin commitear")"
      atrapado=$((atrapado + 1))
    fi

    # Las ramas se miran desde el repo principal y no desde cada worktree:
    # comparten las referencias, y contarlas dos veces sería ruido.
    es_worktree "$repo" && continue

    while IFS=$'\t' read -r b up; do
      if [[ -z "$up" ]]; then
        # Sin seguimiento: solo está a salvo si algún remoto ya la contiene.
        if [[ -z "$(git -C "$repo" branch -r --contains "$b" 2>/dev/null)" ]]; then
          err "$nombre: la rama $b no está en ningún remoto"
          atrapado=$((atrapado + 1))
        fi
      elif ! git -C "$repo" rev-parse -q --verify "$up" >/dev/null; then
        # Seguía a una rama que ya no existe: casi siempre una propuesta
        # fusionada con squash, cuyos commits no aparecen en la principal.
        avisos=$((avisos + 1))
      else
        delante="$(git -C "$repo" rev-list --count "$up..$b" 2>/dev/null || echo 0)"
        if [[ "$delante" -gt 0 ]]; then
          err "$nombre: $b lleva $(cuenta "$delante" commit commits) sin subir"
          atrapado=$((atrapado + 1))
        fi
      fi
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)%09%(upstream:short)' refs/heads)

    stash="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$stash" -gt 0 ]]; then
      warn "$nombre: $(cuenta "$stash" stash stashes) — no viajan; conviértelos en una rama si los quieres allí"
    fi
  done < <(repos_principales; worktrees)

  echo
  if [[ $avisos -gt 0 ]]; then
    info "$(cuenta "$avisos" "rama sigue" "ramas siguen") a una rama borrada del remoto (fusionadas, casi seguro): no bloquean"
  fi
  if [[ $atrapado -eq 0 ]]; then
    ok "nada atrapado: puedes seguir en la otra máquina"
    return 0
  fi
  err "$(cuenta "$atrapado" "cosa" "cosas") no llegarían a la otra máquina"
  info "súbelas, o decide conscientemente que se quedan aquí"
  return 1
}

# --- Al llegar ---------------------------------------------------------------

# Trae todos los remotos en paralelo: en serie, con treinta repos, el hook de
# inicio de sesión tardaba lo bastante como para notarse cada vez.
traer_todo() {
  repos_principales | xargs -P 16 -I{} sh -c \
    'GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$1" fetch -q --all --prune --tags >/dev/null 2>&1 || echo "$1"' _ {}
}

# Avanza la rama actual si va por detrás y no hay nada que decidir.
avanzar() {
  local repo="$1" nombre up detras delante
  nombre="$(nombre_de "$repo")"
  up="$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" || return 0
  git -C "$repo" rev-parse -q --verify "$up" >/dev/null || return 0
  detras="$(git -C "$repo" rev-list --count "HEAD..$up" 2>/dev/null || echo 0)"
  [[ "$detras" -gt 0 ]] || return 0
  delante="$(git -C "$repo" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)"

  if [[ "$delante" -gt 0 ]]; then
    echo "separada	$nombre: la rama local y $up se han separado ($delante aquí, $detras allí) — decide tú cómo juntarlas"
  elif [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "sucia	$nombre: va $(cuenta "$detras" commit commits) por detrás, pero tiene cambios sin commitear — no la toco"
  elif git -C "$repo" merge -q --ff-only "$up" >/dev/null 2>&1; then
    echo "ok	$nombre: $(cuenta "$detras" "commit nuevo" "commits nuevos")"
  else
    echo "fallo	$nombre: no pude avanzar a $up"
  fi
}

# Repos que el contrato de un proyecto de esta máquina declara y no están en
# disco: aparecen cuando se añadieron desde la otra. Son del mismo proyecto.
traer_repos_nuevos() {
  local p docs repo falta
  for docs in "$RAIZ"/*/*-docs; do
    [[ -f "$docs/crux.json" ]] || continue
    p="$(basename "$(dirname "$docs")")"
    falta=0
    while IFS= read -r repo; do
      nombre_valido "$repo" 2>/dev/null || continue
      [[ -e "$RAIZ/$p/$repo/.git" ]] || falta=1
    done < <(json_get "$docs/crux.json" repos 2>/dev/null || true)
    [[ $falta -eq 1 ]] || continue
    if bash "$CRUX_HOME/bin/clone.sh" "$p" --parent "$RAIZ" >/dev/null 2>&1; then
      echo "nuevo	$p: repos que faltaban, traídos"
    else
      echo "fallo	$p: le faltan repos y no pude traerlos — 'crux clone $p'"
    fi
  done
}

# El kernel se actualiza desde su clon, y solo a una versión publicada: el
# VERSION de la principal puede ir por delante de la última etiqueta.
kernel_al_dia() {
  local clon="$RAIZ/crux" nueva actual
  [[ -f "$clon/install.sh" && -f "$clon/VERSION" ]] || return 0
  nueva="$(tr -d '[:space:]' < "$clon/VERSION")"
  actual="$(crux_version)"
  es_semver "$nueva" || return 0
  version_mayor_que "$nueva" "$actual" || return 0
  git -C "$clon" rev-parse -q --verify "refs/tags/v$nueva" >/dev/null || return 0
  [[ "${CRUX_SYNC_NO_INSTALL:-0}" == "1" ]] && { echo "kernel	crux $nueva disponible (instalación desactivada)"; return 0; }
  # En modo dev el kernel ya es el clon: reinstalar lo pasaría a release.
  grep -qE '^CRUX_MODE="?dev' "${CRUX_CONFIG:-$HOME/.crux/config}" 2>/dev/null && return 0

  if ( cd "$HOME" && bash "$clon/install.sh" ) >/dev/null 2>&1 \
     && ( cd "$HOME" && bash "$HOME/.crux/kernel/$nueva/bin/hooks.sh" install ) >/dev/null 2>&1; then
    echo "kernel	crux $actual → $nueva, con sus hooks"
  else
    echo "fallo	kernel: no pude instalar crux $nueva — '$clon/install.sh' a mano"
  fi
}

sincronizar_llegada() {
  local sin_red lineas repo
  sin_red="$(traer_todo)"
  lineas=""
  while IFS= read -r repo; do
    lineas+="$(avanzar "$repo")"$'\n'
  done < <(repos_principales)
  lineas+="$(traer_repos_nuevos)"$'\n'
  lineas+="$(kernel_al_dia)"$'\n'
  lineas="$(printf '%s' "$lineas" | sed '/^$/d')"

  local n_sin_red=0
  [[ -n "$sin_red" ]] && n_sin_red="$(printf '%s\n' "$sin_red" | wc -l | tr -d ' ')"

  if [[ "$MODO" == "hook" ]]; then
    # En el hook, lo que se imprime entra en el contexto del agente: solo lo
    # que cambió o pide una decisión, y nada si todo estaba al día. Un repo
    # cuyo remoto se borró no responde nunca, y repetirlo en cada sesión es
    # ruido: aquí solo cuenta que no responda ninguno, que es estar sin red.
    local total sin_red_hook=0
    total="$(repos_principales | wc -l | tr -d ' ')"
    [[ $n_sin_red -gt 0 && $n_sin_red -eq $total ]] && sin_red_hook=1
    [[ -z "$lineas" && $sin_red_hook -eq 0 ]] && return 0
    echo "crux sync, al empezar la sesión:"
    [[ -n "$lineas" ]] && printf '%s\n' "$lineas" | cut -f2- | sed 's/^/  /'
    [[ $sin_red_hook -eq 1 ]] && echo "  sin red: ningún remoto respondió, los repos pueden no estar al día"
    return 0
  fi

  echo "al día con el remoto — $RAIZ"
  echo
  if [[ -z "$lineas" ]]; then
    ok "nada nuevo: esta máquina ya estaba al día"
  else
    while IFS=$'\t' read -r tipo texto; do
      case "$tipo" in
        ok|nuevo|kernel) ok "$texto" ;;
        separada|sucia)  warn "$texto" ;;
        *)               err "$texto" ;;
      esac
    done <<< "$lineas"
  fi
  if [[ $n_sin_red -gt 0 ]]; then
    echo
    warn "sin respuesta del remoto (sin red, o el remoto ya no existe):"
    printf '%s\n' "$sin_red" | while IFS= read -r r; do info "$(nombre_de "$r")"; done
  fi
  # Separadas y sucias piden una decisión: se sale con error para que un
  # script que lo encadene no siga como si estuviera todo al día.
  printf '%s\n' "$lineas" | grep -qE '^(separada|sucia|fallo)' && return 1
  return 0
}

# --- Hook: una vez cada poco, no en cada sesión -------------------------------
#
# Varias sesiones abiertas a la vez lanzarían la misma ronda de fetch en
# paralelo. Con una marca de diez minutos, la primera sincroniza y el resto no.

if [[ "$MODO" == "hook" ]]; then
  cat >/dev/null 2>&1 || true
  estado="$HOME/.crux/state"
  ( umask 077 && mkdir -p "$estado" ) 2>/dev/null || true
  marca="$estado/sync-last"
  if [[ -f "$marca" ]] && [[ -n "$(find "$marca" -mmin -"${CRUX_SYNC_EVERY_MIN:-10}" 2>/dev/null)" ]]; then
    exit 0
  fi
  : > "$marca"
  sincronizar_llegada
  exit 0
fi

if [[ "$MODO" == "irse" ]]; then
  sincronizar_salida
  exit $?
fi

sincronizar_llegada
exit $?
