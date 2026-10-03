#!/usr/bin/env bash
# crux release — publish a kernel version.
#
#   crux release <version>          shows what it would do and verifies, touching nothing
#   crux release <version> --yes    tags and publishes
#
# The version number is bumped in VERSION **by proposal**, like any other
# change: this command does not commit to the main branch, it only checks that
# the version is already there and creates the tag.
#
# What sets this apart from a `git tag` is the third check: **before
# publishing, it verifies that the projects consuming the kernel are still
# conformant**. Changing the standard and breaking whoever uses it without
# noticing is the failure a release must prevent.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

# Publishing is an operation on the kernel repository, not on the installed
# copy: from there there is neither git nor a suite to run.
REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$REPO" || ! -f "$REPO/test/run.sh" || ! -f "$REPO/STANDARD.md" ]]; then
  err "crux release runs from the kernel repository"
  info "you are in: $PWD"
  exit 1
fi

NEW="${1:-}"
[[ -n "$NEW" ]] || die "usage: crux release <version> [--yes]"
shift

CONFIRMED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) CONFIRMED=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must be semver: 1.2.3"

CURRENT="$(tr -d '[:space:]' < "$REPO/VERSION")"
last_tag="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")"
version_greater_than "$NEW" "${last_tag:-0.0.0}" || die "$NEW is not later than the last published ($last_tag)"

echo "release $CURRENT → $NEW"
echo

FAILURES=0
failure() { err "$*"; FAILURES=$((FAILURES + 1)); }

# --- 1. The kernel repo ---------------------------------------------------

branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "main" ]] || failure "you are on branch $branch, not main"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || failure "there are uncommitted changes"
[[ -z "$(git -C "$REPO" log --oneline '@{u}..' 2>/dev/null)" ]] || failure "there are unpushed commits"
git -C "$REPO" rev-parse "v$NEW" >/dev/null 2>&1 && failure "tag v$NEW already exists"
[[ "$CURRENT" == "$NEW" ]] || failure "VERSION says $CURRENT: bump it to $NEW by proposal before tagging"

# `crux release` runs the installed copy's code, not the repo's: publishing
# with an old copy publishes with the old publisher, and this command's
# improvements are lost right on their debut.
installed=""
if [[ -f "$HOME/.crux/config" ]]; then
  installed_home="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"' || true)"
  [[ -n "$installed_home" && -f "$installed_home/VERSION" ]] &&
    installed="$(tr -d '[:space:]' < "$installed_home/VERSION")"
fi
[[ -z "$installed" || "$installed" == "$NEW" ]] ||
  failure "the installed kernel is $installed: reinstall it before publishing $NEW ('bash install.sh')"
[[ $FAILURES -eq 0 ]] && ok "repo ready: main, clean, up to date and with VERSION at $NEW"

# --- 2. The suite -------------------------------------------------------------

# The suite also tests this command, so without this guard they would call
# each other endlessly.
if [[ -n "${CRUX_IN_TESTS:-}" ]]; then
  info "suite skipped: running from the suite itself"
elif ( cd "$REPO" && ./test/run.sh >/tmp/crux-release-tests.$$ 2>&1 ); then
  ok "suite green ($(grep -oE '[0-9]+ (aserciones|assertions)' /tmp/crux-release-tests.$$ | tail -1))"
else
  failure "the suite does not pass:"
  tail -5 /tmp/crux-release-tests.$$ | sed 's/^/      /'
fi
rm -f /tmp/crux-release-tests.$$

# --- 3. The projects that consume the kernel ---------------------------------
#
# It is the check that justifies this being a command and not a `git tag`.

root="$(projects_root)"
consumers=0
for docs in "$root"/*/*-docs; do
  [[ -f "$docs/crux.json" ]] || continue
  consumers=$((consumers + 1))
  name="$(basename "$docs")"
  if bash "$CRUX_HOME/bin/doctor.sh" "$docs" >/tmp/crux-release-doctor.$$ 2>&1; then
    ok "$name conformant"
  else
    failure "$name stops meeting the standard with this version:"
    grep -E "^error" /tmp/crux-release-doctor.$$ | head -5 | sed 's/^/      /'
  fi
  rm -f /tmp/crux-release-doctor.$$
done
[[ $consumers -eq 0 ]] && warn "no project consumes the kernel in $root: nothing to verify"

# --- Notes -------------------------------------------------------------------

last_one="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || echo "")"
range="${last_one:+$last_one..}HEAD"

notes="$(git -C "$REPO" log --format='%s' "$range" | node -e '
  const types = { feat: "Features", fix: "Fixes", refactor: "Refactor",
                  docs: "Documentation", test: "Tests", chore: "Maintenance" };
  let d = "";
  process.stdin.on("data", (c) => (d += c)).on("end", () => {
    const groups = new Map();
    for (const line of d.split("\n").filter(Boolean)) {
      const m = line.match(/^(\w+)(?:\([^)]*\))?!?:\s*(.+)$/);
      const type = m && types[m[1]] ? types[m[1]] : "Other";
      const text = m ? m[2] : line;
      groups.set(type, [...(groups.get(type) || []), text]);
    }
    // Fixed order: what matters most to whoever updates goes first.
    const order = ["Features", "Fixes", "Refactor", "Documentation", "Tests", "Maintenance", "Other"];
    const out = [];
    for (const t of order) {
      if (!groups.has(t)) continue;
      out.push(`### ${t}`, "", ...groups.get(t).map((x) => `- ${x}`), "");
    }
    process.stdout.write(out.join("\n"));
  });
')"

echo
echo "Release notes${last_one:+ (since $last_one)}:"
echo
echo "$notes" | sed 's/^/  /'

# --- Publish ----------------------------------------------------------------

echo
if [[ $FAILURES -gt 0 ]]; then
  err "$FAILURES checks fail: not publishing"
  exit 1
fi

if [[ $CONFIRMED -eq 0 ]]; then
  ok "all ready to publish $NEW"
  info "to do it: crux release $NEW --yes"
  exit 0
fi

git -C "$REPO" tag -a "v$NEW" -m "$NEW

$notes"
git -C "$REPO" push -q origin "v$NEW"
ok "v$NEW published"

# Without this the notes only exist in the tag message, which nobody reads:
# whoever arrives at the repo has no way to see what changed between two
# versions.
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  if ( cd "$REPO" && gh release create "v$NEW" --title "$NEW" --notes "$notes" >/dev/null 2>&1 ); then
    ok "notes published in release v$NEW"
  else
    warn "could not publish the notes: 'gh release create v$NEW --notes ...' by hand"
  fi
else
  info "gh not authenticated: the notes stay in the tag"
fi

echo
info "projects align with 'crux upgrade' when their turn comes"
