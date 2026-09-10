#!/bin/bash
#
# run-test-odds.sh -- the :odds sugar, at every site that takes a cost.
#
# FiFO scores a model by P(x) ~ exp(-cost(x)), so a cost THETA multiplies the odds
# in the weighted thing's favour by exp(-THETA).  :odds R asks for that factor
# directly.  The sign is NOT the same at every site, which is the whole reason the
# sugar exists:
#
#   (weight phi :odds R)              -> cost    -ln R   (a cost ON phi)
#   (:action ... :odds R)             -> cost    -ln R   (a cost on its Occurs)
#   (:fluent-cost lit :odds R)        -> cost    -ln R   (emitted as a weight)
#   (preference n phi :odds R)        -> weight  +ln R   (a VIOLATION penalty)
#
# The load-bearing cases are the semantic ones: that :odds 2 really does make a
# free atom twice as likely (P = 2/3), and that the same :odds 2 written at a
# preference comes out with the OPPOSITE sign and still means "twice as likely".
# Checking the arithmetic alone would pass with both signs wrong in the same way.
#
# Run from anywhere:  bash tests/run-test-odds.sh
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
ok()  { printf '  %-58s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-58s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
# near <got> <want> -- equal to 1e-6
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<1e-6)}'; }

LN2=$(awk 'BEGIN{printf "%.10f", log(2)}')
LN3=$(awk 'BEGIN{printf "%.10f", log(3)}')

inst() { printf '%s\n' "$1" > in.wff
  sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" \
       --eval "(instantiate \"$TMP/in.wff\" :scnfile \"$TMP/out.scnf\")" 2>&1; }

echo "=== the :odds sugar ==="

# --- 1. FiFO (weight ... :odds R): a cost, so -ln R -------------------------
inst '(weight a :odds 2)
(weight b :odds 1)
(weight c :odds 0.5)
(weight d 3.0)' > inst.log 2>&1
W() { sed -n "s/^(WEIGHT $1 \(.*\))$/\1/p" out.scnf | tr -d 'd0' | sed 's/[dD]$//'; }
GA=$(sed -n 's/^(WEIGHT A \(.*\))$/\1/p' out.scnf | sed 's/d0$//')
GB=$(sed -n 's/^(WEIGHT B \(.*\))$/\1/p' out.scnf | sed 's/d0$//')
GC=$(sed -n 's/^(WEIGHT C \(.*\))$/\1/p' out.scnf | sed 's/d0$//')
GD=$(sed -n 's/^(WEIGHT D \(.*\))$/\1/p' out.scnf | sed 's/d0$//')
near "$GA" "-$LN2" && ok "(weight a :odds 2) is the cost -ln 2" \
                   || bad "(weight a :odds 2) is the cost -ln 2" "got $GA, want -$LN2"
near "$GB" 0       && ok "(weight b :odds 1) is cost 0 (even money)" \
                   || bad "(weight b :odds 1) is cost 0" "got $GB"
near "$GC" "$LN2"  && ok "(weight c :odds 0.5) is the cost +ln 2" \
                   || bad "(weight c :odds 0.5) is the cost +ln 2" "got $GC, want $LN2"
[[ "$GD" == "3" ]] && ok "a plain numeric weight is untouched" \
                   || bad "a plain numeric weight is untouched" "got $GD, want 3"

# --- 2. what it MEANS: exact marginals on a free atom -----------------------
# P = R/(1+R) when the atom is otherwise free.  This is the case that pins the
# SIGN -- the magnitudes above would pass with every sign flipped.
if bash "$BIN/marginals.sh" out.scnf --solver maxent > marg.txt 2>&1; then
  PA=$(sed -n 's/^(MARGINAL A \(.*\))$/\1/p' marg.txt)
  PC=$(sed -n 's/^(MARGINAL C \(.*\))$/\1/p' marg.txt)
  PB=$(sed -n 's/^(MARGINAL B \(.*\))$/\1/p' marg.txt)
  near "$PA" 0.666667 && ok ":odds 2 makes a free atom twice as likely (P=2/3)" \
                      || bad ":odds 2 makes a free atom twice as likely" "P(a)=$PA, want 0.666667"
  near "$PC" 0.333333 && ok ":odds 0.5 halves it (P=1/3)" \
                      || bad ":odds 0.5 halves it" "P(c)=$PC, want 0.333333"
  near "$PB" 0.5      && ok ":odds 1 is even money (P=1/2)" \
                      || bad ":odds 1 is even money" "P(b)=$PB"
else
  bad "exact marginals for the :odds semantics" "$(head -1 marg.txt)"
fi

# --- 3. R is a FACTOR on the theory's baseline, not an absolute R:1 ---------
# (and c d) over free c,d has baseline odds 1:3, so :odds 0.5 lands at 1:6 --
# P = 1/7, NOT 1/3.  Pinned because the docstring makes exactly this claim.
inst '(weight (and c d) :odds 0.5)' >/dev/null 2>&1
if bash "$BIN/marginals.sh" out.scnf --solver maxent --weighted-only > m2.txt 2>&1; then
  PW=$(sed -n 's/^(MARGINAL (WEIGHTED-FORMULA 1) \(.*\))$/\1/p' m2.txt)
  near "$PW" 0.142857 \
    && ok ":odds multiplies the baseline odds (compound: P=1/7)" \
    || bad ":odds multiplies the baseline odds (compound)" "P=$PW, want 0.142857 (1/7)"
else
  bad ":odds multiplies the baseline odds (compound)" "$(head -1 m2.txt)"
fi

# --- 4. FiFO error paths ----------------------------------------------------
werr() { inst "$1" 2>&1 | grep -qi -- "$2" && ok "$3" || bad "$3" "got: $(inst "$1" 2>&1 | grep -io 'odds[^\"]*' | head -1)"; }
werr '(weight a :odds 0)'    "positive real" "(weight a :odds 0) is refused"
werr '(weight a :odds -1)'   "positive real" "(weight a :odds -1) is refused"
werr '(weight a :odds 2 3)'  "exactly one"   "(weight a :odds 2 3) is refused"
# (probability ...) must NOT quietly accept it: :odds is a FACTOR on the theory's
# odds, a probability target holds OUTRIGHT.  Same spelling, different guarantee.
werr '(probability a :odds 2)' "sugar on (weight" ":odds on (probability ...) is refused, naming both forms"
inst '(probability a 0.75)' >/dev/null 2>&1
grep -q '(PROBABILITY A 0.75' out.scnf && ok "a plain probability target still works" \
                                       || bad "a plain probability target still works" "$(grep -i prob out.scnf | head -1)"

# --- 5. PDDL: the three sites ----------------------------------------------
cat > dom.pddl <<'PDDL'
(define (domain sw)
   (:requirements :strips :negative-preconditions :action-costs)
   (:predicates (on ?x))
   (:functions (total-cost))
   (:action turn-on  :parameters (?x) :precondition (not (on ?x))
      :effect (on ?x) :odds 2)
   (:action turn-off :parameters (?x) :precondition (on ?x)
      :effect (not (on ?x)) :cost 2))
PDDL
cat > prob.pddl <<'PDDL'
(define (problem sw3) (:domain sw) (:objects s1 s2)
   (:init (on s1) (= (total-cost) 0))
   (:fluent-cost (on s2) :odds 3)
   (:goal (and (not (on s1)) (preference p1 (on s2) :odds 2))))
PDDL
bash "$BIN/planner.sh" prob.pddl --domain dom.pddl --numslices 3 --stop-after wff \
     > wff.log 2>&1
AC=$(sed -n 's/.*(cost (turn-on x) \(.*\))).*/\1/p' prob.wff | sed 's/d0$//')
FC=$(sed -n 's/.*(weight (holds (on s2) s) \(.*\))).*/\1/p' prob.wff | sed 's/d0$//')
PV=$(sed -n 's/^(weight (pref-violated p1) \(.*\))$/\1/p' prob.wff | sed 's/d0$//')
near "$AC" "-$LN2" && ok "an action's :odds 2 is the cost -ln 2" \
                   || bad "an action's :odds 2 is the cost -ln 2" "got '$AC'"
near "$FC" "-$LN3" && ok ":fluent-cost :odds 3 is the cost -ln 3" \
                   || bad ":fluent-cost :odds 3 is the cost -ln 3" "got '$FC'"
# THE case: same :odds 2, opposite sign, because a preference weight is a penalty
# for VIOLATING it.  Both spellings mean "twice as likely".
near "$PV" "$LN2"  && ok "a preference's :odds 2 is the PENALTY +ln 2" \
                   || bad "a preference's :odds 2 is the PENALTY +ln 2" "got '$PV'"
if near "$AC" "-$LN2" && near "$PV" "$LN2"; then
  ok "the same :odds 2 is signed per site (-ln2 cost vs +ln2 penalty)"
else
  bad "the same :odds 2 is signed per site" "action $AC, preference $PV"
fi

# --- 6. :odds R equals writing the number out ------------------------------
sed "s/:odds 2/:cost -$LN2/" dom.pddl > dom-n.pddl
sed -e "s/(on s2) :odds 3/(on s2) -$LN3/" -e "s/(on s2) :odds 2/(on s2) $LN2/" prob.pddl > prob-n.pddl
bash "$BIN/planner.sh" prob-n.pddl --domain dom-n.pddl --numslices 3 --stop-after wff \
     >> wff.log 2>&1
if diff <(sed -e 's/prob\.pddl/P/;s/dom\.pddl/D/' prob.wff | sed 's/[0-9]\{6,\}[0-9]*d0/NUM/g') \
        <(sed -e 's/prob-n\.pddl/P/;s/dom-n\.pddl/D/' prob-n.wff | sed 's/[0-9]\{6,\}/NUM/g') \
     > tdiff.txt 2>&1; then
  ok ":odds R translates the same as writing the number"
else
  bad ":odds R translates the same as writing the number" "$(grep '^[<>]' tdiff.txt | head -2 | tr '\n' ' ')"
fi

# --- 7. PDDL error paths ---------------------------------------------------
perr() { local label="$1" pat="$2" sedexp="$3" which="$4"
  if [[ "$which" == dom ]]; then sed "$sedexp" dom.pddl > e-d.pddl; D=e-d.pddl; P=prob.pddl
  else sed "$sedexp" prob.pddl > e-p.pddl; D=dom.pddl; P=e-p.pddl; fi
  local out; out="$(bash "$BIN/planner.sh" "$P" --domain "$D" --numslices 3 --stop-after wff 2>&1)"
  grep -qi -- "$pat" <<<"$out" && ok "$label" || bad "$label" "got: $(grep -io 'odds.*\|has both.*' <<<"$out" | head -1)"; }
perr "an action's :odds 0 is refused"          "positive real"  's/:odds 2/:odds 0/'                dom
perr "an action's :odds with :cost is refused" "has both :odds" 's/:odds 2/:odds 2 :cost 5/'        dom
perr "an action's :odds with :probability"     "has both :odds" 's/:odds 2/:odds 2 :probability 0.5/' dom
perr ":fluent-cost :odds 0 is refused"         "positive real"  's/(on s2) :odds 3/(on s2) :odds 0/' prob
perr "a preference's :odds 0 is refused"       "positive real"  's/(on s2) :odds 2/(on s2) :odds 0/' prob

# --- 8. recognize.sh reads :odds in a hypothesis preference ----------------
# Its prior is pi ~ exp(w), so :odds R is prior weight R exactly -- the reason
# the sugar and --priors-from-preferences compose.
HAVE=0; python3 -c "import pysat" >/dev/null 2>&1 && HAVE=1
REC="$REPO/SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts"
if [[ "$HAVE" -eq 1 && -d "$REC" ]]; then
  cp "$REC"/{intrusion-detection-costs.pddl,problem.pddl,evidence-3.txt} .
  mk() { sed "s|(:goal|(:goal (and|; s|(hyp9)))|(hyp9)) $1))|" problem.pddl > "$2"; }
  mk "(preference h0 (hyp0) :odds 2)" r-odds.pddl
  mk "(preference h0 (hyp0) $LN2)"    r-num.pddl
  for v in odds num; do
    bash "$BIN/recognize.sh" intrusion-detection-costs.pddl r-$v.pddl evidence-3.txt \
         --horizon 6 --priors-from-preferences --out rr-$v >/dev/null 2>&1
  done
  PR=$(awk -F'\t' '$1=="hyp0"{print $6}' rr-odds/summary.tsv 2>/dev/null)
  if [[ -s rr-odds/summary.tsv ]] && near "${PR:-0}" 2.0; then
    ok "recognize.sh reads :odds 2 as prior weight 2"
  else
    bad "recognize.sh reads :odds 2 as prior weight 2" "prior column was '${PR:-<none>}'"
  fi
  if [[ -s rr-odds/summary.tsv ]] && diff -q rr-odds/summary.tsv rr-num/summary.tsv >/dev/null 2>&1; then
    ok ":odds 2 and the inline ln 2 agree exactly"
  else
    bad ":odds 2 and the inline ln 2 agree exactly" "$(diff rr-odds/summary.tsv rr-num/summary.tsv 2>&1 | head -2 | tr '\n' ' ')"
  fi
else
  echo "  (no python-sat -- skipping the recognize.sh cases)"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
