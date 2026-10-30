#!/bin/bash
#
# run-test-visualizer.sh -- SatPlan/Visualizer: the web page's TypeScript.
#
#   1. the committed visualizer.js and examples.js are what build.sh makes from
#      src/ and examples/ (a stale build would ship code the tests never saw);
#   2. tests/test.ts under Node: problem parsing (counts checked with regular
#      expressions over the PDDL), the three solution formats, and the SVG map.
#      The oracle for plan simulation is FiFO's own .answer: its HOLDS facts are
#      the state at every slice, and the same plan with the HOLDS removed must
#      reproduce them from the actions alone.
#
# Needs tsc (TypeScript) and node; skips cleanly (exit 0) without them.
# Run from anywhere:  bash tests/run-test-visualizer.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
VIZ="$REPO/SatPlan/Visualizer"
echo "=== SatPlan visualizer ==="
for tool in tsc node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  $tool not found on PATH: skipped"
    echo "=== summary: 0 passed, 0 failed, 1 skipped ==="
    exit 0
  fi
done

TMP="$(mktemp -d /tmp/fifo-viz-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

STALE=0
mkdir -p "$TMP/build"
if ! bash "$VIZ/build.sh" --outdir "$TMP/build" >"$TMP/build.log" 2>&1; then
  echo "  build.sh failed:"; cat "$TMP/build.log"
  STALE=1
fi
for f in visualizer.js examples.js; do
  if [ "$STALE" = 0 ] && cmp -s "$TMP/build/$f" "$VIZ/$f"; then
    printf '  %-66s ... PASS\n' "$f is up to date (build.sh)"
  else
    printf '  %-66s ... FAIL\n' "$f is up to date (build.sh)"
    echo "      rebuild: bash SatPlan/Visualizer/build.sh"
    STALE=1
  fi
done

if ! tsc -p "$VIZ/tsconfig.test.json" --outFile "$TMP/test.js" >"$TMP/tsc-test.log" 2>&1; then
  echo "  the tests do not compile:"; cat "$TMP/tsc-test.log"
  exit 1
fi
node "$TMP/test.js" "$VIZ" || FAIL=1
[ "$STALE" = 0 ] && [ "$FAIL" = 0 ]
