#!/usr/bin/env bash
# crux installation on a machine. Idempotent.
#
#   ~/Proyectos/crux/install.sh                          installs
#   ~/Proyectos/crux/install.sh --remote '<template>'    installs, setting the
#                                                        usual remote
#   ~/Proyectos/crux/install.sh --projects-dir <path>    sets the projects root
#   ~/Proyectos/crux/install.sh --dev                    links this working copy
#   ~/Proyectos/crux/install.sh --dry-run                shows what it would do
#
# The projects root is, by default, the directory where you cloned the kernel:
# if crux is in /opt/dev/crux, your projects go in /opt/dev. It can be changed,
# but the kernel should live alongside them.
#
# It does not touch any project's docs repos: that is what `crux link` and
# `crux upgrade` are for.
#
# crux is one binary. This script only gets it —from CRUX_BIN, from a release
# placed next to it as bin/crux-core, or by building it from rs/ with cargo—
# and hands it the rest of the installation.

set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

bin="${CRUX_BIN:-}"
[[ -n "$bin" || ! -x "$here/bin/crux-core" ]] || bin="$here/bin/crux-core"
if [[ -z "$bin" ]]; then
  cargo="$(command -v cargo || echo "$HOME/.cargo/bin/cargo")"
  if [[ ! -x "$cargo" ]]; then
    echo "crux is built with Rust and cargo is not here: install it from https://rustup.rs" >&2
    echo "and run this again" >&2
    exit 1
  fi
  echo "building crux (once per version)…"
  "$cargo" build --release --quiet --manifest-path "$here/rs/Cargo.toml"
  bin="$here/rs/target/release/crux"
fi

CRUX_HOME="$here" exec "$bin" __install "$@"
