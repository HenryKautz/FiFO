#!/bin/bash
# build.sh -- rebuild the visualizer's two generated scripts:
#   visualizer.js  the page's code, compiled from src/*.ts; its first line
#                  records the tsc version (another version may emit different
#                  code, so the test suite compares builds only within one)
#   examples.js    the files in examples/, for the page's Examples menu
# Needs tsc and node.  With --outdir DIR, writes them there instead (the test
# suite uses this to check the checked-in copies are current).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE"
if [ "${1:-}" = "--outdir" ]; then OUT="$2"; fi
TMP="$(mktemp -d /tmp/fifo-vizbuild-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

tsc -p "$HERE" --outFile "$TMP/visualizer.js"
{ echo "// Built from src/ by build.sh with tsc $(tsc --version | awk '{print $2}') -- do not edit; rebuild instead."
  cat "$TMP/visualizer.js"; } > "$OUT/visualizer.js"
tsc -p "$HERE/tsconfig.tools.json" --outFile "$TMP/bundle-examples.js"
node "$TMP/bundle-examples.js" "$HERE/examples" > "$OUT/examples.js"
