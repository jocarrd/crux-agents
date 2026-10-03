#!/usr/bin/env bash
# Codex adapter.
#
# Codex does not interpret skill frontmatter nor has a skills directory of its
# own. What it does have are custom prompts in ~/.codex/prompts/<name>.md,
# invocable with /<name>.
#
# The stub does NOT duplicate the content: it points to the kernel's SKILL.md,
# which is the single source. So a skill edited once works for both agents.

CODEX_PROMPTS_DIR="${CODEX_PROMPTS_DIR:-$HOME/.codex/prompts}"
CODEX_HOME_DIR="${CODEX_HOME_DIR:-$HOME/.codex}"

codex_materialize_skill() {
  # codex_materialize_skill <skill_path> <name>
  local src="$1" name="$2"
  local skill_md="$src/SKILL.md"
  [[ -f "$skill_md" ]] || return 0
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] codex: $name"; return 0; }
  mkdir -p "$CODEX_PROMPTS_DIR"
  cat > "$CODEX_PROMPTS_DIR/$name.md" <<EOF
Read and follow the procedure described in:

$skill_md

Apply it to the current task. User arguments (if any): \$ARGUMENTS
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
  # Codex reads ~/.codex/AGENTS.md as global context. It is generated pointing
  # to the kernel standard, with markers so it can be regenerated without
  # overwriting what the user wrote by hand outside the block.
  local crux_home="$1"
  local file="$CODEX_HOME_DIR/AGENTS.md"
  local begin="<!-- crux:begin -->"
  local end="<!-- crux:end -->"

  local block
  block="$(cat <<EOF
$begin
# Work system (crux)

The documentation and agent work standard lives in:

  $crux_home/STANDARD.md

Rules that apply in any project:

- A project's documentation lives in its \`<project>-docs\` repo, never inside
  the code repo. A repo's specific documentation goes in \`repos/<repo>/\`.
- When changing code that affects a doc, update the doc in the same turn.
- Project notes and references go to git, not to local memory.
- Conventional commits, body lines of 100 characters, no emojis.
- Before working in a repo, read its \`AGENTS.md\` and the docs repo's.

The procedures available as \`/<name>\` are in
$crux_home/skills/ and in each project's docs repo.
$end
EOF
)"

  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] codex: global AGENTS.md"; return 0; }
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
