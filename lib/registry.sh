#!/usr/bin/env bash
# El registro de espacios de trabajo: dónde vive cada worktree, qué rama lleva
# y qué franja de puertos tiene reservada.
#
# Estaba dentro de bin/workspace.sh, y por eso los demás lo releían a mano con
# su propio node: status.sh en tres bloques y el hook worktree-guard en otro.
# Cambiar el esquema obligaba a acordarse de los tres.
#
# Requiere CRUX_HOME y lib/common.sh cargada. No fija `set`, por lo mismo que
# common.sh: pisarle las opciones a quien te carga lo mata en silencio.

REGISTRY="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
LOCK="$(dirname "$REGISTRY")/.workspaces.lock"
FLOCK="$(command -v flock 2>/dev/null || true)"
LOCK_MIO=0

registry_init() {
  # 077: el registro lleva las rutas, las ramas y las tareas de todos los
  # proyectos a la vez, incluidos los de clientes distintos. Con el umask
  # corriente quedaba legible por cualquiera en la maquina.
  ( umask 077 && mkdir -p "$(dirname "$REGISTRY")" )
  [[ -f "$REGISTRY" ]] || ( umask 077 && echo '{"workspaces":{}}' > "$REGISTRY" )
  chmod 600 "$REGISTRY" 2>/dev/null || true
}

borra_del_registro() {
  local propio=0
  if [[ $LOCK_MIO -eq 0 ]]; then with_lock 50 && propio=1; fi
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    delete r.workspaces[process.argv[2]];
    fs.writeFileSync(process.argv[1], JSON.stringify(r, null, 2) + "\n");
  ' "$REGISTRY" "$1" || warn "no pude retirar '$1' del registro"
  [[ $propio -eq 1 ]] && unlock
  return 0
}

with_lock() {
  local tope="${1:-300}" segundos=$(( (${1:-300} + 9) / 10 ))
  mkdir -p "$(dirname "$REGISTRY")"

  if [[ -n "$FLOCK" ]]; then
    exec 9>"$LOCK.flock"
    "$FLOCK" -w "$segundos" 9 \
      || die "el registro lleva ${segundos}s cogido por otro crux"
    LOCK_MIO=1
    return 0
  fi

  local tries=0 dueno
  until mkdir "$LOCK" 2>/dev/null; do
    dueno=""
    if [[ -r "$LOCK/pid" ]]; then dueno="$(cat "$LOCK/pid" || true)"; fi
    if [[ -n "$dueno" ]] && ! kill -0 "$dueno" 2>/dev/null; then
      if mv "$LOCK" "$LOCK.$$" 2>/dev/null; then
        rm -rf "$LOCK.$$"
        warn "retirado el cerrojo del proceso $dueno, que ya no existe"
      fi
      continue
    fi
    tries=$((tries + 1))
    if [[ $tries -gt $tope ]]; then
      [[ -n "$dueno" ]] \
        && die "el registro lleva ${segundos}s cogido por el proceso $dueno, que sigue vivo" \
        || die "cerrojo sin dueño en $LOCK: retíralo si ningún crux está corriendo"
    fi
    sleep 0.1
  done
  echo $$ > "$LOCK/pid"
  LOCK_MIO=1
}

unlock() {
  [[ $LOCK_MIO -eq 1 ]] || return 0
  if [[ -n "$FLOCK" ]]; then exec 9>&-; else rm -rf "$LOCK" 2>/dev/null || true; fi
  LOCK_MIO=0
}

escribir_espacio() {
  node -e '
    const fs = require("fs");
    const [file, name, slot, repo, path, branch, port0, perSlot, task, project] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    r.workspaces[name] = {
      slot: Number(slot), repo, path, branch,
      ports: [Number(port0), Number(port0) + Number(perSlot) - 1],
      task, project,
    };
    fs.writeFileSync(file, JSON.stringify(r, null, 2) + "\n");
  ' "$REGISTRY" "$@"
}

registry_entries() {
  # Una línea por espacio: nombre, ruta, rama y slot, separados por tabulador.
  # Quien solo lee no coge el cerrojo: el fichero se escribe de una vez.
  [[ -f "$REGISTRY" ]] || return 0
  node -e '
    const fs = require("fs");
    let r; try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      process.stdout.write([n, w.path, w.branch, w.slot].join("\t") + "\n");
    }
  ' "$REGISTRY"
}

registry_paths() {
  # Solo las rutas, una por línea, para comprobar si un directorio está registrado.
  registry_entries | cut -f2
}
