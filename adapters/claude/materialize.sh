#!/usr/bin/env bash
# Claude Code adapter.
#
# Claude discovers skills through the frontmatter of each SKILL.md, so it is
# enough to link the skill directory inside ~/.claude/skills/.
# It is then invoked with /<name>.

CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

claude_materialize_skill() {
  # claude_materialize_skill <skill_path> <name>
  local src="$1" name="$2"
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] claude: $name"; return 0; }
  mkdir -p "$CLAUDE_SKILLS_DIR"
  # Without -f: a kernel skill is not replaced by a project's. The link is
  # global, so doing so left that project's /ship running in all the others,
  # and crux_prune_skills only cleans broken links.
  local target="$CLAUDE_SKILLS_DIR/$name"
  if [[ -L "$target" ]]; then
    local current_target; current_target="$(readlink "$target")"
    if [[ "$current_target" != "$src" && "$current_target" == "$CRUX_HOME"/* && "$src" != "$CRUX_HOME"/* ]]; then
      echo "warning: skill '$name' is already shipped by the kernel: not replaced by the project's" >&2
      return 0
    fi
  fi
  ln -sfn "$src" "$target"
}

claude_prune_skill() {
  local name="$1"
  local link="$CLAUDE_SKILLS_DIR/$name"
  [[ -L "$link" && ! -e "$link" ]] || return 0
  [[ "${CRUX_DRY_RUN:-0}" == "1" ]] && { echo "      [dry-run] claude: prune $name"; return 0; }
  rm -f "$link"
}

claude_materialize_global() {
  # Claude's global context is ~/.claude/CLAUDE.md. It is not overwritten: it
  # may have the user's own content. It only warns if it does not reference
  # the kernel.
  local marker="$1"
  local file="$HOME/.claude/CLAUDE.md"
  [[ -f "$file" ]] || return 0
  grep -qF "$marker" "$file" || echo "      claude: ~/.claude/CLAUDE.md does not reference the kernel"
}
