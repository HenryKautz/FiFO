#!/bin/bash
# build.sh -- rebuild the visualizer's generated scripts:
#   visualizer.js  the plan visualizer (index.html), compiled from src/*.ts
#   circuit.js     the circuit visualizer (circuit.html), from the same shared
#                  modules plus src/circuit-app.ts
#   examples.js    the files in examples/, for the plan visualizer's Examples menu
#   domains.js     FiFO's domain library (../../pddl), found by name for a
#                  problem loaded without its domain
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
node "$TMP/bundle-examples.js" --domains "$HERE/../../pddl" > "$OUT/domains.js"
# clara-examples/ (git-ignored links into a CLARA checkout, made by
# build-clara-examples.sh) -> clara-examples.js, which index.html also loads;
# without the directory, remove any old bundle so the menu does not go stale.
# Not with --outdir: the test suite's check of the checked-in files must not
# depend on a local CLARA checkout.  Written to a scratch file first, so a
# failure leaves the old bundle (and the CLARA button) in place.
if [ "$OUT" = "$HERE" ]; then
  if [ -d "$HERE/clara-examples" ]; then
    node "$TMP/bundle-examples.js" "$HERE/clara-examples" VIZ_CLARA_EXAMPLES > "$TMP/clara-examples.js"
    mv "$TMP/clara-examples.js" "$OUT/clara-examples.js"
  else
    rm -f "$OUT/clara-examples.js"
  fi
fi
