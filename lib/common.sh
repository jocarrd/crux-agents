#!/usr/bin/env bash
# Functions shared by the crux commands.
# Load it with: source "$CRUX_HOME/lib/common.sh"
#
# A library does NOT set shell options: whoever loads it already declared
# theirs, and overriding them breaks things in the worst way —the script dies
# silently on the first command that returns non-zero.

# --- Locating the kernel ------------------------------------------------------

crux_home() {
  if [[ -n "${CRUX_HOME:-}" ]]; then
    echo "$CRUX_HOME"
  elif [[ -f "$HOME/.crux/config" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.crux/config"
    echo "$CRUX_HOME"
  else
    echo "" # the caller decides whether this is an error
  fi
}

crux_version() {
  local home
  home="$(crux_home)"
  [[ -f "$home/VERSION" ]] && tr -d '[:space:]' < "$home/VERSION" || echo "unknown"
}

# --- Requirements -------------------------------------------------------------
#
# Node is used to read the contract. Without it, commands failed with a
# "command not found" halfway through their output, which says nothing about
# what is going on.

command -v node >/dev/null || {
  echo "crux needs node to read the project contract" >&2
  echo "install it and try again; 'crux doctor --machine' checks the rest" >&2
  exit 1
}

# --- Output -------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_OFF=""
fi

# count <n> <singular> <plural> — "1 commit", "2 commits".
count() { if [[ "$1" == 1 ]]; then echo "1 $2"; else echo "$1 $3"; fi; }

ok()   { echo "${C_GRN}ok${C_OFF}    $*"; }
warn() { echo "${C_YEL}warn${C_OFF}  $*"; }
err()  { echo "${C_RED}error${C_OFF} $*"; }
info() { echo "${C_DIM}      $*${C_OFF}"; }
die()  { err "$*"; exit 1; }

# --- Names and versions -------------------------------------------------------

valid_name() {
  # This does not legislate style —there are real repos in CamelCase— but what
  # does harm: a name with '/' or '..' gets concatenated into a path and ends
  # up writing outside the docs repo.
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *".."* ]]
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

preference() {
  # preference <key> [default] — from ~/.crux/config, which belongs to the user
  # and not to the project: each person closes their cycle as they like without
  # touching the contract.
  local key="$1" default_value="${2:-}" value=""
  [[ -f "$HOME/.crux/config" ]] &&
    value="$(grep -E "^$key=" "$HOME/.crux/config" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  echo "${value:-$default_value}"
}

main_branch() {
  # main_branch <dir> — the one declared in the contract, the remote's, or the
  # one the repo is using. In that order.
  local dir="$1" docs declared
  docs="$(find_docs_repo "$dir" 2>/dev/null || echo "")"
  if [[ -n "$docs" && -f "$docs/crux.json" ]]; then
    declared="$(json_get "$docs/crux.json" branch 2>/dev/null || echo "")"
    [[ -n "$declared" ]] && { echo "$declared"; return 0; }
  fi
  declared="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  if [[ -z "$declared" ]]; then
    # The current branch only as a last resort: from a worktree it is the work
    # branch, and taking it as the main one leaves the hook blocking exactly that.
    for c in main master; do
      git -C "$dir" show-ref --verify --quiet "refs/heads/$c" && { declared="$c"; break; }
    done
  fi
  [[ -n "$declared" ]] || declared="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$declared" && "$declared" != "HEAD" ]] || declared=main
  echo "$declared"
}

is_worktree() {
  # In a worktree, .git is a file and the common directory lives in the main
  # repo.
  local common
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" != ".git" && "$common" != "$1/.git" ]]
}

main_repo() {
  dirname "$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)"
}

version_greater_than() {
  # version_greater_than <a> <b>. Compared as text, 0.9.0 comes out greater than
  # 0.10.0. What is not semver is not compared: 'sort -V' would put "?" above
  # everything.
  is_semver "$1" && is_semver "$2" || return 1
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# --- Reading crux.json --------------------------------------------------------
#
# node is used (present on any machine where these repos are worked on)
# instead of jq, which is not always installed.

valid_json() {
  # valid_json <file> — 0 if it parses; otherwise, prints the parser's reason.
  node -e '
    const fs = require("fs");
    try { JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stdout.write(e.message); process.exit(1); }
  ' "$1"
}

json_get() {
  # json_get <file> <js expression over the root object>
  local file="$1" expr="$2"
  node -e '
    const fs = require("fs");
    let o;
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stderr.write("invalid json: " + e.message + "\n"); process.exit(1); }
    const v = (function (root) { return eval(process.argv[2]); })(o);
    if (v === undefined || v === null) process.exit(2);
    // Trailing newline: without it, `while read` drops the last element.
    process.stdout.write((Array.isArray(v) ? v.join("\n") : String(v)) + "\n");
  ' "$file" "root.$expr"
}

json_has() {
  json_get "$1" "$2" >/dev/null 2>&1
}

# --- Quality gate receipt -----------------------------------------------------

receipt_commands() {
  # receipt_commands <file> — how many commands were run.
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk '$1 == "run" { n++ } END { print n + 0 }' "$1"
}

receipt_kernel() {
  # receipt_kernel <file> — the crux version it was sealed with, or nothing.
  [[ -f "$1" ]] || return 0
  awk '$1 == "kernel" { v = $2 } END { if (v != "") print v }' "$1"
}

pinned_version() {
  # pinned_version <path> — the crux version the project contract pins.
  local docs
  docs="$(find_docs_repo "$1" 2>/dev/null)" || return 0
  [[ -f "$docs/crux.json" ]] || return 0
  json_get "$docs/crux.json" 'crux' 2>/dev/null || true
}

receipt_failures() {
  # receipt_failures <file> — how many exited with something other than zero.
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk '$1 == "run" && $2 != 0 { n++ } END { print n + 0 }' "$1"
}

receipt_failed() {
  # receipt_failed <file> — the label of the ones that failed, with their code.
  [[ -f "$1" ]] || return 0
  awk '$1 == "run" && $2 != 0 {
    code = $2; $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, "")
    printf "%s (exit %s)\n", $0, code
  }' "$1"
}

# --- Profiles -----------------------------------------------------------------
#
# Three layers, from the general to the specific: the one the kernel ships, the
# user's —which survives upgrades and travels with the machine— and the
# project's. They overlap field by field, so a project can change one field
# without copying the rest, and an own profile does not require touching the
# kernel repo.

profile_layers() {
  # profile_layers <name> [docs] — the paths that exist, from least to most specific.
  local name="$1" docs="${2:-}"
  local c
  for c in "$CRUX_HOME/profiles/$name.json" "$HOME/.crux/profiles/$name.json"; do
    [[ -f "$c" ]] && echo "$c"
  done
  [[ -n "$docs" && -f "$docs/profile.json" ]] && echo "$docs/profile.json"
  return 0
}

profile_exists() {
  # profile_exists <name> [docs]
  [[ -n "$(profile_layers "$1" "${2:-}")" ]]
}

profile_json() {
  # profile_json <name> [docs] — the profile with its layers already merged.
  local layers; layers="$(profile_layers "$1" "${2:-}")"
  [[ -n "$layers" ]] || { echo '{}'; return 0; }
  printf '%s\n' "$layers" | node -e '
    const fs = require("fs");
    let raw = "";
    process.stdin.on("data", (d) => (raw += d)).on("end", () => {
      const merge = (a, b) => {
        for (const [k, v] of Object.entries(b)) {
          a[k] = (v && typeof v === "object" && !Array.isArray(v)
                  && a[k] && typeof a[k] === "object" && !Array.isArray(a[k]))
            ? merge({ ...a[k] }, v) : v;
        }
        return a;
      };
      let o = {};
      for (const f of raw.split("\n").filter(Boolean)) {
        o = merge(o, JSON.parse(fs.readFileSync(f, "utf8")));
      }
      process.stdout.write(JSON.stringify(o));
    });
  '
}

profile_get() {
  # profile_get <name> <docs> <key> [default]
  local name="$1" docs="$2" key="$3" default_value="${4:-}" value
  value="$(profile_json "$name" "$docs" | node -e '
    const key = process.argv[1];
    let raw = "";
    process.stdin.on("data", (d) => (raw += d)).on("end", () => {
      const v = key.split(".").reduce((x, k) => (x == null ? x : x[k]), JSON.parse(raw));
      if (v === undefined || v === null) process.exit(2);
      process.stdout.write(Array.isArray(v) ? v.join("\n") : String(v));
    });
  ' "$key")" || { [[ -n "$default_value" ]] && echo "$default_value"; return 0; }
  echo "$value"
}

commit_language() {
  # commit_language <profile> <docs> — the language commits and proposals are
  # written in. What the project declares in crux.json wins, then the profile,
  # and if nobody says anything, English.
  local profile="$1" docs="$2" own=""
  [[ -n "$docs" && -f "$docs/crux.json" ]] &&
    own="$(json_get "$docs/crux.json" 'commit && root.commit.language' 2>/dev/null || true)"
  if [[ -n "$own" && "$own" != "false" && "$own" != "undefined" ]]; then
    echo "$own"
  else
    profile_get "$profile" "$docs" commit.language en 2>/dev/null || echo en
  fi
}

profile_forbid() {
  # profile_forbid <name> [docs] — one pattern per line, with its reason after
  # a tab. Profiles written before the keys were renamed use "patron" and
  # "motivo": both spellings are read.
  profile_json "$1" "${2:-}" | node -e '
    let raw = "";
    process.stdin.on("data", (d) => (raw += d)).on("end", () => {
      const list = (JSON.parse(raw).propose || {}).forbid || [];
      for (const e of list) {
        const pattern = typeof e === "string" ? e : e.pattern || e.patron;
        if (!pattern) continue;
        const reason = (typeof e === "object" && (e.reason || e.motivo)) || "the profile does not allow this in a proposal";
        process.stdout.write(`${pattern}\t${reason}\n`);
      }
    });
  '
}

# --- Projects root ------------------------------------------------------------
#
# No specific folder is assumed: the most reliable hint is that the kernel
# itself lives inside the root, so its parent identifies it without any
# configuration. Without this, on a machine with another convention the
# commands that walk every project do not fail: they report zero, which is
# worse because it looks like data.

projects_root() {
  if [[ -n "${CRUX_PROJECTS_DIR:-}" ]]; then
    echo "$CRUX_PROJECTS_DIR"; return
  fi
  if [[ -f "$HOME/.crux/config" ]]; then
    local declared_value
    declared_value="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"' || true)"
    [[ -n "$declared_value" ]] && { echo "$declared_value"; return; }
  fi
  local home
  home="$(crux_home)"
  [[ -n "$home" && -d "$(dirname "$home")" ]] && { dirname "$home"; return; }
  echo "$HOME/Proyectos"
}

# --- The person's profile ----------------------------------------------------
#
# A project's knowledge lives in its docs repo; the person's (how they want to
# work, who they are, what only holds on one machine) lives in a repo of its
# own next to the projects. It is markdown that does not belong to any agent:
# each adapter loads it in its own place. See ADR-018.

profile_repo_name() {
  preference CRUX_PROFILE_REPO agent-profile
}

profile_dir() {
  # profile_dir — prints the profile's directory; fails if there is none here.
  local dir
  dir="$(projects_root)/$(profile_repo_name)"
  [[ -f "$dir/PROFILE.md" ]] || return 1
  echo "$dir"
}

profile_field() {
  # profile_field <dir> <key> — a value of PROFILE.md's frontmatter.
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ":") == 1 {
      sub("^" key ":[ \t]*", "")
      if ($0 ~ /^".*"$/) { $0 = substr($0, 2, length($0) - 2); gsub(/\\"/, "\"") }
      print; exit
    }
  ' "$1/PROFILE.md"
}

profile_machine_note() {
  # profile_machine_note <dir> — this machine's note, if the profile has one.
  local note
  note="$1/machines/$(hostname 2>/dev/null || uname -n).md"
  [[ -f "$note" ]] && echo "$note"
  return 0
}

write_marked_block() {
  # write_marked_block <file> <begin> <end> <block> — puts the block at the top
  # of the file, replacing the one between the markers if it was already there,
  # and leaves the rest of the file as the person wrote it. An empty block
  # removes it. At the top because what is read first is what weighs most.
  node -e '
    const fs = require("fs");
    const [file, begin, end, block] = process.argv.slice(1);
    const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const src = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
    const re = new RegExp(esc(begin) + "[\\s\\S]*?" + esc(end) + "\\n*");
    const rest = src.replace(re, "").replace(/^\n+/, "");
    const out = block ? block + "\n" + (rest ? "\n" + rest : "") : rest;
    if (out !== src) fs.writeFileSync(file, out);
  ' "$1" "$2" "$3" "$4"
}

# --- Locating the docs repo ---------------------------------------------------

find_docs_repo() {
  # Walks up from the given directory until it finds a crux.json.
  # If it does not find one, it tries the parent's sibling <project>-docs.
  local dir="${1:-$PWD}"
  # Without this the path ended up empty, and dirname "" returns "." forever:
  # the loop below never ended.
  [[ -d "$dir" ]] || return 1
  dir="$(cd "$dir" && pwd)"

  # The sibling <project>-docs wins over a crux.json that shows up inside the
  # code repo itself. Otherwise, whoever sends a proposal with a crux.json at
  # the root decides the contract: the main branch the hook guards, the quality
  # gate commands and the setup that runs when a workspace opens. The contract
  # belongs to the team, not to whatever branch you have checked out.
  local sibling_parent sibling_project sibling
  sibling_parent="$(dirname "$dir")"
  sibling_project="$(basename "$sibling_parent")"
  sibling="$sibling_parent/${sibling_project}-docs"
  [[ -f "$sibling/crux.json" ]] && { echo "$sibling"; return 0; }

  local probe="$dir"
  while [[ "$probe" != "/" ]]; do
    if [[ -f "$probe/crux.json" ]]; then
      # A crux.json at the root of a code repo is not the project contract: it
      # only counts if that repo is the documentation one.
      local base_probe; base_probe="$(basename "$probe")"
      if [[ -d "$probe/.git" && "$base_probe" != *-docs && "$base_probe" != docs ]]; then
        probe="$(dirname "$probe")"
        continue
      fi
      echo "$probe"; return 0
    fi
    probe="$(dirname "$probe")"
  done

  # Fallback: layout convention — sibling <project>-docs
  local parent project candidate
  parent="$(dirname "$dir")"
  project="$(basename "$parent")"
  candidate="$parent/${project}-docs"
  [[ -d "$candidate" ]] && { echo "$candidate"; return 0; }

  [[ "$(basename "$dir")" == *-docs ]] && { echo "$dir"; return 0; }

  return 1
}

# --- Templates ----------------------------------------------------------------

render_managed() {
  # render_managed <source> <target> <VAR=value>...
  #
  # Writes the template respecting what the repo has added: if the target
  # already has the marked block, only that block is replaced. Without this,
  # improving the pointer would mean overwriting each repo's own context, and
  # nobody would ever update.
  #
  # Returns: 0 created, 1 block updated, 2 unchanged, 3 exists without markers,
  # 4 the template has no managed block.
  #
  # 4 cannot collapse into 1: a malformed template used to be reported as
  # written without having touched the target.
  local src="$1" dst="$2"; shift 2
  local new_value
  new_value="$(render_to_stdout "$src" "$@")"

  if [[ ! -e "$dst" ]]; then
    mkdir -p "$(dirname "$dst")"
    printf '%s\n' "$new_value" > "$dst"
    return 0
  fi

  grep -qF 'crux:begin' "$dst" || return 3

  node -e '
    const fs = require("fs");
    const [dst, incoming] = process.argv.slice(1);
    const re = /<!-- crux:begin[\s\S]*?crux:end -->/;
    const block = incoming.match(re);
    if (!block) process.exit(4);
    const current = fs.readFileSync(dst, "utf8");
    // Whitespace-insensitive comparison: many repos run a formatter that aligns
    // markdown tables. Without this, the formatter and `crux link` rewrite the
    // block back and forth on every pass, forever.
    // Formatters align columns with spaces and stretch the dashes of the
    // separator line: both have to be neutralised.
    const norm = (t) => t
      .replace(/-{2,}/g, "--")
      .replace(/[ \t]+/g, " ")
      .replace(/ *\n/g, "\n");
    const previous = current.match(re)?.[0];
    if (previous && norm(previous) === norm(block[0])) process.exit(2);
    fs.writeFileSync(dst, current.replace(re, block[0]));
  ' "$dst" "$new_value"
  local code=$?
  [[ $code -eq 2 ]] && return 2
  [[ $code -eq 4 ]] && return 4
  return 1
}

# The client-repo profile does not allow writing anything versioned in someone
# else's repo, but without a file the agent loads on its own, the docs repo is
# never discovered. CLAUDE.local.md loads just like CLAUDE.md and goes into the
# exclude of git's common directory: it neither shows up in `git status` nor can
# it be committed by mistake.
LOCAL_POINTER="CLAUDE.local.md"

write_local_pointer() {
  # write_local_pointer <repo_dir> <docs_repo_name>
  # 0 written · 2 not a git repo · 3 the client versions its own file
  local dir="$1" docs_name="$2" common
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 2
  if git -C "$dir" ls-files --error-unmatch "$LOCAL_POINTER" >/dev/null 2>&1; then
    return 3
  fi
  mkdir -p "$common/info"
  grep -qxF "$LOCAL_POINTER" "$common/info/exclude" 2>/dev/null ||
    echo "$LOCAL_POINTER" >> "$common/info/exclude"
  # render_to_stdout trims the trailing newline, and without it the client
  # repo's `prettier --check`, which does not read info/exclude, flags the file
  # as badly formatted.
  {
    render_to_stdout "$CRUX_HOME/templates/code-repo/$LOCAL_POINTER" "DOCS=$docs_name"
    echo
  } > "$dir/$LOCAL_POINTER"
}

render_to_stdout() {
  local src="$1"; shift
  local content pair key value
  content="$(cat "$src")"
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    content="${content//\{\{$key\}\}/$value}"
  done
  printf '%s' "$content"
}

render_template() {
  # render_template <source> <target> <VAR=value>...
  local src="$1" dst="$2"; shift 2
  local content
  content="$(cat "$src")"
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    content="${content//\{\{$key\}\}/$value}"
  done
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" > "$dst"
}

# --- Project remote -----------------------------------------------------------
#
# The kernel knows nothing about providers. Each project declares how the URL
# of its repos is built, and with that it works the same for GitHub, GitLab
# —including self-hosted with a port—, Bitbucket or Azure DevOps.
#
#   "remote": { "url": "git@github.com:jocarrd/{repo}.git" }
#
# Equivalent shortcut, for convenience:
#
#   "remote": { "host": "gitlab.company.com", "owner": "team/sub", "protocol": "ssh" }

remote_url() {
  # remote_url <crux.json> <repo>
  #
  # The per-repo override exists because a project can keep its documentation
  # on your remote and its code on someone else's: that is the case of a client
  # repo, and without this cloning looks where it is not.
  local cfg="$1" repo="$2"
  node -e '
    const fs = require("fs");
    const [file, repo] = process.argv.slice(1);
    let r = {};
    try { r = (JSON.parse(fs.readFileSync(file, "utf8")).remote) || {}; } catch {}

    const own = (r.repos || {})[repo];
    if (own) { process.stdout.write(own.replace(/\{repo\}/g, repo)); process.exit(0); }

    let tmpl = r.url;
    if (!tmpl && r.host && r.owner) {
      tmpl = (r.protocol === "https")
        ? `https://${r.host}/${r.owner}/{repo}.git`
        : `git@${r.host}:${r.owner}/{repo}.git`;
    }
    if (!tmpl) process.exit(2);
    process.stdout.write(tmpl.replace(/\{repo\}/g, repo));
  ' "$cfg" "$repo"
}

remote_from_git() {
  # Infers the template from the origin of an already cloned repo. This is what
  # lets adopt work without asking for the remote.
  local dir="$1" name url
  name="$(basename "$dir")"
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$url" ]] || return 1
  # Only the last occurrence: if the owner has the same name as the repo,
  # replacing all of them produces a broken template.
  node -e '
    const [url, name] = process.argv.slice(1);
    const i = url.lastIndexOf(name);
    if (i === -1) { process.stdout.write(url); process.exit(0); }
    process.stdout.write(url.slice(0, i) + "{repo}" + url.slice(i + name.length));
  ' "$url" "$name"
}

normalize_git_url() {
  # normalize_git_url <url> — canonical «host/owner/repo» form for comparing.
  # git@host:owner/repo.git and https://host/owner/repo.git give the same, so
  # declaring ssh and cloning with gh (which leaves https) does not trigger a
  # false alarm in doctor. Compared in lowercase: the owner is case-insensitive.
  local u="${1%.git}"
  u="${u#ssh://}"; u="${u#git@}"; u="${u#https://}"; u="${u#http://}"
  u="${u/:/\/}"
  # tr and not ${u,,}: that expansion is bash 4 and macOS ships 3.2 by default.
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

owner_from_template() {
  # owner_from_template <template> — the owner of git@host:OWNER/{repo}.git or
  # https://host/OWNER/{repo}.git. Empty if it does not match the GitHub
  # pattern, which is the only provider the kernel creates the remote repo for.
  local tmpl="$1"
  [[ "$tmpl" =~ github\.com[:/]([^/]+)/ ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# --- Projects on the remote ---------------------------------------------------
#
# Used by `bootstrap`, which brings all of them, and `sync`, which brings the
# missing ones. The list comes from the remote and not from an inventory: one
# written by hand goes stale as soon as you create a project from the other
# machine.

default_owner() {
  # Comes from the same place as the clone URLs, so there are not two sources
  # of truth that can disagree.
  local remote="" cfg="${CRUX_CONFIG:-$HOME/.crux/config}"
  [[ -f "$cfg" ]] && remote="$(grep -E '^CRUX_REMOTE=' "$cfg" | cut -d= -f2- | tr -d '"')"
  local owner
  owner="$(owner_from_template "$remote")"
  [[ -n "$owner" ]] && { echo "$owner"; return; }
  gh api user --jq .login 2>/dev/null || true
}

candidate_projects() {
  # candidate_projects <owner> — the owner's <something>-docs repos, without the suffix.
  gh repo list "$1" --limit 300 --json name --jq '.[].name' 2>/dev/null \
    | grep -E -- '-docs$' | sed -E 's/-docs$//' | sort -u
}

has_contract() {
  # has_contract <owner> <project> — without crux.json, any repo ending in -docs
  # would count as a project.
  gh api "repos/$1/$2-docs/contents/crux.json" --silent >/dev/null 2>&1
}

projects_with_contract() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && has_contract "$1" "$p" && echo "$p"
  done < <(candidate_projects "$1")
}

# --- Task records -------------------------------------------------------------
#
# Next to the workspace registry: if a test redirects that registry to its
# sandbox, the tasks follow without having to remember another variable.

# A task's decisions (the notes with a why) live in its record, which is local
# and gets archived. Before archiving they move to repos/<repo>/notes.md in the
# docs repo, which is what the next session reads, and are committed there on
# their own. Returns 0 even when there is nothing to move: archiving does not
# depend on this.
promote_decisions() {
  local record="$1" project docs data repo target entry
  [[ -f "$record" ]] || return 0
  project="$(awk -F': ' '/^project:/{print $2; exit}' "$record")"
  [[ -n "$project" ]] || return 0
  docs="$(projects_root)/$project/$project-docs"
  [[ -f "$docs/crux.json" ]] || return 0
  data="$(node "$CRUX_HOME/lib/task.mjs" decisions --file "$record" 2>/dev/null)" || return 0
  entry="$(node -e '
    const d = JSON.parse(process.argv[1]);
    if (!d.items.length) process.exit(0);
    const day = new Date().toISOString().slice(0, 10);
    const out = [];
    for (const i of d.items) {
      out.push(`## ${i.what}, ${day}`, "", `Task: \`${d.task}\``, "");
      for (const k of ["why", "where", "learned"]) {
        if (i[k]) out.push(`- **${k[0].toUpperCase() + k.slice(1)}**: ${i[k]}`);
      }
      out.push("");
    }
    process.stdout.write(out.join("\n"));
  ' "$data")"
  [[ -n "$entry" ]] || return 0

  while IFS= read -r repo; do
    [[ -n "$repo" && -d "$docs/repos/$repo" ]] && { target="$docs/repos/$repo/notes.md"; break; }
  done < <(node -e 'for (const r of JSON.parse(process.argv[1]).repos) console.log(r)' "$data")
  if [[ -z "${target:-}" ]]; then
    warn "the task has decisions, but its repo has no folder in $(basename "$docs")/repos/"
    info "move them by hand from: $record"
    return 0
  fi

  [[ -f "$target" ]] && [[ -s "$target" ]] && printf '\n' >> "$target"
  printf '%s\n' "$entry" >> "$target"
  local rel="${target#"$docs"/}"
  if git -C "$docs" add -- "$rel" >/dev/null 2>&1 &&
     git -C "$docs" commit -q -m "docs($repo): decisions from task $(basename "$record" .md)" -- "$rel" >/dev/null 2>&1; then
    ok "task decisions in $(basename "$docs")/$rel (committed; push them with git push)"
  else
    warn "decisions written to $(basename "$docs")/$rel, but the commit could not be made"
    info "review it and commit it by hand"
  fi
  return 0
}

task_dir() {
  if [[ -n "${CRUX_TASKS_DIR:-}" ]]; then echo "$CRUX_TASKS_DIR"; return; fi
  echo "$(dirname "${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}")/tasks"
}

project_name_for() {
  # project_name_for <path of a repo or a workspace>
  #
  # The project comes from the layout: <root>/<project>/<repo>. A repo that
  # hangs directly from the root —the kernel itself— is its own project.
  local path_value="$1" root rel
  root="$(projects_root)"
  case "$path_value/" in
    "$root"/*/*/*)
      rel="${path_value#"$root"/}"; echo "${rel%%/*}" ;;
    "$root"/*/)
      rel="${path_value#"$root"/}"; rel="${rel%%/*}"; echo "${rel%%-ws-*}" ;;
    *)
      basename "$path_value" | sed 's/-ws-.*$//' ;;
  esac
}

task_file_for_path() {
  # task_file_for_path <registry> <toplevel> — the task record of the workspace
  # that lives at that path. Exits with 1 if the path is not a workspace.
  local task_record="$1" path_value="$2" data
  [[ -f "$task_record" ]] || return 1
  data="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const e = Object.entries(r.workspaces || {}).find(([, w]) => w.path === process.argv[2]);
    if (!e || !e[1].task || !e[1].project) process.exit(1);
    process.stdout.write(`${e[1].project}/${e[1].task}`);
  ' "$task_record" "$path_value" 2>/dev/null)" || return 1
  echo "$(task_dir)/$data.md"
}
