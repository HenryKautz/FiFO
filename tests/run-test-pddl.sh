#!/bin/bash
#
# run-test-pddl.sh -- regression tests for the PDDL -> FiFO translator.
#
# For each example problem with a checked-in translation under
# SatPlan/Examples/, the problem and domain files are copied to a temp
# directory, pddl2fifo is run on the copy, and the generated wff is diffed
# against the checked-in one.  The (include ...) line is normalized before
# comparison: it records the relative location of satplan.wff at generation
# time, which depends on how the translator was invoked (planner.sh computes
# it from FIFO_LISP; some checked-in wffs predate the current repo layout).
#
# Run from anywhere:  bash tests/run-test-pddl.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
PDDL2FIFO="$FIFO_LISP/pddl2fifo.lisp"
EXAMPLES="$REPO/SatPlan/Examples"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$PDDL2FIFO" ]]; then echo "pddl2fifo.lisp not found at $PDDL2FIFO" >&2; exit 2; fi
if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

PASS=0; FAIL=0

# Normalize the satplan include path (see header comment).  stdin -> stdout.
strip_include() { sed 's|(include ".*satplan\.wff")|(include "satplan.wff")|'; }

# run_one <example-subdir> <problem.pddl> <domain.pddl> <gold-wff-relative-to-subdir>
run_one() {
  local dir="$EXAMPLES/$1" prob="$2" dom="$3" gold="$4"
  printf '  %-16s %-14s ... ' "$1" "${prob%.pddl}"
  local work="$TMP/$1-${prob%.pddl}"
  mkdir -p "$work"
  cp "$dir/$prob" "$dir/$dom" "$work/"
  if ! sbcl --script "$PDDL2FIFO" "$work/$prob" "$work/$dom" >"$work/log" 2>&1; then
    echo "FAIL (pddl2fifo error)"
    sed 's/^/      | /' "$work/log" | tail -8
    FAIL=$((FAIL+1)); return
  fi
  local out="$work/${prob%.pddl}.wff"
  if [[ ! -f "$out" ]]; then
    echo "FAIL (no wff produced)"; FAIL=$((FAIL+1)); return
  fi
  if diff <(strip_include <"$dir/$gold") <(strip_include <"$out") >"$work/diff"; then
    echo "PASS"; PASS=$((PASS+1))
  else
    echo "FAIL (differs from $gold)"
    sed 's/^/      | /' "$work/diff" | head -15
    FAIL=$((FAIL+1))
  fi
}

echo "=== pddl2fifo regression tests ==="
for i in 1 2 3 4 5 6 7; do
  run_one LogisticsCosts "pb$i.pddl" logistics-costs.pddl "intermediates/pb$i.wff"
done
run_one TruckLog trucklogprob.pddl trucklog.pddl trucklogprob.wff
run_one Switch switchprob.pddl switches.pddl switchprob.wff
run_one LogisticsPrefs pbq1.pddl logistics-prefs.pddl intermediates/pbq1.wff
run_one Plan_Recognition/BlockWords pb1.pddl block-words.pddl intermediates/pb1.wff
run_one Plan_Recognition/IntrusionDetection pb1.pddl intrusion-detection.pddl intermediates/pb1.wff

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
