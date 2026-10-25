#!/usr/bin/env bash
# Builds the crux-agents package from the release binaries.
#
#   npm/pack.sh <folder with crux-{linux,darwin}-{x64,arm64}> [output folder]
#
# The version comes from VERSION, never from package.json: the one in the repo
# is a placeholder so that nobody publishes it by hand without binaries.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bins="${1:?usage: npm/pack.sh <folder with the binaries> [output folder]}"
out="$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd)"
version="$(tr -d '[:space:]' < "$here/../VERSION")"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$here/bin" "$here/package.json" "$here/README.md" "$here/../LICENSE" "$stage/"
mkdir "$stage/vendor"
for p in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
  [[ -f "$bins/crux-$p" ]] || { echo "missing $bins/crux-$p" >&2; exit 1; }
  install -m 755 "$bins/crux-$p" "$stage/vendor/crux-$p"
done
chmod 755 "$stage/bin/crux.js"
(cd "$stage" && npm pkg set version="$version" && npm pack --silent --pack-destination "$out")
