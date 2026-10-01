#!/usr/bin/env bash
# Instalación de crux en una máquina. Idempotente.
#
#   ~/Proyectos/crux/install.sh                          instala
#   ~/Proyectos/crux/install.sh --remote '<plantilla>'    instala fijando el
#                                                        remoto habitual
#   ~/Proyectos/crux/install.sh --projects-dir <ruta>    fija la raíz de proyectos
#   ~/Proyectos/crux/install.sh --dry-run                enseña qué haría
#
# La raíz de proyectos es, por defecto, el directorio donde has clonado el
# kernel: si crux está en /opt/dev/crux, tus proyectos van en /opt/dev. Se puede
# cambiar, pero conviene que el kernel viva con ellos.
#
# No toca los docs repos de ningún proyecto: para eso están `crux link` y
# `crux upgrade`.

set -euo pipefail

CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
source "$CRUX_HOME/lib/skills.sh"

export CRUX_DRY_RUN=0
REMOTE_DEFECTO=""
RAIZ_PROYECTOS=""
MODO="release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) export CRUX_DRY_RUN=1; shift ;;
    --dev)     MODO="dev"; shift ;;
    --remote)  REMOTE_DEFECTO="$2"; shift 2 ;;
    --projects-dir) RAIZ_PROYECTOS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Los proyectos consumen el kernel por symlink. Enlazados al working copy, usan
# lo que haya en él en cada momento: una rama a medias cambia el comportamiento
# de todos los proyectos sin tocarlos. La copia por versión los desacopla.
ORIGEN="$CRUX_HOME"
VERSION_INSTALADA="$(tr -d '[:space:]' < "$ORIGEN/VERSION")"
# Esta version es parte de la ruta que se borra unas lineas mas abajo, asi que
# un VERSION con ../ dentro borraba lo que hubiera ahi. es_semver ya existe.
es_semver "$VERSION_INSTALADA" ||
  die "VERSION no es una version valida: '$VERSION_INSTALADA'"

# En dev todo cuelga por symlink de este directorio: si es un worktree, al
# cerrarlo la máquina se queda sin skills. En release da igual, porque se copia.
if [[ "$MODO" == "dev" ]] && es_worktree "$ORIGEN"; then
  err "esto es un worktree del kernel: $ORIGEN"
  info "en dev las skills quedarían colgando de un directorio efímero"
  info "instala desde el principal ($(repo_principal "$ORIGEN")), o sin --dev"
  exit 1
fi
es_worktree "$ORIGEN" && warn "instalando desde un worktree: la copia será de la rama $(git -C "$ORIGEN" rev-parse --abbrev-ref HEAD)"
if [[ "$MODO" == "release" && "$CRUX_DRY_RUN" == "0" ]]; then
  DESTINO="$HOME/.crux/kernel/$VERSION_INSTALADA"
  rm -rf "$DESTINO"
  mkdir -p "$DESTINO"
  for pieza in bin lib skills templates profiles adapters VERSION STANDARD.md GUIA.md README.md AGENTS.md; do
    [[ -e "$ORIGEN/$pieza" ]] && cp -R "$ORIGEN/$pieza" "$DESTINO/"
  done
  CRUX_HOME="$DESTINO"
  export CRUX_HOME
fi

echo "crux $VERSION_INSTALADA — $CRUX_HOME"
[[ "$MODO" == "dev" ]] && warn "modo dev: los proyectos usarán tu working copy, tal como esté en cada momento"
[[ "$CRUX_DRY_RUN" == "1" ]] && warn "dry-run: no se escribe nada"
echo

# --- 1. Config de máquina ----------------------------------------------------

# La raíz se deduce del clon del kernel, no de $CRUX_HOME: en release este ya
# apunta a ~/.crux/kernel/<version>, cuyo padre es el directorio de kernels y no
# contiene ningún proyecto. Con esa raíz, la comprobación de consumidores de
# `crux release` no encontraba a nadie y publicaba sin verificar nada.
# Precedencia: la bandera, lo ya declarado, y por último la deducción.
RAIZ_ORIGEN_TEXTO="deducida de dónde está el clon del kernel"
RAIZ_POR_BANDERA=0
[[ -n "$RAIZ_PROYECTOS" ]] && RAIZ_POR_BANDERA=1
if [[ -z "$RAIZ_PROYECTOS" && -f "$HOME/.crux/config" ]]; then
  declarada="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"' || true)"
  # El directorio de kernels es donde una instalación anterior dejó escrita la
  # raíz mal deducida. Conservarlo sería conservar el fallo en toda máquina ya
  # instalada, así que se descarta y se vuelve a deducir.
  if [[ -n "$declarada" && "$declarada" == "$HOME/.crux/kernel" ]]; then
    warn "la raíz declarada era el directorio de kernels: se corrige"
    declarada=""
  fi
  if [[ -n "$declarada" ]]; then
    RAIZ_PROYECTOS="$declarada"
    RAIZ_ORIGEN_TEXTO="conservada de la instalación anterior"
  fi
fi
RAIZ_EFECTIVA="${RAIZ_PROYECTOS:-$(dirname "$ORIGEN")}"

if [[ "$CRUX_DRY_RUN" == "0" ]]; then
  mkdir -p "$HOME/.crux"
  # Se conserva el remoto por defecto si ya estaba: reinstalar no debe borrarlo.
  anterior=""
  [[ -f "$HOME/.crux/config" ]] && anterior="$(grep -E '^CRUX_REMOTE=' "$HOME/.crux/config" || true)"
  cat > "$HOME/.crux/config" <<EOF
# Generado por crux install.sh
CRUX_HOME="$CRUX_HOME"
CRUX_MODE="$MODO"
EOF
  if [[ -n "$REMOTE_DEFECTO" ]]; then
    echo "CRUX_REMOTE=\"$REMOTE_DEFECTO\"" >> "$HOME/.crux/config"
  elif [[ -n "$anterior" ]]; then
    echo "$anterior" >> "$HOME/.crux/config"
  fi
  # Se deja escrita para que la lean también los hooks y los scripts de node,
  # que no pasan por lib/common.sh.
  echo "CRUX_PROJECTS_DIR=\"$RAIZ_EFECTIVA\"" >> "$HOME/.crux/config"
fi
ok "config en ~/.crux/config"
info "raíz de proyectos: $RAIZ_EFECTIVA"
[[ "$RAIZ_POR_BANDERA" == "0" ]] && info "($RAIZ_ORIGEN_TEXTO; cámbiala con --projects-dir)"

# --- 2. Comando en el PATH ---------------------------------------------------

BIN_DIR="$HOME/.local/bin"
if [[ "$CRUX_DRY_RUN" == "0" ]]; then
  mkdir -p "$BIN_DIR"
  ln -sfn "$CRUX_HOME/bin/crux" "$BIN_DIR/crux"
  chmod +x "$CRUX_HOME/bin/crux" "$CRUX_HOME"/bin/*.sh "$CRUX_HOME"/lib/*.sh "$CRUX_HOME"/lib/*.mjs 2>/dev/null || true
fi
ok "comando en $BIN_DIR/crux"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR no está en tu PATH — añádelo para usar 'crux' directamente" ;;
esac

# --- 3. Skills del kernel ----------------------------------------------------

crux_materialize_skills "$CRUX_HOME/skills" "kernel"
ok "skills del kernel materializadas (Claude + Codex)"

# Los hooks del agente llevan la versión en la ruta: sin esto, la sesión seguía
# ejecutando el kernel anterior hasta un 'crux hooks install' que nadie lanzaba.
AJUSTES="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
if [[ "$MODO" == "release" && "$CRUX_DRY_RUN" == "0" && -f "$AJUSTES" ]]; then
  movidos="$(node -e '
    const fs = require("fs");
    const [file, kernels, destino] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(file, "utf8"));
    const esc = kernels.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const viejo = new RegExp(`${esc}/[^/]+/adapters/`, "g");
    let n = 0;
    for (const grupos of Object.values(s.hooks || {})) for (const g of grupos) for (const h of g.hooks || []) {
      const cmd = (h.command || "").replace(viejo, `${destino}/adapters/`);
      if (cmd !== h.command) { h.command = cmd; n++; }
    }
    if (n) fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
    process.stdout.write(String(n));
  ' "$AJUSTES" "$HOME/.crux/kernel" "$CRUX_HOME")"
  [[ "$movidos" != "0" ]] && ok "hooks del agente movidos a $VERSION_INSTALADA ($movidos)"
fi

# --- 4. Contexto global por agente ------------------------------------------

codex_materialize_global "$CRUX_HOME"
ok "contexto global de Codex en ~/.codex/AGENTS.md"

claude_materialize_global "$CRUX_HOME"
ok "contexto global de Claude verificado"

echo
if [[ "$MODO" == "release" ]]; then
  echo "Instalado $VERSION_INSTALADA en $CRUX_HOME"
  echo "Tus proyectos usan esa copia, no tu working copy: al cambiar el kernel, repite el install."
  echo "Para desarrollar el propio kernel: install.sh --dev"
else
  echo "Modo dev: enlazado a $CRUX_HOME"
  echo "Para volver a una versión inmutable: install.sh"
fi
echo
echo "Siguiente paso: en el docs repo de un proyecto, 'crux adopt' o 'crux doctor'."
echo "Para un proyecto nuevo: 'crux init <project>'."
