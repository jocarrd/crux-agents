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
  local docs="$1"
  PORT_BASE=3000; PORTS_PER_SLOT=10; ENV_FILE=""; ENV_TEMPLATE="{}"
  local cfg="$docs/crux.json"
  [[ -f "$cfg" ]] || return 0
  PORT_BASE="$(json_get "$cfg" 'workspace.portBase' 2>/dev/null || echo 3000)"
  PORTS_PER_SLOT="$(json_get "$cfg" 'workspace.portsPerSlot' 2>/dev/null || echo 10)"
  ENV_FILE="$(json_get "$cfg" 'workspace.envFile' 2>/dev/null || echo "")"
  ENV_TEMPLATE="$(node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(JSON.stringify((o.workspace || {}).env || {}));
  ' "$cfg" 2>/dev/null || echo "{}")"
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
  load_config "$docs"

  local port0=$((PORT_BASE + slot * PORTS_PER_SLOT))

  git -C "$repo" worktree add ${base:+-b "$branch"} "$path" ${base:-"$branch"} >/dev/null 2>&1 \
    || git -C "$repo" worktree add -b "$branch" "$path" >/dev/null \
    || die "no pude crear el worktree"

  ok "worktree $path (rama $branch)"

  # Fichero de entorno derivado del slot
  if [[ -n "$ENV_FILE" && "$ENV_TEMPLATE" != "{}" ]]; then
    node -e '
      const fs = require("fs");
      const [file, tmplRaw, slot, port0, perSlot, name, branch] = process.argv.slice(1);
      const tmpl = JSON.parse(tmplRaw);
      const subst = (v) => {
        v = String(v).replace(/\{\{SLOT\}\}/g, slot)
                     .replace(/\{\{NAME\}\}/g, name)
                     .replace(/\{\{BRANCH\}\}/g, branch);
        return v.replace(/\{\{PORT(\d+)\}\}/g, (_, i) => String(Number(port0) + Number(i)));
      };
      const lines = Object.entries(tmpl).map(([k, v]) => `${k}=${subst(v)}`);
      fs.writeFileSync(file, lines.join("\n") + "\n");
    ' "$path/$ENV_FILE" "$ENV_TEMPLATE" "$slot" "$port0" "$PORTS_PER_SLOT" "$name" "$branch"
    ok "$ENV_FILE con el slot $slot (puertos desde $port0)"
  else
    info "sin sección workspace en crux.json: solo se reserva el rango de puertos"
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
  ' "$REGISTRY" "$name" "$slot" "$repo" "$path" "$branch" "$port0" "$PORTS_PER_SLOT"

  echo
  ok "espacio '$name' listo"
  info "slot $slot · puertos $port0-$((port0 + PORTS_PER_SLOT - 1))"
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
