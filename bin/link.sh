#!/usr/bin/env bash
# crux link — generates and checks the context pointers of the project's code
# repos, and materializes their own skills.
#
# Everything comes from crux.json: no project names or repo lists are
# hardcoded. The profile decides whether anything is written to code repos.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
source "$CRUX_HOME/lib/skills.sh"

REFRESH=0
TARGET="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh) REFRESH=1; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

DOCS="$(find_docs_repo "$TARGET")" || die "no docs repo found from $TARGET"
CONFIG="$DOCS/crux.json"
[[ -f "$CONFIG" ]] || die "$CONFIG is missing — run 'crux adopt' first"

PROJECT="$(json_get "$CONFIG" project)"
PROFILE="$(json_get "$CONFIG" profile)"
DOCS_NAME="$(basename "$DOCS")"
ROOT="$(dirname "$DOCS")"

# The contract is read from the main checkout, but what is written into the
# docs repo goes to the tree link was run from when that tree is a worktree of
# it: from a workspace of the docs repo it used to land in the main checkout.
DOCS_TREE="$DOCS"
target_top="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$target_top" && "$target_top" != "$DOCS" ]] &&
   [[ "$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == \
      "$(git -C "$DOCS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]]; then
  DOCS_TREE="$target_top"
fi

echo "project $PROJECT · profile $PROFILE"
echo

# Each repo's one-line description lives in the repos/README.md table, which is
# its canonical source. Without it the pointer loses the only useful thing it
# said about the repo.
tagline_of() {
  local repo="$1" out
  out="$(node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    let out = "";
    try {
      for (const l of fs.readFileSync(file, "utf8").split("\n")) {
        if (!l.startsWith("|")) continue;
        const c = l.split("|").map((x) => x.trim());
        if (c[1]?.replace(/[`\/]/g, "") === repo) { out = c[3] || ""; break; }
      }
    } catch {}
    process.stdout.write(out);
  ' "$DOCS/repos/README.md" "$repo" 2>/dev/null || true)"
  echo "${out:-part of $PROJECT}"
}

# --- Profile rules -----------------------------------------------------------
#
# They used to live in the profile with nobody reading them, or be copied by
# hand into a project's AGENTS.md claiming doctor enforced them, which was
# false. They are written from the profile into a managed block, and doctor
# checks they are there. The old block was marked `perfil`: it is still
# recognised and replaced by the `profile` one.

write_profile_rules() {
  local rules; rules="$(profile_get "$PROFILE" "$DOCS" rules "")"
  [[ -n "$rules" ]] || return 0

  # Built with $'\n' and not with $(printf ...): a command substitution drops
  # the trailing newlines, and every rule ended up glued to the previous one.
  local nl=$'\n' block r
  block="<!-- crux:begin profile -->${nl}## Rules of the \`$PROFILE\` profile${nl}${nl}"
  block+="The profile declares them, and \`crux doctor\` checks they are written here.${nl}"
  block+="Following them is up to whoever does the work: they are working rules, not${nl}"
  block+="automatic checks.${nl}${nl}"
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    block+="- $r${nl}"
  done <<< "$rules"
  block+="${nl}<!-- crux:end -->"

  local target="$DOCS_TREE/AGENTS.md"
  [[ -f "$target" ]] || return 0
  if grep -qE 'crux:begin (perfil|profile)' "$target"; then
    node -e '
      const fs = require("fs");
      const [f, block] = process.argv.slice(1);
      const re = /<!-- crux:begin (?:perfil|profile)[\s\S]*?crux:end -->/;
      const current = fs.readFileSync(f, "utf8");
      if (current.match(re)[0] === block) process.exit(2);
      fs.writeFileSync(f, current.replace(re, block));
    ' "$target" "$block" && ok "profile $PROFILE rules updated in AGENTS.md" || true
  else
    printf '\n%s\n' "$block" >> "$target"
    ok "profile $PROFILE rules written to AGENTS.md"
  fi
}

write_profile_rules

# --- Code repo pointers ------------------------------------------------------

WRITES_POINTERS="$(profile_get "$PROFILE" "$DOCS" pointers.write true)"

if [[ "$WRITES_POINTERS" != "true" ]]; then
  if [[ "$(profile_get "$PROFILE" "$DOCS" pointers.local false)" != "true" ]]; then
    warn "profile $PROFILE: nothing is written outside the docs repo"
    info "agents must open $DOCS_NAME/AGENTS.md explicitly"
  else
    info "profile $PROFILE: nothing versioned outside the docs repo; only the local pointer $LOCAL_POINTER"
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      valid_name "$repo" || { warn "invalid repo name in the contract: $repo"; continue; }
      [[ -d "$ROOT/$repo" ]] || { warn "declared in crux.json but not on disk: $repo"; continue; }
      rc=0
      write_local_pointer "$ROOT/$repo" "$DOCS_NAME" || rc=$?
      case $rc in
        0) ok "$repo/$LOCAL_POINTER points to $DOCS_NAME (excluded from git)" ;;
        2) warn "$repo is not a git repo: no local pointer, there would be no way to exclude it" ;;
        3) info "$repo versions its own $LOCAL_POINTER — respected, not touched" ;;
      esac
    done < <(json_get "$CONFIG" repos 2>/dev/null || true)
  fi
else
  created=0; updated=0; seen=0; without_markers=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    valid_name "$repo" || { warn "invalid repo name in the contract: $repo"; continue; }
    repo_dir="$ROOT/$repo"
    [[ -d "$repo_dir" ]] || { warn "declared in crux.json but not on disk: $repo"; continue; }
    seen=$((seen + 1))

    tagline="$(tagline_of "$repo")"

    for file in AGENTS.md CLAUDE.md; do
      # `|| rc=$?` and not a bare `$?`: render_managed returns meaningful
      # codes, and under set -e a non-zero return outside a conditional
      # aborts the script without a word.
      rc=0
      render_managed "$CRUX_HOME/templates/code-repo/$file" "$repo_dir/$file" \
        "REPO=$repo" "PROJECT=$PROJECT" "DOCS=$DOCS_NAME" "TAGLINE=$tagline" || rc=$?
      case $rc in
        0) ok "created $repo/$file"; created=$((created + 1)) ;;
        1) ok "updated the block of $repo/$file"; updated=$((updated + 1)) ;;
        3) without_markers+=("$repo/$file") ;;
        4) die "the kernel's $file template has no managed block" ;;
      esac
    done
  done < <(json_get "$CONFIG" repos 2>/dev/null || true)

  if [[ ${#without_markers[@]} -gt 0 ]]; then
    echo
    if [[ $REFRESH -eq 1 ]]; then
      for f in "${without_markers[@]}"; do
        repo="${f%%/*}"; file="${f##*/}"
        own="$(sed '1{/^# /d}' "$ROOT/$f")"
        render_to_stdout "$CRUX_HOME/templates/code-repo/$file" \
          "REPO=$repo" "PROJECT=$PROJECT" "DOCS=$DOCS_NAME" "TAGLINE=$(tagline_of "$repo")" > "$ROOT/$f.tmp"
        printf '\n---\n\n## Own context of %s\n\n%s\n' "$repo" "$own" >> "$ROOT/$f.tmp"
        mv "$ROOT/$f.tmp" "$ROOT/$f"
        ok "$f rewritten with the block, previous content kept below"
      done
    else
      warn "these pointers predate the managed block:"
      for f in "${without_markers[@]}"; do info "$f"; done
      info "'crux link --refresh' rewrites them keeping their content below"
    fi
  fi

  if [[ $seen -eq 0 ]]; then
    info "no code repo on disk yet"
  elif [[ $((created + updated)) -eq 0 && ${#without_markers[@]} -eq 0 ]]; then
    ok "pointers up to date ($(count "$seen" repo repos))"
  fi

fi

# --- Kernel catalog in the project index ------------------------------------
#
# The list of cross-cutting skills goes stale as soon as the kernel grows, and
# an index that lies is worse than none. If AGENTS.md marks the spot, it fills
# itself in.

if grep -q '<!-- crux:skills -->' "$DOCS_TREE/AGENTS.md" 2>/dev/null; then
  catalog="$(for d in "$CRUX_HOME"/skills/*/; do
    n="$(basename "$d")"
    line="$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description: /,""); print; exit}' "$d/SKILL.md" 2>/dev/null)"
    # An index is scanned, not read: the whole sentence makes it unreadable.
    cut="${line%%.*}"
    cut="${cut%%:*}"
    [[ ${#cut} -gt 78 ]] && cut="${cut:0:75}…"
    printf -- '- `%s` — %s\n' "$n" "$cut"
  done)"
  node -e '
    const fs = require("fs");
    const [file, catalog] = process.argv.slice(1);
    const src = fs.readFileSync(file, "utf8");
    const re = /<!-- crux:skills -->[\s\S]*?<!-- \/crux:skills -->/;
    fs.writeFileSync(file, src.replace(re, `<!-- crux:skills -->\n${catalog}\n<!-- /crux:skills -->`));
  ' "$DOCS_TREE/AGENTS.md" "$catalog"
  ok "kernel catalog updated in AGENTS.md ($(echo "$catalog" | wc -l) skills)"
fi

# --- Project's own skills ----------------------------------------------------

echo
crux_materialize_skills "$DOCS_TREE/.claude/skills" "$PROJECT"
crux_prune_skills
ok "project skills materialized"
