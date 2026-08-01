#!/usr/bin/env bash
# crux workspace — espacios de trabajo aislados para trabajar en paralelo.
#
#   crux workspace new <nombre> [--repo <dir>] [--base <rama>]
#   crux workspace list
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
  SETUP_CMD=""; TEARDOWN_CMD=""
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

  local repo="$PWD" base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
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
  load_config "$docs" "$repo_name"

  SLOT="$slot"; PORT0=$((PORT_BASE + slot * PORTS_PER_SLOT))
  WS_NAME="$name"; WS_BRANCH="$branch"

  git -C "$repo" worktree add ${base:+-b "$branch"} "$path" ${base:-"$branch"} >/dev/null 2>&1 \
    || git -C "$repo" worktree add -b "$branch" "$path" >/dev/null \
    || die "no pude crear el worktree"

  ok "worktree $path (rama $branch)"

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

cmd_list() {
  registry_init
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const rows = Object.entries(r.workspaces);
    if (!rows.length) { console.log("sin espacios activos"); process.exit(0); }
    for (const [name, w] of rows) {
      console.log(`${name.padEnd(16)} slot ${w.slot}  puertos ${w.ports[0]}-${w.ports[1]}  ${w.path}`);
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
  rm)   shift; cmd_rm "$@" ;;
  *) die "uso: crux workspace {new|list|rm}" ;;
esac
