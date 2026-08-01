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
MARK="crux/adapters"

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
    if [[ -f "$docs/.git/hooks/pre-commit" ]] && grep -q "$MARK\|crux doctor" "$docs/.git/hooks/pre-commit"; then
      ok "pre-commit instalado"
    else
      info "sin pre-commit de crux"
    fi
  fi
}

cmd_install() {
  [[ -f "$DOC_SYNC" ]] || die "falta $DOC_SYNC"
  chmod +x "$DOC_SYNC"

  mkdir -p "$(dirname "$SETTINGS")"
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak"

  # Se reemplazan las entradas apuntando a un doc-sync anterior (incluidas las
  # que quedaron rotas al mover el script al kernel) y se deja el resto intacto:
  # el fichero es del usuario, no nuestro.
  node -e '
    const fs = require("fs");
    const [file, cmd] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(file, "utf8"));
    s.hooks = s.hooks || {};
    const grupos = (s.hooks.Stop = s.hooks.Stop || []);
    const esDocSync = (c) => /doc-sync|check-doc-sync/.test(c || "");
    let reemplazados = 0;
    for (const g of grupos) {
      g.hooks = (g.hooks || []).map((h) => {
        if (!esDocSync(h.command)) return h;
        reemplazados++;
        return { ...h, command: cmd };
      });
    }
    if (!reemplazados) {
      grupos.push({ matcher: "", hooks: [{ type: "command", command: cmd }] });
    }
    fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
    console.log(reemplazados ? `      reemplazadas ${reemplazados} entradas previas` : "      entrada nueva");
  ' "$SETTINGS" "$DOC_SYNC"

  ok "hook de deriva de documentación al cerrar sesión"
  info "copia previa en $SETTINGS.bak"

  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)" && [[ -d "$docs/.git" ]]; then
    cat > "$docs/.git/hooks/pre-commit" <<'EOF'
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
    chmod +x "$docs/.git/hooks/pre-commit"
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
        .map((g) => ({ ...g, hooks: (g.hooks || []).filter((h) => !/doc-sync/.test(h.command || "")) }))
        .filter((g) => (g.hooks || []).length);
      if (!s.hooks[evento].length) delete s.hooks[evento];
    }
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");
  ' "$SETTINGS"
  ok "hooks de crux retirados (el resto queda como estaba)"

  local docs
  if docs="$(find_docs_repo "$PWD" 2>/dev/null)" && [[ -f "$docs/.git/hooks/pre-commit" ]]; then
    grep -q "crux doctor" "$docs/.git/hooks/pre-commit" && rm "$docs/.git/hooks/pre-commit" && ok "pre-commit retirado"
  fi
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) die "uso: crux hooks {status|install|remove}" ;;
esac
