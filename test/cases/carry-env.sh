#!/usr/bin/env bash

# `carry-env` moves files with secrets inside. What has to be pinned down is not
# that it copies —that is a `cp`— but the three things that make it safe to run.

_project_with_envs() {
  local root="$SB/project"
  mkdir -p "$root"/{api,web/.next,api-ws-task,web/apps/mobile}
  echo "TOKEN=value-that-must-not-reach-the-screen" > "$root/api/.env"
  echo "X=1" > "$root/web/.env.production"
  echo "X=1" > "$root/web/apps/mobile/.env.local"
  echo "X=1" > "$root/api-ws-task/.env"          # workspace copy
  echo "X=1" > "$root/web/.next/.env.production"  # build artifact
  echo "X=1" > "$root/web/.env.example"           # template
  echo "$root"
}

test_carry_env_prints_no_file_content() {
  sandbox >/dev/null
  local root; root="$(_project_with_envs)"

  local out
  out="$(bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$root" --out "$SB/out" 2>&1)"

  # The guarantee everything depends on: an agent can run it without a secret
  # ending up written in the session transcript.
  assert_not_contains "$out" "value-that-must-not-reach" "does not dump the content"
  assert_file "$SB/out/.env.api" "but does copy it"
  teardown
}

test_carry_env_skips_derived_files() {
  sandbox >/dev/null
  local root; root="$(_project_with_envs)"
  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$root" --out "$SB/out" >/dev/null 2>&1

  assert_file "$SB/out/.env.api" "the one in the repo"
  assert_file "$SB/out/.env.web.production" "and the one in another repo"
  assert_file "$SB/out/.env.web.mobile.local" "a nested one, with its directory in the name"
  # Restoring a workspace copy on top of the good one leaves an environment
  # that looks fine and points at other ports.
  assert_no_file "$SB/out/.env.api-ws-task" "does not take workspace copies"
  assert_no_file "$SB/out/.env.web.next.production" "nor build artifacts"
  assert_no_file "$SB/out/.env.web.example" "nor templates"
  teardown
}

test_carry_env_leaves_map_and_way_back() {
  sandbox >/dev/null
  local root; root="$(_project_with_envs)"
  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$root" --out "$SB/out" >/dev/null 2>&1

  assert_file "$SB/out/RESTAURAR.md" "the map"
  assert_file "$SB/out/restaurar.sh" "the way back"
  assert_contains "$(cat "$SB/out/RESTAURAR.md")" "api/.env" "the map says the destination"
  assert_not_contains "$(cat "$SB/out/RESTAURAR.md")" "value-that-must-not-reach" \
    "and the map carries no value"
  teardown
}

test_carry_env_does_not_overwrite_on_restore() {
  sandbox >/dev/null
  local root; root="$(_project_with_envs)"
  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$root" --out "$SB/out" >/dev/null 2>&1

  # A destination with something different inside: losing a value that was only
  # there is worse than copying too little.
  local target="$SB/dest"
  mkdir -p "$target/api" "$target/web"
  echo "WHAT-WAS-ALREADY-THERE=1" > "$target/api/.env"

  bash "$SB/out/restaurar.sh" "$target" --apply >/dev/null 2>&1

  assert_eq "WHAT-WAS-ALREADY-THERE=1" "$(cat "$target/api/.env")" "does not overwrite what was already there"
  assert_file "$target/web/.env.production" "and does put what was missing"
  teardown
}

# The anchor. Collecting while pointing at a repo left a bundle that believes it
# is a project named like the repo, with paths relative to it: on the new
# machine <root>/<repo> is looked up, which does not exist, and there is no way
# to restore it without knowing why. The flaw does not show when collecting but
# months later, which is when it no longer helps.

_adopted_project() {
  local root="$SB/Proyectos/shop"
  mkdir -p "$root/shop-docs" "$root/shop-api"
  echo '{"project": "shop"}' > "$root/shop-docs/crux.json"
  echo "X=1" > "$root/shop-api/.env"
  echo "$root"
}

test_carry_env_anchors_at_root_even_if_pointed_at_a_repo() {
  sandbox >/dev/null
  local root; root="$(_adopted_project)"

  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$root/shop-api" --out "$SB/out" >/dev/null 2>&1

  # The whole line: "shop-api" contains "shop", so a contains would pass even
  # if the bundle believed it was the repo.
  assert_eq "# proyecto: shop" "$(head -1 "$SB/out/mapa.txt")" \
    "the bundle is named like the project, not like the repo"
  assert_contains "$(cat "$SB/out/mapa.txt")" "shop-api/.env" \
    "and the paths are relative to the project root"
  teardown
}

test_carry_env_restores_a_bundle_collected_as_repo() {
  sandbox >/dev/null
  local root; root="$(_adopted_project)"
  rm -f "$root/shop-api/.env"

  # A bundle like the ones the previous version left: named like the repo, and
  # restored with the old --hazlo flag, which is still accepted.
  mkdir -p "$SB/old"
  printf '# proyecto: shop-api\n.env|.env\n' > "$SB/old/mapa.txt"
  echo "X=1" > "$SB/old/.env"
  cp "$CRUX_HOME/skills/carry-env/scripts/restaurar.sh" "$SB/old/"

  CRUX_PROJECTS_DIR="$SB/Proyectos" bash "$SB/old/restaurar.sh" --hazlo >/dev/null 2>&1

  assert_file "$root/shop-api/.env" \
    "finds it one level deeper instead of giving up"
  teardown
}

test_carry_env_names_root_files_without_inventing_a_repo() {
  sandbox >/dev/null
  mkdir -p "$SB/loose"
  echo "X=1" > "$SB/loose/.env"
  echo "X=1" > "$SB/loose/.env.local"

  bash "$CRUX_HOME/skills/carry-env/scripts/collect.sh" \
    --project "$SB/loose" --out "$SB/out" >/dev/null 2>&1

  # It used to come out as `.env..env.`: it took `.env` for a repo name. A name
  # that does not say where it came from is exactly what this skill exists to
  # avoid.
  assert_file "$SB/out/.env" "the one at the root is named as it is"
  assert_file "$SB/out/.env.local" "and its variant too"
  teardown
}
