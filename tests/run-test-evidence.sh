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

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
