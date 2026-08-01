#!/usr/bin/env bash
# crux hooks — engancha el estándar a los momentos en que se aplica.
#
#   crux hooks status     qué hay puesto y si apunta a algo que existe
#   crux hooks install    instala los del agente y, si procede, los de git
#   crux hooks remove     retira solo los que gestiona crux
#
# Un estándar que hay que acordarse de comprobar se comprueba a veces. Estos
# hooks lo comprueban siempre.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DOC_SYNC="$CRUX_HOME/adapters/claude/hooks/doc-sync.sh"
CYCLE_GUARD="$CRUX_HOME/adapters/claude/hooks/cycle-guard.sh"
MARK="crux/adapters"

# En un worktree, .git es un fichero y los hooks viven en el directorio común
# del repo. Preguntárselo a git es lo único que funciona en los dos casos.
dir_hooks() {
  local d
  d="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$d" = /* ]] || d="$1/$d"
  mkdir -p "$d/hooks"
  echo "$d/hooks"
}

cmd_status() {
  echo "hooks del agente — $SETTINGS"
  if [[ ! -f "$SETTINGS" ]]; then
    warn "no existe todavía"
  else
    node -e '
      const fs = require("fs");
      const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const hooks = s.hooks || {};
      let n = 0;
      for (const [evento, grupos] of Object.entries(hooks)) {
        for (const g of grupos) for (const h of (g.hooks || [])) {
          n++;
          const cmd = h.command || "";
          const path = cmd.replace(/^~/, process.env.HOME).split(" ")[0];
          const existe = fs.existsSync(path);
          const propio = cmd.includes(process.argv[2]);
          console.log(`      ${existe ? "ok " : "ROTO"}  ${evento.padEnd(12)} ${propio ? "[crux] " : ""}${cmd}`);
        }
      }
      if (!n) console.log("      ninguno configurado");
    ' "$SETTINGS" "$MARK"
  fi

  echo
  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)"; then
    echo "hooks de git — $(basename "$docs")"
    if [[ -f "$(dir_hooks "$docs")/pre-commit" ]] && grep -q "$MARK\|crux doctor" "$(dir_hooks "$docs")/pre-commit"; then
      ok "pre-commit instalado"
    else
      info "sin pre-commit de crux"
    fi
    if [[ -f "$(dir_hooks "$docs")/pre-push" ]] && grep -q "crux workspace" "$(dir_hooks "$docs")/pre-push"; then
      ok "pre-push instalado — sin push directo a la principal"
    else
      info "sin pre-push de crux"
    fi
  fi
}

# Reemplaza las entradas que apuntan a una versión anterior del mismo hook
# (incluidas las que quedaron rotas al mover los scripts al kernel) y deja el
# resto intacto: el fichero es del usuario, no nuestro.
enganchar() {
  # enganchar <evento> <comando> <patrón de lo anterior>
  node -e '
    const fs = require("fs");
    const [file, evento, cmd, patron] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(file, "utf8"));
    s.hooks = s.hooks || {};
    const grupos = (s.hooks[evento] = s.hooks[evento] || []);
    const previo = new RegExp(patron);
    let reemplazados = 0;
    for (const g of grupos) {
      g.hooks = (g.hooks || []).map((h) => {
        if (!previo.test(h.command || "")) return h;
        reemplazados++;
        return { ...h, command: cmd };
      });
    }
    if (!reemplazados) {
      grupos.push({ matcher: "", hooks: [{ type: "command", command: cmd }] });
    }
    fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
    console.log(reemplazados ? `      reemplazadas ${reemplazados} entradas previas` : "      entrada nueva");
  ' "$SETTINGS" "$1" "$2" "$3"
}

cmd_install() {
  [[ -f "$DOC_SYNC" ]] || die "falta $DOC_SYNC"
  [[ -f "$CYCLE_GUARD" ]] || die "falta $CYCLE_GUARD"
  chmod +x "$DOC_SYNC" "$CYCLE_GUARD"

  mkdir -p "$(dirname "$SETTINGS")"
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak"

  enganchar Stop "$DOC_SYNC" 'doc-sync|check-doc-sync'
  ok "hook de deriva de documentación al cerrar sesión"

  enganchar UserPromptSubmit "$CYCLE_GUARD" 'cycle-guard'
  ok "hook del ciclo al empezar en la rama principal"

  info "copia previa en $SETTINGS.bak"

  # Impedir el push directo a la rama principal. La protección de verdad es del
  # lado del servidor, pero en un repo privado sin plan de pago no está
  # disponible: esto cubre el descuido, que es el caso real. Un `--no-verify`
  # lo salta, y eso es aceptable porque entonces es una decisión.
  instalar_pre_push() {
    local repo="$1" principal hooks
    hooks="$(dir_hooks "$repo")" || return 1
    # La principal del repo, no la del worktree en el que estemos ahora.
    # `|| true`: si no hay origin/HEAD el pipeline falla y con pipefail se lleva
    # por delante el script entero.
    principal="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    [[ -n "$principal" ]] || principal=main
    cat > "$hooks/pre-push" <<EOF
#!/usr/bin/env bash
# Instalado por crux hooks install.
# El trabajo entra por propuesta, no por push directo a $principal.
while read -r _ _ remote_ref _; do
  [[ "\$remote_ref" == "refs/heads/$principal" ]] || continue
  echo
  echo "push directo a $principal bloqueado"
  echo
  echo "  crux workspace new <tarea>     # rama propia y entorno aislado"
  echo "  crux workspace finish <tarea>  # sube la rama y abre la propuesta"
  echo
  echo "Si de verdad hace falta: git push --no-verify"
  exit 1
done
exit 0
EOF
    chmod +x "$hooks/pre-push"
  }

  local kernel
  kernel="$(crux_home)"
  if [[ -n "$kernel" ]] && git -C "$kernel" rev-parse --git-dir >/dev/null 2>&1; then
    instalar_pre_push "$kernel"
    ok "pre-push en el kernel — el trabajo entra por propuesta"
  fi

  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)" && git -C "$docs" rev-parse --git-dir >/dev/null 2>&1; then
    instalar_pre_push "$docs"
    ok "pre-push en $(basename "$docs")"
    cat > "$(dir_hooks "$docs")/pre-commit" <<'EOF'
#!/usr/bin/env bash
# Instalado por crux hooks install.
# Verifica la conformidad antes de dejar commitear en el docs repo.
command -v crux >/dev/null || exit 0
if ! crux doctor >/tmp/crux-precommit.$$ 2>&1; then
  echo
  echo "crux doctor no pasa — el commit se detiene:"
  echo
  grep -E "^error" /tmp/crux-precommit.$$ | sed 's/^/  /'
  echo
  echo "Arréglalo, o salta la comprobación con: git commit --no-verify"
  rm -f /tmp/crux-precommit.$$
  exit 1
fi
rm -f /tmp/crux-precommit.$$
EOF
    chmod +x "$(dir_hooks "$docs")/pre-commit"
    ok "pre-commit en $(basename "$docs") — bloquea si doctor falla"
  else
    info "sin docs repo en el directorio actual: no se instala el pre-commit"
    info "entra en uno y repite para engancharlo"
  fi
}

cmd_remove() {
  [[ -f "$SETTINGS" ]] || die "no hay $SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak"
  node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const [evento, grupos] of Object.entries(s.hooks || {})) {
      s.hooks[evento] = grupos
        .map((g) => ({ ...g, hooks: (g.hooks || []).filter((h) => !/doc-sync|cycle-guard/.test(h.command || "")) }))
        .filter((g) => (g.hooks || []).length);
      if (!s.hooks[evento].length) delete s.hooks[evento];
    }
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");
  ' "$SETTINGS"
  ok "hooks de crux retirados (el resto queda como estaba)"

  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)" && [[ -f "$(dir_hooks "$docs")/pre-commit" ]]; then
    grep -q "crux doctor" "$(dir_hooks "$docs")/pre-commit" && rm "$(dir_hooks "$docs")/pre-commit" && ok "pre-commit retirado"
  fi
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) die "uso: crux hooks {status|install|remove}" ;;
esac
