#!/bin/bash
#
# run-test-restrict.sh -- planner.sh --restrict steps|actions: cost minimization
# restricted to the actions of the feasibility step's SAT plan.
#
#   1. plan--restrict-wcnf on a hand-written map and WCNF: exactly the unit
#      clauses each mode should add (steps forbids every (action, slice) the plan
#      did not take; actions forbids every ground action it never took, at any
#      slice; pin also forces the plan's own atoms true), and, solved, a costly
#      detour in the "SAT plan" that :steps must drop.
#   2. End to end on a generated problem at a horizon with slack: the restricted
#      plan uses only the SAT plan's actions (steps: its exact (action, slice)
#      pairs), and  optimum <= restricted cost <= the SAT plan's cost, the
#      optimum coming from an UNRESTRICTED run -- an independent oracle.
#   3. Option errors.
#
# Needs the exact MaxSAT solver EvalMaxSAT_bin; skips the solving checks cleanly
# without it.  Deliberately NOT $WEIGHTED_SOLVER, which planner.sh reads as its
# own default: an anytime solver exported there for everyday use would make the
# cost-order checks fail at random.
#
# Run from anywhere:  bash tests/run-test-restrict.sh
# Tests the working copy's lisp/ and bin/ by default; set FIFO_LISP to override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"   # resolve /var -> /private/var for (include ...)
trap 'rm -rf "$TMP"' EXIT
SOLVER=EvalMaxSAT_bin

if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP ($1)"; SKIP=$((SKIP+1)); }
name() { printf '  %-60s ... ' "$1"; }
HAVE_SOLVER=1; command -v "$SOLVER" >/dev/null 2>&1 || HAVE_SOLVER=0

mkdir -p "$TMP/w"; cd "$TMP/w" || exit 2

# ------------------------------------------------- 1. plan--restrict-wcnf ---

# Three ways to get from A to B: directly at slice 1 (cost 5), or by the detour
# A->C at 1 and C->B at 2 (cost 1 + 1).  Variable 6 is a fluent, never touched.
cat > t.map <<'EOF'
map 6
1 (OCCURS (MOVE A B) 1)
2 (OCCURS (MOVE A C) 1)
3 (OCCURS (MOVE C B) 2)
4 (OCCURS (MOVE A B) 2)
5 (OCCURS (MOVE B B) 2)
6 (AT B 3)
EOF
# at B at the end; B reached only through one of the three routes; costs on moves
cat > t.wcnf <<'EOF'
h 6 0
h -6 1 4 3 5 0
h -3 2 0
h -5 1 4 3 0
5 -1 0
5 -4 0
1 -2 0
1 -3 0
3 -5 0
EOF

lisp() {   # lisp <form> : run FORM after loading FiFO and the planner, print its output
  sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" --eval "(load \"$FIFO_LISP/pddl2fifo.lisp\")" \
    --eval "(load \"$FIFO_LISP/planner.lisp\")" --eval "$1" 2>&1 | grep -v '^;'
}
units() {  # units <mode> <sat-actions> : the unit clauses appended, one per line
  cp t.wcnf u.wcnf
  lisp "(progn (plan--restrict-wcnf \"u.wcnf\" \"t.map\" '$2 $1) (terpri))" >/dev/null
  tail -n +10 u.wcnf | tr '\n' ' ' | sed 's/ *$//'
}

# the "SAT plan" took the costly direct move at slice 1, and a pointless B->B at 2
SAT='(((MOVE A B) 1) ((MOVE B B) 2))'
name ":steps forbids every (action, slice) the plan did not take"
got="$(units :steps "$SAT")"
[ "$got" = "h -2 0 h -3 0 h -4 0" ] && pass || fail "got: $got"

name ":actions keeps the plan's actions at every slice"
got="$(units :actions "$SAT")"
# (MOVE A B) is allowed at slices 1 AND 2; the detour's two moves are forbidden
[ "$got" = "h -2 0 h -3 0" ] && pass || fail "got: $got"

name ":pin forces the plan's atoms true and the rest false"
got="$(units :pin "$SAT")"
[ "$got" = "h 1 0 h -2 0 h -3 0 h -4 0 h 5 0" ] && pass || fail "got: $got"

name "the counts returned are allowed and forbidden action atoms"
got="$(cp t.wcnf c.wcnf; lisp "(multiple-value-bind (a f) (plan--restrict-wcnf \"c.wcnf\" \"t.map\" '$SAT :steps) (format t \"~D ~D~%\" a f))" | tail -1)"
[ "$got" = "2 3" ] && pass || fail "got: $got (expected 2 allowed, 3 forbidden; the fluent ignored)"

# Solved: the SAT plan's own cost (pinned) is 5 + 3 = 8; :steps can drop the
# pointless B->B (cost 3) but not switch to the detour, so 5; unrestricted, 2.
solve_cost() {  # solve_cost <wcnf> : the optimum, as the solver reports it
  "$SOLVER" "$1" 2>/dev/null | awk '/^o /{o=$2} END{print o}'
}
if [ "$HAVE_SOLVER" -eq 1 ]; then
  cp t.wcnf p.wcnf; lisp "(plan--restrict-wcnf \"p.wcnf\" \"t.map\" '$SAT :pin)" >/dev/null
  cp t.wcnf s.wcnf; lisp "(plan--restrict-wcnf \"s.wcnf\" \"t.map\" '$SAT :steps)" >/dev/null
  name "solved: pinned 8, steps 5 (detour B->B dropped), unrestricted 2"
  got="$(solve_cost p.wcnf) $(solve_cost s.wcnf) $(solve_cost t.wcnf)"
  [ "$got" = "8 5 2" ] && pass || fail "got: $got"
  # with the detour's moves in the plan, :actions finds the cheap route
  name "solved: :actions over the detour's moves finds cost 2"
  cp t.wcnf a.wcnf
  lisp "(plan--restrict-wcnf \"a.wcnf\" \"t.map\" '(((MOVE A C) 1) ((MOVE C B) 2) ((MOVE A B) 1)) :actions)" >/dev/null
  got="$(solve_cost a.wcnf)"
  [ "$got" = "2" ] && pass || fail "got: $got"
else
  name "solved restriction costs"; skip "no $SOLVER"
fi

# ------------------------------------------------------- 2. end to end ---

# One truck, two packages, 4x4, every package delivered; drives cost 2.  At its
# shortest horizon the SAT plan has little room to waste, so give it slack.
bash "$REPO/SatPlan/ppgen.sh" --style grid --dimensions 4 4 --airports 0 --airplanes 0 \
     --trucks 1 --packages 2 --destinations 1 --require all --drive-cost 2 \
     --seed 3 --name e2e -o e2e.pddl >/dev/null
plan_run() {  # plan_run <tag> [planner options] : output in <tag>.out, answer in <tag>/
  local tag="$1"; shift
  mkdir -p "$tag"; cp e2e.pddl "$tag/"
  bash "$REPO/bin/planner.sh" "$tag/e2e.pddl" --weighted-solver "$SOLVER" "$@" > "$tag.out" 2>&1
}
occurs() { grep '^(OCCURS ' "$1" | sort; }
# Costs as the planner prints them: plan-true-cost is a Lisp rational, so "17/2"
# or "-3" as well as "14" -- the awk below evaluates a ratio itself.
cost_of() { sed -n 's/.*time slices: cost \([-0-9./]*\).*/\1/p' "$1" | tail -1; }
satcost_of() { sed -n 's/.*the SAT plan ([0-9]* actions) as found: cost \([-0-9./]*\).*/\1/p' "$1"; }
num() { awk -v x="$1" 'BEGIN{n=split(x,p,"/"); printf "%.10g\n", (n==2 ? p[1]/p[2] : x)}'; }

if [ "$HAVE_SOLVER" -eq 1 ]; then
  # (planner.sh's default --maxslices, twice its reachability bound, is too few)
  H0="$(bash "$REPO/bin/planner.sh" e2e.pddl --weighted-solver "$SOLVER" --maxslices 40 2>&1 \
          | sed -n 's/^SOLVED with \([0-9]*\) time slices.*/\1/p')"
  [ -n "$H0" ] || { echo "no plan for the end-to-end problem" >&2; exit 2; }
  H=$((H0 + 6))
  plan_run full  --numslices "$H"
  plan_run steps --numslices "$H" --restrict steps
  plan_run acts  --numslices "$H" --restrict actions

  name "both restricted runs solve and keep the SAT plan (-restrict-sat.answer)"
  if grep -q '^SOLVED' steps.out && grep -q '^SOLVED' acts.out &&
     [ -s steps/e2e-restrict-sat.answer ] && [ -s acts/e2e-restrict-sat.answer ]
  then pass; else fail "$(for f in steps.out acts.out; do tail -n 3 "$f"; done | tr '\n' ' ')"; fi

  name "steps: the plan's (action, slice) pairs are a subset of the SAT plan's"
  extra="$(comm -23 <(occurs steps/e2e.answer) <(occurs steps/e2e-restrict-sat.answer))"
  [ -z "$extra" ] && [ -n "$(occurs steps/e2e.answer)" ] && pass || fail "not in the SAT plan: $extra"

  name "actions: every action used is one the SAT plan took"
  strip() { sed 's/^(OCCURS \(.*\) [0-9]*)$/\1/' | sort -u; }
  extra="$(comm -23 <(occurs acts/e2e.answer | strip) <(occurs acts/e2e-restrict-sat.answer | strip))"
  [ -z "$extra" ] && [ -n "$(occurs acts/e2e.answer)" ] && pass || fail "not in the SAT plan: $extra"

  name "kissat is deterministic: both runs restricted the same SAT plan"
  cmp -s steps/e2e-restrict-sat.answer acts/e2e-restrict-sat.answer && pass || fail "the SAT plans differ"

  opt="$(cost_of full.out)"; cs="$(cost_of steps.out)"; ca="$(cost_of acts.out)"
  sat="$(satcost_of steps.out)"
  name "optimum <= actions <= steps <= SAT plan  ($opt <= $ca <= $cs <= $sat)"
  if [ -n "$opt" ] && [ -n "$cs" ] && [ -n "$ca" ] && [ -n "$sat" ] &&
     awk -v o="$(num "$opt")" -v a="$(num "$ca")" -v s="$(num "$cs")" -v p="$(num "$sat")" \
         'BEGIN{exit !(o<=a && a<=s && s<=p)}'
  then pass; else fail "costs out of order"; fi

  name "steps allows exactly as many action atoms as the SAT plan has"
  n_sat="$(occurs steps/e2e-restrict-sat.answer | wc -l | tr -d ' ')"
  grep -q "steps: $n_sat of [0-9]* action atoms allowed" steps.out && pass \
    || fail "$(grep 'action atoms allowed' steps.out) vs $n_sat SAT-plan actions"

  # The case above leaves every cost equal (a route cannot be shortened by
  # dropping drives), so it would pass if the restricted solve returned the SAT
  # plan unchanged.  This one cannot: a 3x3 problem whose SAT plan at 2 slices of
  # slack (kissat 4.0.4, deterministic) carries removable waste: cost 12 -> 8.  If a kissat
  # upgrade changes its plan the case is reported as SKIP, not passed -- but
  # only under another kissat: with 4.0.4 an unchanged cost is a FAIL, since that
  # is exactly what a restricted solve returning the SAT plan would look like.
  bash "$REPO/SatPlan/ppgen.sh" --style grid --dimensions 3 3 --airports 0 --airplanes 0 \
       --trucks 1 --packages 2 --destinations 1 --require all --drive-cost 2 \
       --seed 3 --name e2e -o e2e3.pddl >/dev/null
  mkdir -p small-full small-steps; cp e2e3.pddl small-full/e2e.pddl; cp e2e3.pddl small-steps/e2e.pddl
  H3="$(bash "$REPO/bin/planner.sh" small-full/e2e.pddl --weighted-solver "$SOLVER" --maxslices 30 2>&1 \
          | sed -n 's/^SOLVED with \([0-9]*\) time slices.*/\1/p')"
  bash "$REPO/bin/planner.sh" small-full/e2e.pddl --weighted-solver "$SOLVER" \
       --numslices $((H3 + 2)) > small-full.out 2>&1
  bash "$REPO/bin/planner.sh" small-steps/e2e.pddl --weighted-solver "$SOLVER" \
       --numslices $((H3 + 2)) --restrict steps > small-steps.out 2>&1
  o3="$(num "$(cost_of small-full.out)")"; s3="$(num "$(cost_of small-steps.out)")"
  p3="$(num "$(satcost_of small-steps.out)")"
  name "steps strictly improves on a wasteful SAT plan ($o3 <= $s3 < $p3)"
  if awk -v o="$o3" -v s="$s3" -v p="$p3" 'BEGIN{exit !(o<=s && s<p)}'; then pass
  elif [ "$(kissat --version 2>/dev/null)" != "4.0.4" ] &&
       awk -v s="$s3" -v p="$p3" 'BEGIN{exit !(s==p)}'; then
    skip "kissat $(kissat --version 2>/dev/null) plans this problem without waste"
  else fail "costs out of order"; fi
  name "  and the improved plan still uses only the SAT plan's (action, slice) pairs"
  extra="$(comm -23 <(occurs small-steps/e2e.answer) <(occurs small-steps/e2e-restrict-sat.answer))"
  [ -z "$extra" ] && [ -n "$(occurs small-steps/e2e.answer)" ] && pass || fail "not in the SAT plan: $extra"
else
  name "end to end"; skip "no $SOLVER"
fi

# --------------------------------------------------------------- 3. errors ---

name "--restrict with an unknown mode is refused"
out="$(bash "$REPO/bin/planner.sh" e2e.pddl --restrict bogus 2>&1)"
[ $? -eq 2 ] && echo "$out" | grep -q "must be steps or actions" && pass || fail "$out"

name "--restrict with --longer is refused"
out="$(bash "$REPO/bin/planner.sh" e2e.pddl --restrict steps --longer 2 2>&1)"
[ $? -eq 2 ] && echo "$out" | grep -q "cannot be combined" && pass || fail "$out"

name "--restrict with --marginals is refused"
out="$(bash "$REPO/bin/planner.sh" e2e.pddl --restrict steps --marginals 2>&1)"
[ $? -eq 2 ] && echo "$out" | grep -q "not --marginals" && pass || fail "$out"

name "--restrict with --stop-after is refused"
out="$(bash "$REPO/bin/planner.sh" e2e.pddl --restrict steps --stop-after scnf 2>&1)"
[ $? -eq 2 ] && echo "$out" | grep -q "not --stop-after" && pass || fail "$out"

name "plan--restrict-wcnf refuses a classic 'p wcnf' file"
printf 'p wcnf 6 9 100\n100 6 0\n' > old.wcnf
got="$(lisp "(handler-case (progn (plan--restrict-wcnf \"old.wcnf\" \"t.map\" '$SAT :steps) (print :appended))
               (error (e) (format t \"~&ERR ~A~%\" e)))")"
echo "$got" | grep -q "classic 'p wcnf'" && [ "$(wc -l < old.wcnf | tr -d ' ')" = 2 ] && pass \
  || fail "got: $got"

echo
echo "=== summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
