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

PASS=0; STALE=0; SKIP=0
mkdir -p "$TMP/build"
if ! bash "$VIZ/build.sh" --outdir "$TMP/build" >"$TMP/build.log" 2>&1; then
  echo "  build.sh failed:"; cat "$TMP/build.log"
  STALE=1
fi
# visualizer.js records the tsc that built it; another tsc version may emit
# different code from the same sources, so that comparison is skipped then
built_with=$(head -1 "$VIZ/visualizer.js" | sed -n 's/.* with tsc \([^ ]*\) .*/\1/p')
here=$(tsc --version | awk '{print $2}')
for f in visualizer.js examples.js domains.js; do
  name="$f is up to date (build.sh)"
  if [ "$f" = visualizer.js ] && [ "$built_with" != "$here" ]; then
    printf '  %-66s ... SKIP\n' "$name"
    echo "      built with tsc ${built_with:-unknown}, this machine has $here"
    SKIP=$((SKIP+1))
  elif [ "$STALE" = 0 ] && cmp -s "$TMP/build/$f" "$VIZ/$f"; then
    printf '  %-66s ... PASS\n' "$name"; PASS=$((PASS+1))
  else
    printf '  %-66s ... FAIL\n' "$name"
    echo "      rebuild: bash SatPlan/Visualizer/build.sh"
    STALE=$((STALE+1))
  fi
done
echo "  (build checks: $PASS passed, $STALE failed, $SKIP skipped)"

if ! tsc -p "$VIZ/tsconfig.test.json" --outFile "$TMP/test.js" >"$TMP/tsc-test.log" 2>&1; then
  echo "  the tests do not compile:"; cat "$TMP/tsc-test.log"
  exit 1
fi
node "$TMP/test.js" "$VIZ" || FAIL=1

# the Examples bundler: a solution belongs to the problem with the longest
# matching name, so grid5x5-air's solutions are not grid5x5's too
echo "=== the Examples bundler ==="
mkdir -p "$TMP/ex"
for f in grid5x5-air.pddl grid5x5-air.answer grid5x5-air.plan; do cp "$VIZ/examples/$f" "$TMP/ex/"; done
sed 's/(problem grid5x5-air)/(problem grid5x5)/' "$VIZ/examples/grid5x5-air.pddl" > "$TMP/ex/grid5x5.pddl"
cp "$VIZ/examples/grid5x5-air.answer" "$TMP/ex/grid5x5.answer"
tsc -p "$VIZ/tsconfig.tools.json" --outFile "$TMP/bundle.js" >/dev/null 2>&1 &&
  node "$TMP/bundle.js" "$TMP/ex" > "$TMP/ex.js" 2>/dev/null
owners=$(node -e "eval(require('fs').readFileSync('$TMP/ex.js','utf8') + ';global.E=VIZ_EXAMPLES');
  console.log(E.map(e => e.problem.file + ':' + e.solutions.map(s => s.file).join('+')).join(' '))" 2>&1)
want="grid5x5-air.pddl:grid5x5-air.answer+grid5x5-air.plan grid5x5.pddl:grid5x5.answer"
if [ "$owners" = "$want" ]; then
  printf '  %-66s ... PASS\n' "each solution goes to the longest matching problem name"
else
  printf '  %-66s ... FAIL\n' "each solution goes to the longest matching problem name"
  echo "      got:  $owners"; echo "      want: $want"; FAIL=1
fi

# a tree (as clara-examples/ is): each problem gets the domain beside it, else
# the nearest parent's -- two directories may each define a DIFFERENT domain of
# one name -- and solutions only from its own directory
mkdir -p "$TMP/tree/a" "$TMP/tree/b/sub"
printf '(define (domain x) (:requirements :strips)) ; a\n' > "$TMP/tree/a/dom.pddl"
printf '(define (domain x) (:requirements :strips)) ; b\n' > "$TMP/tree/b/dom.pddl"
# and a third at the top, which only a problem with none nearer may get
printf '(define (domain x) (:requirements :strips)) ; top\n' > "$TMP/tree/dom.pddl"
for p in a/p b/p b/sub/q; do
  printf '(define (problem %s) (:domain x))\n' "$(basename "$p")" > "$TMP/tree/$p.pddl"
done
echo '(OCCURS (drive) 1)' > "$TMP/tree/a/p.answer"
echo '(OCCURS (drive) 1)' > "$TMP/tree/b/sub/p.answer"   # beside q, named after b/p: no one's
tree=$(node "$TMP/bundle.js" "$TMP/tree" 2>/dev/null > "$TMP/tree.js" &&
  node -e "eval(require('fs').readFileSync('$TMP/tree.js','utf8') + ';global.E=VIZ_EXAMPLES');
  console.log(E.map(e => e.problem.file + '<' + (e.domain ? e.domain.file : '-') + ':' + e.solutions.map(s => s.file).join('+')).join(' '))" 2>&1)
want="a/p.pddl<a/dom.pddl:a/p.answer b/p.pddl<b/dom.pddl: b/sub/q.pddl<b/dom.pddl:"
if [ "$tree" = "$want" ]; then
  printf '  %-66s ... PASS\n' "a tree: the domain beside the problem, else a parent's"
else
  printf '  %-66s ... FAIL\n' "a tree: the domain beside the problem, else a parent's"
  echo "      got:  $tree"; echo "      want: $want"; FAIL=1
fi
# two different domains of one name in ONE directory: refused, not one picked
cp "$TMP/tree/b/dom.pddl" "$TMP/tree/a/dom2.pddl"
if node "$TMP/bundle.js" "$TMP/tree" >/dev/null 2>&1; then
  printf '  %-66s ... FAIL\n' "two different same-named domains in one directory are refused"; FAIL=1
else
  printf '  %-66s ... PASS\n' "two different same-named domains in one directory are refused"
fi
[ "$STALE" = 0 ] && [ "$FAIL" = 0 ]
