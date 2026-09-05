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

# Negated occur-in-order (R&G's does-not-comply case): forbidding an observation
# that the goal makes necessary must render the problem unsatisfiable.  pb1's
# goal needs (information-gathered perseus), which requires (recon perseus), so
# (not (occur-in-order (recon perseus))) -- recon perseus never occurs -- is
# unsatisfiable at every horizon.
printf '  %-52s ... ' "not-occur-in-order forbids a necessary observation"
stage Plan_Recognition/IntrusionDetection pb1.pddl intrusion-detection.pddl
bash "$PLANNER" pb1.pddl --domain intrusion-detection.pddl \
     --pddl-evidence '(not (occur-in-order (recon perseus)))' >log 2>&1
if grep -qiE "unsatisfiable|no plan exists" log && ! grep -q "^SOLVED" log; then
  pass
else
  fail "expected UNSAT (recon perseus is necessary), but a plan was found"
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

# Recognition-style marginals: a disjunctive goal (which introduces Tseitin
# auxiliary variables in the CNF) conditioned on occur-in-order evidence, under
# the maxent counter.  Guards the reweight.lisp fix that lets marginal inference
# tolerate bare Tseitin-variable literals; observing (flip a) must tilt the
# posterior toward the "a" hypothesis (R a) over the "b" hypothesis (R b).
printf '  %-52s ... ' "disjunctive-goal marginals under occur-in-order"
work="$TMP/case-$((PASS+FAIL))"; mkdir -p "$work"; cd "$work"
cat > dm.pddl <<'PDDL'
(define (domain dm)
  (:requirements :strips :typing :action-costs :disjunctive-preconditions)
  (:functions (total-cost))
  (:predicates (p ?x) (q ?x) (r ?x))
  (:action flip :parameters (?x) :precondition (p ?x)
     :effect (and (q ?x) (not (p ?x)) (increase (total-cost) 1)))
  (:action boost :parameters (?x) :precondition (q ?x)
     :effect (and (r ?x) (increase (total-cost) 1))))
PDDL
cat > pm.pddl <<'PDDL'
(define (problem pm) (:domain dm)
  (:objects a b)
  (:init (p a) (p b) (= (total-cost) 0))
  (:goal (or (and (r a) (q a)) (and (r b) (q b)))))
PDDL
if bash "$PLANNER" pm.pddl --domain dm.pddl --numslices 3 --marginals \
     --pddl-evidence '(occur-in-order (flip a))' >log 2>&1; then
  ra=$(sed -n 's/.*(MARGINAL (HOLDS (R A) 3) \([0-9.]*\)).*/\1/p' log)
  rb=$(sed -n 's/.*(MARGINAL (HOLDS (R B) 3) \([0-9.]*\)).*/\1/p' log)
  if [[ -n "$ra" && -n "$rb" ]] && awk "BEGIN{exit !($ra > $rb)}"; then pass
  else fail "expected P(R a) > P(R b), got R a=$ra R b=$rb"; fi
else
  fail "marginals crashed (Tseitin literal in disjunctive goal?)"
  tail -5 log | sed 's/^/      | /'
fi

# --- Derived predicates (:derived) ---------------------------------------------
# A nullary derived predicate equal to a conjunction, used as one disjunct of a
# disjunctive goal, plus a parameterized derived predicate with a quantified body
# that it references.  The derived atoms must be reified (holds ...) with NO frame
# axioms, and their marginals must be determined by their bodies (count-neutral).
dp_domain() {
  cat > dp.pddl <<'PDDL'
(define (domain dp)
  (:requirements :strips :typing :derived-predicates :disjunctive-preconditions)
  (:predicates (on ?x ?y - block) (ontable ?x - block) (clear ?x - block)
               (handempty) (holding ?x - block))
  (:derived (clear-d ?x - block) (forall (?y - block) (not (on ?y ?x))))
  (:derived (spells-ab) (and (on a b) (ontable b) (clear-d a)))
  (:action pick-up :parameters (?x - block)
     :precondition (and (clear ?x) (ontable ?x) (handempty))
     :effect (and (not (ontable ?x)) (not (clear ?x)) (not (handempty)) (holding ?x)))
  (:action put-down :parameters (?x - block)
     :precondition (holding ?x)
     :effect (and (not (holding ?x)) (clear ?x) (handempty) (ontable ?x)))
  (:action stack :parameters (?x ?y - block)
     :precondition (and (holding ?x) (clear ?y))
     :effect (and (not (holding ?x)) (not (clear ?y)) (clear ?x) (handempty) (on ?x ?y)))
  (:action unstack :parameters (?x ?y - block)
     :precondition (and (on ?x ?y) (clear ?x) (handempty))
     :effect (and (holding ?x) (clear ?y) (not (clear ?x)) (not (handempty)) (not (on ?x ?y)))))
PDDL
}

printf '  %-52s ... ' "derived predicate: frame-axiom exclusion + marginal"
work="$TMP/case-$((PASS+FAIL))"; mkdir -p "$work"; cd "$work"
dp_domain
cat > dp.prob <<'PDDL'
(define (problem dpp) (:domain dp)
  (:objects a b - block)
  (:init (handempty) (ontable a) (ontable b) (clear a) (clear b))
  (:goal (or (spells-ab) (on b a))))
PDDL
mv dp.prob pm2.pddl
if bash "$PLANNER" pm2.pddl --domain dp.pddl --numslices 3 --marginals >log 2>&1; then
  # SPELLS-AB / CLEAR-D must be defined by biconditionals but never framed:
  # no OCCURS/ADD/DEL clause may mention them (grep the instantiated scnf).
  scnf=$(ls *-combined.scnf pm2.scnf 2>/dev/null | head -1)
  sab=$(sed -n 's/.*(MARGINAL (HOLDS (SPELLS-AB) 3) \([0-9.]*\)).*/\1/p' log)
  if [[ -z "$sab" ]]; then
    fail "no SPELLS-AB marginal reported"; tail -5 log | sed 's/^/      | /'
  elif grep -qiE '(add|del|occurs).*(spells-ab|clear-d)' "$scnf"; then
    fail "derived atom appears in a frame/effect clause (should be definition-only)"
  else
    pass
  fi
else
  fail "derived-predicate marginals failed"; tail -5 log | sed 's/^/      | /'
fi

# All-derived (or all-static) general goal: GOAL-FLUENTS is empty while the goal
# still takes the general-formula path.  Guards the fix for the emitter's
# goal-fluents domain cycle (an empty goal-fluents must not be folded into, nor
# emitted in terms of, the fluents domain).
printf '  %-52s ... ' "all-derived disjunctive goal instantiates"
work="$TMP/case-$((PASS+FAIL))"; mkdir -p "$work"; cd "$work"
dp_domain
cat > pm2.pddl <<'PDDL'
(define (problem dpp) (:domain dp)
  (:objects a b - block)
  (:init (handempty) (ontable a) (ontable b) (clear a) (clear b))
  (:goal (or (spells-ab))))
PDDL
if bash "$PLANNER" pm2.pddl --domain dp.pddl --numslices 3 --marginals >log 2>&1 \
   && grep -q '(MARGINAL (HOLDS (SPELLS-AB) 3)' log; then
  pass
else
  fail "all-derived goal failed to instantiate/marginalize (goal-fluents cycle?)"
  tail -5 log | sed 's/^/      | /'
fi

# Bare single derived-atom goal (:goal (spells-ab)) -- simple by structure but a
# general goal because it names a derived predicate.  Guards the fix that empties
# goal+/goal- for general goals: otherwise the lone atom flows through goal-state
# into fluents and wrongly acquires frame axioms + a slice-1 default, going UNSAT.
# (This is the single-goal shape bin/recognize.sh builds per hypothesis.)
printf '  %-52s ... ' "bare single derived-atom goal solves"
work="$TMP/case-$((PASS+FAIL))"; mkdir -p "$work"; cd "$work"
dp_domain
cat > pm2.pddl <<'PDDL'
(define (problem dpp) (:domain dp)
  (:objects a b - block)
  (:init (handempty) (ontable a) (ontable b) (clear a) (clear b))
  (:goal (spells-ab)))
PDDL
if bash "$PLANNER" pm2.pddl --domain dp.pddl --minslices 3 --maxslices 5 >log 2>&1 \
   && grep -q "^SOLVED" log; then
  pass
else
  fail "bare derived-atom goal went UNSAT (goal+ leaked into goal-state/fluents?)"
  tail -5 log | sed 's/^/      | /'
fi

# Negative tests: each malformed derived use must raise its contextual error.
dp_neg() {
  local label="$1" mutate="$2" expect="$3"
  printf '  %-52s ... ' "$label"
  work="$TMP/case-$((PASS+FAIL))"; mkdir -p "$work"; cd "$work"
  dp_domain
  eval "$mutate"
  cat > pm2.pddl <<'PDDL'
(define (problem dpp) (:domain dp)
  (:objects a b - block)
  (:init (handempty) (ontable a) (ontable b) (clear a) (clear b))
  (:goal (or (spells-ab) (on b a))))
PDDL
  if bash "$PLANNER" pm2.pddl --domain dp.pddl --stop-after wff >log 2>&1; then
    fail "expected an error, but translation succeeded"
  elif grep -qi "$expect" log; then pass
  else fail "wrong error (expected: $expect)"; tail -4 log | sed 's/^/      | /'; fi
}

dp_neg "derived: recursion rejected" \
  "sed -i.bak 's|(:derived (spells-ab)|(:derived (loopy) (or (loopy) (handempty))) (:derived (spells-ab)|' dp.pddl" \
  "recursive"
dp_neg "derived: in action effect rejected" \
  "sed -i.bak 's|(holding ?x)))\$|(holding ?x) (spells-ab)))|' dp.pddl" \
  "action effect"
dp_neg "derived: in action precondition rejected" \
  "sed -i.bak 's|:precondition (holding ?x)|:precondition (and (holding ?x) (spells-ab))|' dp.pddl" \
  "precondition on derived"

# ---------------------------------------------------------------------------
# Evidence that names an atom the problem does not have.
#
# FiFO's parse mints a fresh proposition for any literal, so before the check in
# plan--resolve-evidence these ran clean and returned the UNCONDITIONED answer:
# the evidence constrained a variable that appeared in no other clause.  The two
# causes need opposite treatment -- a typo is wrong at every horizon, while a
# slice past the horizon just means this horizon is too short -- so the fixture
# below pins both, and the cost of the conditioned answer proves the evidence
# actually bound.
# ---------------------------------------------------------------------------

echo
echo "=== evidence naming atoms the problem does not have ==="

SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}"
if command -v "$SOLVER" >/dev/null 2>&1; then
  stage Switch switchprob.pddl switches.pddl
  # baseline: what the problem costs with no evidence at all
  bash "$PLANNER" switchprob.pddl --domain switches.pddl --numslices 4 >base.log 2>&1
  BASE="$(grep -oE 'cost [0-9]+' base.log | tail -1)"

  printf '  %-52s ... ' "a misspelled action in evidence is an error"
  if bash "$PLANNER" switchprob.pddl --domain switches.pddl --numslices 4 \
       --evidence '(occurs (turn-onn s1) 2)' >e1.log 2>&1; then
    fail "a misspelled action was accepted"
  elif grep -q "which this problem has at no slice" e1.log; then pass
  else fail "wrong error"; tail -3 e1.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "a misspelled fluent in evidence is an error"
  if bash "$PLANNER" switchprob.pddl --domain switches.pddl --numslices 4 \
       --evidence '(holds (onn s1) 2)' >e2.log 2>&1; then
    fail "a misspelled fluent was accepted"
  elif grep -q "which this problem has at no slice" e2.log; then pass
  else fail "wrong error"; tail -3 e2.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "a misspelled atom under (not ...) is an error too"
  if bash "$PLANNER" switchprob.pddl --domain switches.pddl --numslices 4 \
       --evidence '(not (occurs (turn-onn s1) 2))' >e3.log 2>&1; then
    fail "a negated misspelling was accepted"
  elif grep -q "which this problem has at no slice" e3.log; then pass
  else fail "wrong error"; tail -3 e3.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "a real action at a slice past the horizon is UNSAT"
  # Not an error: the atom is real, this horizon is just too short.  (Checked on
  # the output, not the exit code -- planner.sh exits 0 on a clean UNSAT verdict.)
  bash "$PLANNER" switchprob.pddl --domain switches.pddl --numslices 4 \
       --evidence '(occurs (turn-on s1) 20)' >e4.log 2>&1
  if grep -qi "unsatisfiable" e4.log && ! grep -q "at no slice" e4.log \
     && ! grep -q "cost " e4.log; then pass
  else fail "expected UNSAT, not an error and not a plan"
       tail -3 e4.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "the horizon search extends past a too-short one"
  # The same observation must not abort the search: a longer horizon can hold it.
  if bash "$PLANNER" switchprob.pddl --domain switches.pddl --minslices 3 --maxslices 9 \
       --evidence '(occurs (turn-on s1) 6)' >e5.log 2>&1 \
     && grep -q "unsatisfiable with 3 time slices" e5.log \
     && grep -qE "SOLVED with [7-9] time slices" e5.log \
     && grep -q "(OCCURS (TURN-ON S1) 6)" switchprob.answer; then pass
  else fail "search did not extend to a horizon that fits the observation"
       tail -4 e5.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "a NEGATED out-of-range literal is vacuously true"
  # Nothing can occur at slice 20 here, so (not ...) of it is satisfied and the
  # problem must solve exactly as it did unconditioned.
  if bash "$PLANNER" switchprob.pddl --domain switches.pddl --numslices 4 \
       --evidence '(not (occurs (turn-on s1) 20))' >e6.log 2>&1 \
     && [[ "$(grep -oE 'cost [0-9]+' e6.log | tail -1)" == "$BASE" ]]; then pass
  else fail "expected the unconditioned cost $BASE"
       tail -3 e6.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "evidence over a DERIVED predicate still works"
  # Derived predicates are deliberately kept OUT of the fluents domain, so a
  # check against the domains rather than the theory's atoms would reject this.
  stage DerivedPreds pb1.pddl blocks-derived.pddl
  if bash "$PLANNER" pb1.pddl --domain blocks-derived.pddl --numslices 4 \
       --evidence '(holds (spells-ab) 4)' >e7.log 2>&1 \
     && grep -q "SOLVED" e7.log; then pass
  else fail "derived-predicate evidence was rejected"; tail -3 e7.log | sed 's/^/      | /'; fi

  printf '  %-52s ... ' "a misspelled DERIVED predicate is still an error"
  if bash "$PLANNER" pb1.pddl --domain blocks-derived.pddl --numslices 4 \
       --evidence '(holds (spells-abc) 4)' >e8.log 2>&1; then
    fail "a misspelled derived predicate was accepted"
  elif grep -q "which this problem has at no slice" e8.log; then pass
  else fail "wrong error"; tail -3 e8.log | sed 's/^/      | /'; fi
else
  echo "  (skipping: no MaxSAT solver '$SOLVER' on PATH)"
fi

# ---------------------------------------------------------------------------
# occur-in-order as a :constraints operator, with an optional slice window.
#
#   (occur-in-order a1 ... ak)       anywhere            = 1 -1
#   (occur-in-order M a1 ... ak)     not before M        = M -1
#   (occur-in-order M N a1 ... ak)   within [M, N];  N = -1 is unbounded
#
# The window is a quantifier GUARD with a complementary one freezing the chain
# outside it, rather than naming slices M and N+1 -- naming a slice that may not
# exist at the current horizon would mint an unconstrained ObsDone atom and the
# constraint would go quietly vacuous.  Case 4 below is what that buys.
# ---------------------------------------------------------------------------

echo
echo "=== occur-in-order as a windowed trajectory constraint ==="

if command -v "${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" >/dev/null 2>&1; then
  CDIR="$TMP/cio"; mkdir -p "$CDIR"; cd "$CDIR"
  sed 's/:disjunctive-preconditions/:constraints :disjunctive-preconditions/' \
      "$REPO/SatPlan/clara-logistics.pddl" > dom.pddl
  bash "$REPO/SatPlan/ppgen.sh" --style clique --clique-size 3 --number-cliques 2 \
       --packages 3 --trucks 2 --airplanes 1 --preferences 1 6 \
       --goals-per-package 2 1 --seed 23 -o base.pddl 2>/dev/null
  # the plan puts A at slice 1, B at 2, C at 4; unconstrained cost 16
  A='(load pkg2 truck1 c1-air)'; B='(drive truck1 c1-air c1-p2)'; C='(fly plane1 c2-air c1-air)'
  mkprob() {   # mkprob <file> <constraint>
    python3 -c "
import sys
s=open('base.pddl').read(); i=s.index('  (:goal')
open(sys.argv[1],'w').write(s[:i]+'  (:constraints '+sys.argv[2]+')\n\n'+s[i:])" "$1" "$2"
  }
  cio() {   # cio <constraint> -> cost or UNSAT
    mkprob "$CDIR/c.pddl" "$1"
    WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" bash "$PLANNER" "$CDIR/c.pddl" \
      --domain "$CDIR/dom.pddl" --numslices 6 2>&1 \
      | grep -oE 'cost [0-9]+|UNSATISFIABLE' | tail -1
  }
  BASE="$(cio '(and (always (at pkg1 c1-p2)))' >/dev/null; cio "(and (occur-in-order $A $B $C))")"

  printf '  %-52s ... ' "the three arities agree when the window is the whole plan"
  M1="$(cio "(and (occur-in-order 1 $A $B $C))")"
  M2="$(cio "(and (occur-in-order 1 -1 $A $B $C))")"
  if [[ "$BASE" == "cost 16" && "$M1" == "$BASE" && "$M2" == "$BASE" ]]; then pass
  else fail "bare=$BASE  M=$M1  M,N=$M2"; fi

  printf '  %-52s ... ' "a window containing the plan leaves the cost alone"
  if [[ "$(cio "(and (occur-in-order 1 5 $A $B $C))")" == "cost 16" ]]; then pass
  else fail "window [1,5] should not constrain this plan"; fi

  printf '  %-52s ... ' "a window starting after the first observation is UNSAT"
  if [[ "$(cio "(and (occur-in-order 3 -1 $A $B $C))")" == "UNSATISFIABLE" ]]; then pass
  else fail "the first action is at slice 1, so [3,-1] cannot hold it"; fi

  printf '  %-52s ... ' "a window too short for k observations is UNSAT"
  if [[ "$(cio "(and (occur-in-order 1 2 $A $B $C))")" == "UNSATISFIABLE" ]]; then pass
  else fail "3 observations cannot embed in 2 slices"; fi

  printf '  %-52s ... ' "a window past the horizon is UNSAT, not vacuous"
  # The case the guard-and-freeze encoding exists for: naming slice 20 would have
  # minted an unconstrained atom and the constraint would have done nothing.
  if [[ "$(cio "(and (occur-in-order 20 30 $A $B $C))")" == "UNSATISFIABLE" ]]; then pass
  else fail "a window entirely past the horizon went vacuous"; fi

  printf '  %-52s ... ' "negation with a window flips exactly that window"
  NIN="$(cio "(and (not (occur-in-order 1 5 $A $B $C)))")"
  NOUT="$(cio "(and (not (occur-in-order 3 -1 $A $B $C)))")"
  # not(embeds in [1,5]) must force a deviation; not(embeds in [3,-1]) is already true
  if [[ "$NIN" != "cost 16" && "$NIN" != "UNSATISFIABLE" && "$NOUT" == "cost 16" ]]; then pass
  else fail "negated in=$NIN out=$NOUT"; fi

  cioerr() {   # cioerr <constraint> -> first matching error text
    mkprob "$CDIR/e.pddl" "$1"
    bash "$PLANNER" "$CDIR/e.pddl" --domain "$CDIR/dom.pddl" --numslices 6 2>&1 \
      | grep -oE "occur-in-order[^\"]{0,70}" | head -1
  }
  printf '  %-52s ... ' "an empty window [5,2] is refused"
  if cioerr "(and (occur-in-order 5 2 $A $B))" | grep -q "is empty"; then pass
  else fail "should reject a backwards window"; fi

  printf '  %-52s ... ' "a first bound below 1 is refused"
  if cioerr "(and (occur-in-order 0 3 $A))" | grep -q "at least 1"; then pass
  else fail "slices are numbered from 1"; fi

  printf '  %-52s ... ' "a third integer bound is refused"
  if cioerr "(and (occur-in-order 1 2 3 $A))" | grep -q "at most two slice bounds"; then pass
  else fail "should reject three bounds"; fi

  printf '  %-52s ... ' "bounds with no actions are refused"
  if cioerr "(and (occur-in-order 1 3))" | grep -q "at least one action"; then pass
  else fail "should require an action"; fi

  printf '  %-52s ... ' "the same three arities work as --pddl-evidence"
  ev3() { WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" bash "$PLANNER" "$CDIR/base.pddl" \
            --domain "$CDIR/dom.pddl" --numslices 6 --pddl-evidence "$1" 2>&1 \
          | grep -oE 'cost [0-9]+|UNSATISFIABLE' | tail -1; }
  if [[ "$(ev3 "(occur-in-order $A $C)")" == "cost 16" \
     && "$(ev3 "(occur-in-order 1 $A $C)")" == "cost 16" \
     && "$(ev3 "(occur-in-order 1 5 $A $C)")" == "cost 16" \
     && "$(ev3 "(occur-in-order 3 -1 $A $C)")" == "UNSATISFIABLE" ]]; then pass
  else fail "the windowed form should work in evidence too"; fi

  # --- occur-in-nonstrict-order: observations may share a slice ------------
  # The plan does A and B in PARALLEL at slice 1.  Strict ordering forces them
  # apart, claiming an order the plan never asserted; non-strict does not.
  PA='(load pkg2 truck1 c1-air)'; PB='(load pkg3 truck2 c2-p1)'

  printf '  %-52s ... ' "strict ordering serializes parallel observations"
  if [[ "$(cio "(and (occur-in-order $PA $PB))")" == "cost 17" ]]; then pass
  else fail "expected the +1 of serializing what the plan did at once"; fi

  printf '  %-52s ... ' "non-strict lets them stay in the same slice"
  if [[ "$(cio "(and (occur-in-nonstrict-order $PA $PB))")" == "cost 16" ]]; then pass
  else fail "non-strict should cost what the unconstrained plan does"; fi

  printf '  %-52s ... ' "and the plan really does keep them together"
  mkprob "$CDIR/ns.pddl" "(and (occur-in-nonstrict-order $PA $PB))"
  WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" bash "$PLANNER" "$CDIR/ns.pddl" \
    --domain "$CDIR/dom.pddl" --numslices 6 >/dev/null 2>&1
  # NOTE the sed: the action names carry digits of their own (PKG2, TRUCK1,
  # C1-AIR), so only the trailing slice number may be taken.
  SA=$(grep -oE '\(OCCURS \(LOAD PKG2 TRUCK1 C1-AIR\) [0-9]+\)' "$CDIR/ns.answer" \
       | sed 's/.*) \([0-9]*\))/\1/')
  SB=$(grep -oE '\(OCCURS \(LOAD PKG3 TRUCK2 C2-P1\) [0-9]+\)' "$CDIR/ns.answer" \
       | sed 's/.*) \([0-9]*\))/\1/')
  if [[ -n "$SA" && "$SA" == "$SB" ]]; then pass
  else fail "landed at slices $SA and $SB, so nothing was gained"; fi

  printf '  %-52s ... ' "two identical observations still need two occurrences"
  # Occurs is boolean per (action, slice) -- there is no "twice at s" -- so one
  # occurrence must not satisfy two adjacent identical observations.  Without
  # the adjacent-duplicate rule the single load at slice 1 would satisfy both.
  if [[ "$(cio "(and (occur-in-nonstrict-order $PA $PA))")" == "UNSATISFIABLE" ]]; then pass
  else fail "one occurrence satisfied two observations"; fi

  printf '  %-52s ... ' "one observation of it is of course fine"
  if [[ "$(cio "(and (occur-in-nonstrict-order $PA))")" == "cost 16" ]]; then pass
  else fail "a single non-strict observation should not constrain"; fi

  printf '  %-52s ... ' "non-strict takes the same window and negation"
  NSW="$(cio "(and (occur-in-nonstrict-order 1 5 $PA $PB))")"
  NSL="$(cio "(and (occur-in-nonstrict-order 3 -1 $PA $PB))")"
  NSN="$(cio "(and (not (occur-in-nonstrict-order 1 5 $PA $PB)))")"
  if [[ "$NSW" == "cost 16" && "$NSL" == "UNSATISFIABLE" && "$NSN" != "cost 16" ]]; then pass
  else fail "window=$NSW late=$NSL negated=$NSN"; fi

  printf '  %-52s ... ' "it works as --pddl-evidence too"
  if [[ "$(ev3 "(occur-in-nonstrict-order $PA $PB)")" == "cost 16" \
     && "$(ev3 "(occur-in-order $PA $PB)")" == "cost 17" ]]; then pass
  else fail "the two orderings should differ in evidence as in constraints"; fi
else
  echo "  (skipping: no MaxSAT solver)"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
