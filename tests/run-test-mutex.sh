#!/bin/bash
#
# run-test-mutex.sh -- the (mutex G1 G2) form and its two encodings.
#
# (mutex (v1 D1 g1 phi1) (v2 D2 g2 phi2)) asserts not (phi1[c] and phi2[d]) for
# every label c of the first family and d of the second with c /= d.  FiFO writes
# it as one clause per pair, or -- when smaller -- as a linear chain of DEFINED
# (TSEITIN n) atoms; (option *mutex-pairwise* 1) forces the pairs.  Both must
# have exactly the models of the definition.
#
#   1. closed forms: at-most-one of 20 atoms has 21 models; two disjoint families
#      of 10 have 2^10 + 2^10 - 1; counted over every atom, auxiliary ones
#      included, so a free or under-defined atom doubles the count.
#   2. the property test (mutex-property.lisp): random families, guards, member
#      formulas and overlaps, default / pairwise / compact-off, each against the
#      definition written out pair by pair and counted by its own DPLL counter.
#      Mutation-checked: see its header.
#   3. the switch: (option *mutex-pairwise* 1) writes the pairs and no atom, and
#      lasts only for its own file.
#   4. SatPlan: a costed logistics problem has the same optimal plan cost with
#      the interfering-action mutexes linear and pairwise, from fewer clauses.
#   5. misuse is refused: a negated mutex, a malformed one, one in a static form.
#
# Run from anywhere:  bash tests/run-test-mutex.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"
BIN="$REPO/bin"
command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }

# No '.' in the path: map.sh derives its scratch names from the first dot.
TMP="$(mktemp -d /tmp/fifo-mutex-XXXXXX)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

PASS=0; FAIL=0
ok()  { printf '  %-66s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-66s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
lisp() { sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" "$@" 2>&1; }
clauses() { grep -c '^(OR' "$1"; }
# Exact model count of an scnf over all its atoms, by FiFO's d-DNNF compiler.
count() {
  sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/ddnnf.lisp\")" \
       --eval "(format t \"Z=~D~%\" (round (ddnnf-query (ddnnf-compile \"$1\" :verbose nil))))" 2>&1 \
    | sed -n 's/^Z=//p'
}

echo "=== mutex ==="

# --- 1. closed forms -----------------------------------------------------------
printf '(domain d (range 1 20))\n(mutex (i d true (p i)) (j d true (p j)))\n' > amo.wff
lisp --eval '(instantiate "amo.wff")' >/dev/null
N=$(clauses amo.scnf)
grep -q TSEITIN amo.scnf && (( N < 190 )) \
  && ok "at-most-one of 20 is linear: $N clauses, not the 190 pairs" \
  || bad "at-most-one of 20 is linear" "$N clauses, TSEITIN: $(grep -c TSEITIN amo.scnf)"
Z=$(count amo.scnf)
[[ "$Z" == 21 ]] && ok "at-most-one of 20 has exactly 21 models" \
                 || bad "at-most-one of 20 has exactly 21 models" "got '$Z'"

printf '(mutex (i (range 1 10) true (p i)) (j (range 11 20) true (p j)))\n' > bi.wff
lisp --eval '(instantiate "bi.wff")' >/dev/null
Z=$(count bi.scnf)
[[ "$Z" == 2047 ]] && ok "two disjoint families of 10 have 2^10+2^10-1 = 2047 models" \
                   || bad "two disjoint families of 10 have 2047 models" "got '$Z' ($(clauses bi.scnf) clauses)"

# A label in both families is not excluded against itself: (p 1) may hold with
# (q 1) but not with (q 2).  Over p1 p2 q1 q2: 16 - 4 (p1&q2) - 4 (p2&q1) + 1 = 9.
printf '(mutex (i (set 1 2) true (p i)) (j (set 1 2) true (q j)))\n' > diag.wff
lisp --eval '(instantiate "diag.wff")' >/dev/null
Z=$(count diag.scnf)
[[ "$Z" == 9 ]] && ok "equal labels are not excluded: 9 models over p1 p2 q1 q2" \
                || bad "equal labels are not excluded: 9 models" "got '$Z'"

# --- 2. the property test ------------------------------------------------------
if FIFO="$FIFO" SEED=1 TRIALS=150 sbcl --noinform --non-interactive \
     --load "$SCRIPT_DIR/mutex-property.lisp" > prop.txt 2>&1; then
  ok "random mutexes: default = pairwise = compact-off = definition ($(sed -n 's/.*linear encoding used \([0-9]*\).*/\1/p' prop.txt) linear)"
else
  bad "random mutexes: default = pairwise = compact-off = definition" "$(grep -m1 'MISMATCH\|trials\|rror' prop.txt)"
fi

# --- 3. the switch -------------------------------------------------------------
printf '(option *mutex-pairwise* 1)\n(include "amo.wff")\n' > amo-pair.wff
lisp --eval '(instantiate "amo-pair.wff")' --eval '(instantiate "amo.wff" :scnfile "amo-after.scnf")' >/dev/null
N=$(clauses amo-pair.scnf)
[[ "$N" == 190 ]] && ! grep -q TSEITIN amo-pair.scnf \
  && ok "(option *mutex-pairwise* 1) writes the 190 pairs and no atom" \
  || bad "(option *mutex-pairwise* 1) writes the 190 pairs and no atom" "$N clauses"
Z=$(count amo-pair.scnf)
[[ "$Z" == 21 ]] && ok "... with the same 21 models" || bad "... with the same 21 models" "got '$Z'"
grep -q TSEITIN amo-after.scnf \
  && ok "the option lasts only for its file (the next one is linear again)" \
  || bad "the option lasts only for its file" "$(clauses amo-after.scnf) clauses, no TSEITIN"

# --- 4. SatPlan ----------------------------------------------------------------
if [[ -x "$(command -v EvalMaxSAT_bin)" ]]; then
  cp "$REPO/SatPlan/Examples/LogisticsCosts/pb3.pddl" "$REPO/SatPlan/Examples/LogisticsCosts/logistics-costs.pddl" .
  bash "$BIN/planner.sh" pb3.pddl --numslices 10 --stop-after wff >/dev/null 2>&1
  printf '(option *satplan-numslices* 10)\n(include "pb3.wff")\n' > lin.wff
  printf '(option *satplan-numslices* 10)\n(option *mutex-pairwise* 1)\n(include "pb3.wff")\n' > pair.wff
  CL=$(bash "$BIN/map.sh" lin.wff --solver evalmaxsat 2>&1 | sed -n 's/^; true cost: //p')
  CP=$(bash "$BIN/map.sh" pair.wff --solver evalmaxsat 2>&1 | sed -n 's/^; true cost: //p')
  lisp --eval '(instantiate "lin.wff")' --eval '(instantiate "pair.wff")' >/dev/null
  NL=$(clauses lin.scnf); NP=$(clauses pair.scnf)
  if [[ -n "$CL" && "$CL" == "$CP" ]] && (( NL < NP )); then
    ok "logistics pb3, 10 slices: optimal cost $CL either way; $NL vs $NP clauses"
  else
    bad "logistics pb3: same optimal cost, fewer clauses" "cost '$CL' vs '$CP', clauses $NL vs $NP"
  fi
else
  echo "  (no EvalMaxSAT_bin -- skipping the SatPlan case)"
fi

# --- 5. misuse -----------------------------------------------------------------
expect_error() {   # expect_error <label> <wff text> <message regex>
  printf '%s\n' "$2" > err.wff
  local out; out="$(lisp --eval '(instantiate "err.wff")')"
  grep -q -E "$3" <<<"$out" && ok "$1" || bad "$1" "$(grep -m1 -i 'error\|mutex' <<<"$out")"
}
expect_error "a negated mutex is refused" \
  '(not (mutex (i (set 1 2) true (p i)) (j (set 1 2) true (p j))))' 'may not be negated'
expect_error "a mutex under implies (negated antecedent) is refused" \
  '(implies (mutex (i (set 1 2) true (p i)) (j (set 1 2) true (p j))) a)' 'may not be negated'
expect_error "a malformed mutex is refused" \
  '(mutex (i (set 1 2) (p i)) (j (set 1 2) true (p j)))' 'Malformed mutex'
expect_error "a mutex with a variable list is refused" \
  '(mutex ((i k) (set 1 2) true (p i)) (j (set 1 2) true (p j)))' 'one variable per family'
expect_error "a mutex in a static form is refused" \
  '(static (mutex (i (set 1 2) true (s i)) (j (set 1 2) true (s j))))' 'static form'

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
