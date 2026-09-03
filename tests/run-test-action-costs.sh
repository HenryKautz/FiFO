#!/bin/bash
#
# run-test-action-costs.sh -- regression tests for problem-file action costs:
# the standard PDDL :action-costs idiom where a domain declares a cost function
# in (:functions ...) and the problem supplies its value in :init, so the same
# domain can be reused with different costs.
#
# Behavioral checks (what cost is emitted / which plan wins / which errors are
# raised), not gold diffs -- the point is that the numbers come from the problem
# file, and gold files would mostly restate the input.
#
# Run from anywhere:  bash tests/run-test-action-costs.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"   # resolve /var -> /private/var for (include ...)
trap 'rm -rf "$TMP"' EXIT

if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

PASS=0; FAIL=0
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }
name() { printf '  %-52s ... ' "$1"; }

# translate <problem> <domain> : run pddl2fifo, print OK or "ERR: <message>"
translate() {
  sbcl --noinform --disable-debugger \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
    --eval "(load \"$FIFO_LISP/pddl2fifo.lisp\")" \
    --eval "(handler-case (progn (pddl2fifo \"$1\" :domain-file \"$2\") (format t \"~&OK~%\"))
              (error (e) (format t \"~&ERR: ~a~%\" e)))" \
    --quit 2>/dev/null | awk '/^OK$/{print;exit} /^ERR: /{f=1} f{printf "%s ",$0} END{if(f)print ""}'
}

mkdir -p "$TMP/w"; cd "$TMP/w" || exit 2

# ---------------------------------------------------------------- domains ---

# constant cost: a 0-ary function, the same for every grounding
cat > const.pddl <<'EOF'
(define (domain costconst)
  (:requirements :strips :typing :action-costs)
  (:types loc - object)
  (:predicates (at ?l - loc))
  (:functions (total-cost) (move-cost))
  (:action move
    :parameters (?from ?to - loc)
    :precondition (at ?from)
    :effect (and (not (at ?from)) (at ?to)
                 (increase (total-cost) (move-cost)))))
EOF

# parameterized cost: differs per grounding
cat > param.pddl <<'EOF'
(define (domain costparam)
  (:requirements :strips :typing :action-costs)
  (:types loc - object)
  (:predicates (at ?l - loc))
  (:functions (total-cost) (road-length ?a ?b - loc))
  (:action move
    :parameters (?from ?to - loc)
    :precondition (at ?from)
    :effect (and (not (at ?from)) (at ?to)
                 (increase (total-cost) (road-length ?from ?to)))))
EOF

# literal cost: the pre-existing form, which must keep working
cat > literal.pddl <<'EOF'
(define (domain costliteral)
  (:requirements :strips :typing :action-costs)
  (:types loc - object)
  (:predicates (at ?l - loc))
  (:functions (total-cost))
  (:action move
    :parameters (?from ?to - loc)
    :precondition (at ?from)
    :effect (and (not (at ?from)) (at ?to) (increase (total-cost) 2))))
EOF

problem() {   # problem <file> <domain-name> <init-extras> [objects]
  cat > "$1" <<EOF
(define (problem $(basename "$1" .pddl))
  (:domain $2)
  (:objects ${4:-a b} - loc)
  (:init (at a) (= (total-cost) 0) $3)
  (:goal (at b))
  (:metric minimize (total-cost)))
EOF
}

# ------------------------------------------------------------- happy path ---

name "0-ary function: value comes from the problem :init"
problem c1.pddl costconst "(= (move-cost) 7)"
if [ "$(translate c1.pddl const.pddl)" = OK ] && grep -q '(cost (move from to) 7)' c1.wff
then pass; else fail "expected cost 7 in the schema"; fi

name "same domain, second problem, different cost"
problem c2.pddl costconst "(= (move-cost) 42)"
if [ "$(translate c2.pddl const.pddl)" = OK ] && grep -q '(cost (move from to) 42)' c2.wff
then pass; else fail "expected cost 42 without touching the domain"; fi

name "the domain file itself contains no number"
if ! grep -qE '\(increase \(total-cost\) [0-9]' const.pddl; then pass
else fail "domain should carry no literal cost"; fi

name "parameterized function: one cost fact per grounding"
problem p1.pddl costparam \
  "(= (road-length a b) 3) (= (road-length b a) 11) (= (road-length a a) 0) (= (road-length b b) 0)"
if [ "$(translate p1.pddl param.pddl)" = OK ] &&
   grep -q '(cost (move a b) 3)' p1.wff && grep -q '(cost (move b a) 11)' p1.wff
then pass; else fail "expected per-grounding cost facts"; fi

name "parameterized costs leave no cost on the schema"
if grep -q '(all (from to) loc true' p1.wff &&
   ! sed -n '/(all (from to) loc true/,/^$/p' p1.wff | grep -q '(cost (move from to)'
then pass; else fail "schema should carry no cost when costs are per-grounding"; fi

name "literal costs still work (backward compatibility)"
problem l1.pddl costliteral ""
if [ "$(translate l1.pddl literal.pddl)" = OK ] && grep -q '(cost (move from to) 2)' l1.wff
then pass; else fail "literal (increase (total-cost) 2) regressed"; fi

name "costs drive the optimum end to end"
cat > p2.pddl <<'EOF'
(define (problem p2)
  (:domain costparam)
  (:objects a b c - loc)
  (:init (at a) (= (total-cost) 0)
         (= (road-length a b) 20) (= (road-length b a) 20)
         (= (road-length a c) 1)  (= (road-length c a) 1)
         (= (road-length c b) 1)  (= (road-length b c) 1)
         (= (road-length a a) 0) (= (road-length b b) 0) (= (road-length c c) 0))
  (:goal (at b))
  (:metric minimize (total-cost)))
EOF
# at 3 slices the detour a->c->b (cost 2) must beat the direct a->b (cost 20)
if out=$(WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" \
         bash "$REPO/bin/planner.sh" p2.pddl --domain param.pddl \
              --minslices 3 --maxslices 3 2>&1) &&
   echo "$out" | grep -q '(\*OBJECTIVE\* 2)' &&
   echo "$out" | grep -q '(OCCURS (MOVE A C) 1)'
then pass
elif ! command -v "${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" >/dev/null 2>&1
then echo "SKIP (no MaxSAT solver)"
else fail "expected the cheap detour, objective 2"; fi

# ----------------------------------------------------------------- errors ---

check_err() {   # check_err <label> <problem> <domain> <pattern>
  name "$1"
  local got; got="$(translate "$2" "$3")"
  if echo "$got" | grep -qi "$4"; then pass; else fail "got: $got"; fi
}

problem e1.pddl costconst ""
check_err "missing value is an error, not a silent 0" e1.pddl const.pddl "gives it no value"

problem e2.pddl costconst "(= (bogus) 5)"
check_err "undeclared function in :init is rejected" e2.pddl const.pddl "undeclared function"

problem e3.pddl costconst "(= (move-cost a) 5)"
check_err "arity mismatch is rejected" e3.pddl const.pddl "argument"

cat > e4.pddl <<'EOF'
(define (problem e4) (:domain costconst) (:objects a b - loc)
  (:init (at a) (= (total-cost) 7) (= (move-cost) 1)) (:goal (at b)))
EOF
check_err "non-zero initial total-cost is rejected" e4.pddl const.pddl "must start at 0"

problem e5.pddl costparam "(= (road-length a b) 3)"
check_err "a grounding with no value is named in the error" e5.pddl param.pddl "no value"

cat > fuel.pddl <<'EOF'
(define (domain costfuel)
  (:requirements :strips :typing :action-costs)
  (:types loc - object)
  (:predicates (at ?l - loc))
  (:functions (total-cost) (fuel))
  (:action move
    :parameters (?from ?to - loc)
    :precondition (at ?from)
    :effect (and (not (at ?from)) (at ?to)
                 (increase (total-cost) (fuel)) (decrease (fuel) 1))))
EOF
cat > e6.pddl <<'EOF'
(define (problem e6) (:domain costfuel) (:objects a b - loc)
  (:init (at a) (= (total-cost) 0) (= (fuel) 10)) (:goal (at b)))
EOF
check_err "an action writing a cost function is rejected" e6.pddl fuel.pddl "must be static"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
