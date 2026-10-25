#!/usr/bin/env bash

# `crux setup` walks a person through a machine with nothing on it. Here gh is
# a fake that answers as an account would, the remote is local bare repos, and
# the answers a person would type come in on stdin: CRUX_TEST_TTY makes setup
# ask as it would at a terminal.

_setup_gh() {
  # _setup_gh <user> <orgs> <protocol> — an account, its organisations and how
  # it clones. The repos of an owner are the bare repos under $SB/remotes/<owner>.
  mkdir -p "$SB/bin" "$SB/remotes"
  cat > "$SB/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "auth status") [[ -e "$SB/gh-logged-out" ]] && exit 1; exit 0 ;;
  "api user") echo "$1" ;;
  "api user/memberships/orgs") printf '%s\n' $2 ;;
  "config get") echo "$3" ;;
  "repo list") for r in "$SB/remotes/\$3"/*.git; do [[ -d "\$r" ]] && basename "\$r" .git; done ;;
  "repo view") [[ -d "$SB/remotes/\${3%%/*}/\${3#*/}.git" ]] ;;
  "api "*)
    if [[ "\$2" =~ ^repos/([^/]+)/([^/]+)/contents/crux.json\$ ]]; then
      git -C "$SB/remotes/\${BASH_REMATCH[1]}/\${BASH_REMATCH[2]}.git" cat-file -e main:crux.json 2>/dev/null; exit \$?
    fi
    exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"
}

# setup_as <home> <answers> [args...] — setup as a person at a terminal would run it.
setup_as() {
  local home="$1" answers="$2"; shift 2
  printf '%b' "$answers" | env HOME="$home" CRUX_TEST_TTY=1 timeout 60 "$CRUX_HOME/bin/crux" setup "$@" 2>&1
}

test_setup_without_a_terminal_says_what_is_missing_and_does_not_wait() {
  sandbox >/dev/null
  _setup_gh ana "" https
  touch "$SB/gh-logged-out"
  local out rc=0
  out="$(env HOME="$SB/h" timeout 30 "$CRUX_HOME/bin/crux" setup --projects-dir "$SB/h/p" </dev/null 2>&1)" || rc=$?
  assert_eq "1" "$rc" "it stops, it does not wait for an answer nobody can give"
  assert_contains "$out" "gh auth login" "and says how to log in"
}

test_setup_creates_the_first_project_of_a_new_account() {
  sandbox >/dev/null
  _setup_gh ana "" https
  local home="$SB/h"; mkdir -p "$home/.crux"
  # The remote is local here: the template is already on the machine, and
  # setup keeps it.
  printf 'CRUX_REMOTE="%s/remotes/ana/{repo}.git"\n' "$SB" > "$home/.crux/config"
  printf '[user]\n\temail = ana@localhost\n\tname = ana\n[init]\n\tdefaultBranch = main\n' > "$home/.gitconfig"
  for r in shop-web shop-api shop-docs; do git init -q --bare -b main "$SB/remotes/ana/$r.git"; done

  # profile: no; first project: yes, shop, its repos, our own
  local out; out="$(setup_as "$home" 'n\ny\nshop\nshop-web,shop-api\n1\n' --projects-dir "$home/p")"
  local docs="$home/p/shop/shop-docs"
  assert_file "$docs/crux.json" "the project is created"
  assert_contains "$(cat "$docs/crux.json")" "shop-api" "with the repos chosen from the account"
  assert_exit 0 "and pushed to the remote" git -C "$SB/remotes/ana/shop-docs.git" rev-parse --verify -q main
  assert_file "$docs/.git/hooks/pre-commit" "its git hooks are installed"
  assert_contains "$out" "Open Claude Code or Codex" "and it ends saying how to start working"

  out="$(setup_as "$home" 'n\nn\n' --projects-dir "$home/p")"
  assert_contains "$out" "shop" "run again, it sees the project and does not create it twice"
  assert_not_contains "$out" "first project" "nor offers to create the first one"
}

test_setup_writes_the_remote_of_the_organisation_chosen() {
  sandbox >/dev/null
  _setup_gh ana "acme" ssh
  local home="$SB/h"
  # where projects go: the organisation; profile: no; first project: no
  local out; out="$(setup_as "$home" '2\nn\nn\n' --projects-dir "$home/p")"
  assert_contains "$(cat "$home/.crux/config" 2>/dev/null)" 'CRUX_REMOTE="git@github.com:acme/{repo}.git"' \
    "the remote is the organisation's, the way the account clones"
  assert_contains "$out" "ana" "the person's own account is offered too"
}

test_setup_brings_the_projects_the_account_already_has() {
  sandbox >/dev/null
  _setup_gh ana "" https
  local home="$SB/h"; mkdir -p "$home/.crux"
  printf 'CRUX_REMOTE="%s/remotes/ana/{repo}.git"\n' "$SB" > "$home/.crux/config"
  printf '[user]\n\temail = ana@localhost\n\tname = ana\n[init]\n\tdefaultBranch = main\n' > "$home/.gitconfig"
  # A project made on another machine: its docs repo, with a contract, on the remote.
  local seed="$SB/seed"
  env HOME="$home" "$CRUX_HOME/bin/crux" init blog --no-remote --parent "$seed" >/dev/null 2>&1
  git init -q --bare -b main "$SB/remotes/ana/blog-docs.git"
  git -C "$seed/blog/blog-docs" push -q "$SB/remotes/ana/blog-docs.git" HEAD:main 2>/dev/null

  # profile: no; bring the projects: yes
  local out; out="$(setup_as "$home" 'n\ny\n' --projects-dir "$home/p")"
  assert_contains "$out" "blog" "it finds the project on the account"
  assert_file "$home/p/blog/blog-docs/crux.json" "and brings it"
}

test_setup_offers_projects_in_home_and_keeps_the_folder_the_person_chooses() {
  sandbox >/dev/null
  _setup_gh ana "" https
  local home="$SB/h"; mkdir -p "$home/.crux"
  printf 'CRUX_REMOTE="%s/remotes/ana/{repo}.git"\n' "$SB" > "$home/.crux/config"
  # folder: the default; profile: no; first project: no
  local out; out="$(setup_as "$home" '\nn\nn\n')"
  # shellcheck disable=SC2088  # setup prints the folder with a literal ~
  assert_contains "$out" "~/Projects" "the folder offered is ~/Projects"
  assert_contains "$(cat "$home/.crux/config")" "CRUX_PROJECTS_DIR=\"$home/Projects\"" "and the default is saved"

  # folder: one of the person's own
  out="$(setup_as "$home" "$home/code\nn\nn\n")"
  assert_contains "$(cat "$home/.crux/config")" "CRUX_PROJECTS_DIR=\"$home/code\"" "an answer replaces it"
  out="$(setup_as "$home" '\nn\nn\n')"
  # shellcheck disable=SC2088  # setup prints the folder with a literal ~
  assert_contains "$out" "~/code" "run again, it offers the folder chosen, not the default"
}

# All or nothing made a machine carry every project of the account: the person
# picks which, by number or name, and none is a valid answer.
test_setup_brings_only_the_projects_picked() {
  sandbox >/dev/null
  _setup_gh ana "" https
  local home="$SB/h"; mkdir -p "$home/.crux"
  printf 'CRUX_REMOTE="%s/remotes/ana/{repo}.git"\n' "$SB" > "$home/.crux/config"
  printf '[user]\n\temail = ana@localhost\n\tname = ana\n[init]\n\tdefaultBranch = main\n' > "$home/.gitconfig"
  local seed="$SB/seed" p
  for p in blog shop; do
    env HOME="$home" "$CRUX_HOME/bin/crux" init "$p" --no-remote --parent "$seed" >/dev/null 2>&1
    git init -q --bare -b main "$SB/remotes/ana/$p-docs.git"
    git -C "$seed/$p/$p-docs" push -q "$SB/remotes/ana/$p-docs.git" HEAD:main 2>/dev/null
  done

  # profile: no; projects: only shop, by name
  local out; out="$(setup_as "$home" 'n\nshop\n' --projects-dir "$home/p")"
  assert_contains "$out" "which to bring" "it asks which"
  assert_file "$home/p/shop/shop-docs/crux.json" "it brings the one picked"
  assert_no_file "$home/p/blog" "and not the other"

  local home2="$SB/h2"; mkdir -p "$home2/.crux"
  cp "$home/.crux/config" "$home2/.crux/"; cp "$home/.gitconfig" "$home2/"
  out="$(setup_as "$home2" 'n\nnone\n' --projects-dir "$home2/p")"
  assert_contains "$out" "crux clone <project> brings one later" "none is an answer, and it says how to bring one later"
  assert_no_file "$home2/p/shop" "nothing is brought"
}
