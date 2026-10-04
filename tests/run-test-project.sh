#!/bin/bash
#
# run-test-project.sh -- projected knowledge compilation (marginals.sh --project,
# planner.sh --marginals --counter d4 --project).
#
# A projected compile counts the models of (exists Y. F(X,Y)), which equals F's
# own count -- marginal for marginal over X -- exactly when X DETERMINES Y.  The
# projection set X is the actions, the final-slice goal atoms, every weighted
# atom and any requested atom; d4 is told it with a 'c p show' line, and before
# compiling one SAT call (Padoa's method) checks that X determines the rest.
#
# The load-bearing cases are therefore:
#   * the ORACLE case -- every kept atom's projected marginal equals the full
#     compile's, on theories whose marginals are not all 0/1 (on a plan's own
#     horizon they would be, and the comparison would prove nothing);
#   * the GUARD case -- a theory where the kept atoms do NOT determine the rest
#     is refused, naming an undetermined atom, rather than counted wrongly;
#   * the PROVENANCE case -- the planner records the goal atoms it PARSED from
#     the PDDL, derived hypothesis predicates included, so they are kept.
#
# Run from anywhere:  bash tests/run-test-project.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.
# Skips cleanly (exit 0) without d4 or kissat.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"
BIN="$REPO/bin"
P="$BIN/planner.sh"
M="$BIN/marginals.sh"
command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }
for t in d4 kissat; do
  command -v "$t" >/dev/null 2>&1 || { echo "=== projected compilation: no $t on PATH -- skipping ==="; exit 0; }
done

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

PASS=0; FAIL=0
ok()  { printf '  %-64s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-64s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# agree <projected> <full> -- every (MARGINAL a p) of <projected> matches <full>
# to 1e-9.  Prints "<n> atoms, <k> strictly between 0 and 1"; fails when any
# atom differs or is missing, when nothing was compared, or when every compared
# marginal is 0 or 1 (vacuous).  The value is the LAST field: atoms have spaces.
agree() {
  awk 'FNR==NR { if ($1=="(MARGINAL") { v=$NF; sub(/\)$/,"",v); a=$0; sub(/ [^ ]*$/,"",a); full[a]=v }; next }
       $1=="(MARGINAL" { v=$NF; sub(/\)$/,"",v); a=$0; sub(/ [^ ]*$/,"",a); n++
                         if (!(a in full)) { print "missing in full: " a; bad=1; exit }
                         d=v-full[a]; if (d<0) d=-d; if (d>1e-9) { print a " " v " vs " full[a]; bad=1; exit }
                         if (v>1e-9 && v<1-1e-9) k++ }
       END { if (bad) exit 1; if (n==0) { print "nothing compared"; exit 1 }
             if (k==0) { print n " atoms, all 0/1 (vacuous)"; exit 1 }
             print n " atoms, " k " strictly between 0 and 1" }' "$2" "$1"
}

echo "=== projected compilation ==="

# --- 1. the planner records what to keep -------------------------------------
mkdir -p sw && cp "$REPO"/SatPlan/Examples/Switch/*.pddl sw/
bash "$P" sw/switchprob.pddl --domain sw/switches.pddl --numslices 4 --stop-after scnf >/dev/null 2>&1
SW=sw/switchprob.scnf
if grep -q '^; fifo-projection-horizon: 4$' "$SW" \
   && grep -q '^; fifo-projection-actions: ((TURN-OFF S1)' "$SW" \
   && grep -q '^; fifo-projection-goal: (' "$SW"; then
  ok "planner.sh writes the horizon, action and goal header"
else
  bad "planner.sh writes the horizon, action and goal header" "$(grep 'fifo-projection' "$SW" | cut -c1-60 | tr '\n' ' ')"
fi
# At the TOP, so the reader stops at the first clause rather than reading a
# theory that can run to hundreds of MB.
[[ "$(head -1 "$SW")" == "; fifo-projection-horizon: 4" ]] \
  && ok "the header is the first thing in the scnf" \
  || bad "the header is the first thing in the scnf" "line 1: $(head -1 "$SW" | cut -c1-60)"
# The goal of a recognition instance is (or (hyp0) ... (hyp9)) over DERIVED
# predicates, which pddl2fifo's goal-fluents deliberately leaves out; the header
# must have them, since they are exactly what recognition asks about.
REC="$REPO/SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts"
mkdir -p rec && cp "$REC"/*.pddl rec/
bash "$P" rec/problem.pddl --domain rec/intrusion-detection-costs.pddl --numslices 6 --stop-after scnf >/dev/null 2>&1
G="$(grep '^; fifo-projection-goal:' rec/problem.scnf)"
NH=$(grep -o '(HYP[0-9]*)' <<<"$G" | sort -u | wc -l | tr -d ' ')
[[ "$NH" -eq 10 ]] && ok "derived hypothesis goals are recorded ((HYP0)..(HYP9))" \
                   || bad "derived hypothesis goals are recorded" "found $NH: $(cut -c1-80 <<<"$G")"

# --- 2. the oracle: projected = full on every kept atom ----------------------
bash "$M" "$SW" --solver d4 > full.m 2>&1
bash "$M" "$SW" --solver d4 --project > proj.m 2>&1
if r="$(agree proj.m full.m)"; then ok "Switch: projected = full ($r)"
else bad "Switch: projected = full" "$r $(grep -v '^(' proj.m | tail -1)"; fi
grep -q 'projecting onto .* (verified exact)' proj.m \
  && ok "the exactness check ran and passed" \
  || bad "the exactness check ran and passed" "$(grep -v '^(' proj.m | tail -1)"
# Z itself must agree, not just the marginals.  Root smoothing over the KEPT
# atoms only is what makes it: smoothing in the projected-away ones too would
# multiply Z (and every kept atom's numerator) by 2 per dropped atom -- invisible
# in the marginals, which is why this case reads Z directly.
ZZ="$(sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" \
        --eval "(load \"$FIFO_LISP/ddnnf.lisp\")" \
        --eval "(format t \"Z ~,12E ~,12E~%\"
                  (ddnnf-query (ddnnf-compile-d4 \"$SW\" :verbose nil))
                  (ddnnf-query (ddnnf-compile-d4 \"$SW\" :verbose nil :project t)))" 2>&1 | grep '^Z ')"
if awk '{d=$2-$3; if(d<0)d=-d; exit !($2>0 && d<=1e-9*$2)}' <<<"$ZZ"; then
  ok "projected Z = full Z (smoothing over kept atoms only)"
else
  bad "projected Z = full Z" "${ZZ:-no output}"
fi
NP=$(grep -c '^(MARGINAL' proj.m); NF=$(grep -c '^(MARGINAL' full.m)
(( NP < NF )) && ok "only the kept atoms are reported ($NP of $NF)" \
              || bad "only the kept atoms are reported" "$NP of $NF"
grep -q '^(MARGINAL (HOLDS (ON S1) 4) ' proj.m \
  && ok "a final-slice goal atom is kept" || bad "a final-slice goal atom is kept" "no (HOLDS (ON S1) 4)"

# A preference-weighted ppgen problem: the PREF-VIOLATED atoms carry the weights
# and must be kept, or their costs would be silently dropped.
bash "$REPO/SatPlan/ppgen.sh" --style clique --number-cliques 2 --clique-size 3 --packages 2 \
     --preferences 1 5 --goals-per-package 2 0 --seed 7 --output pp.pddl >/dev/null 2>&1
bash "$P" pp.pddl --domain "$REPO/SatPlan/clara-logistics.pddl" --numslices 5 --stop-after scnf >/dev/null 2>&1
bash "$M" pp.scnf --solver d4 > ppfull.m 2>&1
bash "$M" pp.scnf --solver d4 --project > ppproj.m 2>&1
if r="$(agree ppproj.m ppfull.m)" && grep -q '^(MARGINAL (PREF-VIOLATED' ppproj.m; then
  ok "preference problem: projected = full, PREF-VIOLATED kept ($r)"
else
  bad "preference problem: projected = full, PREF-VIOLATED kept" "${r:-} $(grep -v '^(' ppproj.m | tail -1)"
fi

# --- 3. evidence, hypotheses, --project-also ---------------------------------
EV='(occurs (turn-on s2) 1)'   # s1 starts on, so turn-on s1 would be UNSAT
bash "$M" "$SW" --solver d4 --evidence "$EV" > evf.m 2>&1
bash "$M" "$SW" --solver d4 --project --evidence "$EV" > evp.m 2>&1
if r="$(agree evp.m evf.m)"; then ok "unit evidence: projected = full ($r)"
else bad "unit evidence: projected = full" "$r $(grep -v '^(' evp.m | tail -1)"; fi
EV2='(or (occurs (turn-on s1) 1) (occurs (turn-on s2) 2))'
bash "$M" "$SW" --solver d4 --evidence "$EV2" > ev2f.m 2>&1
bash "$M" "$SW" --solver d4 --project --evidence "$EV2" > ev2p.m 2>&1
if r="$(agree ev2p.m ev2f.m)" && grep -q 'projecting onto .* (verified exact)' ev2p.m; then
  ok "non-unit evidence recompiles PROJECTED, = full ($r)"
else
  bad "non-unit evidence recompiles PROJECTED, = full" "${r:-} $(grep -v '^(' ev2p.m | tail -1)"
fi
MID='(HOLDS (ON S2) 2)'
bash "$M" "$SW" --solver d4 --project --project-also "$MID" > also.m 2>&1
if grep -q "^(MARGINAL $MID " also.m && ! grep -q "^(MARGINAL $MID " proj.m; then
  ok "--project-also keeps a mid-plan state atom"
else
  bad "--project-also keeps a mid-plan state atom" "$(grep -v '^(' also.m | tail -1)"
fi
H1='(HOLDS (ON S2) 3)'; H2='(HOLDS (ON S3) 3)'
bash "$M" "$SW" --solver d4 --hypotheses "$H1" --hypotheses "$H2" --evidence "$EV" > hf.m 2>&1
bash "$M" "$SW" --solver d4 --project --hypotheses "$H1" --hypotheses "$H2" --evidence "$EV" > hp.m 2>&1
if [[ -s hf.m ]] && grep -q '^(HYPOTHESIS' hf.m && diff <(grep '^(HYPOTHESIS' hf.m) <(grep '^(HYPOTHESIS' hp.m) >/dev/null; then
  ok "--hypotheses: projected posteriors = full (hypotheses kept)"
else
  bad "--hypotheses: projected posteriors = full" "$(grep -v '^(' hp.m | tail -1)"
fi

# --- 4. the guard ---------------------------------------------------------------
# Not a planning theory: no header, no OCCURS, nothing weighted -- the kept set
# determines nothing, and the projected count would be wrong.  It must refuse.
printf '(or (and a b c d) (and e f g))\n(weight a 1)\n' > g.wff
sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" --eval '(instantiate "g.wff")' >/dev/null 2>&1
OUT="$(bash "$M" g.scnf --solver d4 --project 2>&1)"
grep -q 'projection is not exact: .* is not determined' <<<"$OUT" \
  && ok "an inexact projection is refused, naming an undetermined atom" \
  || bad "an inexact projection is refused, naming an undetermined atom" "$(tail -1 <<<"$OUT")"
# Keeping every atom makes it trivially exact -- and then it must agree.
bash "$M" g.scnf --solver d4 > gf.m 2>&1
bash "$M" g.scnf --solver d4 --project --project-also B --project-also C --project-also D \
     --project-also E --project-also F --project-also G > gp.m 2>&1
if r="$(agree gp.m gf.m)"; then ok "with every atom kept it is exact and agrees ($r)"
else bad "with every atom kept it is exact and agrees" "$r $(tail -1 gp.m)"; fi
# Without the planner's header, actions and goal atoms are INFERRED -- and the
# answer must not change.
grep -v '^; fifo-projection-' "$SW" > nohdr.scnf
bash "$M" nohdr.scnf --solver d4 --project > nh.m 2>&1
if grep -q 'actions inferred' nh.m && grep -q 'goal inferred' nh.m && r="$(agree nh.m full.m)"; then
  ok "no header: inferred actions/goals, still = full ($r)"
else
  bad "no header: inferred actions/goals, still = full" "${r:-} $(grep -v '^(' nh.m | tail -1)"
fi
# The fallback is PER FIELD: a .wff given to planner.sh gets a horizon and an
# actions line but no goal line (the planner never parsed a goal) -- the goal
# must then be inferred, not dropped.  (A review caught it keeping 0 goal atoms.)
cp sw/switchprob.wff wffin.wff
sed -i.bak 's|(include "[^"]*")|(include "'"$FIFO_LISP"'/satplan.wff")|' wffin.wff
bash "$P" wffin.wff --numslices 4 --marginals --counter d4 --project > wf.m 2>&1
# (ON S2) is a POSITIVE goal; the negative one, (not (on s1)), is the structural
# rule's documented blind spot, which is why the parsed goal is preferred.
if grep -q '^(MARGINAL (HOLDS (ON S2) 4) ' wf.m && grep -q 'actions from the header' wf.m \
   && grep -q 'goal inferred' wf.m; then
  ok "a .wff input: header actions, goal inferred, goal atom kept"
else
  bad "a .wff input: header actions, goal inferred, goal atom kept" "$(grep '^; projection' wf.m)"
fi

# --- 5. saved circuits ------------------------------------------------------------
bash "$M" "$SW" --solver d4 --project --save-circuit sw.dnnf > /dev/null 2>&1
bash "$M" --circuit sw.dnnf > ld.m 2>&1
if r="$(agree ld.m full.m)" && [[ $(grep -c '^(MARGINAL' ld.m) -eq $NP ]]; then
  ok "a reloaded projected circuit reports the kept atoms only ($r)"
else
  bad "a reloaded projected circuit reports the kept atoms only" "${r:-} $(tail -1 ld.m)"
fi
# Evidence on an atom the circuit DROPPED cannot be a clamp (there is no leaf to
# clamp -- it would be silently ignored); it must recompile with it conjoined.
DROP='(holds (on s2) 2)'
bash "$M" "$SW" --solver d4 --evidence "$DROP" > dropf.m 2>&1
bash "$M" --circuit sw.dnnf --evidence "$DROP" > dropc.m 2>&1
if grep -q 'dropped; recompiled' dropc.m && r="$(agree dropc.m dropf.m)"; then
  ok "evidence on a dropped atom recompiles, = full ($r)"
else
  bad "evidence on a dropped atom recompiles, = full" "${r:-} $(grep -v '^(' dropc.m | tail -1)"
fi

# --- 6. planner.sh --project ------------------------------------------------------
bash "$P" sw/switchprob.pddl --domain sw/switches.pddl --numslices 4 --marginals --counter d4 > pf.m 2>&1
bash "$P" sw/switchprob.pddl --domain sw/switches.pddl --numslices 4 --marginals --counter d4 --project > pp.m 2>&1
if r="$(agree pp.m pf.m)"; then ok "planner.sh --marginals --counter d4 --project = full ($r)"
else bad "planner.sh --marginals --counter d4 --project = full" "$r $(grep -v '^(' pp.m | tail -1)"; fi

# --- 7. refusals ------------------------------------------------------------------
refuse() { local label="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  grep -q -- "$pat" <<<"$out" && ok "$label" || bad "$label" "$(grep -m1 -i 'project' <<<"$out")"; }
refuse "--project with --solver ddnnf is refused" "d4 solver only" bash "$M" "$SW" --solver ddnnf --project
refuse "--project-also without --project is refused" "needs --project" bash "$M" "$SW" --solver d4 --project-also A
refuse "--project-also naming no atom of the theory is refused" "not an atom of" \
       bash "$M" "$SW" --solver d4 --project --project-also '(HOLDS (ON S9) 2)'
refuse "planner.sh --project without --counter d4 is refused" "counter d4" \
       bash "$P" sw/switchprob.pddl --domain sw/switches.pddl --numslices 4 --marginals --project
# --save-circuit used to REPLACE an explicit --solver with ddnnf, so a non-circuit
# solver ran FiFO's compiler instead of being refused.
refuse "--solver addmc --save-circuit is refused, not silently ddnnf" "apply to the ddnnf and d4" \
       bash "$M" "$SW" --solver addmc --save-circuit x.dnnf

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
