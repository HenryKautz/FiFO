#!/bin/bash
#
# run-test-recognize.sh -- recognize.sh's merged fast path.
#
# recognize.sh used to spend 2n translate-instantiate-solve cycles through
# planner.sh, one pair per hypothesis.  It now instantiates ONCE and clamps 2n
# solves on that single scnf, which is the same computation: clamping hypI in the
# disjunctive theory selects the same models as rewriting the goal to G_i, since
# hypI implies the disjunction (T_or ^ hypI == T_i).
#
# The old implementation is kept as --method plan-runs, and the load-bearing case
# here checks the two against each other rather than against numbers recorded in
# this file -- an independent oracle, not a snapshot.
#
# The enabling trick is the occur-in-order split: translate-occur-in-order emits
# (and <monitor axioms> <assertion>), the axioms are biconditional and therefore
# count-neutral, so they belong in the theory while the assertion is the one
# literal to condition on.  Case 2 tests that count-neutrality directly, because
# everything else rests on it.
#
# Run from anywhere:  bash tests/run-test-recognize.sh
# Skips cleanly (exit 0) with no MaxSAT solver.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
BIN="$REPO/bin"
REC="$REPO/SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts"
SW="$REPO/SatPlan/Examples/Switch"

PASS=0; FAIL=0
ok()  { printf '  %-58s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-58s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

HAVE_MAXSAT=0
for s in tt-open-wbo-inc-Glucose4_1 nuwls-c wmaxcdcl EvalMaxSAT_bin; do
  command -v "$s" >/dev/null 2>&1 && HAVE_MAXSAT=1
done
python3 -c "import pysat" >/dev/null 2>&1 || HAVE_MAXSAT=0
[[ "$HAVE_MAXSAT" -eq 1 ]] || { echo "no MaxSAT solver / python-sat -- skipping"; exit 0; }

TMP="$(mktemp -d /tmp/fifo-rec-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
cp "$REC"/{intrusion-detection-costs.pddl,problem.pddl,evidence-3.txt} .
cp "$SW"/*.pddl .

echo "=== recognize.sh: the merged fast path ==="

# --- 1. the split, and that the assertion is a resolved literal --------------
bash "$BIN/planner.sh" problem.pddl --domain intrusion-detection-costs.pddl \
     --numslices 6 --pddl-evidence-file evidence-3.txt --stop-after scnf \
     --split-evidence > split.log 2>&1
A="$(cat problem-assertion.txt 2>/dev/null)"
# NUMSLICES is bound in the instantiation environment; an unresolved symbol here
# would name an atom the theory does not have, and so would constrain nothing.
if [[ "$A" == "(OBSDONE 1 3 6)" ]]; then
  ok "the split writes a RESOLVED assertion literal"
else
  bad "the split writes a RESOLVED assertion literal" "got '$A'"
fi
grep -q "OBSDONE 1 3 6" problem.scnf \
  && ok "the assertion's atom is present in the theory" \
  || bad "the assertion's atom is present in the theory" "not found in the scnf"

bash "$BIN/planner.sh" problem.pddl --domain intrusion-detection-costs.pddl \
     --numslices 6 --stop-after scnf --split-evidence \
     --pddl-evidence '(not (occur-in-order (recon taurus) (recon leo) (recon virgo)))' \
     > splitneg.log 2>&1
[[ "$(cat problem-assertion.txt)" == "(NOT (OBSDONE 1 3 6))" ]] \
  && ok "the negated form flips only the assertion" \
  || bad "the negated form flips only the assertion" "got '$(cat problem-assertion.txt)'"

# --- 2. count-neutrality: the assumption everything else rests on -----------
# The monitor axioms are biconditional, so every ObsDone atom is determined by
# the action trace and adding them multiplies the weighted model count by 1.  If
# that were false the per-hypothesis baseline's unconditioned run would be wrong.
mkdir -p cn1 cn2 && cp "$SW"/*.pddl cn1/ && cp "$SW"/*.pddl cn2/
bash "$BIN/planner.sh" cn1/switchprob.pddl --domain cn1/switches.pddl \
     --numslices 3 --stop-after scnf >/dev/null 2>&1
bash "$BIN/planner.sh" cn2/switchprob.pddl --domain cn2/switches.pddl --numslices 3 \
     --pddl-evidence '(occur-in-order (turn-off s1) (turn-on s2))' \
     --stop-after scnf --split-evidence >/dev/null 2>&1
bash "$BIN/marginals.sh" cn1/switchprob.scnf --solver maxent 2>/dev/null | sort > base.txt
bash "$BIN/marginals.sh" cn2/switchprob.scnf --solver maxent 2>/dev/null \
     | grep -v OBSDONE | sort > withax.txt
if diff -q base.txt withax.txt >/dev/null && [[ -s base.txt ]]; then
  ok "monitor axioms are count-neutral ($(wc -l < base.txt | tr -d ' ') atoms unchanged)"
else
  bad "monitor axioms are count-neutral" "$(diff base.txt withax.txt | head -3 | tr '\n' ' ')"
fi

# --- 3. fast == plan-runs, against the independent oracle -------------------
# This is the real check of T_or ^ hypI == T_i, not just of the arithmetic.
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --out r-fast >/dev/null 2>&1
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --method plan-runs --out r-slow >/dev/null 2>&1
if [[ -s r-fast/summary.tsv && -s r-slow/summary.tsv ]] \
   && diff -q r-fast/summary.tsv r-slow/summary.tsv >/dev/null; then
  ok "fast and plan-runs agree exactly, occur-in-order evidence"
else
  bad "fast and plan-runs agree exactly, occur-in-order evidence" \
      "$(diff r-fast/summary.tsv r-slow/summary.tsv 2>&1 | head -4 | tr '\n' ' ')"
fi

# The costs, not only the posterior, must survive the move: they are the
# diagnostic that says WHY a hypothesis scored as it did.
grep -q '^hyp0	20	20	0' r-fast/summary.tsv \
  && ok "c(O) and c(~O) are reported by the fast path" \
  || bad "c(O) and c(~O) are reported by the fast path" "$(sed -n 2p r-fast/summary.tsv)"

# --- 4. the fast path is the default, and much faster -----------------------
S=$(date +%s); bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl \
     evidence-3.txt --horizon 6 --out r-t >/dev/null 2>&1; E=$(date +%s)
if [[ $((E-S)) -lt 120 ]]; then
  ok "the default path finishes in $((E-S))s (plan-runs takes ~30s)"
else
  bad "the default path finishes quickly" "took $((E-S))s"
fi

# --- 4a. --stop-after scnf: the same theory, no scoring ----------------------
# For a caller that compiles the theory (CLARA's compile-d4.py), which used to
# run a full max-term recognition just to get rec-problem.scnf.
# The out dir holds an earlier run's posteriors: they must not survive beside a
# theory they were not computed from.
mkdir -p r-stop && echo stale > r-stop/hypotheses.txt && echo stale > r-stop/hypotheses.err
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --out r-stop --stop-after scnf > r-stop.log 2>&1; RC=$?
if [[ $RC == 0 && -s r-fast/rec-problem.scnf ]] && cmp -s r-fast/rec-problem.scnf r-stop/rec-problem.scnf \
   && [[ ! -e r-stop/summary.tsv && ! -e r-stop/hypotheses.txt && ! -e r-stop/hypotheses.err ]] \
   && grep -q '^Horizon H = 6' r-stop.log; then
  ok "--stop-after scnf writes the same theory and scores nothing"
else bad "--stop-after scnf writes the same theory and scores nothing" \
  "rc=$RC $(ls r-stop 2>&1 | tr '\n' ' ')"; fi
# What it says it wrote is what it wrote.  pddl evidence: the monitor axioms are
# in the theory, the literal to condition on apart -- no evidence scnf.
if [[ -s r-stop/rec-problem-assertion.txt && ! -e r-stop/rec-problem-evidence.scnf ]] \
   && grep -q "condition on the literal in .*rec-problem-assertion.txt" r-stop.log; then
  ok "--stop-after, pddl evidence: the assertion file, named"
else bad "--stop-after, pddl evidence: the assertion file, named" "$(ls r-stop | tr '\n' ' ')"; fi
printf '(occurs (recon taurus) 1)\n' > fifoev1.txt
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl fifoev1.txt --evidence-kind fifo \
     --horizon 6 --out r-stopf --stop-after scnf > r-stopf.log 2>&1; RC=$?
if [[ $RC == 0 && -s r-stopf/rec-problem-evidence.scnf && ! -e r-stopf/rec-problem-assertion.txt ]] \
   && grep -q "evidence is apart, in .*rec-problem-evidence.scnf" r-stopf.log; then
  ok "--stop-after, fifo evidence: the evidence scnf, named"
else bad "--stop-after, fifo evidence: the evidence scnf, named" "rc=$RC $(ls r-stopf 2>&1 | tr '\n' ' ')"; fi
# Evidence a full run refuses is refused here too, not handed back as a theory.
printf '(and (occur-in-order (recon taurus) (recon leo)) (occur-in-order (recon leo) (recon virgo)))\n' > two-ooo.txt
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl two-ooo.txt \
     --horizon 6 --out r-stop2 --stop-after scnf > r-stop2.log 2>&1; RC=$?
if [[ $RC == 2 ]] && grep -q "no assertion literal was written" r-stop2.log; then
  ok "--stop-after refuses evidence a full run refuses"
else bad "--stop-after refuses evidence a full run refuses" "rc=$RC $(tail -1 r-stop2.log)"; fi
# No MaxSAT solve runs, so a missing python-sat (rc2) must not stop it.  The
# control, without --stop-after, shows the stand-in python3 does hide pysat.
mkdir -p nopy && printf '#!/bin/sh\nexit 1\n' > nopy/python3 && chmod +x nopy/python3
PATH="$TMP/nopy:$PATH" bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --out r-nopy --stop-after scnf > r-nopy.log 2>&1; RC=$?
CTL="$(PATH="$TMP/nopy:$PATH" bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl \
         evidence-3.txt --horizon 6 --out r-nopy2 2>&1)"
if [[ $RC == 0 && -s r-nopy/rec-problem.scnf ]] && grep -q "needs python-sat" <<<"$CTL"; then
  ok "--stop-after does not need python-sat"
else bad "--stop-after does not need python-sat" "rc=$RC $(tail -1 r-nopy.log) / $(tail -1 <<<"$CTL")"; fi

# --- 5. flags ---------------------------------------------------------------
errs() { local out; out="$(bash "$BIN/recognize.sh" "$@" 2>&1)"; printf '%s' "$out"; }
grep -q "must be 'scnf'" \
  <<<"$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --stop-after wff)" \
  && ok "--stop-after other than scnf is refused" || bad "--stop-after other than scnf is refused" "?"
grep -q "applies to --method fast only (plan-runs" \
  <<<"$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --stop-after scnf --method plan-runs)" \
  && ok "--stop-after with plan-runs is refused" || bad "--stop-after with plan-runs is refused" "?"
grep -q "must be 'fast' or 'plan-runs'" \
  <<<"$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --method bogus)" \
  && ok "an unknown --method is refused" || bad "an unknown --method is refused" "?"
grep -q "must be 'per-hypothesis' or 'best-rival'" \
  <<<"$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --baseline bogus)" \
  && ok "an unknown --baseline is refused" || bad "an unknown --baseline is refused" "?"
# --solver still means the SAT feasibility solver, not the counter
grep -q "unknown solver" \
  <<<"$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --solver kisat --horizon 3)" \
  && ok "--solver still names the SAT solver, and is validated" \
  || bad "--solver still names the SAT solver, and is validated" "?"
grep -q "unknown counter" \
  <<<"$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --counter nope --horizon 3)" \
  && ok "an unknown --counter is refused" || bad "an unknown --counter is refused" "?"

# --- 5a. the cost solver must be EXACT, and the same on both paths ----------
# R&G's score is c(~O) - c(O), a DIFFERENCE of two minima.  With an anytime
# solver those are two upper bounds, which do not cancel -- the hazard max-term
# warns about, and which the plan-runs path silently had, since planner.sh's
# default weighted solver is anytime.  It made repeated runs disagree with each
# other, so the equivalence above was only true by luck.
OUT_MS="$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
              --maxsat-solver nuwls --horizon 3)"
if grep -q "unknown solver\|is a plain SAT" <<<"$OUT_MS"; then
  bad "--maxsat-solver accepts a MaxSAT solver" "refused a valid one: $(head -1 <<<"$OUT_MS")"
else
  ok "--maxsat-solver accepts a MaxSAT solver"
fi
OUT_KS="$(errs intrusion-detection-costs.pddl problem.pddl evidence-3.txt --maxsat-solver kissat --horizon 3)"
grep -q "is a plain SAT solver" <<<"$OUT_KS" \
  && ok "--maxsat-solver refuses a plain SAT solver" \
  || bad "--maxsat-solver refuses a plain SAT solver" "got: $(head -1 <<<"$OUT_KS")"

# --- 5b. best-rival: a DIFFERENT posterior, and a real one ------------------
# Only max-term under per-hypothesis yields c(O)/c(~O); any other combination has
# to report the posterior marginals.sh computed.  Feeding the missing costs into
# the sigmoid instead would make every likelihood -- and so every posterior --
# silently zero, which is what this pins.
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --baseline best-rival --out r-br >/dev/null 2>&1
# Summing to 1 is NOT enough on its own: a flat 0.1 across ten hypotheses sums to
# 1 too, and that is exactly what a broken run returns -- the prior echoed back as
# the posterior.  Requiring VARIATION is what makes this case bite.  (It caught
# forwarding a relative weight of 1 to marginals.sh as if it were a probability:
# max-term reads a prior as a log-odds shift, so 1 means logit(1) = infinity and
# every marginal came back pinned at 1.0.)
BRSUM=$(awk -F'\t' 'NR>1{s+=$7; if($7+0>mx)mx=$7+0; if(mn==""||$7+0<mn)mn=$7+0}
                    END{print (s>0.9 && s<1.1) ? ((mx-mn>0.01)?"ok":"flat:"mx) : "bad:"s}' \
         r-br/summary.tsv 2>/dev/null)
case "$BRSUM" in
  ok)    ok "best-rival reports a real posterior (sums to 1, and varies)" ;;
  flat*) bad "best-rival reports a real posterior (sums to 1, and varies)" "uniform ${BRSUM#flat:} -- the prior, not a posterior" ;;
  *)     bad "best-rival reports a real posterior (sums to 1, and varies)" "posteriors sum to ${BRSUM#bad:}" ;;
esac
# The two baselines disagree here, which is the point of having both: best-rival
# favours hyp3 for being cheap to REACH, per-hypothesis divides that out.
A_BR=$(awk -F'\t' 'NR>1 && $7+0>m{m=$7+0; b=$1} END{print b}' r-br/summary.tsv 2>/dev/null)
A_PH=$(awk -F'\t' 'NR>1 && $7+0>m{m=$7+0; b=$1} END{print b}' r-fast/summary.tsv 2>/dev/null)
if [[ -n "$A_BR" && -n "$A_PH" && "$A_BR" != "$A_PH" ]]; then
  ok "the two baselines pick different hypotheses ($A_PH vs $A_BR)"
else
  bad "the two baselines pick different hypotheses" "per-hyp=$A_PH best-rival=$A_BR"
fi

# --- 5c. the code-review findings, one case each -----------------------------
# Every one of these is a SILENT wrong answer if unguarded, which is why they are
# errors rather than warnings.

# The four new flags must be reachable from --help.  The earlier version of this
# check ended in `|| true`, so it asserted nothing and missed that they were
# never added to the header block usage() prints.
HELP="$(bash "$BIN/recognize.sh" --help 2>&1)"
MISSING=""
for f in --counter --baseline --maxsat-solver --method --timeout --planner-timeout; do
  grep -q -- "$f" <<<"$HELP" || MISSING="$MISSING $f"
done
[[ -z "$MISSING" ]] && ok "--help documents the new flags" \
                    || bad "--help documents the new flags" "missing:$MISSING"

# plan-runs is the fixed R&G computation; accepting a counter/baseline and then
# ignoring it would report numbers that are not the ones asked for.
expect_err() { local label="$1" pat="$2"; shift 2
  local out; out="$(bash "$BIN/recognize.sh" "$@" 2>&1)"
  grep -q -- "$pat" <<<"$out" && ok "$label" || bad "$label" "got: $(head -1 <<<"$out")"; }
expect_err "--counter is refused with --method plan-runs" "no meaning with --method plan-runs" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --method plan-runs --counter ddnnf
expect_err "--baseline is refused with --method plan-runs" "no meaning with --method plan-runs" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --method plan-runs --baseline best-rival
expect_err "--timeout is refused with --method plan-runs" "applies to --method fast only" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --method plan-runs --timeout 60
expect_err "--timeout must be a number of seconds" "must be a number of seconds" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --timeout soon
expect_err "--timeout -300 is refused, not read as no limit" "must be a number of seconds" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --timeout -300
expect_err "--planner-timeout must be whole seconds" "must be a whole number of seconds" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --planner-timeout 1.5
expect_err "--planner-timeout -300 is refused, not read as no limit" "must be a whole number of seconds" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --planner-timeout -300

# --timeout must REACH the counts.  Without it every solver run inside the
# inference had FiFO's default 600 s limit, which recognize.sh could not change:
# in the 2026-10-17 SimpleGrid sweep 36 of 144 7x7 SharpSAT-TD runs failed on one
# count over 600 s, inside a 1200 s run limit.  A stand-in sharpSAT that never
# answers must be stopped after the 2 s asked for, not run its full 60 s.
mkdir -p stall
printf '#!/bin/sh\nexec sleep 60\n' > stall/sharpSAT
chmod +x stall/sharpSAT
T0=$SECONDS
OUT_TO="$(PATH="$TMP/stall:$PATH" bash "$BIN/recognize.sh" intrusion-detection-costs.pddl \
          problem.pddl evidence-3.txt --horizon 6 --counter sharpsat-td --timeout 2 --out r-to 2>&1)"
if grep -q "timed out after 2 s" <<<"$OUT_TO" && (( SECONDS - T0 < 60 )); then
  ok "--timeout reaches the counts ($((SECONDS - T0)) s)"
else
  bad "--timeout reaches the counts" "$((SECONDS - T0)) s: $(grep -i 'timed out\|error' <<<"$OUT_TO" | head -1)"
fi

# --priors must REACH marginals.sh on the path that reports its posterior; the
# awk that would otherwise apply them never runs there.
printf 'hyp0 = 9\n' > skew.txt
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --baseline best-rival --priors skew.txt --out r-pri >/dev/null 2>&1
P_SKEW=$(awk -F'\t' '$1=="hyp0"{print $6}' r-pri/summary.tsv 2>/dev/null)
if [[ -n "$P_SKEW" ]] && awk -v p="$P_SKEW" 'BEGIN{exit !(p>0.4)}'; then
  ok "--priors reach the marginals-posterior path (hyp0 prior $P_SKEW)"
else
  bad "--priors reach the marginals-posterior path" "hyp0 prior came out '$P_SKEW', expected ~0.5"
fi

# A stale scnf in a persistent --out must not be mistaken for this run's output.
mkdir -p r-stale && cp r-fast/summary.tsv r-stale/ 2>/dev/null
printf 'nonsense\n' > r-stale/rec-problem.scnf
OUT_STALE="$(bash "$BIN/recognize.sh" intrusion-detection-costs.pddl nosuch.pddl \
             evidence-3.txt --horizon 6 --out r-stale 2>&1)"
grep -q "no such file\|instantiation failed" <<<"$OUT_STALE" \
  && ok "a stale scnf does not pass for a fresh run" \
  || bad "a stale scnf does not pass for a fresh run" "got: $(head -1 <<<"$OUT_STALE")"

# bash 3.2 is what the #!/bin/bash shebang actually gets on macOS, and "${a[@]}"
# on an empty array is fatal there under set -u.  Both new arrays are empty in
# ordinary configurations.
OUT_32="$(/bin/bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl \
          evidence-3.txt --evidence-kind fifo --horizon 6 --out r-32 2>&1)"
grep -q "unbound variable" <<<"$OUT_32" \
  && bad "runs under /bin/bash 3.2 (empty arrays)" "unbound variable" \
  || ok "runs under /bin/bash 3.2 (empty arrays)"

# --- 5d. hypotheses from the parsed goal, and priors by name ----------------
# The hypotheses used to come from a grep over the problem TEXT, and priors were
# matched to that list BY LINE NUMBER -- so a stray (hypN) anywhere shifted every
# weight onto the wrong hypothesis.

cat > two.pddl <<'PDDL'
;; a note mentioning (hyp7) in passing -- NOT a hypothesis of this problem
(define (problem intrusion-two) (:domain intrusion-detection)
 (:objects perseus cassiopea andromeda sagittarius scorpio virgo aries leo
  libra taurus - host)
 (:init (dummy) (= (total-cost) 0))
 (:goal (or (hyp0) (hyp1))))
PDDL
# the grep this replaced would find three
[[ "$(grep -oE '\(hyp[0-9]+\)' two.pddl | sort -u | wc -l | tr -d ' ')" -eq 3 ]] \
  || echo "  (fixture no longer exercises the hazard)" >&2
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl two.pddl evidence-3.txt \
     --horizon 6 --out r-two >/dev/null 2>&1
NH=$(awk 'NR>1' r-two/summary.tsv 2>/dev/null | wc -l | tr -d ' ')
[[ "$NH" -eq 2 ]] && ok "a (hypN) in a comment is not a hypothesis" \
                  || bad "a (hypN) in a comment is not a hypothesis" "got $NH hypotheses, want 2"

# Order independence: the whole point of naming them.
printf 'hyp0 = 9\nhyp3 = 4\n' > pa.txt
printf 'hyp3 = 4\nhyp0 = 9\n' > pb.txt
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --priors pa.txt --out r-pa >/dev/null 2>&1
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --priors pb.txt --out r-pb >/dev/null 2>&1
if [[ -s r-pa/summary.tsv ]] && diff -q r-pa/summary.tsv r-pb/summary.tsv >/dev/null; then
  ok "priors are order-independent"
else
  bad "priors are order-independent" "$(diff r-pa/summary.tsv r-pb/summary.tsv 2>&1 | head -2 | tr '\n' ' ')"
fi

expect_err "an unknown hypothesis in --prior is refused" "is not a hypothesis of this problem" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --horizon 6 --prior hyp99=2
printf '9\n1\n' > old-style.txt
expect_err "the old positional priors file is refused" "given BY NAME" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --horizon 6 --priors old-style.txt

# --- 5e. priors from preferences, opt-in ------------------------------------
# pi = exp(w): w is a VIOLATION penalty, so escaping it is worth odds exp(w).
# ln 2 = 0.69314718, so this must equal --prior hyp0=2 exactly.
cat > pref.pddl <<'PDDL'
(define (problem intrusion-pref) (:domain intrusion-detection)
 (:objects perseus cassiopea andromeda sagittarius scorpio virgo aries leo
  libra taurus - host)
 (:init (dummy) (= (total-cost) 0))
 (:goal
  (and (or (hyp0) (hyp1) (hyp2) (hyp3) (hyp4) (hyp5) (hyp6) (hyp7) (hyp8) (hyp9))
       (preference h0 (hyp0) 0.69314718))))
PDDL
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl pref.pddl evidence-3.txt \
     --horizon 6 --priors-from-preferences --out r-pref >/dev/null 2>&1
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl evidence-3.txt \
     --horizon 6 --prior hyp0=2 --out r-p2 >/dev/null 2>&1
PP=$(awk -F'\t' '$1=="hyp0"{print $7}' r-pref/summary.tsv 2>/dev/null)
P2=$(awk -F'\t' '$1=="hyp0"{print $7}' r-p2/summary.tsv 2>/dev/null)
if [[ -n "$PP" && "$PP" == "$P2" ]]; then
  ok "a preference weight w gives prior exp(w) (posterior $PP)"
else
  bad "a preference weight w gives prior exp(w)" "preference gave '$PP', --prior hyp0=2 gave '$P2'"
fi
# Stripping: the weight is the prior and must NOT also be charged as a cost, so
# the costs must match the same problem without the preference.
CP=$(awk -F'\t' '$1=="hyp1"{print $2"/"$3}' r-pref/summary.tsv 2>/dev/null)
CN=$(awk -F'\t' '$1=="hyp1"{print $2"/"$3}' r-p2/summary.tsv 2>/dev/null)
[[ -n "$CP" && "$CP" == "$CN" ]] \
  && ok "the preference is stripped from the cost model (c=$CP)" \
  || bad "the preference is stripped from the cost model" "with preference $CP, without $CN"

expect_err "--priors-from-preferences is refused under best-rival" "needs --baseline per-hypothesis" \
  intrusion-detection-costs.pddl pref.pddl evidence-3.txt --horizon 6 \
  --priors-from-preferences --baseline best-rival
expect_err "--priors-from-preferences with --prior is refused" "not both" \
  intrusion-detection-costs.pddl pref.pddl evidence-3.txt --horizon 6 \
  --priors-from-preferences --prior hyp0=2
expect_err "--priors-from-preferences with no preference is refused" "no preference on a hypothesis" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --horizon 6 --priors-from-preferences

# --- 6. slice-pinned FiFO evidence still works through the fast path --------
printf '(occurs (recon taurus) 1)\n' > fifoev.txt
bash "$BIN/recognize.sh" intrusion-detection-costs.pddl problem.pddl fifoev.txt \
     --evidence-kind fifo --horizon 6 --out r-fifo >/dev/null 2>&1
if grep -q '^hyp0	20	20	0' r-fifo/summary.tsv 2>/dev/null; then
  ok "slice-pinned FiFO evidence takes the fast path too"
else
  bad "slice-pinned FiFO evidence takes the fast path too" "$(sed -n 2p r-fifo/summary.tsv 2>&1)"
fi

echo
echo "=== recognize.sh: hypotheses read from the goal ==="

# A 3x3 road-only grid, one truck at p1-1, two goal literals at distance 2.
# The first drive goes to p1-2, toward p1-3: complying costs 2 for p1-3 and 4
# for p3-1 (a detour).  Not complying costs 2 for both: with the horizon's slack
# the truck can wait a slice and then drive.  So the deltas are 0 and -2, the
# posterior must favour p1-3, and that is what keeps these cases from
# passing vacuously: every comparison below is between non-uniform results.
bash "$REPO/SatPlan/ppgen.sh" --style grid --dimensions 3 3 --airports 0 --trucks 1 \
     --packages 0 --mindist 1 --seed 1 -o grid-base.pddl 2>/dev/null
lit_problem() {   # lit_problem <out.pddl> <goal>
  sed "/(:goal/,/^\$/c\\
  (:goal $2)\\
" grid-base.pddl > "$1"
}
GOAL2='(or (at truck1 p1-3) (at truck1 p3-1))'
lit_problem lit.pddl "$GOAL2"
printf '(and\n  (occurs (drive truck1 p1-1 p1-2) 1))\n' > lit-ev.txt
printf '(occur-in-order (drive truck1 p1-1 p1-2))\n' > lit-ord.txt
GD="$REPO/pddl/clara-logistics.pddl"
rec() { local out="$1"; shift; bash "$BIN/recognize.sh" "$GD" "$@" --horizon 5 --out "$out" > "$out.log" 2>&1; }
# The scores without the hypothesis names, which differ between spellings.
scores() { cut -f2- "$1/summary.tsv" 2>/dev/null; }

rec r-lit lit.pddl lit-ev.txt --evidence-kind fifo
if awk -F'\t' '$1=="at-truck1-p1-3"{a=$7} $1=="at-truck1-p3-1"{b=$7} END{exit !(a>b && a>0)}' r-lit/summary.tsv 2>/dev/null \
   && grep -q "^at-truck1-p1-3	2	2	0	" r-lit/summary.tsv && grep -q "^at-truck1-p3-1	4	2	-2	" r-lit/summary.tsv; then
  ok "ground goal literals are hypotheses (deltas 0 and -2, favours p1-3)"
else
  bad "ground goal literals are hypotheses" "$(tr '\n' ' ' < r-lit/summary.tsv 2>/dev/null; tail -2 r-lit.log)"
fi

rec r-lit-slow lit.pddl lit-ev.txt --evidence-kind fifo --method plan-runs
diff -q r-lit/summary.tsv r-lit-slow/summary.tsv >/dev/null 2>&1 \
  && ok "literal hypotheses: fast and plan-runs agree exactly" \
  || bad "literal hypotheses: fast and plan-runs agree exactly" "$(diff r-lit/summary.tsv r-lit-slow/summary.tsv 2>&1 | head -3 | tr '\n' ' ')"

rec r-lit-atoms lit.pddl lit-ev.txt --evidence-kind fifo --create-hypothesis-atoms
if diff -q r-lit/summary.tsv r-lit-atoms/summary.tsv >/dev/null 2>&1 \
   && grep -q 'derived atom (rechyp0)' r-lit-atoms.log; then
  ok "--create-hypothesis-atoms: derived atoms, identical results"
else
  bad "--create-hypothesis-atoms: derived atoms, identical results" "$(diff r-lit/summary.tsv r-lit-atoms/summary.tsv 2>&1 | head -3 | tr '\n' ' ')"
fi

rec r-lit-ord lit.pddl lit-ord.txt
rec r-lit-ord-slow lit.pddl lit-ord.txt --method plan-runs
if grep -q '^at-truck1-p1-3	' r-lit-ord/summary.tsv 2>/dev/null \
   && diff -q r-lit-ord/summary.tsv r-lit-ord-slow/summary.tsv >/dev/null 2>&1 \
   && awk -F'\t' '$1=="at-truck1-p1-3"{a=$7} $1=="at-truck1-p3-1"{b=$7} END{exit !(a>b)}' r-lit-ord/summary.tsv; then
  ok "literal hypotheses with ordering evidence, fast == plan-runs"
else
  bad "literal hypotheses with ordering evidence" "$(tr '\n' ' ' < r-lit-ord/summary.tsv 2>/dev/null; diff r-lit-ord/summary.tsv r-lit-ord-slow/summary.tsv 2>&1 | head -2)"
fi

# Exclusivity clauses are ignored: dropped from the problem both methods score.
lit_problem lit-x.pddl "(and $GOAL2 (or (not (at truck1 p1-3)) (not (at truck1 p3-1))))"
rec r-lit-x lit-x.pddl lit-ev.txt --evidence-kind fifo
if diff -q r-lit/summary.tsv r-lit-x/summary.tsv >/dev/null 2>&1 \
   && ! sed -n '/(:goal/,$p' r-lit-x/rec-problem-base.pddl | grep -q '(not'; then
  ok "exclusivity clauses are accepted and dropped"
else
  bad "exclusivity clauses are accepted and dropped" "$(tail -2 r-lit-x.log)"
fi

# A disjunct that is not an atom gets a derived atom, with a warning.  At the
# final slice (and (at truck1 p3-1) (not (at truck1 p2-2))) holds exactly when
# (at truck1 p3-1) does, so the scores must be the literal case's.
lit_problem lit-c.pddl '(or (at truck1 p1-3) (and (at truck1 p3-1) (not (at truck1 p2-2))))'
rec r-lit-c lit-c.pddl lit-ev.txt --evidence-kind fifo
if grep -q 'WARNING: hypothesis (and (at truck1 p3-1)' r-lit-c.log \
   && [[ -n "$(scores r-lit)" && "$(scores r-lit)" == "$(scores r-lit-c)" ]]; then
  ok "a complex hypothesis gets a derived atom, with a warning"
else
  bad "a complex hypothesis gets a derived atom, with a warning" "$(grep -i warn r-lit-c.log | head -1); $(scores r-lit-c | tr '\n' ' ')"
fi

# Goal preferences stay in the costs on BOTH methods.  plan-runs used to replace
# the whole goal with the hypothesis, dropping every preference.  Not stripped
# (no --priors-from-preferences), the weight 5 is charged whenever p3-1 is the
# hypothesis, so it shows in p3-1's costs -- and must on both methods.
lit_problem lit-p.pddl "(and $GOAL2 (preference end-p1-3 (at truck1 p1-3) 5))"
rec r-lit-p lit-p.pddl lit-ev.txt --evidence-kind fifo
rec r-lit-p-slow lit-p.pddl lit-ev.txt --evidence-kind fifo --method plan-runs
if grep -q '^at-truck1-p3-1	9	7	' r-lit-p/summary.tsv 2>/dev/null \
   && diff -q r-lit-p/summary.tsv r-lit-p-slow/summary.tsv >/dev/null 2>&1; then
  ok "goal preferences count on both methods (p3-1 costs 9/7)"
else
  bad "goal preferences count on both methods" "fast: $(sed -n '/p3-1/p' r-lit-p/summary.tsv 2>&1) slow: $(sed -n '/p3-1/p' r-lit-p-slow/summary.tsv 2>&1)"
fi

# --priors-from-preferences matches a preference on a literal hypothesis.
lit_problem lit-pp.pddl "(and $GOAL2 (preference h (at truck1 p3-1) 0.69314718))"
rec r-lit-pp lit-pp.pddl lit-ev.txt --evidence-kind fifo --priors-from-preferences
rec r-lit-p2 lit.pddl lit-ev.txt --evidence-kind fifo --prior at-truck1-p3-1=2
PP=$(awk -F'\t' '$1=="at-truck1-p3-1"{print $7}' r-lit-pp/summary.tsv 2>/dev/null)
P2=$(awk -F'\t' '$1=="at-truck1-p3-1"{print $7}' r-lit-p2/summary.tsv 2>/dev/null)
[[ -n "$PP" && "$PP" == "$P2" ]] \
  && ok "a preference on a literal hypothesis gives its prior ($PP)" \
  || bad "a preference on a literal hypothesis gives its prior" "preference '$PP', --prior '$P2'"

# --- review fixes ----------------------------------------------------------
# Observations are counted from the parsed evidence: an evgen-style comment
# holding "(...)" must not count as one (it raised the default horizon).
{ echo ';; (order only: the slices are not fixed).'; cat lit-ord.txt; } > lit-ord-c.txt
bash "$BIN/recognize.sh" "$GD" lit.pddl lit-ord-c.txt --out r-lit-oc > r-lit-oc.log 2>&1
grep -q 'observations = 1)' r-lit-oc.log \
  && ok "a comment is not counted as an observation" \
  || bad "a comment is not counted as an observation" "$(grep 'observations' r-lit-oc.log)"

# Several preferences on one hypothesis: penalties add, so the prior is
# exp(w1 + w2) -- here exp(0.3 + 0.39314718) = 2, exactly --prior ...=2.
lit_problem lit-pp2.pddl "(and $GOAL2 (preference a (at truck1 p3-1) 0.3) (preference b (at truck1 p3-1) 0.39314718))"
rec r-lit-pp2 lit-pp2.pddl lit-ev.txt --evidence-kind fifo --priors-from-preferences
PP2=$(awk -F'\t' '$1=="at-truck1-p3-1"{print $7}' r-lit-pp2/summary.tsv 2>/dev/null)
[[ -n "$PP2" && "$PP2" == "$P2" ]] \
  && ok "two preferences on one hypothesis add ($PP2)" \
  || bad "two preferences on one hypothesis add" "got '$PP2', --prior gave '$P2'"

# Floats survive the rewrite at full precision.
lit_problem lit-f.pddl "(and $GOAL2 (preference far (at truck1 p1-3) 0.123456789))"
rec r-lit-f lit-f.pddl lit-ev.txt --evidence-kind fifo
grep -q '0.123456789' r-lit-f/rec-problem-base.pddl 2>/dev/null \
  && ok "float weights keep full precision in the scored problem" \
  || bad "float weights keep full precision in the scored problem" "$(grep -o 'far.*' r-lit-f/rec-problem-base.pddl 2>&1)"

# A set of NEGATED literals is still the hypothesis set beside a preference.
lit_problem lit-n.pddl "(and (or (not (at truck1 p1-3)) (not (at truck1 p3-1))) (preference q (at truck1 p1-3) 1))"
rec r-lit-n lit-n.pddl lit-ev.txt --evidence-kind fifo
if ! grep -q 'conjunction with no' r-lit-n.log && [[ "$(grep -c '^rechyp' r-lit-n/summary.tsv 2>/dev/null)" == 2 ]]; then
  ok "a negated hypothesis set beside a preference is read"
else
  bad "a negated hypothesis set beside a preference is read" "$(grep -m1 'recognize.sh:' r-lit-n.log)"
fi

# Report names stay distinct even when a renamed one could collide.
lit_problem lit-nm.pddl '(or (on-a-b 3) (on a b) (on-a b))'
NAMES=$(sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/recognition-goal.lisp\")" \
          --eval "(rg-prepare \"$TMP/lit-nm.pddl\" \"$GD\" \"$TMP/\")" 2>/dev/null | awk -F'\t' '$1=="HYP"{print $2}')
[[ "$(sort -u <<<"$NAMES" | wc -l | tr -d ' ')" == 3 ]] \
  && ok "hypothesis names are distinct ($(echo $NAMES))" \
  || bad "hypothesis names are distinct" "$(echo $NAMES)"

# A stale assertion from an earlier run in the same --out is not reused: the
# second evidence cannot be split, so the run must say so, not condition on
# the first run's assertion.
rec r-stale lit.pddl lit-ord.txt
printf '(and (occur-in-order (drive truck1 p1-1 p1-2)) (never (drive truck1 p1-2 p2-2)))\n' > lit-ord2.txt
bash "$BIN/recognize.sh" "$GD" lit.pddl lit-ord2.txt --horizon 5 --out r-stale > r-stale2.log 2>&1
grep -q 'no assertion literal was written' r-stale2.log \
  && ok "a stale assertion from an earlier run is not reused" \
  || bad "a stale assertion from an earlier run is not reused" "$(tail -2 r-stale2.log | tr '\n' ' ')"

# What the reader refuses, each with its reason.
lit_problem lit-2.pddl '(and (or (at truck1 p1-3) (at truck1 p3-1)) (or (at truck1 p2-3) (at truck1 p3-2)))'
expect_err "two hypothesis sets are refused, not yet supported" "2 hypothesis sets" \
  "$GD" lit-2.pddl lit-ev.txt --evidence-kind fifo --horizon 5
expect_err "  ... and the message says it is not supported yet" "not supported yet" \
  "$GD" lit-2.pddl lit-ev.txt --evidence-kind fifo --horizon 5
lit_problem lit-and.pddl '(and (at truck1 p1-3) (at truck1 p3-1))'
expect_err "a plain conjunction is not read as hypotheses" "conjunction with no (or" \
  "$GD" lit-and.pddl lit-ev.txt --evidence-kind fifo --horizon 5
lit_problem lit-hard.pddl "(and $GOAL2 (at truck1 p2-2))"
expect_err "another hard goal beside the hypotheses is refused" "hard goal beside the hypotheses" \
  "$GD" lit-hard.pddl lit-ev.txt --evidence-kind fifo --horizon 5
lit_problem lit-xo.pddl "(and $GOAL2 (or (not (at truck1 p1-3)) (not (at truck1 p2-2))))"
expect_err "an exclusivity clause outside the set is refused" "not one of the hypotheses" \
  "$GD" lit-xo.pddl lit-ev.txt --evidence-kind fifo --horizon 5
lit_problem lit-var.pddl '(or (at truck1 p1-3) (at truck1 ?p))'
expect_err "a hypothesis with a free variable is refused" "free variable" \
  "$GD" lit-var.pddl lit-ev.txt --evidence-kind fifo --horizon 5

# --stop-after skips the INSTALLED checks of the counter and MaxSAT solver, not
# the names: a typo is still refused before any work.
expect_err "--stop-after still refuses an unknown --counter" "unknown counter" \
  "$GD" lit.pddl lit-ev.txt --evidence-kind fifo --horizon 5 --stop-after scnf --counter d44
expect_err "--stop-after still refuses an unknown --maxsat-solver" "unknown solver" \
  "$GD" lit.pddl lit-ev.txt --evidence-kind fifo --horizon 5 --stop-after scnf --maxsat-solver wmaxcdc

# --timeout reaches the horizon search's planner.sh runs.  Their SAT solves had
# the fixed 600 s cap: one stopped there read as "unreachable", and H stayed too
# short for that hypothesis.  A stand-in SAT solver that never answers must be
# stopped at the limit -- the log says so -- within seconds.
printf '#!/bin/sh\nexec sleep 60\n' > stall-sat; chmod +x stall-sat
T0=$SECONDS
bash "$BIN/recognize.sh" "$GD" lit.pddl lit-ev.txt --evidence-kind fifo --solver "$TMP/stall-sat" \
     --timeout 1 --out r-hto > r-hto.log 2>&1
EL=$((SECONDS - T0))
if grep -q 'stopped after the 1 s limit' r-hto/horizon-*.log 2>/dev/null && (( EL < 120 )); then
  ok "--timeout reaches the horizon search ($EL s)"
else bad "--timeout reaches the horizon search" "$EL s: $(cat r-hto/horizon-*.log 2>/dev/null | grep -m1 -i 'limit\|fail')"; fi

# --planner-timeout reaches the watchdog round each planner.sh run.  It was a
# fixed 900 s: FourPackage's 15x15 instantiations were killed there whatever limit
# the caller gave.  The same stalled SAT solver, now with no solver limit, must be
# killed by the watchdog at 2 s, not at 900.
T0=$SECONDS
bash "$BIN/recognize.sh" "$GD" lit.pddl lit-ev.txt --evidence-kind fifo --solver "$TMP/stall-sat" \
     --timeout none --planner-timeout 2 --out r-pto > r-pto.log 2>&1
EL=$((SECONDS - T0))
if grep -q 'planner exceeded 2s' r-pto.log && (( EL < 120 )); then
  ok "--planner-timeout reaches the planner watchdog ($EL s)"
else bad "--planner-timeout reaches the planner watchdog" "$EL s: $(grep -m1 -i 'exceeded\|fail' r-pto.log)"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
