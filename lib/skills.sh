#!/usr/bin/env bash
# Materialización de skills para todos los agentes soportados.
#
# Una skill es un directorio con un SKILL.md dentro. El contenido es markdown
# neutro; cada adaptador decide cómo lo expone su agente.
#
# Requiere CRUX_HOME. Respeta CRUX_DRY_RUN=1.

# shellcheck source=../adapters/claude/materialize.sh
source "$CRUX_HOME/adapters/claude/materialize.sh"
# shellcheck source=../adapters/codex/materialize.sh
source "$CRUX_HOME/adapters/codex/materialize.sh"

crux_materialize_skills() {
  # crux_materialize_skills <directorio_que_contiene_skills> [etiqueta]
  # Acepta tanto un directorio de skills plano como uno con subcategorías.
  local root="$1" label="${2:-}"
  local count=0

  [[ -d "$root" ]] || return 0

  local skill name
  while IFS= read -r skill; do
    skill="$(dirname "$skill")"
    name="$(basename "$skill")"
    claude_materialize_skill "$skill" "$name"
    codex_materialize_skill "$skill" "$name"
    count=$((count + 1))
  done < <(find "$root" -mindepth 2 -maxdepth 3 -name SKILL.md 2>/dev/null | sort)

  if [[ $count -gt 0 ]]; then
    echo "      $count skills${label:+ ($label)}"
  fi
  return 0
}

crux_prune_skills() {
  local name
  if [[ -d "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" ]]; then
    for link in "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/*; do
      [[ -e "$link" || -L "$link" ]] || continue
      name="$(basename "$link")"
      claude_prune_skill "$name"
      codex_prune_skill "$name"
    done
  fi
  return 0
}
