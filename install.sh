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

export CRUX_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$CRUX_HOME/lib/common.sh"
source "$CRUX_HOME/lib/skills.sh"

export CRUX_DRY_RUN=0
REMOTE_DEFECTO=""
RAIZ_PROYECTOS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) export CRUX_DRY_RUN=1; shift ;;
    --remote)  REMOTE_DEFECTO="$2"; shift 2 ;;
    --projects-dir) RAIZ_PROYECTOS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "crux $(tr -d '[:space:]' < "$CRUX_HOME/VERSION") — $CRUX_HOME"
[[ "$CRUX_DRY_RUN" == "1" ]] && warn "dry-run: no se escribe nada"
echo

# --- 1. Config de máquina ----------------------------------------------------

if [[ "$CRUX_DRY_RUN" == "0" ]]; then
  mkdir -p "$HOME/.crux"
  # Se conserva el remoto por defecto si ya estaba: reinstalar no debe borrarlo.
  anterior=""
  [[ -f "$HOME/.crux/config" ]] && anterior="$(grep -E '^CRUX_REMOTE=' "$HOME/.crux/config" || true)"
  cat > "$HOME/.crux/config" <<EOF
# Generado por crux install.sh
CRUX_HOME="$CRUX_HOME"
EOF
  if [[ -n "$REMOTE_DEFECTO" ]]; then
    echo "CRUX_REMOTE=\"$REMOTE_DEFECTO\"" >> "$HOME/.crux/config"
  elif [[ -n "$anterior" ]]; then
    echo "$anterior" >> "$HOME/.crux/config"
  fi
  # Se deja escrita para que la lean también los hooks y los scripts de node,
  # que no pasan por lib/common.sh.
  echo "CRUX_PROJECTS_DIR=\"${RAIZ_PROYECTOS:-$(dirname "$CRUX_HOME")}\"" >> "$HOME/.crux/config"
fi
ok "config en ~/.crux/config"
info "raíz de proyectos: ${RAIZ_PROYECTOS:-$(dirname "$CRUX_HOME")}"
[[ -z "$RAIZ_PROYECTOS" ]] && info "(deducida de dónde está el kernel; cámbiala con --projects-dir)"

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

# --- 4. Contexto global por agente ------------------------------------------

codex_materialize_global "$CRUX_HOME"
ok "contexto global de Codex en ~/.codex/AGENTS.md"

claude_materialize_global "$CRUX_HOME"
ok "contexto global de Claude verificado"

echo
echo "Siguiente paso: en el docs repo de un proyecto, 'crux adopt' o 'crux doctor'."
echo "Para un proyecto nuevo: 'crux init <project>'."
