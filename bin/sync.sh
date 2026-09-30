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

# En una máquina recién montada, ssh pregunta por la huella de cada host y git
# por usuario y contraseña. Sin terminal que conteste, cada repo esperaba hasta
# el tiempo límite: mejor que falle al momento y salga como sin respuesta.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

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

# Lee repos por la entrada y saca "x<TAB>repo" si su remoto ya no existe y
# "?<TAB>repo" si no se pudo saber. Sin red no se afirma que falte nada.
remotos_que_faltan() {
  local repo
  while IFS= read -r repo; do
    [[ -n "$(git -C "$repo" remote)" ]] || continue
    echo "$repo"
  done | xargs -P 16 -I{} bash -c '
    r="$(git -C "$1" config "branch.$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null).remote" 2>/dev/null)"
    [ -n "$r" ] || r="$(git -C "$1" remote | grep -x origin || git -C "$1" remote | head -1)"
    salida="$(LC_ALL=C timeout 20 git -C "$1" ls-remote -q "$r" 2>&1 >/dev/null)" && exit 0
    if printf "%s" "$salida" | grep -qiE "repository not found|does not appear to be a git repository|repository .* does not exist"; then
      printf "x\t%s\n" "$1"
    else
      printf "?\t%s\n" "$1"
    fi' _ {}
}

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

    # Un commit hecho con HEAD separado no está en ninguna rama, así que el
    # repaso de ramas de abajo no lo ve. Cada worktree tiene su propio HEAD.
    if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null \
       && git -C "$repo" rev-parse -q --verify HEAD >/dev/null \
       && [[ -z "$(git -C "$repo" for-each-ref --contains HEAD refs/heads refs/remotes 2>/dev/null)" ]]; then
      err "$nombre: HEAD separado con commits que no están en ninguna rama — crea una: git switch -c <rama>"
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

  # Con el remoto borrado, las referencias locales siguen diciendo que todo
  # está subido: git no se entera hasta que pregunta. Es la única comprobación
  # de la salida que necesita red, y se hace en paralelo.
  local desaparecidos sin_comprobar r
  desaparecidos="$(repos_principales | remotos_que_faltan)"
  sin_comprobar="$(printf '%s\n' "$desaparecidos" | sed -n 's/^?\t//p')"
  desaparecidos="$(printf '%s\n' "$desaparecidos" | sed -n 's/^x\t//p')"
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    err "$(nombre_de "$r"): su remoto ya no existe — lo que tiene solo vive aquí"
    atrapado=$((atrapado + 1))
  done <<< "$desaparecidos"
  if [[ -n "$sin_comprobar" ]]; then
    warn "no pude comprobar si siguen existiendo los remotos de:"
    while IFS= read -r r; do info "$(nombre_de "$r")"; done <<< "$sin_comprobar"
  fi

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
  repos_principales | xargs -P 16 -I{} bash -c '
    repo="$1"
    remoto="$(git -C "$repo" config "branch.$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null).remote" 2>/dev/null)"
    [ -n "$remoto" ] || remoto="$(git -C "$repo" remote | grep -x origin || git -C "$repo" remote | head -1)"
    timeout 30 git -C "$repo" fetch -q --all --prune --tags >/dev/null 2>&1 && exit 0
    # Con --all basta que falle un remoto secundario para que falle todo.
    [ -n "$remoto" ] && timeout 30 git -C "$repo" fetch -q --prune --tags "$remoto" >/dev/null 2>&1 && exit 0
    echo "$repo"' _ {}
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
  # En C: el mensaje se compara, y git lo traduce al idioma del sistema.
  elif salida="$(LC_ALL=C git -C "$repo" merge -q --ff-only "$up" 2>&1)"; then
    echo "ok	$nombre: $(cuenta "$detras" "commit nuevo" "commits nuevos")"
  elif [[ "$salida" == *"untracked working tree files would be overwritten"* ]]; then
    echo "sucia	$nombre: un fichero sin seguir de aquí choca con uno que llega — muévelo y repite: $(printf '%s\n' "$salida" | sed -n 's/^[[:space:]]\{1,\}//p' | head -3 | tr '\n' ' ')"
  else
    echo "fallo	$nombre: no pude avanzar a $up — $(printf '%s' "$salida" | head -1)"
  fi
}

# Las otras ramas locales que van por detrás de su remoto: sin esto, al cambiar
# a main en la otra máquina se empezaba sobre lo viejo, con sync diciendo que
# todo estaba al día. `fetch .` no avanza una rama que esté en uso en algún
# worktree ni la que se haya separado, que es exactamente lo que se quiere.
avanzar_las_demas() {
  local repo="$1" nombre actual b up detras
  nombre="$(nombre_de "$repo")"
  actual="$(git -C "$repo" symbolic-ref -q HEAD 2>/dev/null || true)"
  while IFS=$'\t' read -r b up; do
    [[ -n "$up" && "$b" != "$actual" ]] || continue
    git -C "$repo" rev-parse -q --verify "$up" >/dev/null || continue
    detras="$(git -C "$repo" rev-list --count "$b..$up" 2>/dev/null || echo 0)"
    [[ "$detras" -gt 0 ]] || continue
    [[ "$(git -C "$repo" rev-list --count "$up..$b" 2>/dev/null || echo 1)" -eq 0 ]] || continue
    git -C "$repo" fetch -q . "$up:$b" >/dev/null 2>&1 \
      && echo "ok	$nombre: ${b#refs/heads/}, $(cuenta "$detras" "commit nuevo" "commits nuevos")"
  done < <(git -C "$repo" for-each-ref --format='%(refname)%09%(upstream)' refs/heads)
}

# Repos que el contrato de un proyecto de esta máquina declara y no están en
# disco: aparecen cuando se añadieron desde la otra. Son del mismo proyecto.
traer_repos_nuevos() {
  local p docs repo falta motivo
  for docs in "$RAIZ"/*/*-docs; do
    [[ -f "$docs/crux.json" ]] || continue
    p="$(basename "$(dirname "$docs")")"
    if ! motivo="$(json_valido "$docs/crux.json")"; then
      echo "fallo	$p: crux.json ilegible, no sé qué repos declara — $motivo"
      continue
    fi
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
    lineas+="$(avanzar_las_demas "$repo")"$'\n'
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

estado="${CRUX_STATE_DIR:-$HOME/.crux/state}"
( umask 077 && mkdir -p "$estado" ) 2>/dev/null || true

# Dos llegadas a la vez —el hook de una sesión y un `crux sync` a mano— se
# pisaban el índice de git: una avanzaba y la otra decía que no había podido.
# mkdir es atómico y existe en todas partes, a diferencia de flock.
candado="$estado/sync.lock"
tomar_candado() {
  local espera=0
  while ! mkdir "$candado" 2>/dev/null; do
    # Un candado de hace más de diez minutos es de un proceso que murió.
    if [[ -n "$(find "$candado" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
      rmdir "$candado" 2>/dev/null; continue
    fi
    [[ "$MODO" == "hook" ]] && return 1
    [[ $espera -eq 0 ]] && info "otra sincronización en marcha, espero a que acabe"
    espera=1; sleep 1
  done
  trap 'rmdir "$candado" 2>/dev/null' EXIT
}

if [[ "$MODO" == "hook" ]]; then
  # A mano y en una terminal, leer la entrada esperaría a un Ctrl-D.
  [[ -t 0 ]] || cat >/dev/null 2>&1 || true
  marca="$estado/sync-last"
  if [[ -f "$marca" ]] && [[ -n "$(find "$marca" -mmin -"${CRUX_SYNC_EVERY_MIN:-10}" 2>/dev/null)" ]]; then
    exit 0
  fi
  tomar_candado || exit 0
  : > "$marca"
  sincronizar_llegada
  exit 0
fi

if [[ "$MODO" == "irse" ]]; then
  sincronizar_salida
  exit $?
fi

tomar_candado
sincronizar_llegada
exit $?
