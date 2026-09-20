#!/usr/bin/env bash
# Adaptador de Claude Code.
#
# Claude descubre las skills por el frontmatter de cada SKILL.md, así que basta
# con enlazar el directorio de la skill dentro de ~/.claude/skills/.
# Se invoca luego con /<nombre>.

CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

claude_materialize_skill() {
  # claude_materialize_skill <ruta_de_la_skill> <nombre>
  local src="$1" name="$2"
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] claude: $name"; return 0; }
  mkdir -p "$CLAUDE_SKILLS_DIR"
  # Sin -f: una skill del kernel no la reemplaza la de un proyecto. El enlace
  # es global, asi que hacerlo dejaba el /ship de ese proyecto corriendo en
  # todos los demas, y crux_prune_skills solo limpia enlaces rotos.
  local destino="$CLAUDE_SKILLS_DIR/$name"
  if [[ -L "$destino" ]]; then
    local actual; actual="$(readlink "$destino")"
    if [[ "$actual" != "$src" && "$actual" == "$CRUX_HOME"/* && "$src" != "$CRUX_HOME"/* ]]; then
      echo "aviso la skill '$name' ya la trae el kernel: no se reemplaza por la del proyecto" >&2
      return 0
    fi
  fi
  ln -sfn "$src" "$destino"
}

claude_prune_skill() {
  local name="$1"
  local link="$CLAUDE_SKILLS_DIR/$name"
  [[ -L "$link" && ! -e "$link" ]] || return 0
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] claude: prune $name"; return 0; }
  rm -f "$link"
}

claude_materialize_global() {
  # El contexto global de Claude es ~/.claude/CLAUDE.md. No se sobrescribe:
  # puede tener contenido propio del usuario. Solo se avisa si no referencia
  # al kernel.
  local marker="$1"
  local file="$HOME/.claude/CLAUDE.md"
  [[ -f "$file" ]] || return 0
  grep -qF "$marker" "$file" || echo "      claude: ~/.claude/CLAUDE.md no referencia el kernel"
}
