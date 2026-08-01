#!/usr/bin/env bash
# Adaptador de Codex.
#
# Codex no interpreta el frontmatter de las skills ni tiene un directorio de
# skills propio. Lo que sí tiene son prompts personalizados en
# ~/.codex/prompts/<nombre>.md, invocables con /<nombre>.
#
# El stub NO duplica el contenido: apunta al SKILL.md del kernel, que es la
# única fuente. Así una skill editada una vez vale para los dos agentes.

CODEX_PROMPTS_DIR="${CODEX_PROMPTS_DIR:-$HOME/.codex/prompts}"
CODEX_HOME_DIR="${CODEX_HOME_DIR:-$HOME/.codex}"

codex_materialize_skill() {
  # codex_materialize_skill <ruta_de_la_skill> <nombre>
  local src="$1" name="$2"
  local skill_md="$src/SKILL.md"
  [[ -f "$skill_md" ]] || return 0
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] codex: $name"; return 0; }
  mkdir -p "$CODEX_PROMPTS_DIR"
  cat > "$CODEX_PROMPTS_DIR/$name.md" <<EOF
Lee y sigue el procedimiento descrito en:

$skill_md

Aplícalo a la tarea actual. Argumentos del usuario (si los hay): \$ARGUMENTS
EOF
}

codex_prune_skill() {
  local name="$1"
  local stub="$CODEX_PROMPTS_DIR/$name.md"
  [[ -f "$stub" ]] || return 0
  local target
  target="$(grep -m1 '/SKILL.md$' "$stub" 2>/dev/null || true)"
  [[ -n "$target" && ! -f "$target" ]] || return 0
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] codex: prune $name"; return 0; }
  rm -f "$stub"
}

codex_materialize_global() {
  # Codex lee ~/.codex/AGENTS.md como contexto global. Se genera apuntando al
  # estándar del kernel, con marcadores para poder regenerarlo sin pisar lo que
  # el usuario haya escrito a mano fuera del bloque.
  local crux_home="$1"
  local file="$CODEX_HOME_DIR/AGENTS.md"
  local begin="<!-- crux:begin -->"
  local end="<!-- crux:end -->"

  local block
  block="$(cat <<EOF
$begin
# Sistema de trabajo (crux)

El estándar de documentación y trabajo con agentes vive en:

  $crux_home/STANDARD.md

Reglas que aplican en cualquier proyecto:

- La documentación de un proyecto vive en su repo \`<project>-docs\`, nunca
  dentro del repo de código. La específica de un repo, en \`repos/<repo>/\`.
- Al cambiar código que afecta a una doc, se actualiza la doc en el mismo turno.
- Las notas de proyecto y las referencias van a git, no a memoria local.
- Conventional commits, body de 100 caracteres por línea, sin emojis.
- Antes de trabajar en un repo, lee su \`AGENTS.md\` y el del docs repo.

Los procedimientos disponibles como \`/<nombre>\` están en
$crux_home/skills/ y en el docs repo de cada proyecto.
$end
EOF
)"

  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] codex: AGENTS.md global"; return 0; }
  mkdir -p "$CODEX_HOME_DIR"

  if [[ -f "$file" ]] && grep -qF "$begin" "$file"; then
    node -e '
      const fs = require("fs");
      const [file, begin, end, block] = process.argv.slice(1);
      const src = fs.readFileSync(file, "utf8");
      const re = new RegExp(begin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[\\s\\S]*?" + end.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
      fs.writeFileSync(file, src.replace(re, block));
    ' "$file" "$begin" "$end" "$block"
  else
    printf '%s\n' "$block" >> "$file"
  fi
}
