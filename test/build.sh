# shellcheck shell=bash
# Sourced by the scripts that test the binary. They build it from the sources
# next to them, so none tests a build older than its own code: two-machines
# took whatever build was lying around and passed on a stale one.
# CRUX_SUITE_BIN tests a binary built elsewhere instead —a release, a static
# one, another platform's— on a machine that may have no Rust at all.
build_core() {
  if [[ -n "${CRUX_SUITE_BIN:-}" ]]; then
    [[ -x "$CRUX_SUITE_BIN" ]] || { echo "CRUX_SUITE_BIN is not an executable: $CRUX_SUITE_BIN"; return 1; }
    export CRUX_BIN="$CRUX_SUITE_BIN"
    return 0
  fi
  local cargo output
  cargo="$(command -v cargo || echo "$HOME/.cargo/bin/cargo")"
  if ! output="$("$cargo" build --quiet --manifest-path "$CRUX_HOME/rs/Cargo.toml" 2>&1)"; then
    echo "$output"
    echo "the Rust core does not build: fix that before running the cases"
    return 1
  fi
  export CRUX_BIN="${CARGO_TARGET_DIR:-$CRUX_HOME/rs/target}/debug/crux"
}
