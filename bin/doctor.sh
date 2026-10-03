#!/usr/bin/env bash
# crux doctor — checks that a docs repo meets the standard.
#
# A standard is worth little if it is only trusted to be followed. This checks
# it. Exits with code 1 on errors; warnings do not block.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

# Temp files go to a directory of their own with an unpredictable name and
# honouring TMPDIR, instead of /tmp/crux-doctor-*.$$ with the path hardcoded.
DOCTOR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/crux-doctor.XXXXXX")"
trap 'rm -rf "$DOCTOR_TMP"' EXIT

ERRORS=0
WARNS=0
SECTION_MARK=0
SECTION_WARNS=0
fail() { err "$*"; ERRORS=$((ERRORS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }

# An 'ok' is only printed if the section produced no errors: saying "ok" and
# "error" about the same check is worse than saying nothing.
section() { SECTION_MARK=$ERRORS; SECTION_WARNS=$WARNS; }
section_ok() { [[ $ERRORS -eq $SECTION_MARK ]] && ok "$*"; return 0; }

summary() {
  echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errors), $WARNS $([[ $WARNS -eq 1 ]] && echo warning || echo warnings)"
}

if [[ "${1:-}" == "--machine" ]]; then
  exec bash "$CRUX_HOME/bin/machine.sh" "${@:2}"
fi

DOCS="$(find_docs_repo "${1:-$PWD}")" || die "no docs repo found from ${1:-$PWD}"
CONFIG="$DOCS/crux.json"

echo "checking $(basename "$DOCS")"
echo

# --- 1. The contract ---------------------------------------------------------

if [[ ! -f "$CONFIG" ]]; then
  fail "crux.json is missing — the project is not adopted ('crux adopt')"
  echo; summary; exit 1
fi

section
# Without stopping here, everything below reads empty fields and reports them
# as absences: false errors about what is actually there.
if ! reason="$(valid_json "$CONFIG")"; then
  fail "crux.json is not valid JSON: $reason"
  echo; summary; exit 1
fi

for field in crux project profile; do
  json_has "$CONFIG" "$field" || fail "crux.json missing required field: $field"
done

PROJECT="$(json_get "$CONFIG" project 2>/dev/null || echo "?")"
PROFILE="$(json_get "$CONFIG" profile 2>/dev/null || echo "?")"
DECLARED="$(json_get "$CONFIG" crux 2>/dev/null || echo "?")"
DECLARED_LANG="$(json_get "$CONFIG" language 2>/dev/null || echo "es")"
KERNEL="$(crux_version)"

profile_exists "$PROFILE" "$DOCS" || fail "unknown profile: $PROFILE"
# Rigor decides how much review is paid for and who merges. A typo in the
# value cannot fall back to a default level without anyone noticing.
if json_has "$CONFIG" rigor; then
  RIGOR="$(json_get "$CONFIG" rigor 2>/dev/null || echo "")"
  case "$RIGOR" in
    light|normal|strict) ;;
    *) fail "unknown rigor: '$RIGOR' — valid values are light, normal or strict" ;;
  esac
fi
# Only the series: a patch brings no templates or checks, so warning about it
# sends people to an upgrade that changes nothing.
if [[ "${DECLARED%.*}" != "${KERNEL%.*}" ]]; then
  if version_greater_than "$DECLARED" "$KERNEL"; then
    note "the project is ahead of the kernel ($DECLARED > $KERNEL): update crux, not the project"
  else
    note "materialized with crux $DECLARED, the kernel is $KERNEL ('crux upgrade')"
  fi
fi
[[ "$(basename "$DOCS")" == "$PROJECT-docs" ]] || note "the docs repo should be named $PROJECT-docs"
section_ok "contract: $PROJECT · profile $PROFILE · crux $DECLARED"

# --- 2. Required structure ---------------------------------------------------

section
for f in README.md AGENTS.md decisions/README.md decisions/index.md repos/README.md; do
  [[ -f "$DOCS/$f" ]] || fail "missing $f"
done

if [[ -L "$DOCS/CLAUDE.md" ]]; then
  [[ "$(readlink "$DOCS/CLAUDE.md")" == "AGENTS.md" ]] || fail "CLAUDE.md should link to AGENTS.md"
elif [[ -f "$DOCS/CLAUDE.md" ]]; then
  note "CLAUDE.md is a file, not a symlink to AGENTS.md (two sources that diverge)"
else
  fail "missing CLAUDE.md"
fi
section_ok "required structure"

# --- 3. Declared repos vs reality --------------------------------------------

section
ROOT="$(dirname "$DOCS")"
origin_docs_early="$(git -C "$DOCS" remote get-url origin 2>/dev/null || true)"
declared=()
while IFS= read -r r; do [[ -n "$r" ]] && declared+=("$r"); done < <(json_get "$CONFIG" repos 2>/dev/null || true)

for repo in ${declared[@]+"${declared[@]}"}; do
  [[ -d "$DOCS/repos/$repo" ]] || fail "declared repo without a doc folder: repos/$repo/"
  [[ -f "$DOCS/repos/$repo/README.md" ]] || note "repos/$repo/ has no README.md"
  [[ -d "$ROOT/$repo" ]] || note "declared repo not on disk: $repo"
done

if [[ -d "$DOCS/repos" ]]; then
  for dir in "$DOCS"/repos/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    found=0
    for repo in ${declared[@]+"${declared[@]}"}; do [[ "$repo" == "$name" ]] && found=1; done
    [[ $found -eq 1 ]] || note "repos/$name/ is not declared in crux.json"
  done
fi

# The repo that is on disk and nobody declared: a new one is cloned into the
# project and the registry is forgotten. The checks above go the other way
# —from what is declared to what exists— so this case passed as conformant.
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  [[ "$name" == "$(basename "$DOCS")" ]] && continue
  # Only the root of a repo: inside a repo, any subdirectory would answer
  # yes.
  toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$toplevel" && "$(cd "$dir" && pwd -P)" == "$(cd "$toplevel" && pwd -P)" ]] || continue
  # Workspaces are sibling worktrees: they are not repos to declare.
  is_worktree "$dir" && continue
  found=0
  for repo in ${declared[@]+"${declared[@]}"}; do [[ "$repo" == "$name" ]] && found=1; done
  [[ $found -eq 1 ]] || note "$name/ is on disk and not declared ('crux add-repo $name')"
done
# The repo that exists on the remote and nobody cloned here: the loop above
# walks the disk, so a project repo that only lives on GitHub is invisible on
# this machine, and can spend half a year outside the contract without anyone
# noticing.
if [[ "$origin_docs_early" == *github.com* ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  owner="$(echo "$origin_docs_early" | sed -E 's#^.*github\.com[:/]##; s#/.*$##')"
  while IFS= read -r remote; do
    [[ -n "$remote" ]] || continue
    [[ "$remote" == "$(basename "$DOCS")" ]] && continue
    # Only those carrying the project name: the rest of the account is none of its business.
    shopt -s nocasematch
    if [[ "$remote" == "$PROJECT" || "$remote" == "$PROJECT-"* ]]; then
      found=0
      for repo in ${declared[@]+"${declared[@]}"}; do
        [[ "$repo" == "$remote" ]] && found=1   # nocasematch, above
      done
      [[ $found -eq 1 ]] || note "$remote is on the remote and not declared ('crux add-repo $remote')"
    fi
    shopt -u nocasematch
  done < <(gh repo list "$owner" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)
fi

section_ok "repos: ${#declared[@]} declared"

# --- 4. Profile rules --------------------------------------------------------

section
WRITES_POINTERS="$(profile_get "$PROFILE" "$DOCS" pointers.write true)"

if [[ "$WRITES_POINTERS" == "true" ]]; then
  for repo in ${declared[@]+"${declared[@]}"}; do
    [[ -d "$ROOT/$repo" ]] || continue
    for file in AGENTS.md CLAUDE.md; do
      if [[ ! -f "$ROOT/$repo/$file" ]]; then
        note "$repo/ has no $file ('crux link')"
      elif ! grep -qF 'crux:begin' "$ROOT/$repo/$file"; then
        note "$repo/$file predates the managed block ('crux link --refresh')"
      fi
    done
  done
else
  # The profile forbids writing outside the docs repo: check nobody did.
  #
  # A client's own AGENTS.md is not an intrusion: it is theirs, and deleting it
  # would be exactly what the profile prevents. The intrusion is the file we
  # put there, recognised by the managed block or by not being versioned in
  # its repo.
  for repo in ${declared[@]+"${declared[@]}"}; do
    [[ -d "$ROOT/$repo" ]] || continue
    for intruder in AGENTS.md CLAUDE.md; do
      file="$ROOT/$repo/$intruder"
      [[ -e "$file" ]] || continue
      if grep -qF 'crux:begin' "$file" 2>/dev/null ||
         ! git -C "$ROOT/$repo" ls-files --error-unmatch "$intruder" >/dev/null 2>&1; then
        fail "profile $PROFILE: $repo/$intruder should not exist (someone else's code)"
      else
        note "$repo/$intruder belongs to the client — respected, not touched"
      fi
    done
  done

  # Without the local pointer the agent loads nothing of ours when working in
  # the client's repo, and finding the docs repo is left to its memory.
  if [[ "$(profile_get "$PROFILE" "$DOCS" pointers.local false)" == "true" ]]; then
    for repo in ${declared[@]+"${declared[@]}"}; do
      [[ -d "$ROOT/$repo" ]] || continue
      git -C "$ROOT/$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
      if git -C "$ROOT/$repo" ls-files --error-unmatch "$LOCAL_POINTER" >/dev/null 2>&1; then
        note "$repo/$LOCAL_POINTER belongs to the client — respected, not touched"
      elif [[ ! -f "$ROOT/$repo/$LOCAL_POINTER" ]]; then
        fail "$repo/ has no $LOCAL_POINTER: the agent will not discover $(basename "$DOCS") ('crux link')"
      elif ! git -C "$ROOT/$repo" check-ignore -q "$LOCAL_POINTER"; then
        fail "$repo/$LOCAL_POINTER is not excluded from git and could be committed ('crux link')"
      fi
    done
  fi
fi
# The block used to be marked `perfil`; both markers count.
if [[ -n "$(profile_get "$PROFILE" "$DOCS" rules "")" ]] &&
   ! grep -qE 'crux:begin (perfil|profile)' "$DOCS/AGENTS.md" 2>/dev/null; then
  note "the profile rules are not in AGENTS.md ('crux link')"
fi
section_ok "profile $PROFILE rules"

# --- 5. Declared remote vs the real one --------------------------------------
#
# Silent drift: everything works on this machine and the clone fails on the
# next, which is when you least want to debug it.

section
if ! git -C "$DOCS" rev-parse --git-dir >/dev/null 2>&1; then
  fail "the docs repo is not in git: the documentation does not survive a change of machine"
elif json_has "$CONFIG" 'remote'; then
  for repo in ${declared[@]+"${declared[@]}"}; do
    [[ -d "$ROOT/$repo/.git" ]] || continue
    real="$(git -C "$ROOT/$repo" remote get-url origin 2>/dev/null || true)"
    [[ -n "$real" ]] || continue
    declared_value="$(remote_url "$CONFIG" "$repo" 2>/dev/null || true)"
    if [[ -z "$declared_value" ]]; then
      note "$repo: no remote in the contract — 'crux clone' will not know where to fetch it from"
    elif [[ "$(normalize_git_url "$declared_value")" != "$(normalize_git_url "$real")" ]]; then
      note "$repo: the contract says $declared_value and origin is $real"
    fi
  done
  [[ $WARNS -eq $SECTION_WARNS ]] && section_ok "remote consistent with the contract"
else
  note "no 'remote' in crux.json — 'crux clone' will not be able to fetch this project"
fi

# --- 6. Docs repo visibility -------------------------------------------------
#
# A public docs repo with internal documentation in it is an incident, not a
# configuration slip. It can only be checked where there is an API to ask;
# where there is not, it says it was not checked instead of staying quiet.

section
EXPECTED_VIS="$(json_get "$CONFIG" 'remote.visibility' 2>/dev/null || echo "private")"
origin_docs="$(git -C "$DOCS" remote get-url origin 2>/dev/null || true)"

if [[ "$origin_docs" == *github.com* ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  slug="$(echo "$origin_docs" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
  vis_actual="$(gh repo view "$slug" --json visibility -q .visibility 2>/dev/null | tr 'A-Z' 'a-z' || echo "")"
  if [[ -z "$vis_actual" ]]; then
    note "could not query the visibility of $slug"
  elif [[ "$vis_actual" == "public" && "$EXPECTED_VIS" != "public" ]]; then
    fail "the docs repo is PUBLIC and the contract expects $EXPECTED_VIS"
    [[ "$PROFILE" == "client-repo" ]] && err "and it contains a client's documentation"
  elif [[ "$vis_actual" != "$EXPECTED_VIS" ]]; then
    note "actual visibility '$vis_actual', the contract says '$EXPECTED_VIS'"
  fi
  section_ok "visibility: $vis_actual"
else
  info "visibility not checked (needs gh and a GitHub remote)"
fi

# --- 7. Declared sections ----------------------------------------------------

while IFS= read -r sect; do
  [[ -n "$sect" ]] || continue
  [[ -d "$DOCS/$sect" ]] || note "declared section without a folder: $sect/"
done < <(json_get "$CONFIG" sections 2>/dev/null || true)

# --- 8. ADR numbering --------------------------------------------------------
#
# Two parallel sessions pick the same "next number" and git does not detect
# the conflict: they are different lines of the same file.

section
# Status is what makes the registry navigable: a "Superseded" that does not
# say by what cuts the chain right where someone was following it.
decisions_out="$DOCTOR_TMP/decisions"
node "$CRUX_HOME/lib/check-decisions.mjs" "$DOCS" >"$decisions_out" 2>&1
decisions_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    warning:*) note "${line#warning: }" ;;
    aviso:*) note "${line#aviso: }" ;;
    *) fail "$line" ;;
  esac
done <"$decisions_out"
if [[ $decisions_rc -gt 1 ]]; then
  fail "could not verify the status of the ADRs"
fi
rm -f "$decisions_out"

section_ok "ADR status and numbering"

# --- 9. Markdown links -------------------------------------------------------

if node "$CRUX_HOME/lib/check-doc-paths.mjs" "$DOCS" >"$DOCTOR_TMP/paths" 2>&1; then
  ok "markdown links resolve"
else
  fail "broken markdown links:"
  sed 's/^/      /' "$DOCTOR_TMP/paths" | head -20
fi
rm -f "$DOCTOR_TMP/paths"

# --- 10. Project skills ------------------------------------------------------
#
# The check lives in lib/, not here, because the same bar has to apply to both
# catalogs: the project's skills and the kernel's, which are the ones present
# in every session. While it was written in this block, nobody looked at the
# kernel's.

section
skills="$(find "$DOCS/.claude/skills" -name SKILL.md 2>/dev/null | wc -l)"
desc_out="$DOCTOR_TMP/desc"
node "$CRUX_HOME/lib/check-skill-description.mjs" "$DOCS/.claude/skills" "$DECLARED_LANG" >"${desc_out}" 2>&1
desc_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    error\ *) fail "${line#error }" ;;
    warning\ *) note "${line#warning }" ;;
    aviso\ *) note "${line#aviso }" ;;
    *)        note "$line" ;;
  esac
done <"$desc_out"
[[ $desc_rc -eq 0 ]] || fail "could not verify skill activation: $(head -1 "$desc_out")"
[[ $skills -gt 0 ]] && section_ok "project skills: $skills"

# --- 11. Credentials written in the documentation ----------------------------
#
# A committed secret stays in the history and in every clone, even after
# deleting it. This decides nothing for anyone: it says where it is so that
# it is a decision and not a slip, and that is why it warns instead of
# blocking.

section
secrets_out="$DOCTOR_TMP/secrets"
node "$CRUX_HOME/lib/check-secrets.mjs" "$DOCS" >"$secrets_out" 2>&1
secrets_rc=$?
if [[ $secrets_rc -gt 0 ]]; then
  note "could not scan the documentation for credentials"
else
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    note "credential in the documentation: $line"
  done <"$secrets_out"
fi
[[ ! -s "$secrets_out" ]] && section_ok "no credentials in plain sight in the documentation"
rm -f "$secrets_out"

# A runbook stamped half a year ago is not false, but nobody knows whether it
# still holds. Only operations/ is looked at: it is where being wrong costs
# the most and where nobody notices until the command fails.
stale_out="$DOCTOR_TMP/stale"
node "$CRUX_HOME/lib/check-staleness.mjs" "$DOCS" >"${stale_out}" 2>&1
stale_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  note "$line"
done <"$stale_out"
[[ $stale_rc -eq 0 ]] || fail "could not verify the staleness of the runbooks: $(head -1 "$stale_out")"

# --- 12. Documents nobody links to -------------------------------------------
#
# A doc that no index mentions is opened by no agent: it takes up space, ages,
# and ends up contradicting the one that does get read.

section
orphans=0
while IFS= read -r doc; do
  [[ -n "$doc" ]] || continue
  rel="${doc#$DOCS/}"
  base="$(basename "$doc")"
  # A README is the index of its own folder: nobody links to it, by design.
  [[ "$base" == "README.md" || "$base" == "AGENTS.md" || "$base" == "CLAUDE.md" ]] && continue
  if ! grep -rlF --include="*.md" "$base" "$DOCS" 2>/dev/null | grep -qv "^$doc$"; then
    note "nobody links to $rel — add it to an index or delete it"
    orphans=$((orphans + 1))
  fi
done < <(find "$DOCS" -name "*.md" -not -path "*/.git/*" -not -path "*/.claude/*" 2>/dev/null | sort)
[[ $orphans -eq 0 ]] && section_ok "every document is in an index"

# --- 13. Drift between code and documentation --------------------------------
#
# It does not measure whether something is missing from the docs —git cannot
# tell that—, but whether the code has been moving without the documentation
# moving. It is the only auditable part of the §7 discipline: the rest is held
# up by the closing gate, and this is what lets you see afterwards whether the
# gate is being skipped.

section
drift_out="$DOCTOR_TMP/drift"
if node "$CRUX_HOME/lib/check-doc-drift.mjs" "$DOCS" >"$drift_out" 2>/dev/null; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    note "code ↔ doc drift: $line"
  done <"$drift_out"
  [[ ! -s "$drift_out" ]] && section_ok "documentation up to date with the code"
else
  note "could not measure the drift between code and documentation"
fi
rm -f "$drift_out"

# --- 14. Declared MCP servers ------------------------------------------------
#
# Only shape and drift: that what is declared can be written, that it carries
# no credentials —.mcp.json is committed— and that what is in the repos is
# still what the contract says. Whether the server responds is not asked here:
# it is network, and doctor has to take the same time and say the same thing
# with wifi and without it. `crux mcp status` answers that, and it runs when
# it matters.

section
mcp_out="$DOCTOR_TMP/mcp"
node "$CRUX_HOME/lib/check-mcp.mjs" "$DOCS" >"${mcp_out}" 2>&1
mcp_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    error\ *) fail "mcp: ${line#error }" ;;
    warning\ *) note "mcp: ${line#warning }" ;;
    aviso\ *) note "mcp: ${line#aviso }" ;;
    *)        note "mcp: $line" ;;
  esac
done <"$mcp_out"
[[ $mcp_rc -eq 0 ]] || fail "could not verify the MCP servers: $(head -1 "$mcp_out")"
if json_has "$DOCS/crux.json" 'mcp && Object.keys(root.mcp).length'; then
  section_ok "MCP servers declared and written where they belong"
fi

# --- Summary -----------------------------------------------------------------

echo
if [[ $ERRORS -eq 0 && $WARNS -eq 0 ]]; then
  echo "${C_GRN}conformant${C_OFF} — $(basename "$DOCS") meets the standard"
else
  summary
fi
exit $(( ERRORS > 0 ? 1 : 0 ))
