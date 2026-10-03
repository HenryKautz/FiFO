#!/bin/bash
#
# run-test-tseitin.sh -- the compact encoding's auxiliary (TSEITIN n) atoms.
#
# When the compact encoding (on by default) clausifies an OR of two multi-clause
# sub-formulas, it introduces a selector atom instead of multiplying the clauses
# out.  That selector used to be an uninterned gensym, #:XX711, with two faults:
#
#   * it did not survive the scnf round trip -- READ makes a new symbol for every
#     occurrence, so each clause got its own unconstrained selector and the
#     disjunction constrained NOTHING: an UNSAT theory was reported SAT, and a
#     valid `prove` came back COUNTEREXAMPLE;
#   * even with a stable name it was not DETERMINED -- free whenever both sides
#     held -- so every model counter over-counted.
#
# It is now (TSEITIN n), defined as exactly one side of the OR (definitions
# asserted at top level, where an enclosing OR cannot weaken them), so every new
# atom is a function of the theory's own atoms and SAT, MaxSAT, model counts and
# marginals are all exact.  Every reader also refuses an uninterned symbol.
#
# The load-bearing case is the PROPERTY test (tseitin-property.lisp): random
# formulas, compact ON and OFF, through the real file round trip, against a
# brute-force truth-table count sharing no code with FiFO.  It refuses to pass
# if the compact encoding never fired.  Mutation-checked: dropping the D -> S
# clause gives 61 mismatches in 300 trials, dropping the d -> H clauses 49, and
# returning the definitions inside the OR (so an enclosing OR distributes over
# them -- the first version of the fix) 34.
#
# Run from anywhere:  bash tests/run-test-tseitin.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"
BIN="$REPO/bin"
command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

PASS=0; FAIL=0
ok()  { printf '  %-62s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-62s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<1e-6)}'; }
lisp() { sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" "$@" 2>&1; }
marg() { sed -n "s/^(MARGINAL $1 \([^)]*\))\$/\1/p" "$2"; }

echo "=== compact-encoding auxiliary atoms ==="

# 23 models over a..g: abcd (8 settings of e,f,g) + efg (16 of a..d) - both (1).
# 4 clauses OR 3: the explicit product is 12 clauses, the compact encoding 8, so
# the selector is used.  (A smaller OR, e.g. 3 OR 2, is multiplied out: see the
# cutoff in multiply-clauses.)
DISJ='(or (and a b c d) (and e f g))'
printf '%s\n' "$DISJ" > disj.wff
lisp --eval '(instantiate "disj.wff")' >/dev/null
grep -q '(TSEITIN 1)' disj.scnf \
  && ok "the disjunction is compact-encoded with a (TSEITIN n) atom" \
  || bad "the disjunction is compact-encoded with a (TSEITIN n) atom" "no TSEITIN in: $(head -2 disj.scnf | tr '\n' ' ')"
grep -q '#:' disj.scnf \
  && bad "no uninterned symbol reaches the scnf" "$(grep '#:' disj.scnf | head -1)" \
  || ok "no uninterned symbol reaches the scnf"

# --- 1. SAT and prove: the answers the gensym got wrong ----------------------
printf '%s\n(not a)\n(not e)\n' "$DISJ" > unsat.wff
OUT="$(bash "$BIN/solve.sh" unsat.wff 2>&1)"
grep -qx 'UNSAT' <<<"$OUT" && ok "an UNSAT compact-encoded theory is UNSAT (was: SAT)" \
                           || bad "an UNSAT compact-encoded theory is UNSAT" "$(grep -v '^;' <<<"$OUT" | head -1)"

# The theory entails all three disjunctions, and the NEGATED goal is an OR of
# three conjunctions, which needs a selector too.
printf '%s\n(prove () true (and (or a e) (or b f) (or c g)))\n' "$DISJ" > prove.wff
OUT="$(bash "$BIN/solve.sh" prove.wff 2>&1)"
grep -qx 'PROVEN' <<<"$OUT" && ok "a valid prove through a compact query is PROVEN (was: COUNTEREXAMPLE)" \
                            || bad "a valid prove through a compact query is PROVEN" "$(grep -v '^;' <<<"$OUT" | head -1)"

# A model is reported without its selectors, and the header counts what it lists
# (it used to count only parenthesised lines, so bare 0-ary atoms read as 0).
OUT="$(bash "$BIN/solve.sh" disj.wff 2>&1)"
grep -q 'TSEITIN' <<<"$OUT" && bad "an answer lists no TSEITIN atoms" "$(grep TSEITIN <<<"$OUT" | head -1)" \
                            || ok "an answer lists no TSEITIN atoms"
N=$(sed -n 's/^; SAT .* the \([0-9]*\) atom(s).*/\1/p' <<<"$OUT")
L=$(grep -v '^;' <<<"$OUT" | tail -n +2 | grep -c .)
[[ -n "$N" && "$N" == "$L" ]] && ok "the SAT header counts the atoms it lists ($L)" \
                              || bad "the SAT header counts the atoms it lists" "header '$N', lines $L"

# --- 2. counting: exact, and the selectors hidden ----------------------------
bash "$BIN/marginals.sh" disj.scnf --solver maxent > m.txt 2>&1
# P(a) = (8 + 8 - 1)/23 = 15/23, P(e) = (16 + 4 - 1)/23 = 19/23.
if near "$(marg A m.txt)" 0.652174 && near "$(marg E m.txt)" 0.826087; then
  ok "marginals are exact: P(a)=15/23, P(e)=19/23"
else
  bad "marginals are exact: P(a)=15/23, P(e)=19/23" "P(a)=$(marg A m.txt) P(e)=$(marg E m.txt)"
fi
grep -q TSEITIN m.txt && bad "marginal listings hide TSEITIN atoms" "$(grep TSEITIN m.txt | head -1)" \
                      || ok "marginal listings hide TSEITIN atoms"

# A weight on a quantified formula is now compact-encoded too (reify-formula used
# to force the encoding OFF, because of the gensyms): far smaller, same answer.
printf '(weight (exists x (range 1 4) true (and (p x) (q x) (r x))) 1.5)\n' > wex.wff
lisp --eval '(let ((*compact-encoding* t)) (instantiate "wex.wff" :scnfile "wex-on.scnf"))' \
     --eval '(let ((*compact-encoding* nil)) (instantiate "wex.wff" :scnfile "wex-off.scnf"))' >/dev/null
bash "$BIN/marginals.sh" wex-on.scnf --solver maxent --weighted-only > won.txt 2>&1
bash "$BIN/marginals.sh" wex-off.scnf --solver maxent --weighted-only > woff.txt 2>&1
CON=$(grep -c '^(OR' wex-on.scnf); COFF=$(grep -c '^(OR' wex-off.scnf)
PON=$(marg '(WEIGHTED-FORMULA 1)' won.txt); POFF=$(marg '(WEIGHTED-FORMULA 1)' woff.txt)
if [[ -n "$PON" ]] && near "$PON" "$POFF" && (( CON < COFF )); then
  ok "a weighted exists: compact $CON clauses vs $COFF, same P ($PON)"
else
  bad "a weighted exists: compact smaller, same P" "clauses $CON vs $COFF, P $PON vs $POFF"
fi

# --- 3. the property test -----------------------------------------------------
if FIFO="$FIFO" SEED=1 TRIALS=400 sbcl --noinform --non-interactive \
     --load "$SCRIPT_DIR/tseitin-property.lisp" > prop.txt 2>&1; then
  ok "random formulas: compact = explicit = truth table ($(sed -n 's/.*with TSEITIN atoms \([0-9]*\).*/\1/p' prop.txt) used TSEITIN)"
else
  bad "random formulas: compact = explicit = truth table" "$(grep -m1 'MISMATCH\|trials' prop.txt)"
fi

# --- 4. the two gold theories, against counts computed by hand ---------------
# nested_exists_compact: some girl loved by >= 2 of 4 boys, 16 atoms:
#   2^16 - (1+4)^4 = 64911.
# alldiff: some girl loved by >= 3 of the 7 other children, 28 atoms:
#   2^28 - (1+7+21)^4 = 267728175.
# Compact-off is infeasible for both (the explicit product is astronomical), so a
# closed form is the only independent oracle.  Counted over ALL atoms, auxiliary
# ones included: by FiFO's own d-DNNF compiler for the small one, and by
# SharpSAT-TD for alldiff, which exhausts that compiler's heap.
lisp --eval "(instantiate \"$REPO/tests/passed_instantiate/test_nested_exists_compact.wff\" :scnfile \"nested.scnf\")" \
     --eval "(instantiate \"$REPO/tests/passed_instantiate/test_alldiff.wff\" :scnfile \"alldiff.scnf\")" >/dev/null
Z=$(sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/ddnnf.lisp\")" \
         --eval '(format t "Z=~D~%" (round (ddnnf-query (ddnnf-compile "nested.scnf" :verbose nil))))' 2>&1 \
    | sed -n 's/^Z=//p')
[[ "$Z" == 64911 ]] && ok "test_nested_exists_compact has exactly 64911 models" \
                    || bad "test_nested_exists_compact has exactly 64911 models" "got '$Z'"
if command -v sharpSAT >/dev/null 2>&1; then
  Z=$(bash "$BIN/wmc.sh" alldiff.scnf --counter sharpsat-td 2>&1 | sed -n 's/^(WMC \(.*\))$/\1/p')
  near "${Z:-0}" 267728175 && ok "test_alldiff has exactly 267728175 models" \
                           || bad "test_alldiff has exactly 267728175 models" "got '$Z'"
else
  echo "  (no sharpSAT -- skipping the test_alldiff count)"
fi

# --- 5. numbering never collides ---------------------------------------------
# Evidence is clausified by a SEPARATE parse that restarts at 1, then conjoined
# with a theory that has its own (TSEITIN 1).  The EVIDENCE namespace keeps them
# apart; without it the answer is silently wrong (measured: P(a)=0 for 1/3).
EV='(or (and a (not c) d) (and (not a) e f g))'
# EV2 leaves two models (P(b)=1/2); a namespace collision would equate its
# selector with EV's, adding a&~c&d == b&c&d and cutting one (measured: P(b)=0).
EV2='(or (and b c d) (and (not b) (not c) (not d)))'
cmp_marg() {   # cmp_marg <file> <ref> -- every atom of <ref> agrees in <file>
  local a
  for a in A B C D E F G; do near "$(marg $a "$1")" "$(marg $a "$2")" || return 1; done
}
printf '%s\n%s\n' "$DISJ" "$EV" > both.wff
lisp --eval '(instantiate "both.wff")' >/dev/null
bash "$BIN/marginals.sh" both.scnf --solver maxent > ref.txt 2>&1
bash "$BIN/marginals.sh" disj.scnf --solver ddnnf --evidence "$EV" > ev.txt 2>&1
if cmp_marg ev.txt ref.txt && ! near "$(marg A ref.txt)" "$(marg A m.txt)"; then
  ok "compound --evidence = the same evidence instantiated in (ddnnf)"
else
  bad "compound --evidence = the same evidence instantiated in (ddnnf)" \
      "P(a) $(marg A ev.txt) vs $(marg A ref.txt); $(grep -v '^(' ev.txt | head -1)"
fi
OUT="$(lisp --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
             --eval "(format t \"~S~%\" (wmc--evidence-clauses (list '$EV) nil))")"
grep -q 'TSEITIN EVIDENCE' <<<"$OUT" && ok "evidence auxiliaries are namespaced (TSEITIN EVIDENCE n)" \
                                     || bad "evidence auxiliaries are namespaced" "$(tail -1 <<<"$OUT")"
if command -v sharpSAT >/dev/null 2>&1; then
  bash "$BIN/marginals.sh" disj.scnf --solver sharpsat-td --evidence "$EV" > ev2.txt 2>&1
  cmp_marg ev2.txt ref.txt \
    && ok "compound --evidence = instantiated (sharpsat-td)" \
    || bad "compound --evidence = instantiated (sharpsat-td)" "P(a) $(marg A ev2.txt)"
else
  echo "  (no sharpSAT -- skipping the sharpsat-td evidence case)"
fi
# Conditioning a theory that ALREADY holds (TSEITIN EVIDENCE n) atoms -- as the
# conditioned scnf hypotheses.lisp writes to disk does -- must not reuse those
# names: the second evidence parse picks the namespace EVIDENCE2.
lisp --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
     --eval "(let ((th (rw--read-scnf \"disj.scnf\")))
               (with-open-file (o \"cond.scnf\" :direction :output :if-exists :supersede)
                 (dolist (c (append th (wmc--evidence-clauses (list '$EV) nil th)))
                   (format o \"~S~%\" c))))" >/dev/null
printf '%s\n%s\n%s\n' "$DISJ" "$EV" "$EV2" > both2.wff
lisp --eval '(instantiate "both2.wff")' >/dev/null
bash "$BIN/marginals.sh" both2.scnf --solver maxent > ref2.txt 2>&1
bash "$BIN/marginals.sh" cond.scnf --solver ddnnf --evidence "$EV2" > ev3.txt 2>&1
if grep -q 'TSEITIN EVIDENCE' cond.scnf && near "$(marg B ref2.txt)" 0.5 && cmp_marg ev3.txt ref2.txt; then
  ok "re-conditioning a conditioned theory does not reuse its names"
else
  bad "re-conditioning a conditioned theory does not reuse its names" \
      "P(a) $(marg A ev3.txt) vs $(marg A ref2.txt); $(grep -v '^(' ev3.txt | head -1)"
fi
# The planner's evidence and prove's query are parsed with parse-same-env, which
# CONTINUES the theory's numbering rather than restarting it.
OUT="$(lisp --eval "(progn (parse '($DISJ))
                           (format t \"~S~%\" (parse-same-env '($EV))))")"
grep -q '(TSEITIN 1)' <<<"$(tail -1 <<<"$OUT")" \
  && bad "parse-same-env continues the numbering (no second (TSEITIN 1))" "$(tail -1 <<<"$OUT")" \
  || ok "parse-same-env continues the numbering (no second (TSEITIN 1))"

# --- 6. the names are reserved -------------------------------------------------
# A user atom spelled (tseitin 1) would BE the selector: it would constrain it,
# and interpret would drop it from the answer.  So the names are refused.
printf '%s\n(not (tseitin 1))\n' "$DISJ" > user.wff
OUT="$(lisp --eval '(instantiate "user.wff")')"
grep -q 'reserved' <<<"$OUT" && ok "a user atom named (tseitin ...) is refused" \
                             || bad "a user atom named (tseitin ...) is refused" "$(tail -1 <<<"$OUT")"
OUT="$(bash "$BIN/marginals.sh" disj.scnf --solver ddnnf --evidence '(tseitin 9)' 2>&1)"
grep -q 'reserved' <<<"$OUT" && ok "evidence naming a stray (tseitin ...) atom is refused" \
                             || bad "evidence naming a stray (tseitin ...) atom is refused" "$(tail -1 <<<"$OUT")"

# --- 7. the guard: an uninterned symbol is refused, not misread --------------
printf '(OR #:XX1 A)\n(OR (NOT #:XX1) B)\n' > stale.scnf
OUT="$(lisp --eval '(propositionalize "stale.scnf")')"
grep -q 'uninterned symbol' <<<"$OUT" && ok "propositionalize refuses a stale scnf with a gensym" \
                                      || bad "propositionalize refuses a stale scnf with a gensym" "$(tail -1 <<<"$OUT")"
OUT="$(bash "$BIN/marginals.sh" stale.scnf --solver maxent 2>&1)"
grep -q 'uninterned symbol' <<<"$OUT" && ok "the counters refuse it too (rw--read-scnf)" \
                                      || bad "the counters refuse it too (rw--read-scnf)" "$(tail -1 <<<"$OUT")"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
