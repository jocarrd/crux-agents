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
  # Devuelve 1 si no pudo. Antes devolvia 0 pasara lo que pasara, y quien la
  # llama ya ha borrado el worktree del disco: quedaba la entrada viva
  # apuntando a una ruta que ya no existe, el slot reservado para siempre y un
  # "ok slot liberado" que era mentira.
  local propio=0 rc=0
  if [[ $LOCK_MIO -eq 0 ]]; then with_lock 50 && propio=1; fi
  node -e '
    const fs = require("fs");
    const [file, nombre] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    delete r.workspaces[nombre];
    // A temporal y renombrar: un kill a mitad dejaba el registro truncado, y
    // con el truncado el guarda de borrado se abre y status lista cero.
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(r, null, 2) + "\n", { mode: 0o600 });
    fs.renameSync(tmp, file);
  ' "$REGISTRY" "$1" || { warn "no pude retirar '$1' del registro"; rc=1; }
  [[ $propio -eq 1 ]] && unlock
  return $rc
}

with_lock() {
  local tope="${1:-300}" segundos=$(( (${1:-300} + 9) / 10 ))
  mkdir -p "$(dirname "$REGISTRY")"

  # El cerrojo por directorio es el unico que entienden los dos caminos: flock
  # bloquea un fichero aparte, y un proceso con el PATH recortado —un hook, un
  # cron— no lo encuentra y cogia el suyo. Eran dos candados distintos sobre el
  # mismo registro, y se comprobo que dos procesos entraban a la vez. Se coge
  # siempre este; flock se mantiene encima porque espera sin dar vueltas.
  if [[ -n "$FLOCK" ]]; then
    exec 9>"$LOCK.flock"
    "$FLOCK" -w "$segundos" 9 \
      || die "el registro lleva ${segundos}s cogido por otro crux"
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
  # Los dos, en el orden inverso al que se cogieron. Sin el `|| true` la
  # función devuelve 1 cuando no hay flock, y quien la llama encadenada con
  # && se corta ahí.
  rm -rf "$LOCK" 2>/dev/null || true
  [[ -n "$FLOCK" ]] && exec 9>&- || true
  LOCK_MIO=0
  return 0
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
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(r, null, 2) + "\n", { mode: 0o600 });
    fs.renameSync(tmp, file);
  ' "$REGISTRY" "$@"
}

registry_entries() {
  # Una línea por espacio: nombre, ruta, rama y slot, separados por tabulador.
  # Quien solo lee no coge el cerrojo: el fichero se escribe de una vez.
  [[ -f "$REGISTRY" ]] || return 0
  node -e '
    const fs = require("fs");
    let r;
    // Un registro ilegible no es un registro vacio: callarlo abria el guarda
    // de borrado y hacia que status listara cero espacios sin decir nada.
    try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stderr.write("registro ilegible: " + e.message + "\n"); process.exit(1); }
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      process.stdout.write([n, w.path, w.branch, w.slot].join("\t") + "\n");
    }
  ' "$REGISTRY"
}

registry_paths() {
  # Solo las rutas, una por línea, para comprobar si un directorio está registrado.
  registry_entries | cut -f2
}
