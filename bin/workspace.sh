#!/usr/bin/env bash
# crux workspace — espacios de trabajo aislados para trabajar en paralelo.
#
#   crux workspace new <nombre> [--repo <dir>] [--base <rama>] [--branch <rama>] [--task <tarea>] [--goal "<texto>"] [--force]
#   crux workspace list
#   crux workspace adopt <ruta> [--task <tarea>]   registra un worktree hecho a mano
#   crux workspace heal [--quiet]                  retira entradas sin carpeta ni rama
#   crux workspace finish <nombre> [--title "..."]
#   crux workspace merge <nombre> [--yes]
#   crux workspace rm <nombre> [--include-ignored]
#   crux workspace gc [--yes] [--include-disk]
#   crux workspace prune [--yes]
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
# Trae REGISTRY, LOCK y el cerrojo. Va despues de common.sh, de la que usa
# die y warn.
source "$CRUX_HOME/lib/registry.sh"

RESERVA=""
WORKTREE_HECHO=0

al_salir() {
  trap - EXIT
  if [[ -n "$RESERVA" ]]; then
    # Con el worktree ya en disco la entrada se queda: es lo que deja
    # retirarlo con 'workspace rm' en vez de a mano.
    if [[ $WORKTREE_HECHO -eq 1 ]]; then
      warn "espacio '$RESERVA' a medias — retíralo con: crux workspace rm $RESERVA"
    else
      borra_del_registro "$RESERVA"
    fi
    RESERVA=""
  fi
  unlock
}
trap al_salir EXIT
trap 'al_salir; exit 130' INT
trap 'al_salir; exit 143' TERM

# El cerrojo lo suelta el sistema al morir el proceso, así que un Ctrl-C duro o
# un OOM no dejan el registro bloqueado. Donde no hay flock —macOS— se usa un
# mkdir con el pid dentro, que sí necesita reconocer al dueño muerto.

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
  local motivo
  motivo="$(json_valido "$cfg")" || die "el contrato de $(basename "$docs") es ilegible — $motivo"

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
  [[ -n "$name" ]] || die "uso: crux workspace new <nombre> [--repo <dir>] [--base <rama>] [--branch <rama>]"
  nombre_valido "$name" \
    || die "nombre de espacio inválido: '$name' — letras, números, punto, guion y guion bajo, sin barras ni '..'"

  local repo="$PWD" base="" rama_pedida="" FORZAR=0 tarea="" objetivo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --task) tarea="$2"; shift 2 ;;
      --goal) objetivo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --branch) rama_pedida="$2"; shift 2 ;;
      --force) FORZAR=1; shift ;;
      *) die "opción desconocida: $1" ;;
    esac
  done

  repo="$(cd "$repo" && git rev-parse --show-toplevel 2>/dev/null)" \
    || die "no es un repo git: $repo"
  local repo_name; repo_name="$(basename "$repo")"
  local parent; parent="$(dirname "$repo")"
  local path="$parent/${repo_name}-ws-${name}"
  # Una tarea que toca varios repos abre un espacio en cada uno con el mismo
  # --task: todos escriben en el mismo registro.
  tarea="${tarea:-$name}"
  nombre_valido "$tarea" || die "nombre de tarea inválido: '$tarea'"
  local proyecto; proyecto="$(project_name_for "$repo")"
  local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
  local perfil=""
  [[ -n "$docs" && -f "$docs/crux.json" ]] &&
    perfil="$(json_get "$docs/crux.json" profile 2>/dev/null || echo "")"

  # El nombre del espacio es local; el de la rama se publica. En el repo de un
  # cliente `ws/<lo-que-sea>` enseña nuestra nomenclatura y, si el nombre va en
  # otro idioma, también eso. Por eso el patrón lo decide el perfil y la rama se
  # puede fijar aparte.
  local patron branch
  patron="$(perfil_get "$perfil" "$docs" branch.pattern "ws/{{name}}")"
  branch="${rama_pedida:-${patron//\{\{name\}\}/$name}}"

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

  # `pointers.write: false` dice que la documentación del estándar no se escribe
  # en el repo de código; no dice que no se pueda trabajar en él. Una rama local
  # no es documentación, y en un repo de cliente desarrollar es justo el encargo:
  # bloquearlo impedía la tarea sin proteger nada. Se avisa de a dónde va la
  # documentación y se sigue. Lo que sí sale hacia el cliente es `finish`, que
  # empuja la rama y abre la propuesta: ahí es donde toca mirar.
  if [[ -n "$perfil" ]]; then
    local escribe
    escribe="$(perfil_get "$perfil" "$docs" pointers.write true)"
    if [[ "$escribe" != "true" && $FORZAR -eq 0 ]]; then
      warn "perfil $perfil: la rama y el worktree son locales y tuyos, pero la"
      warn "documentación de $repo_name va a $(basename "$docs"), no al repo del cliente"
      # La rama sí acaba publicada en su repositorio al proponer el cambio.
      if [[ -z "$rama_pedida" ]]; then
        warn "y la rama '$branch' se verá en su repositorio, con nuestra nomenclatura"
        info "para elegirla: crux workspace new $name --branch fix/<algo-en-ingles>"
      fi
    fi
  fi

  load_config "$docs" "$repo_name"

  cmd_heal --quiet

  registry_init
  with_lock

  # El registro esta indexado por nombre de espacio, asi que dos repos con el
  # mismo nombre se pisaban: la entrada del primero desaparecia, su worktree
  # quedaba vivo pero invisible, sus puertos volvian a repartirse, y un gc
  # posterior lo borraba del disco por "no conocerlo". cmd_adopt ya comprobaba
  # esto; cmd_new no.
  local ocupado
  ocupado="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = (r.workspaces || {})[process.argv[2]];
    process.stdout.write(w ? w.path : "");
  ' "$REGISTRY" "$name")" || ocupado=""
  if [[ -n "$ocupado" ]]; then
    unlock
    err "ya hay un espacio llamado $name en el registro"
    info "está en $ocupado"
    info "usa otro nombre, o retíralo con: crux workspace rm $name"
    exit 1
  fi

  # El menor slot con su rango libre: cada proyecto parte de su propia base, y
  # dos slots distintos de dos proyectos daban el mismo rango de puertos.
  local slot
  slot="$(node -e '
    const fs = require("fs");
    const [file, base, perSlot] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    const ws = Object.values(r.workspaces);
    const ocupados = new Set(ws.map((w) => w.slot));
    const rangos = ws.map((w) => w.ports).filter(Array.isArray);
    const libre = (s) => {
      if (ocupados.has(s)) return false;
      const desde = Number(base) + s * Number(perSlot);
      const hasta = desde + Number(perSlot) - 1;
      return !rangos.some(([a, b]) => desde <= b && a <= hasta);
    };
    let s = 0;
    while (!libre(s)) {
      if (++s > 9999) { process.stderr.write("no queda ningún rango de puertos libre\n"); process.exit(1); }
    }
    process.stdout.write(String(s));
  ' "$REGISTRY" "$PORT_BASE" "$PORTS_PER_SLOT")" || die "no pude repartir un slot"

  SLOT="$slot"; PORT0=$((PORT_BASE + slot * PORTS_PER_SLOT))
  WS_NAME="$name"; WS_BRANCH="$branch"

  # Reservado el slot, el cerrojo se suelta: instalar y levantar el setup tarda
  # minutos, y con el registro cogido el segundo espacio no arrancaba.
  escribir_espacio "$name" "$slot" "$repo" "$path" "$branch" "$PORT0" "$PORTS_PER_SLOT" "$tarea" "$proyecto"
  RESERVA="$name"
  unlock

  # Si se pidio una base concreta y no sale, se para: el camino de respaldo
  # creaba la rama desde HEAD sin decirlo, y se trabajaban horas sobre la base
  # equivocada. El 2>/dev/null del primer intento tiraba ademas el motivo.
  if [[ -n "$base" ]]; then
    git -C "$repo" show-ref --verify --quiet "refs/heads/$base" ||
      git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$base" ||
      die "la base $base no existe en $repo"
    git -C "$repo" worktree add -b "$branch" "$path" "$base" >/dev/null \
      || die "no pude crear el worktree desde $base"
  else
    git -C "$repo" worktree add "$path" "$branch" >/dev/null 2>&1 \
      || git -C "$repo" worktree add -b "$branch" "$path" >/dev/null \
      || die "no pude crear el worktree"
  fi

  WORKTREE_HECHO=1
  ok "worktree $path (rama $branch)"

  local registro_tarea resultado
  registro_tarea="$(task_dir)/$proyecto/$tarea.md"
  if resultado="$(node "$CRUX_HOME/lib/task.mjs" ensure --file "$registro_tarea" \
      --task "$tarea" --project "$proyecto" --repo "$repo_name" --workspace "$name" 2>&1)"; then
    [[ "$resultado" == joined ]] && ok "se une a la tarea '$tarea' ya abierta" || ok "tarea '$tarea' registrada"
    local idioma_tarea
    idioma_tarea="$(idioma_commits "$perfil" "$docs")"
    info "escríbela en '$idioma_tarea': de ella sale la descripción de la propuesta"
    [[ -z "$objetivo" ]] || node "$CRUX_HOME/lib/task.mjs" set --file "$registro_tarea" \
      --section Objetivo --text "$objetivo" >/dev/null 2>&1 || warn "no pude anotar el objetivo"
  else
    warn "no pude escribir el registro de la tarea: $resultado"
  fi

  # La marca de la puerta es estado local. Va al exclude del directorio común,
  # que es el que git respeta desde un worktree, y así no toca el .gitignore
  # versionado —que en un repo ajeno no se puede tocar.
  local comun; comun="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null || echo "")"
  if [[ -n "$comun" ]]; then
    mkdir -p "$comun/info"
    local ignorar
    for ignorar in .crux-ship .crux-visual ${ENV_FILE:+"$ENV_FILE"}; do
      grep -qxF "$ignorar" "$comun/info/exclude" 2>/dev/null \
        || echo "$ignorar" >> "$comun/info/exclude"
    done
  fi

  # Un fichero sin versionar no viaja con `git worktree add`: sin esto, el
  # puntero local del perfil de cliente se quedaba en el repo original.
  if [[ -n "$docs" && "$(perfil_get "$perfil" "$docs" pointers.local false)" == "true" ]]; then
    local rc_puntero=0
    escribir_puntero_local "$path" "$(basename "$docs")" || rc_puntero=$?
    if [[ $rc_puntero -eq 0 ]]; then
      ok "$PUNTERO_LOCAL apunta a $(basename "$docs") (excluido de git)"
    fi
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

  RESERVA=""

  echo
  ok "espacio '$name' listo"
  info "slot $slot · puertos $PORT0-$((PORT0 + PORTS_PER_SLOT - 1))"
  info "cd $path"
}

cmd_finish() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "uso: crux workspace finish <nombre> [--title \"...\"] [--skip-gate]"

  local titulo="" SKIP_GATE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) titulo="$2"; shift 2 ;;
      --skip-gate) SKIP_GATE=1; shift ;;
      --sin-puerta) die "--sin-puerta ahora se llama --skip-gate" ;;
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
  pendiente="$(git -C "$path" status --porcelain | grep -vE ' \.crux-(ship|visual)$' || true)"
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
  # El recibo dice qué se ejecutó y con qué resultado. Un sha suelto solo decía
  # que alguien lo escribió, que no es lo mismo: la puerta se gana, no se
  # declara. El atajo existe, pero hay que pedirlo y se ve.
  local head
  head="$(git -C "$path" rev-parse HEAD)"
  if [[ $SKIP_GATE -eq 1 ]]; then
    warn "propuesta abierta SIN pasar la puerta de calidad, a petición explícita"
  else
    local recibo="$path/.crux-ship" sellado="" comandos=0 fallos=0
    if [[ -f "$recibo" ]]; then
      sellado="$(awk '/^sealed /{print $2}' "$recibo" | tail -1)"
      comandos="$(recibo_comandos "$recibo")"
      fallos="$(recibo_fallos "$recibo")"
    fi
    if [[ ! -f "$recibo" ]]; then
      err "este commit no ha pasado la puerta de calidad"
      info "pásala: crux ship run -- <comando>, y después crux ship seal"
      info "si de verdad hace falta saltarla: --skip-gate"
      exit 1
    fi
    if [[ "${comandos:-0}" -eq 0 ]]; then
      err "el recibo de la puerta no registra ni un comando ejecutado"
      info "un sha suelto no prueba que se verificara nada: crux ship run -- <comando>"
      exit 1
    fi
    if [[ "${fallos:-0}" -gt 0 ]]; then
      err "el recibo registra $(cuenta "$fallos" comprobación comprobaciones) en rojo"
      recibo_en_rojo "$recibo" | sed 's/^/      /'
      exit 1
    fi
    if [[ "$sellado" != "$head" ]]; then
      err "este commit no ha pasado la puerta de calidad"
      [[ -n "$sellado" ]] && info "el recibo es de ${sellado:0:8}, y HEAD es ${head:0:8}"
      info "vuelve a pasarla y cierra con: crux ship seal"
      exit 1
    fi
    local kernel_recibo
    kernel_recibo="$(recibo_kernel "$recibo")"
    if [[ -z "$kernel_recibo" ]]; then
      err "el recibo no dice con qué versión de crux se selló"
      info "vuelve a cerrarlo: crux ship seal"
      exit 1
    fi
    if [[ "$kernel_recibo" != "$(crux_version)" ]]; then
      err "el recibo se selló con crux $kernel_recibo y ahora se ejecuta $(crux_version)"
      info "las reglas de la puerta pueden haber cambiado: vuelve a pasarla"
      exit 1
    fi
    ok "puerta pasada sobre ${head:0:8} con $(cuenta "$comandos" comprobación comprobaciones) (crux $kernel_recibo)"
  fi

  # Aquí es donde se pierde el contexto: la propuesta sale y la sesión que sabía
  # por qué se hizo cada cosa se acaba. Si el registro no tiene ni un paso, la
  # tarea queda con el objetivo de una línea y nada más, y lo que se midió o se
  # descartó por el camino no lo recupera nadie. Va antes de subir, que es
  # cuando todavía se puede anotar. Avisa y sigue: quien decide si la tarea
  # merecía registro es quien la hizo, no el kernel.
  local registro_tarea
  registro_tarea="$(task_file_for_path "$REGISTRY" "$path" 2>/dev/null || echo "")"
  if [[ -n "$registro_tarea" && -f "$registro_tarea" ]]; then
    local pasos_tarea
    pasos_tarea="$(node "$CRUX_HOME/lib/task.mjs" summary --file "$registro_tarea" 2>/dev/null |
      cut -d$'\x1f' -f3)"
    if [[ -z "$pasos_tarea" ]]; then
      warn "la tarea se cierra sin un solo paso anotado"
      info "en $registro_tarea solo queda el objetivo"
      info "lo que mediste y lo que descartaste por el camino no lo recupera nadie"
      info "anótalo ahora: crux task add \"<paso>\" · crux task note \"<decisión>\" --why \"<porqué>\""
    fi
  fi

  # Una rama que choca con la principal sale como propuesta que no se puede
  # integrar, y la puerta se pasó contra una base que ya no existe. Se mira
  # antes de subir, con lo último del remoto; sin red, se sigue como antes.
  local principal_remota
  principal_remota="$(rama_principal "$path")"
  if git -C "$path" fetch -q origin "$principal_remota" 2>/dev/null &&
     git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$principal_remota"; then
    local choques detras
    if ! choques="$(git -C "$path" merge-tree --write-tree --name-only --no-messages \
        HEAD "origin/$principal_remota" 2>/dev/null)"; then
      err "la rama choca con origin/$principal_remota"
      printf '%s\n' "$choques" | tail -n +2 | sed 's/^/      /'
      info "rebasa y vuelve a pasar la puerta: git rebase origin/$principal_remota"
      exit 1
    fi
    detras="$(git -C "$path" rev-list --count "HEAD..origin/$principal_remota" 2>/dev/null || echo 0)"
    [[ "${detras:-0}" -gt 0 ]] &&
      warn "origin/$principal_remota lleva $(cuenta "$detras" "commit" "commits") que esta rama no tiene; no chocan"
  fi

  # La rama base sale del contrato, del remoto o de la local, en ese orden.
  # Antes caía a origin/main cuando no habia origin/HEAD, y en un repo con otra
  # rama principal el rango de abajo falla con 128: con set -e el script muere
  # aqui, con la rama ya subida y sin abrir la propuesta.
  local rama base
  rama="$(rama_principal "$path")"
  if git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$rama"; then
    base="origin/$rama"
  else
    base="$rama"
  fi

  # Una propuesta de más de 400 líneas escritas no se revisa bien de una
  # sentada. Avisa y sigue: partirla es cosa de quien la hizo, y hay cambios que
  # no se dejan partir. Lo generado no cuenta, porque nadie lo lee línea a línea.
  local written_lines
  written_lines="$(git -C "$path" diff --numstat "$base...$branch" 2>/dev/null | awk '
    $1 == "-" { next }
    $3 ~ /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|go\.sum)$/ { next }
    $3 ~ /(^|\/)(dist|build|vendor|generated|__snapshots__)\// || $3 ~ /\.(min\.(js|css)|snap)$/ { next }
    { n += $1 + $2 } END { print n + 0 }')"
  if [[ "${written_lines:-0}" -gt 400 ]]; then
    warn "la propuesta tiene $written_lines líneas escritas: pasa de 400, lo que se revisa bien de una vez"
    info "si se puede partir en unidades que funcionen solas, pártela en propuestas encadenadas"
    info "si no, di en la descripción por qué va entera"
  fi

  # Nada obliga a presentar el plan antes de escribir código, y bloquearlo
  # sería peor: una errata no lo necesita. Pero un cambio de este tamaño sin
  # plan en el registro es justo el que nadie pudo parar a tiempo.
  if [[ "${written_lines:-0}" -gt 100 && -n "$registro_tarea" && -f "$registro_tarea" ]]; then
    local plan_lines
    plan_lines="$(awk '/^## /{on = ($0 == "## Plan"); next} on && NF && !/^<!--.*-->$/' "$registro_tarea" | wc -l | tr -d ' ')"
    if [[ "$plan_lines" -eq 0 ]]; then
      warn "$written_lines líneas escritas y la tarea no tiene plan"
      info "si se aprobó en la conversación, guárdalo: crux task plan <fichero>"
    fi
  fi

  # Si la tarea dice qué cambia y por qué, la descripción sale de ahí; si no,
  # de los commits, como siempre. Un registro vacío no mejora la propuesta.
  local cuerpo="" idioma docs_fin perfil_fin=""

  docs_fin="$(find_docs_repo "$path" 2>/dev/null || echo "")"
  [[ -n "$docs_fin" && -f "$docs_fin/crux.json" ]] &&
    perfil_fin="$(json_get "$docs_fin/crux.json" profile 2>/dev/null || echo "")"
  # La descripción va en el idioma de lo que se publica en el repo, el mismo de
  # los commits. La tarea se escribe en ese idioma porque de ahí sale el texto.
  idioma="$(idioma_commits "$perfil_fin" "$docs_fin")"
  if [[ -n "$registro_tarea" && -f "$registro_tarea" ]]; then
    cuerpo="$(node "$CRUX_HOME/lib/task.mjs" body --file "$registro_tarea" --lang "$idioma" 2>/dev/null || true)"
  fi
  # Si se saltó la puerta, la propuesta lo dice. Antes el cuerpo por defecto
  # afirmaba "puerta pasada" también con --skip-gate: una evidencia falsa
  # engaña más que una que falta.
  local cambios gate_line
  if [[ "$idioma" == "es" ]]; then
    cambios="Cambios"
    if [[ $SKIP_GATE -eq 1 ]]; then gate_line="Abierta SIN pasar la puerta de calidad, a petición explícita."
    else gate_line="Puerta de calidad pasada sobre ${head:0:8}."; fi
  else
    cambios="Changes"
    if [[ $SKIP_GATE -eq 1 ]]; then gate_line="Opened WITHOUT passing the quality gate, at explicit request."
    else gate_line="Quality gate passed on ${head:0:8}."; fi
  fi
  if [[ -z "$cuerpo" ]]; then
    cuerpo="$(printf '%s:\n\n%s\n\n---\n%s\n' "$cambios" \
      "$(git -C "$path" log --format='- %s' "$base..$branch")" "$gate_line")"
  elif [[ $SKIP_GATE -eq 1 ]]; then
    cuerpo="$(printf '%s\n\n---\n%s\n' "$cuerpo" "$gate_line")"
  fi

  # La revisión visual que aprobó una persona entra en la propuesta si es del
  # commit que se propone. Si no lo es, se dice y se sigue: las capturas viejas
  # no se publican como si fueran las de ahora, pero tampoco bloquean.
  if [[ -f "$path/.crux-visual" ]]; then
    local visual="" rc_visual=0
    visual="$(cd "$path" && bash "$CRUX_HOME/bin/visual.sh" section --publish --lang "$idioma" 2>&1)" || rc_visual=$?
    if [[ $rc_visual -eq 0 ]]; then
      cuerpo="$(printf '%s\n\n%s' "$cuerpo" "$visual")"
      ok "revisión visual añadida a la propuesta"
    else
      warn "la revisión visual no entra en la propuesta"
      printf '%s\n' "$visual" | sed 's/^/      /'
    fi
  fi

  # El cuerpo pasa por el mismo filtro que ship body antes de que nada salga.
  # Existia y no lo llamaba nadie: dependia de que el agente se acordara, y lo
  # que se publica fuera no puede depender de eso. Va antes del push para que
  # un cuerpo con una credencial dentro ni siquiera suba la rama.
  local cuerpo_tmp
  cuerpo_tmp="$(mktemp "${TMPDIR:-/tmp}/crux-cuerpo.XXXXXX")"
  printf '%s\n' "$cuerpo" > "$cuerpo_tmp"
  if ! ( cd "$path" && bash "$CRUX_HOME/bin/ship.sh" body "$cuerpo_tmp" >/dev/null 2>&1 ); then
    err "el cuerpo de la propuesta no pasa el filtro"
    ( cd "$path" && bash "$CRUX_HOME/bin/ship.sh" body "$cuerpo_tmp" 2>&1 | sed 's/^/      /' ) || true
    info "sale del registro de la tarea: $registro_tarea"
    rm -f "$cuerpo_tmp"
    exit 1
  fi
  rm -f "$cuerpo_tmp"

  git -C "$path" push -q -u origin "$branch" || die "no pude subir $branch"
  ok "$branch subida ($(cuenta "$commits" commit commits))"

  local url_pr=""
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    # Contra la rama base, no contra --remotes: para cuando se calcula el título
    # la rama ya está subida, así que --remotes la excluiría entera y el título
    # se quedaría vacío.
    local primero
    primero="$(git -C "$path" log --format='%s' "$base..$branch" | tail -1)"
    [[ -n "$primero" ]] || primero="$(git -C "$path" log -1 --format=%s "$branch")"
    # El error de gh se guarda en vez de tirarse: sin el, una propuesta ya
    # abierta, una plantilla obligatoria o un permiso que falta daban el mismo
    # mensaje que no tener gh instalado.
    local gh_err
    gh_err="$(mktemp "${TMPDIR:-/tmp}/crux-gh.XXXXXX")"
    url_pr="$(cd "$path" && gh pr create \
      --title "${titulo:-$primero}" \
      --body "$cuerpo" 2>"$gh_err" || true)"
    if [[ -z "$url_pr" && -s "$gh_err" ]]; then
      warn "gh no pudo abrir la propuesta"
      head -3 "$gh_err" | sed 's/^/      /'
    fi
    rm -f "$gh_err"
  fi

  if [[ -n "$url_pr" ]]; then
    ok "propuesta abierta: $url_pr"
    if [[ -n "$registro_tarea" && -f "$registro_tarea" ]]; then
      node "$CRUX_HOME/lib/task.mjs" meta --file "$registro_tarea" --key pr --value "$url_pr" >/dev/null 2>&1 || true
      node "$CRUX_HOME/lib/task.mjs" status --file "$registro_tarea" --to proposed >/dev/null 2>&1 || true
    fi
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
    // Comillas simples, como en load_config: dentro de las dobles bash sigue
    // expandiendo $(...), y estos valores salen de gh, o sea del titulo que
    // cualquiera puede ponerle a la propuesta.
    const q = (v) => `'"'"'${String(v).replace(/'"'"'/g, "")}'"'"'`;
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
  local registro_tarea
  registro_tarea="$(task_file_for_path "$REGISTRY" "$path" 2>/dev/null || echo "")"
  [[ -n "$registro_tarea" && -f "$registro_tarea" ]] &&
    node "$CRUX_HOME/lib/task.mjs" status --file "$registro_tarea" --to merged >/dev/null 2>&1 || true

  git -C "$path" push -q origin --delete "$branch" 2>/dev/null \
    && ok "rama remota borrada" \
    || info "la rama remota sigue ahí: bórrala desde tu proveedor si quieres"

  echo
  # Fusionada, el espacio ya no tiene nada que hacer. Dejarlo vivo por defecto
  # era lo que acumulaba espacios de trabajo terminado durante semanas. rm se
  # niega solo si queda algo sin commitear, y entonces se queda y se dice.
  if [[ "$(preferencia CRUX_MERGE_CLOSE_WORKSPACE true)" == "true" ]]; then
    ( cmd_rm "$name" ) || warn "el espacio sigue vivo: ciérralo con 'crux workspace rm $name' cuando esté limpio"
  else
    info "el espacio sigue vivo (CRUX_MERGE_CLOSE_WORKSPACE=false): 'crux workspace rm $name'"
  fi
}

cmd_list() {
  local todos=0
  [[ "${1:-}" == "--all" ]] && todos=1
  registry_init
  local aqui=""
  [[ $todos -eq 0 ]] && aqui="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const aqui = process.argv[2];
    let rows = Object.entries(r.workspaces);
    const total = rows.length;
    // Desde dentro de un espacio, "este repo" es el repo del que cuelga, no la
    // ruta del worktree: si no, la lista decía que no había nada justo al
    // retomar, que es cuando se mira.
    const propio = rows.find(([, w]) => w.path === aqui);
    const repo = propio ? propio[1].repo : aqui;
    if (aqui) rows = rows.filter(([, w]) => w.repo === repo);
    if (!rows.length) {
      console.log(total ? `sin espacios en este repo (${total} en otros: crux workspace list --all)`
                        : "sin espacios activos");
      process.exit(0);
    }
    const desde = (p) => {
      try {
        const dias = Math.floor((Date.now() - fs.statSync(p).mtimeMs) / 86400000);
        return dias < 1 ? "hoy" : dias === 1 ? "ayer" : `hace ${dias} días`;
      } catch { return ""; }
    };
    // Lo que importa al volver a un espacio es en qué punto quedó: el estado y
    // el siguiente paso de su tarea, no solo el slot.
    const tarea = (w) => {
      if (!w.task || !w.project) return "";
      try {
        const t = fs.readFileSync(`${process.argv[3]}/${w.project}/${w.task}.md`, "utf8");
        const estado = (t.match(/^status: (.*)$/m) || [])[1] || "";
        const sig = ((t.split(/^## Siguiente paso$/m)[1] || "").split(/^## /m)[0] || "")
          .replace(/<!--[\s\S]*?-->/g, "").trim().split("\n")[0];
        const pend = (t.match(/^- \[ \] (T\d+ .*)$/m) || [])[1] || "";
        return `${estado}${(sig || pend) ? " · " + (sig || pend).slice(0, 60) : ""}`;
      } catch { return ""; }
    };
    for (const [name, w] of rows) {
      const vivo = fs.existsSync(w.path);
      const cola = vivo ? desde(w.path) : "sin worktree — retíralo con: crux workspace gc";
      console.log(`${name.padEnd(16)} slot ${String(w.slot).padStart(2)}  puertos ${w.ports[0]}-${w.ports[1]}  ${cola.padEnd(14)}  ${w.path}`);
      const t = tarea(w);
      if (t) console.log(`${"".padEnd(16)} tarea ${w.task}: ${t}`);
    }
  ' "$REGISTRY" "$aqui" "$(task_dir)"
}

# Los hooks se prueban antes de un release instalándolos desde un espacio del
# kernel. Al cerrarlo apuntarían a una carpeta borrada y fallarían en cada
# mensaje, comando y cierre del agente: si el repo es el kernel, se reinstalan
# desde el checkout principal y se retiran los que solo existían en el espacio.
repoint_hooks() {
  local workspace="$1" main_repo="$2" settings="$3"
  if [[ ! -f "$main_repo/bin/hooks.sh" || ! -d "$main_repo/adapters" ]] ||
    ! ( cd "$main_repo" && CRUX_HOME="$main_repo" CLAUDE_SETTINGS="$settings" \
          bash "$main_repo/bin/hooks.sh" install >/dev/null 2>&1 ); then
    warn "los hooks del agente apuntan a este espacio: quedarán rotos al borrarlo"
    info "reinstálalos desde el repo principal: crux hooks install"
    return 0
  fi

  local removed
  removed="$(node -e '
    const fs = require("fs");
    const [file, prefix] = process.argv.slice(1);
    const settings = JSON.parse(fs.readFileSync(file, "utf8"));
    let removed = 0;
    for (const [event, groups] of Object.entries(settings.hooks || {})) {
      for (const group of groups) {
        const kept = (group.hooks || []).filter((h) => !(h.command || "").includes(prefix));
        removed += (group.hooks || []).length - kept.length;
        group.hooks = kept;
      }
      settings.hooks[event] = groups.filter((g) => g.hooks.length);
    }
    fs.writeFileSync(file, JSON.stringify(settings, null, 2) + "\n");
    process.stdout.write(String(removed));
  ' "$settings" "$workspace/")"

  ok "hooks del agente devueltos al checkout principal: $main_repo"
  [[ "$removed" == "0" ]] || info "retirados $removed que solo existían en el espacio"
}

cmd_rm() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "uso: crux workspace rm <nombre> [--include-ignored]"
  local include_ignored=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-ignored) include_ignored=1; shift ;;
      --con-ignorados) die "--con-ignorados ahora se llama --include-ignored" ;;
      *) die "opción desconocida: $1" ;;
    esac
  done

  registry_init
  with_lock

  local path repo branch
  path="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const w = r.workspaces[process.argv[2]];
    if (!w) process.exit(2);
    process.stdout.write([w.path, w.repo, w.branch, w.project || "", w.task || ""].join("\n"));
  ' "$REGISTRY" "$name")" || die "no existe el espacio '$name'"

  repo="$(echo "$path" | sed -n 2p)"
  branch="$(echo "$path" | sed -n 3p)"
  local proyecto_rm tarea_rm
  proyecto_rm="$(echo "$path" | sed -n 4p)"
  tarea_rm="$(echo "$path" | sed -n 5p)"
  path="$(echo "$path" | sed -n 1p)"
  unlock

  if [[ -d "$path" ]]; then
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      die "$path tiene cambios sin commitear — resuélvelos antes de borrarlo"
    fi
    # Instalar los hooks desde dentro de un espacio los deja apuntando a él, y
    # al cerrarlo dejan de existir sin que nada lo diga hasta la sesión
    # siguiente.
    local settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
    if [[ -f "$settings" ]] && grep -qF "$path/" "$settings"; then
      repoint_hooks "$path" "$repo" "$settings"
    fi

    SLOT="$(node -e '
      const fs = require("fs");
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(r.workspaces[process.argv[2]].slot));
    ' "$REGISTRY" "$name")"
    PORT0=0; WS_NAME="$name"; WS_BRANCH="$branch"
    local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
    load_config "$docs" "$(basename "$repo")"

    # Despues de load_config: ENV_FILE sale del contrato, y ese fichero lo
    # escribe el propio crux, asi que no cuenta como trabajo que se pierde.
    if [[ $include_ignored -eq 0 && -n "$(ficheros_ignorados "$path" "${ENV_FILE:-}")" ]]; then
      err "$path tiene ficheros ignorados que se perderian al retirarlo"
      ficheros_ignorados "$path" "${ENV_FILE:-}" | sed 's/^/      /' | head -10
      info "sacalos de ahi, o retiralo igualmente: crux workspace rm $name --include-ignored"
      exit 1
    fi

    if [[ -n "$TEARDOWN_CMD" ]]; then
      ( cd "$path" && eval "$(substitute "$TEARDOWN_CMD")" ) \
        && ok "teardown ejecutado" \
        || warn "el teardown falló — revisa si quedaron recursos del slot $SLOT"
    fi
    if git -C "$repo" worktree remove "$path" 2>/dev/null \
       || git -C "$repo" worktree remove --force "$path" 2>/dev/null; then
      ok "worktree eliminado"
    else
      # git deja de reconocerlo si alguien borró su registro por otra vía. El
      # directorio sigue ocupando el slot, así que se retira igual.
      rm -rf "$path"
      git -C "$repo" worktree prune 2>/dev/null || true
      ok "directorio retirado (git ya no lo tenía como worktree)"
    fi
  fi

  with_lock
  if borra_del_registro "$name"; then
    unlock
    ok "slot liberado"
  else
    unlock
    err "el worktree ya no está, pero su entrada sigue en el registro"
    info "el slot y los puertos quedan reservados hasta que se retire"
    info "revisa los permisos de $REGISTRY y repite: crux workspace heal"
    exit 1
  fi

  [[ -n "$tarea_rm" && -n "$proyecto_rm" ]] && archivar_si_terminada "$proyecto_rm" "$tarea_rm"

  # Solo si está integrada: una rama con trabajo que no está en ningún sitio no
  # se borra por una preferencia.
  # Aqui la rama la creo crux para este espacio, asi que `--merged` si dice lo
  # que parece: sus commits estan en la principal. Lo que no vale como prueba
  # es para una rama cualquiera del repo, que es de lo que va prune.
  if [[ "$(preferencia CRUX_RM_DELETE_BRANCH false)" == "true" ]] &&
     git -C "$repo" branch --merged "$(rama_principal "$repo")" 2>/dev/null |
       sed 's/^[ *]*//' | grep -qxF -- "$branch" &&
     [[ -n "$(git -C "$repo" log --oneline "$(rama_principal "$repo")".."$branch" 2>/dev/null ||
              git -C "$repo" log --oneline -1 "$branch" 2>/dev/null)" ]]; then
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 \
      && ok "rama $branch borrada (CRUX_RM_DELETE_BRANCH)" \
      || info "la rama $branch sigue existiendo"
  else
    info "la rama $branch sigue existiendo; bórrala si ya no la necesitas"
  fi
}

# Una tarea se archiva sola cuando se cierra su último espacio y ya está
# fusionada. Si sigue abierta, se queda: un espacio se puede cerrar para
# retomarla desde otro, y archivar trabajo sin terminar lo escondería.
archivar_si_terminada() {
  local proyecto="$1" tarea="$2" registro estado otros destino
  registro="$(task_dir)/$proyecto/$tarea.md"
  [[ -f "$registro" ]] || return 0
  otros="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const n = Object.values(r.workspaces || {}).filter((w) => w.project === process.argv[2] && w.task === process.argv[3]).length;
    process.stdout.write(String(n));
  ' "$REGISTRY" "$proyecto" "$tarea")"
  if [[ "${otros:-0}" -gt 0 ]]; then
    info "la tarea '$tarea' sigue en $otros espacio(s) más"
    return 0
  fi
  estado="$(awk -F': ' '/^status:/{print $2; exit}' "$registro")"
  case "$estado" in
    merged|deployed)
      promote_decisions "$registro"
      if destino="$(node "$CRUX_HOME/lib/task.mjs" archive --file "$registro" 2>&1)"; then
        ok "tarea '$tarea' archivada"
      else
        warn "no pude archivar la tarea: $destino"
      fi
      ;;
    closed) ;;
    *)
      info "la tarea '$tarea' sigue abierta ($estado)"
      info "si ya no sigue: crux task archive --task $proyecto/$tarea"
      ;;
  esac
}

# Una rama fusionada por squash no aparece en `git branch --merged`: su commit
# nunca entra en la principal. Preguntarle a la propuesta es lo único fiable en
# un flujo que fusiona así.
ramas_con_propuesta_fusionada() {
  # Las ramas que de verdad tuvieron una propuesta fusionada, en una sola
  # llamada. Antes se usaba `git branch --merged` como atajo, y eso es cierto
  # para cualquier rama que apunte a un ancestro de la principal: una recien
  # creada sin un solo commit propio, o una de vida larga como develop o
  # staging justo despues de que su release entre. Se borraban, aqui y en el
  # remoto, diciendo "su propuesta ya fusionada" sin haber preguntado nunca.
  local repo="$1" slug
  slug="$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || return 1
  [[ -n "$slug" ]] || return 1
  gh pr list --repo "$slug" --state merged --limit 200 --json headRefName \
     -q '.[].headRefName' 2>/dev/null
}

# El registro se repara solo. Una entrada cuya carpeta ya no existe y cuya rama
# tampoco no guarda nada: alguien retiró el worktree por su cuenta —un
# `git worktree remove` para liberar disco— y el registro no se enteró. Se
# acumularon 41 así. Si la rama sigue viva, puede haber trabajo: se avisa y se
# deja.
cmd_heal() {
  local callado=0
  [[ "${1:-}" == "--quiet" ]] && callado=1
  [[ -f "$REGISTRY" ]] || return 0
  local n repo branch path proyecto tarea retiradas=0
  while IFS=$'\t' read -r n repo branch path proyecto tarea; do
    [[ -n "$n" ]] || continue
    if [[ -d "$repo" ]] && git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1; then
      [[ $callado -eq 1 ]] || warn "'$n' no tiene carpeta, pero su rama $branch sigue viva: no se retira"
      continue
    fi
    with_lock 50
    borra_del_registro "$n"
    unlock
    retiradas=$((retiradas + 1))
    [[ $callado -eq 1 ]] || ok "'$n' retirado del registro: ni carpeta ni rama"
    [[ -n "$tarea" && -n "$proyecto" ]] && archivar_si_terminada "$proyecto" "$tarea" >/dev/null
  done < <(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      if (fs.existsSync(w.path)) continue;
      console.log([n, w.repo, w.branch, w.path, w.project || "", w.task || ""].join("\t"));
    }
  ' "$REGISTRY")
  if [[ $callado -eq 1 ]]; then
    [[ $retiradas -gt 0 ]] && info "registro reparado: $retiradas espacio(s) sin carpeta ni rama retirados"
  elif [[ $retiradas -eq 0 ]]; then
    ok "el registro está al día"
  fi
  return 0
}

# Un worktree hecho a mano no existe para crux: ni sale en las listas ni lo
# protege nada, y `gc --include-disk` lo trataría como basura. Pasó con uno que
# tenía trabajo pendiente de revisión.
cmd_adopt() {
  local ruta="${1:-}"; shift || true
  [[ -n "$ruta" ]] || die "uso: crux workspace adopt <ruta> [--task <tarea>]"
  local tarea=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) tarea="$2"; shift 2 ;;
      *) die "opción desconocida: $1" ;;
    esac
  done
  [[ -d "$ruta" ]] || die "no existe $ruta"
  ruta="$(cd "$ruta" && pwd)"
  es_worktree "$ruta" || die "$ruta no es un worktree de git"
  local base; base="$(basename "$ruta")"
  [[ "$base" == *-ws-* ]] || die "el nombre no sigue el patrón <repo>-ws-<nombre>: $base"
  local name="${base#*-ws-}" repo branch
  repo="$(repo_principal "$ruta")"
  branch="$(git -C "$ruta" rev-parse --abbrev-ref HEAD)"
  nombre_valido "$name" || die "nombre de espacio inválido: '$name'"
  tarea="${tarea:-$name}"
  local proyecto; proyecto="$(project_name_for "$repo")"

  registry_init
  with_lock
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const [, , name, path] = process.argv.slice(1);
    if (r.workspaces[name]) { console.error(`ya hay un espacio llamado ${name}`); process.exit(2); }
    if (Object.values(r.workspaces).some((w) => w.path === path)) { console.error("ese worktree ya está registrado"); process.exit(2); }
  ' "$REGISTRY" x "$name" "$ruta" || { unlock; exit 1; }

  local docs; docs="$(find_docs_repo "$repo" 2>/dev/null || echo "")"
  load_config "$docs" "$(basename "$repo")"
  local slot
  slot="$(node -e '
    const fs = require("fs");
    const [file, base, perSlot] = process.argv.slice(1);
    const r = JSON.parse(fs.readFileSync(file, "utf8"));
    const ws = Object.values(r.workspaces);
    const ocupados = new Set(ws.map((w) => w.slot));
    const rangos = ws.map((w) => w.ports).filter(Array.isArray);
    const libre = (s) => {
      if (ocupados.has(s)) return false;
      const desde = Number(base) + s * Number(perSlot);
      return !rangos.some(([a, b]) => desde <= b && a <= desde + Number(perSlot) - 1);
    };
    let s = 0; while (!libre(s)) s++;
    process.stdout.write(String(s));
  ' "$REGISTRY" "$PORT_BASE" "$PORTS_PER_SLOT")"
  local port0=$((PORT_BASE + slot * PORTS_PER_SLOT))
  escribir_espacio "$name" "$slot" "$repo" "$ruta" "$branch" "$port0" "$PORTS_PER_SLOT" "$tarea" "$proyecto"
  unlock

  local registro_tarea resultado
  registro_tarea="$(task_dir)/$proyecto/$tarea.md"
  resultado="$(node "$CRUX_HOME/lib/task.mjs" ensure --file "$registro_tarea" \
    --task "$tarea" --project "$proyecto" --repo "$(basename "$repo")" --workspace "$name" 2>&1)" \
    || warn "no pude escribir el registro de la tarea: $resultado"
  ok "'$name' adoptado ($branch, slot $slot)"
  info "tarea '$tarea': $registro_tarea"
}

# El registro y el disco se separan en las dos direcciones: una entrada cuyo
# worktree borró alguien a mano, y un worktree que nunca llegó al registro.
# `prune` mira ramas; esto mira espacios.
cmd_gc() {
  local confirmado=0 include_disk=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) confirmado=1; shift ;;
      --include-disk) include_disk=1; shift ;;
      --con-disco) die "--con-disco ahora se llama --include-disk" ;;
      *) die "opción desconocida: $1" ;;
    esac
  done

  registry_init
  local raiz; raiz="$(projects_root)"

  local sin_worktree=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && sin_worktree+=("$n")
  done < <(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      if (!fs.existsSync(w.path)) console.log(n);
    }
  ' "$REGISTRY")

  local registrados; registrados="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(Object.values(r.workspaces || {}).map((w) => w.path).join("\n"));
  ' "$REGISTRY")"

  local sin_registrar=() d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\n' "$registrados" | grep -qxF "$d" && continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    es_worktree "$d" || continue
    sin_registrar+=("$d")
  done < <(find "$raiz" -maxdepth 2 -type d -name '*-ws-*' 2>/dev/null | sort)

  caducar_tareas "$confirmado"

  if [[ ${#sin_worktree[@]} -eq 0 && ${#sin_registrar[@]} -eq 0 ]]; then
    ok "registro y disco están de acuerdo"
    return 0
  fi

  if [[ ${#sin_worktree[@]} -gt 0 ]]; then
    echo "entradas del registro sin worktree en disco (${#sin_worktree[@]}):"
    printf '      %s\n' "${sin_worktree[@]}"
    echo
  fi
  if [[ ${#sin_registrar[@]} -gt 0 ]]; then
    echo "worktrees en disco que el registro no conoce (${#sin_registrar[@]}):"
    local w
    for w in "${sin_registrar[@]}"; do
      printf '      %s%s\n' "$(basename "$w")" "$(espacio_limpio "$w" || echo "  (con trabajo dentro)")"
    done
    echo
  fi

  if [[ $confirmado -eq 0 ]]; then
    info "para retirar las entradas huérfanas: crux workspace gc --yes"
    [[ ${#sin_registrar[@]} -gt 0 ]] \
      && info "y los worktrees, si están limpios: crux workspace gc --yes --include-disk"
    return 0
  fi

  local n
  for n in ${sin_worktree[@]+"${sin_worktree[@]}"}; do
    with_lock 50
    borra_del_registro "$n"
    unlock
    ok "$n retirado del registro"
  done

  [[ $include_disk -eq 1 ]] || {
    [[ ${#sin_registrar[@]} -gt 0 ]] && info "el disco no se toca sin --include-disk"
    return 0
  }

  local w repo
  for w in ${sin_registrar[@]+"${sin_registrar[@]}"}; do
    if ! espacio_limpio "$w"; then
      warn "$(basename "$w") tiene trabajo sin subir: se queda"
      continue
    fi
    repo="$(repo_principal "$w")"
    if git -C "$repo" worktree remove "$w" 2>/dev/null; then
      ok "$(basename "$w") retirado del disco"
    else
      warn "no pude retirar $(basename "$w"): hazlo con 'git worktree remove'"
    fi
  done
}

# Las tareas archivadas caducan. Lo que tenía que durar ya salió: la descripción
# está en la propuesta y las decisiones en el docs repo. La fecha va en el
# nombre del fichero, no en la de modificación, que cambia con cualquier copia.
caducar_tareas() {
  local confirmado="$1" dias corte f fecha viejas=()
  dias="${CRUX_TASKS_RETENTION_DAYS:-$(preferencia CRUX_TASKS_RETENTION_DAYS 180)}"
  [[ "$dias" =~ ^[0-9]+$ ]] || die "CRUX_TASKS_RETENTION_DAYS tiene que ser un número de días: '$dias'"
  corte="$(node -e 'const d = new Date(Date.now() - Number(process.argv[1]) * 86400000); process.stdout.write(d.toISOString().slice(0, 10))' "$dias")"
  for f in "$(task_dir)"/*/done/*.md; do
    [[ -f "$f" ]] || continue
    fecha="$(basename "$f" | cut -c1-10)"
    [[ "$fecha" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ "$fecha" < "$corte" ]] && viejas+=("$f")
  done
  [[ ${#viejas[@]} -gt 0 ]] || return 0
  echo "tareas archivadas hace más de $dias días (${#viejas[@]}):"
  for f in "${viejas[@]}"; do printf '      %s/%s\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(basename "$f" .md)"; done
  if [[ "$confirmado" -eq 1 ]]; then
    rm -f "${viejas[@]}"
    ok "${#viejas[@]} tareas caducadas borradas"
  else
    info "para borrarlas: crux workspace gc --yes"
  fi
  echo
}

# Un worktree se retira solo si no se pierde nada: ni cambios sin commitear ni
# commits propios del espacio que no estén en ningún remoto. Contra la rama
# principal y no contra HEAD: en un repo sin remoto, HEAD --not --remotes son
# todos los commits del proyecto y nunca saldría limpio.
ficheros_ignorados() {
  # ficheros_ignorados <dir> [fichero que crux regenera]
  #
  # Lo que git status normal no ensena y al retirar el worktree se borra igual:
  # ahi viven la base de datos del espacio y lo que se haya dejado a mano. Se
  # deja fuera lo reponible por una instalacion, el recibo de la puerta, el
  # puntero local y el fichero de entorno que escribe el propio crux.
  local propio="${2:-}"
  git -C "$1" status --porcelain --ignored=matching 2>/dev/null |
    grep -E '^!! ' |
    grep -vE '^!! (\.crux-ship|\.crux-visual|CLAUDE\.local\.md$|node_modules/|\.next/|dist/|build/|target/|\.venv/|__pycache__/|\.turbo/|\.nx/|\.pnpm-store/|coverage/)' |
    { [[ -n "$propio" ]] && grep -vxF "!! $propio" || cat; } || true
}

espacio_limpio() {
  local w="$1"
  [[ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ]] || return 1
  [[ -z "$(ficheros_ignorados "$w" "${ENV_FILE:-}")" ]] || return 1
  local base sueltos
  base="$(rama_principal "$w")"
  sueltos="$(git -C "$w" log --oneline "$base..HEAD" --not --remotes 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${sueltos:-0}" -eq 0 ]]
}

cmd_prune() {
  local confirmado=0
  [[ "${1:-}" == "--yes" ]] && confirmado=1

  local repo; repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "esto se ejecuta dentro de un repo"
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
    || die "hace falta gh autenticado para saber qué propuestas se fusionaron"

  local principal; principal="$(rama_principal "$repo")"
  local fusionadas
  fusionadas="$(ramas_con_propuesta_fusionada "$repo")" \
    || die "no pude preguntarle a gh que propuestas se fusionaron"

  local integradas=()
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != "$principal" ]] || continue
    # Nada de ramas de vida larga: aunque su propuesta se fusionara, borrarlas
    # rompe el flujo de quien las usa.
    case "$b" in
      develop|development|staging|stage|next|production|prod|release|release/*|hotfix/*) continue ;;
    esac
    printf '%s\n' "$fusionadas" | grep -qxF -- "$b" && integradas+=("$b")
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin |
           sed 's|^origin/||' | sort -u)

  if [[ ${#integradas[@]} -eq 0 ]]; then
    ok "no hay ramas fusionadas que limpiar"
    return 0
  fi

  echo "ramas con su propuesta ya fusionada (${#integradas[@]}):"
  printf '      %s\n' "${integradas[@]}"
  echo
  if [[ $confirmado -eq 0 ]]; then
    info "para borrarlas, aquí y en el remoto: crux workspace prune --yes"
    return 0
  fi

  local limpiadas=0
  local en_uso; en_uso="$(git -C "$repo" worktree list --porcelain | sed -n 's/^branch refs\/heads\///p')"
  for b in "${integradas[@]}"; do
    if echo "$en_uso" | grep -qx "$b"; then
      info "$b la usa un worktree: se queda"
      continue
    fi
    # Con set -e, un borrado que falla —la rama solo existía en local, o ya no
    # está en el remoto— se llevaría por delante el resto de la pasada.
    local borrada=0
    git -C "$repo" branch -D "$b" >/dev/null 2>&1 && borrada=1
    git -C "$repo" push -q origin --delete "$b" >/dev/null 2>&1 && borrada=1
    [[ $borrada -eq 1 ]] && limpiadas=$((limpiadas + 1))
  done
  ok "$limpiadas de ${#integradas[@]} ramas limpiadas"
}

uso() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

for arg in "$@"; do
  [[ "$arg" == "--help" || "$arg" == "-h" ]] && { uso; exit 0; }
done

case "${1:-}" in
  new)  shift; cmd_new "$@" ;;
  list) shift; cmd_heal --quiet; cmd_list "$@" ;;
  adopt) shift; cmd_adopt "$@" ;;
  heal) shift; cmd_heal "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  merge)  shift; cmd_merge "$@" ;;
  rm)   shift; cmd_rm "$@" ;;
  gc)   shift; cmd_gc "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  help) uso ;;
  *) uso >&2; die "uso: crux workspace {new|list|adopt|finish|merge|rm|gc|heal|prune}" ;;
esac
