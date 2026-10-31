#!/bin/bash
# build.sh -- rebuild the visualizer's generated scripts:
#   visualizer.js  the plan visualizer (index.html), compiled from src/*.ts
#   circuit.js     the circuit visualizer (circuit.html), from the same shared
#                  modules plus src/circuit-app.ts
#   examples.js    the files in examples/, for the plan visualizer's Examples menu
# The first line of each .js records the tsc version (another version may emit
# different code, so the test suite compares builds only within one).
# Needs tsc and node.  With --outdir DIR, writes them there instead (the test
# suite uses this to check the checked-in copies are current).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE"
if [ "${1:-}" = "--outdir" ]; then OUT="$2"; fi
TMP="$(mktemp -d /tmp/fifo-vizbuild-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
VERSION="$(tsc --version | awk '{print $2}')"

build() {   # build <tsconfig> <output name>
  tsc -p "$1" --outFile "$TMP/$2"
  { echo "// Built from src/ by build.sh with tsc $VERSION -- do not edit; rebuild instead."
    cat "$TMP/$2"; } > "$OUT/$2"
}
build "$HERE" visualizer.js
build "$HERE/tsconfig.circuit.json" circuit.js
tsc -p "$HERE/tsconfig.tools.json" --outFile "$TMP/bundle-examples.js"
node "$TMP/bundle-examples.js" "$HERE/examples" > "$OUT/examples.js"
