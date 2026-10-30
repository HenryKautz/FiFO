#!/bin/bash
# build.sh -- rebuild the visualizer's two generated scripts:
#   visualizer.js  the page's code, compiled from src/*.ts
#   examples.js    the files in examples/, for the page's Examples menu
# Needs tsc and node.  With --outdir DIR, writes them there instead (the test
# suite uses this to check the checked-in copies are current).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE"
if [ "${1:-}" = "--outdir" ]; then OUT="$2"; fi
TMP="$(mktemp -d /tmp/fifo-vizbuild-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

tsc -p "$HERE" --outFile "$OUT/visualizer.js"
tsc -p "$HERE/tsconfig.tools.json" --outFile "$TMP/bundle-examples.js"
node "$TMP/bundle-examples.js" "$HERE/examples" > "$OUT/examples.js"
