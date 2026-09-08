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
printf '1\n' > one-weight.txt

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

# --- 5. flags ---------------------------------------------------------------
errs() { local out; out="$(bash "$BIN/recognize.sh" "$@" 2>&1)"; printf '%s' "$out"; }
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
BRSUM=$(awk -F'\t' 'NR>1{s+=$7} END{print (s>0.9 && s<1.1) ? "ok" : "bad:"s}' r-br/summary.tsv 2>/dev/null)
if [[ "$BRSUM" == "ok" ]]; then
  ok "best-rival reports a real posterior (sums to 1, not all zero)"
else
  bad "best-rival reports a real posterior (sums to 1, not all zero)" "posteriors sum to ${BRSUM#bad:}"
fi
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
for f in --counter --baseline --maxsat-solver --method; do
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
expect_err "a --priors count mismatch is refused" "but there are" \
  intrusion-detection-costs.pddl problem.pddl evidence-3.txt --horizon 6 \
  --baseline best-rival --priors one-weight.txt

# --priors must REACH marginals.sh on the path that reports its posterior; the
# awk that would otherwise apply them never runs there.
printf '9\n1\n1\n1\n1\n1\n1\n1\n1\n1\n' > skew.txt
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
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
