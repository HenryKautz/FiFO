#!/bin/bash
#
# run-test-evidence.sh -- regression tests for --pddl-evidence, in particular
# the occur-in-order modal (ordered action-occurrence evidence).
#
# These are behavioral checks (plan found / plan embeds the observed sequence
# in strictly increasing slices / bad evidence raises its contextual error),
# not gold-file diffs: the evidence scnf's clause forms can contain gensym'd
# auxiliary variables, so byte comparisons are unstable across SBCL sessions.
#
# Run from anywhere:  bash tests/run-test-evidence.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
PLANNER="$REPO/bin/planner.sh"
EXAMPLES="$REPO/SatPlan/Examples"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"   # resolve /var -> /private/var: the wff's relative
                               # (include ...) path breaks under a symlinked cwd
trap 'rm -rf "$TMP"' EXIT

if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

PASS=0; FAIL=0

pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }

# stage <example-subdir> <file>... : copy files into a fresh work dir, cd there.
stage() {
  local dir="$EXAMPLES/$1"; shift
  work="$TMP/case-$((PASS+FAIL))"
  mkdir -p "$work"
  for f in "$@"; do cp "$dir/$f" "$work/"; done
  cd "$work" || exit 2
}

# embedded_in_order <answer> <action>... : greedily check that the actions can
# be embedded, in the given order, at strictly increasing OCCURS slices.
embedded_in_order() {
  local answer="$1"; shift
  local prev=0 t
  for a in "$@"; do
    t=$(grep -F "(OCCURS ($a) " "$answer" \
          | sed 's/.* \([0-9][0-9]*\))$/\1/' \
          | sort -n | awk -v p="$prev" '$1 > p { print; exit }')
    if [[ -z "$t" ]]; then return 1; fi
    prev=$t
  done
  return 0
}

echo "=== occur-in-order evidence tests ==="

printf '  %-52s ... ' "BlockWords, 50%-observability trace embeds in order"
stage Plan_Recognition/BlockWords pb1.pddl block-words.pddl evidence-partial.txt
if bash "$PLANNER" pb1.pddl --domain block-words.pddl --minslices 9 --maxslices 12 \
     --pddl-evidence-file evidence-partial.txt >log 2>&1 \
   && grep -q "(OBSDONE 1 5 11)" pb1.answer \
   && embedded_in_order pb1.answer \
        "UNSTACK R P" "PICK-UP O" "UNSTACK D A" "UNSTACK A C" "PICK-UP C"; then
  pass
else
  fail "no plan, or observed sequence not embedded in order"
  tail -5 log | sed 's/^/      | /'
fi

printf '  %-52s ... ' "IntrusionDetection, evidence forces recon AFTER break-into"
stage Plan_Recognition/IntrusionDetection pb1.pddl intrusion-detection.pddl
if bash "$PLANNER" pb1.pddl --domain intrusion-detection.pddl \
     --pddl-evidence '(occur-in-order (break-into perseus) (recon perseus))' >log 2>&1 \
   && embedded_in_order pb1.answer "BREAK-INTO PERSEUS" "RECON PERSEUS"; then
  # The unconstrained problem solves at 3 slices; fitting recon strictly after
  # break-into needs a 4th, so the evidence must have pushed the horizon.
  if grep -q "unsatisfiable with 3 time slices" log; then pass
  else fail "expected 3 slices to be unsatisfiable under the evidence"; fi
else
  fail "no plan, or break-into..recon order not embedded"
  tail -5 log | sed 's/^/      | /'
fi

# Negative tests: each bad evidence form must fail with its contextual error.
neg_test() {
  local label="$1" evidence="$2" expect="$3"
  printf '  %-52s ... ' "$label"
  stage Plan_Recognition/IntrusionDetection pb1.pddl intrusion-detection.pddl
  if bash "$PLANNER" pb1.pddl --domain intrusion-detection.pddl \
       --pddl-evidence "$evidence" >log 2>&1; then
    fail "expected an error, but the planner succeeded"
  elif grep -qi "$expect" log; then
    pass
  else
    fail "wrong error (expected: $expect)"
    tail -5 log | sed 's/^/      | /'
  fi
}

neg_test "empty sequence rejected" \
  '(occur-in-order)' "requires at least one action"
neg_test "variable in observed action rejected" \
  '(occur-in-order (recon ?h))' "ground actions only"
neg_test "unknown action rejected" \
  '(occur-in-order (hack perseus))' "unknown action"
neg_test "unknown object rejected" \
  '(occur-in-order (recon mars))' "not an object of type"
neg_test "occur-in-order under forall rejected" \
  '(forall (?h - host) (occur-in-order (recon ?h)))' "not under.*forall"

printf '  %-52s ... ' "never-executable observation rejected (static guard)"
stage LogisticsCosts pb6.pddl logistics-costs.pddl
if bash "$PLANNER" pb6.pddl --domain logistics-costs.pddl \
     --pddl-evidence '(occur-in-order (drive-truck t1 l1 l2 c1))' >log 2>&1; then
  fail "expected an error, but the planner succeeded"
elif grep -qi "never.*executable" log; then
  pass
else
  fail "wrong error (expected: never executable)"
  tail -5 log | sed 's/^/      | /'
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
