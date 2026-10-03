#!/usr/bin/env bash
# git hook (commit-msg). Copied by `crux hooks install`.
#
# A rule nobody checks is a recommendation. The standard asked for messages in
# English from day one and the history of this kernel was entirely in Spanish;
# it asked not to sign with the tool and the signature ended up in a client's
# proposal.
#
# It has two scopes, and the difference matters:
#
#   full       our repo: our conventions are checked
#   signature  client repo: the tool signature is removed and the language checked
#
# In a client's repo, the format of their history is theirs: imposing our
# conventional commits or line width would be exactly the mistake the
# client-repo profile exists to avoid. The language is not ours to choose
# either, and that is why it comes from the contract: English unless the
# project declares another. Leaving it out let a client whose whole team writes
# English receive dozens of commits in Spanish. And the agent's signature must
# not appear anywhere.
SCOPE="${CRUX_COMMIT_MSG_SCOPE:-full}"
COMMIT_LANG="${CRUX_COMMIT_MSG_LANG:-en}"

set -u

[[ -f "${1:-}" ]] || exit 0

# --- Tool signature (in all repos) ------------------------------------------
#
# It is deleted instead of rejecting the commit: the agent adds it because its
# own environment asks it to, so blocking forces rewriting a message that is
# otherwise fine, and the slip returns in the next commit.
SIGNATURE='^[[:space:]]*(co-authored-by:[[:space:]]*(claude|ona|copilot|cursor|devin|gemini)|claude-session:|(🤖[[:space:]]*)?(generated|generado) with)'
if grep -qiE "$SIGNATURE" "$1"; then
  tmp="$(mktemp)"
  grep -viE "$SIGNATURE" "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$tmp"
  mv "$tmp" "$1"
  echo "crux: removed the tool signature from the commit message"
fi

# A merge, a revert or a fixup is written by nobody: git generates them.
subject="$(grep -v '^#' "$1" | grep -m1 . || true)"
case "$subject" in
  Merge\ *|Revert\ *|fixup!\ *|squash!\ *|amend!\ *) exit 0 ;;
esac

# The detail arrives as a multi-line block: it is indented whole, not split by
# words.
rejection() {
  echo; echo "$1"; echo
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/  /'
  echo
  echo "Rewrite it, or skip with: git commit --no-verify"
  exit 1
}

if [[ "$SCOPE" == "full" ]]; then
  # --- Conventional commits ----------------------------------------------------
  #
  # All 97 commits of the kernel comply except the 8 merges, already exempt above.
  KINDS='feat|fix|chore|docs|refactor|test|style|perf|build|ci|revert'
  if ! printf '%s' "$subject" | grep -qE "^($KINDS)(\([^)]+\))?!?: ."; then
    rejection "the subject does not follow conventional commits" \
      "$(printf '%s\n\ntypes: %s' "$subject" "$KINDS")"
  fi

  # Not a single one in the history starts with a capital after the prefix: it costs nothing.
  if printf '%s' "$subject" | grep -qE "^($KINDS)(\([^)]+\))?!?: [A-Z]"; then
    rejection "the subject starts with a capital letter after the prefix" "$subject"
  fi

  # --- Body width --------------------------------------------------------
  #
  # 100 characters. Of the real history only two lines exceed it, and by one.
  # A line without spaces cannot be split: a long URL is not an oversight.
  long_ones="$(grep -v '^#' "$1" | awk 'length($0)>100 && $0 ~ / / {print NR": "substr($0,1,60)"…"}')"
  if [[ -n "$long_ones" ]]; then
    rejection "there are lines over 100 characters in the body" "$long_ones"
  fi
fi

# --- Language ------------------------------------------------------------------
#
# Detects by function words and by the verbs a Spanish subject starts with
# (añade, arregla, quita…), which do not exist in English, and requires two
# occurrences. With only one, a proper name —"Los Angeles", "Los Angeles"— would
# be a false positive, and a hook that gets it wrong is disabled within a week.
#
# Comment lines belong to git, and what is in backticks is code: neither says
# what language the message is written in.
[[ "$COMMIT_LANG" == "en" ]] || exit 0

msg="$(sed -e '/^#/d' -e 's/`[^`]*`//g' "$1" | tr '[:upper:]' '[:lower:]')"

hints="$(printf '%s' "$msg" | grep -owE \
  'que|para|porque|cuando|esto|esta|este|esa|ese|del|las|los|una|unos|unas|pero|aunque|desde|tambien|segun|asi|muy|cada|donde|hasta|mientras|siempre|nunca|antes|despues|ahora|hace|hacer|tiene|tener|puede|debe|deja|pasa|sigue|vuelve|el|la|al|un|es|son|ser|su|sus|ni|se|de|en|por|añade|anade|arregla|corrige|quita|elimina|actualiza|mejora|cambia|mueve|evita|permite|crea|borra|sube|muestra|comprueba')"

[[ "$(printf '%s' "$hints" | grep -c .)" -lt 2 ]] && exit 0
hints="$(printf '%s' "$hints" | sort -u)"

echo
echo "commit message in Spanish — the standard asks for English"
echo
echo "  hints: $(printf '%s' "$hints" | tr '\n' ' ')"
echo
echo "Documentation goes in the project language; names, branches and"
echo "commits, in English. Rewrite it, or skip with: git commit --no-verify"
exit 1
