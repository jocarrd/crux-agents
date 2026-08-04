#!/usr/bin/env bash
# crux workspace — espacios de trabajo aislados para trabajar en paralelo.
#
#   crux workspace new <nombre> [--repo <dir>] [--base <rama>] [--force]
#   crux workspace list
#   crux workspace finish <nombre> [--title "..."]
#   crux workspace merge <nombre> [--yes]
#   crux workspace rm <nombre>
#
# Un worktree de git aísla los ficheros, pero no el runtime: dos agentes sobre
# el mismo repo siguen peleándose por el puerto, la base de datos y el .env.
# Esto reparte también esos recursos, con un registro para que dos espacios no
# cojan el mismo hueco.
#
# El worktree se crea como hermano del repo original, no en un directorio
# aparte: es lo que hace que los punteros de contexto relativos
# (../<project>-docs/) sigan resolviendo dentro del espacio aislado.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

REGISTRY="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
LOCK="$(dirname "$REGISTRY")/.workspaces.lock"

registry_init() {
  mkdir -p "$(dirname "$REGISTRY")"
  [[ -f "$REGISTRY" ]] || echo '{"workspaces":{}}' > "$REGISTRY"
}

with_lock() {
  # mkdir es atómico: sirve de cerrojo sin depender de flock.
  local tries=0
  until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [[ $tries -gt 50 ]] && die "registro bloqueado: borra $LOCK si ningún crux está corriendo"
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

# --- Configuración de workspace del proyecto --------------------------------
#
# Sale de la sección "workspace" de crux.json. Sin ella se usan los valores por
# defecto, que solo reparten puertos.

load_config() {
  # load_config <docs-repo> <nombre-del-repo>
  #
  # Un proyecto multi-repo no tiene un único juego de variables: el front, el
  # backend y el panel necesitan cosas distintas. La sección por repo se
  # solapa sobre la común.
  local docs="$1" repo="$2"
  PORT_BASE=3000; PORTS_PER_SLOT=10; ENV_FILE=""; ENV_TEMPLATE="{}"
  SETUP_CMD=""; TEARDOWN_CMD=""; INSTALAR="true"
  local cfg="$docs/crux.json"
  [[ -f "$cfg" ]] || return 0

  eval "$(node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    const w = (JSON.parse(fs.readFileSync(file, "utf8")).workspace) || {};
    const r = (w.repos || {})[repo] || {};
    const env = { ...(w.env || {}), ...(r.env || {}) };
    const q = (v) => `'"'"'${String(v).replace(/'"'"'/g, "")}'"'"'`;
    console.log(`PORT_BASE=${Number(w.portBase) || 3000}`);
    console.log(`PORTS_PER_SLOT=${Number(w.portsPerSlot) || 10}`);
    console.log(`ENV_FILE=${q(r.envFile || w.envFile || "")}`);
    console.log(`ENV_TEMPLATE=${q(JSON.stringify(env))}`);
    console.log(`SETUP_CMD=${q(r.setup || w.setup || "")}`);
    console.log(`TEARDOWN_CMD=${q(r.teardown || w.teardown || "")}`);
    const inst = r.install !== undefined ? r.install : w.install;
    console.log(`INSTALAR=${q(inst === false ? "false" : "true")}`);
  ' "$cfg" "$repo" 2>/dev/null)"
}

substitute() {
  # substitute <texto> — aplica {{SLOT}}, {{PORTn}}, {{NAME}}, {{BRANCH}}
  node -e '
    const [text, slot, port0, name, branch] = process.argv.slice(1);
    let v = text.replace(/\{\{SLOT\}\}/g, slot)
                .replace(/\{\{NAME\}\}/g, name)
                .replace(/\{\{BRANCH\}\}/g, branch);
    process.stdout.write(v.replace(/\{\{PORT(\d+)\}\}/g, (_, i) => String(Number(port0) + Number(i))));
  ' "$1" "$SLOT" "$PORT0" "$WS_NAME" "$WS_BRANCH"
}

cmd_new() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "uso: crux workspace new <nombre> [--repo <dir>] [--base <rama>]"

  local repo="$PWD" base="" FORZAR=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --force) FORZAR=1; shift ;;
      *) die "opción desconocida: $1" ;;
    esac
  done

  repo="$(cd "$repo" && git rev-parse --show-toplevel 2>/dev/null)" \
    || die "no es un repo git: $repo"
  local repo_name; repo_name="$(basename "$repo")"
  local parent; parent="$(dirname "$repo")"
  local path="$parent/${repo_name}-ws-${name}"
  local branch="ws/$name"

  [[ -e "$path" ]] && die "ya existe $path"

  # Si otro espacio ya trabaja sobre este repo, decirlo: es la señal de que hay
  # otra sesión viva y de que conviene repartir por superficie.
  otros="$(node -e '
    const fs = require("fs");
    try {
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const m = Object.entries(r.workspaces || {}).filter(([, w]) => w.repo === process.argv[2]);
      process.stdout.write(m.map(([n, w]) => `${n} (${w.branch})`).join(", "));
    } catch {}
  ' "$REGISTRY" "$repo" 2>/dev/null || true)"
  [[ -n "$otros" ]] && warn "ya hay trabajo abierto sobre $repo_name: $otros"

  registry_init
  with_lock

  # Menor slot libre: los espacios van y vienen, y reutilizar huecos mantiene
  # los puertos en un rango pequeño y predecible.
  local slot
  slot="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const used = new Set(Object.values(r.workspaces).map(w => w.slot));
    let s = 0; while (used.has(s)) s++;
    process.stdout.write(String(s));
  ' "$REGISTRY")"

  local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"

  # Un worktree crea una rama en el repo de origen. Con un perfil que prohíbe
  # escribir fuera del docs repo, eso es exactamente lo que no se puede hacer.
  if [[ -n "$docs" && -f "$docs/crux.json" ]]; then
    local perfil escribe
    perfil="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"
    escribe="$(json_get "$CRUX_HOME/profiles/$perfil.json" 'pointers.write' 2>/dev/null || echo "true")"
    if [[ "$escribe" != "true" && $FORZAR -eq 0 ]]; then
      err "perfil $perfil: no se escribe en $repo_name, y un worktree le crea una rama"
      info "si el cliente lo autoriza, repite con --force"
      exit 1
    fi
  fi

  load_config "$docs" "$repo_name"

  SLOT="$slot"; PORT0=$((PORT_BASE + slot * PORTS_PER_SLOT))
  WS_NAME="$name"; WS_BRANCH="$branch"

  git -C "$repo" worktree add ${base:+-b "$branch"} "$path" ${base:-"$branch"} >/dev/null 2>&1 \
    || git -C "$repo" worktree add -b "$branch" "$path" >/dev/null \
    || die "no pude crear el worktree"

  ok "worktree $path (rama $branch)"

  # La marca de la puerta es estado local. Va al exclude del directorio común,
  # que es el que git respeta desde un worktree, y así no toca el .gitignore
  # versionado —que en un repo ajeno no se puede tocar.
  local comun; comun="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null || echo "")"
  if [[ -n "$comun" ]]; then
    mkdir -p "$comun/info"
    grep -qxF '.crux-ship' "$comun/info/exclude" 2>/dev/null \
      || echo '.crux-ship' >> "$comun/info/exclude"
  fi

  if [[ -n "$ENV_FILE" && "$ENV_TEMPLATE" != "{}" ]]; then
    node -e '
      const fs = require("fs");
      const [file, tmplRaw, slot, port0, name, branch] = process.argv.slice(1);
      const subst = (v) => String(v)
        .replace(/\{\{SLOT\}\}/g, slot).replace(/\{\{NAME\}\}/g, name)
        .replace(/\{\{BRANCH\}\}/g, branch)
        .replace(/\{\{PORT(\d+)\}\}/g, (_, i) => String(Number(port0) + Number(i)));
      const lines = Object.entries(JSON.parse(tmplRaw)).map(([k, v]) => `${k}=${subst(v)}`);
      fs.writeFileSync(file, lines.join("\n") + "\n");
    ' "$path/$ENV_FILE" "$ENV_TEMPLATE" "$slot" "$PORT0" "$name" "$branch"
    ok "$ENV_FILE con el slot $slot (puertos desde $PORT0)"
  else
    info "sin configuración de workspace para $repo_name: solo se reserva el rango de puertos"
  fi

  # Un worktree comparte el historial pero no los ficheros ignorados, así que
  # nace sin dependencias instaladas. Sin esto, el primer comando que se ejecuta
  # en el espacio falla con un error que no dice qué pasa.
  if [[ "$INSTALAR" != "false" ]]; then
    local instalar=""
    if   [[ -f "$path/pnpm-lock.yaml" ]];   then instalar="pnpm install --prefer-offline"
    elif [[ -f "$path/package-lock.json" ]]; then instalar="npm ci --prefer-offline"
    elif [[ -f "$path/yarn.lock" ]];        then instalar="yarn install"
    elif [[ -f "$path/bun.lockb" ]];        then instalar="bun install"
    elif [[ -f "$path/uv.lock" ]];          then instalar="uv sync"
    elif [[ -f "$path/poetry.lock" ]];      then instalar="poetry install"
    elif [[ -f "$path/requirements.txt" ]]; then instalar="pip install -r requirements.txt"
    elif [[ -f "$path/go.mod" ]];           then instalar="go mod download"
    elif [[ -f "$path/Cargo.toml" ]];       then instalar="cargo fetch"
    fi
    if [[ -n "$instalar" ]]; then
      if ( cd "$path" && eval "$instalar" >/dev/null 2>&1 ); then
        ok "dependencias instaladas (${instalar%% *})"
      else
        warn "no pude instalar las dependencias: hazlo con '$instalar'"
      fi
    fi
  fi

  if [[ -n "$SETUP_CMD" ]]; then
    local cmd; cmd="$(substitute "$SETUP_CMD")"
    if ( cd "$path" && eval "$cmd" ); then
      ok "setup ejecutado"
    else
      warn "el setup falló — el espacio existe, pero revisa sus recursos"
    fi
  fi

  node -e '
    const fs = require("fs");
    const [file, name, slot, repo, path, branch, port0, perSlot] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    r.workspaces[name] = {
      slot: Number(slot), repo, path, branch,
      ports: [Number(port0), Number(port0) + Number(perSlot) - 1],
    };
    fs.writeFileSync(file, JSON.stringify(r, null, 2) + "\n");
  ' "$REGISTRY" "$name" "$slot" "$repo" "$path" "$branch" "$PORT0" "$PORTS_PER_SLOT"

  echo
  ok "espacio '$name' listo"
  info "slot $slot · puertos $PORT0-$((PORT0 + PORTS_PER_SLOT - 1))"
  info "cd $path"
}

cmd_finish() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "uso: crux workspace finish <nombre> [--title \"...\"]"

  local titulo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) titulo="$2"; shift 2 ;;
      *) die "opción desconocida: $1" ;;
    esac
  done

  registry_init
  local datos
  datos="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.branch, w.repo].join("\n"));
  ' "$REGISTRY" "$name")" || die "no existe el espacio '$name'"

  local path branch repo
  path="$(echo "$datos" | sed -n 1p)"
  branch="$(echo "$datos" | sed -n 2p)"
  repo="$(echo "$datos" | sed -n 3p)"
  [[ -d "$path" ]] || die "el espacio '$name' ya no está en disco"

  # Nada sale de un espacio sin estar commiteado: lo que se queda fuera de git
  # no llega a la revisión, y ese es el punto de trabajar así.
  local pendiente
  pendiente="$(git -C "$path" status --porcelain | grep -v ' \.crux-ship$' || true)"
  if [[ -n "$pendiente" ]]; then
    err "quedan cambios sin commitear en $path"
    echo "$pendiente" | sed 's/^/      /'
    exit 1
  fi

  # Lo que aún no está en ningún remoto: es lo que va a la propuesta.
  local commits
  commits="$(git -C "$path" log --oneline "$branch" --not --remotes 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${commits:-0}" -gt 0 ]] || commits=0
  [[ "$commits" -eq 0 ]] && die "no hay nada que proponer en $branch"

  # La puerta de calidad deja constancia del commit que verificó. Sin ella, se
  # abriría una propuesta de código que nadie ha revisado, y la revisión pasaría
  # a depender de que alguien se acuerde.
  local head verificado
  head="$(git -C "$path" rev-parse HEAD)"
  verificado="$(tr -d '[:space:]' < "$path/.crux-ship" 2>/dev/null || echo "")"
  if [[ "$verificado" != "$head" ]]; then
    err "este commit no ha pasado la puerta de calidad"
    [[ -n "$verificado" ]] && info "lo último verificado fue ${verificado:0:8}, y HEAD es ${head:0:8}"
    info "pasa /ship y repite"
    exit 1
  fi
  ok "puerta de calidad pasada sobre ${head:0:8}"

  git -C "$path" push -q -u origin "$branch" || die "no pude subir $branch"
  ok "$branch subida ($commits commits)"

  local base
  base="$(git -C "$path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"

  local cuerpo
  cuerpo="$(printf 'Cambios:\n\n%s\n\n---\nPuerta de calidad pasada sobre %s.\n' \
    "$(git -C "$path" log --format='- %s' "$base..$branch")" "${head:0:8}")"

  local url_pr=""
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    # Contra la rama base, no contra --remotes: para cuando se calcula el título
    # la rama ya está subida, así que --remotes la excluiría entera y el título
    # se quedaría vacío.
    local primero
    primero="$(git -C "$path" log --format='%s' "$base..$branch" | tail -1)"
    [[ -n "$primero" ]] || primero="$(git -C "$path" log -1 --format=%s "$branch")"
    url_pr="$(cd "$path" && gh pr create \
      --title "${titulo:-$primero}" \
      --body "$cuerpo" 2>/dev/null || true)"
  fi

  if [[ -n "$url_pr" ]]; then
    ok "propuesta abierta: $url_pr"
  else
    info "abre la propuesta en tu proveedor desde la rama $branch"
  fi

  echo
  info "revísala antes de pedir revisión humana: /review-pr"
  info "cuando esté integrada: crux workspace rm $name"
}

cmd_merge() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "uso: crux workspace merge <nombre> [--yes]"

  local confirmado=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) confirmado=1; shift ;;
      *) die "opción desconocida: $1" ;;
    esac
  done

  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
    || die "hace falta gh autenticado para consultar y fusionar la propuesta"

  registry_init
  local datos path branch
  datos="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.branch].join("\n"));
  ' "$REGISTRY" "$name")" || die "no existe el espacio '$name'"
  path="$(echo "$datos" | sed -n 1p)"
  branch="$(echo "$datos" | sed -n 2p)"
  [[ -d "$path" ]] || die "el espacio '$name' ya no está en disco"

  local estado
  estado="$(cd "$path" && gh pr view --json number,title,url,mergeable,reviewDecision,statusCheckRollup 2>/dev/null)" \
    || die "no hay propuesta abierta para $branch — lanza 'crux workspace finish $name'"

  # Se listan todas las señales antes de decidir: una propuesta puede tener los
  # checks en verde y estar en conflicto, o al revés.
  eval "$(node -e '
    const d = JSON.parse(process.argv[1]);
    const checks = d.statusCheckRollup || [];
    const fallan = checks.filter((c) => ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT"].includes(c.conclusion));
    const enCurso = checks.filter((c) => c.status && c.status !== "COMPLETED");
    const q = (v) => `"${String(v).replace(/"/g, "")}"`;
    console.log(`PR_NUM=${d.number}`);
    console.log(`PR_URL=${q(d.url)}`);
    console.log(`PR_TITULO=${q(d.title)}`);
    console.log(`PR_MERGEABLE=${q(d.mergeable)}`);
    console.log(`PR_REVISION=${q(d.reviewDecision || "sin revisión requerida")}`);
    console.log(`PR_CHECKS_TOTAL=${checks.length}`);
    console.log(`PR_CHECKS_FALLAN=${fallan.length}`);
    console.log(`PR_CHECKS_CURSO=${enCurso.length}`);
    console.log(`PR_FALLAN_NOMBRES=${q(fallan.map((c) => c.name || c.context).join(", "))}`);
  ' "$estado")"

  echo "propuesta #$PR_NUM · $PR_TITULO"
  echo "$PR_URL"
  echo

  local bloqueado=0
  local sin_ci=0
  if [[ "$PR_CHECKS_TOTAL" -eq 0 ]]; then
    warn "sin comprobaciones automáticas: la única validación es la que pasaste en local"
    sin_ci=1
  elif [[ "$PR_CHECKS_CURSO" -gt 0 ]]; then
    warn "$PR_CHECKS_CURSO comprobaciones aún en curso"
    bloqueado=1
  elif [[ "$PR_CHECKS_FALLAN" -gt 0 ]]; then
    err "$PR_CHECKS_FALLAN comprobaciones fallan: $PR_FALLAN_NOMBRES"
    bloqueado=1
  else
    ok "$PR_CHECKS_TOTAL comprobaciones en verde"
  fi

  case "$PR_MERGEABLE" in
    MERGEABLE) ok "sin conflictos" ;;
    CONFLICTING) err "hay conflictos que resolver"; bloqueado=1 ;;
    *) warn "estado de fusión desconocido: $PR_MERGEABLE" ;;
  esac

  [[ "$PR_REVISION" == "CHANGES_REQUESTED" ]] && { err "hay cambios solicitados en la revisión"; bloqueado=1; }

  echo
  if [[ $bloqueado -eq 1 ]]; then
    err "no se fusiona: hay algo que resolver antes"
    exit 1
  fi

  if [[ $confirmado -eq 0 ]]; then
    [[ $sin_ci -eq 1 ]] && ok "nada bloquea la fusión, pero no hay red automática detrás" \
                        || ok "todo en verde"
    info "para fusionarla: crux workspace merge $name --yes"
    exit 0
  fi

  # Sin --delete-branch: gh intenta cambiar a la rama base para borrar la local,
  # y desde un worktree eso falla porque la base ya está usada por otro. La rama
  # remota se borra aparte.
  ( cd "$path" && gh pr merge --squash ) || true

  # No se confía en el código de salida: el fallo puede venir de la limpieza
  # posterior con la fusión ya hecha, y reportar un error entonces sería mentir.
  local fusionada
  fusionada="$(cd "$path" && gh pr view --json mergedAt -q '.mergedAt // ""' 2>/dev/null)"
  [[ -n "$fusionada" ]] || die "la propuesta #$PR_NUM no se fusionó"
  ok "propuesta #$PR_NUM fusionada"

  git -C "$path" push -q origin --delete "$branch" 2>/dev/null \
    && ok "rama remota borrada" \
    || info "la rama remota sigue ahí: bórrala desde tu proveedor si quieres"

  echo
  info "el espacio sigue vivo: 'crux workspace rm $name' libera el slot y sus recursos"
}

cmd_list() {
  registry_init
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const rows = Object.entries(r.workspaces);
    if (!rows.length) { console.log("sin espacios activos"); process.exit(0); }
    for (const [name, w] of rows) {
      const huerfano = fs.existsSync(w.path) ? "" : "  (sin worktree — libéralo con: crux workspace rm)";
      console.log(`${name.padEnd(16)} slot ${w.slot}  puertos ${w.ports[0]}-${w.ports[1]}  ${w.path}${huerfano}`);
    }
  ' "$REGISTRY"
}

cmd_rm() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "uso: crux workspace rm <nombre>"

  registry_init
  with_lock

  local path repo branch
  path="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.repo, w.branch].join("\n"));
  ' "$REGISTRY" "$name")" || die "no existe el espacio '$name'"

  repo="$(echo "$path" | sed -n 2p)"
  branch="$(echo "$path" | sed -n 3p)"
  path="$(echo "$path" | sed -n 1p)"

  if [[ -d "$path" ]]; then
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      die "$path tiene cambios sin commitear — resuélvelos antes de borrarlo"
    fi

    SLOT="$(node -e '
      const fs = require("fs");
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(r.workspaces[process.argv[2]].slot));
    ' "$REGISTRY" "$name")"
    PORT0=0; WS_NAME="$name"; WS_BRANCH="$branch"
    local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
    load_config "$docs" "$(basename "$repo")"
    if [[ -n "$TEARDOWN_CMD" ]]; then
      ( cd "$path" && eval "$(substitute "$TEARDOWN_CMD")" ) \
        && ok "teardown ejecutado" \
        || warn "el teardown falló — revisa si quedaron recursos del slot $SLOT"
    fi
    git -C "$repo" worktree remove "$path" 2>/dev/null || git -C "$repo" worktree remove --force "$path"
    ok "worktree eliminado"
  fi

  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    delete r.workspaces[process.argv[2]];
    fs.writeFileSync(process.argv[1], JSON.stringify(r, null, 2) + "\n");
  ' "$REGISTRY" "$name"

  ok "slot liberado"
  info "la rama $branch sigue existiendo; bórrala si ya no la necesitas"
}

case "${1:-}" in
  new)  shift; cmd_new "$@" ;;
  list) shift; cmd_list ;;
  finish) shift; cmd_finish "$@" ;;
  merge)  shift; cmd_merge "$@" ;;
  rm)   shift; cmd_rm "$@" ;;
  *) die "uso: crux workspace {new|list|finish|merge|rm}" ;;
esac
