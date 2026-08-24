#!/bin/bash
#
# run-test-mcsat.sh -- regression tests for the MC-SAT marginal-inference back end
# (bin/marginals.sh --solver mc-sat, lisp/mcsat.lisp), which samples rather than
# counts: it hands one weighted CNF to WalkSAT v58's -mcsat mode and reads every
# marginal back from a single run.
#
# These are BEHAVIORAL checks, not gold diffs -- the output is a Monte-Carlo
# estimate.  Each case fixes --seed and asserts the sampled marginals agree with
# the EXACT ones (bin/marginals.sh's default maxent enumeration) to a tolerance.
#
# MC-SAT needs WalkSAT version 58 or later; when no such binary is found the suite
# skips cleanly (exit 0), like the other optional-dependency back ends.
#
# Run from anywhere:  bash tests/run-test-mcsat.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override, and
# WALKSAT to point at the v58 binary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
MARGINALS="$REPO/bin/marginals.sh"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2          # keep marginals scratch files out of the repo

if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

# --- locate the MC-SAT-capable binary, exactly as marginals.sh does -----------
WS="${WALKSAT:-}"
if [[ -z "$WS" ]]; then
  SIBLING="$FIFO_LISP/../../Walksat/Walksat_v58_MC-SAT/walksat"
  if [[ -x "$SIBLING" ]]; then WS="$SIBLING"; else WS="walksat"; fi
fi
if ! command -v "$WS" >/dev/null 2>&1 && [[ ! -x "$WS" ]]; then
  echo "=== MC-SAT marginals: SKIPPED (no walksat binary found) ==="; exit 0
fi
if ! grep -q -- "-mcsat" <<<"$("$WS" -help </dev/null 2>&1 || true)"; then
  echo "=== MC-SAT marginals: SKIPPED ('$WS' has no -mcsat; needs WalkSAT v58+) ==="; exit 0
fi
export WALKSAT="$WS"

SEED=20260823
SAMPLES=200000
TOL=0.015                    # generous enough for 200k correlated samples

PASS=0; FAIL=0
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }

# marginal <file> <atom-text> -- the probability on the (MARGINAL <atom> <p>) line
marginal() {
  awk -v pat="(MARGINAL $2 " 'index($0, pat)==1 {
        p=substr($0, length(pat)+1); sub(/\).*$/, "", p); print p; exit }' "$1"
}

# close <a> <b> <tol> -- numeric comparison
close() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{ exit !(a-b<t && b-a<t) }'; }

mcsat() { bash "$MARGINALS" --solver mc-sat --seed "$SEED" --samples "$SAMPLES" "$@"; }
exact() { bash "$MARGINALS" "$@"; }

# agree <scnf> <label> [shared args...] -- every sampled marginal within TOL of the
# exact one.  Shared args go to BOTH back ends; MC_EXTRA holds mc-sat-only flags.
MC_EXTRA=()
agree() {
  local scnf="$1" label="$2"; shift 2
  printf '  %-52s ... ' "$label"
  if ! mcsat "$scnf" "$@" ${MC_EXTRA[@]+"${MC_EXTRA[@]}"} >"$TMP/mc.out" 2>"$TMP/mc.err"; then
    fail "mc-sat run failed: $(tail -1 "$TMP/mc.err")"; return
  fi
  if ! exact "$scnf" "$@" >"$TMP/ex.out" 2>"$TMP/ex.err"; then
    fail "exact run failed: $(tail -1 "$TMP/ex.err")"; return
  fi
  # "(MARGINAL <atom...> <p>)" -> "<atom>|<p>", so the two runs are matched by ATOM
  # rather than by line order (the back ends need not sort identically).
  local split='/^\(MARGINAL /{ p=$NF; sub(/\)$/,"",p); $1=""; $NF="";
                               a=$0; gsub(/^ +| +$/,"",a); print a "|" p }'
  awk "$split" "$TMP/mc.out" >"$TMP/mc.m"
  awk "$split" "$TMP/ex.out" >"$TMP/ex.m"
  if [[ ! -s "$TMP/mc.m" ]]; then fail "mc-sat produced no marginals"; return; fi
  local report
  report=$(awk -F'|' '
      NR==FNR { e[$1]=$2; n++; next }
      { m++
        if (!($1 in e)) { miss = miss " " $1; next }
        d = $2 - e[$1]; if (d < 0) d = -d
        if (d > w) { w = d; at = $1 } }
      END { if (m != n) printf "atom-set mismatch: %d sampled vs %d exact\n", m, n
            else if (miss != "") printf "atoms missing from exact:%s\n", miss
            else printf "%.4f %s\n", w, at }' "$TMP/ex.m" "$TMP/mc.m")
  local worst="${report%% *}"
  if [[ ! "$worst" =~ ^[0-9.]+$ ]]; then fail "$report"; return; fi
  if close "$worst" 0 "$TOL"; then pass
  else fail "worst |mc-sat - exact| = $report > $TOL"; fi
}

echo "=== MC-SAT marginal inference (walksat: $WS) ==="

# ---------------------------------------------------------------------------
# 1. Accuracy against exact enumeration on the documented example, which mixes
#    a positive cost, a NEGATIVE cost -- (WEIGHT (NOT (BUY MILK)) 220), i.e. a
#    reward for MILK -- hard unit clauses, and an unweighted atom.
# ---------------------------------------------------------------------------
agree "$REPO/Probability/test_marginals_reweighted.scnf" "mixed signs + hard units vs exact"

# ---------------------------------------------------------------------------
# 2. Sign convention on a single free atom: cost c on A means P(A) = sigmoid(-c),
#    and negating the cost flips it.  Checked against the closed form, not just
#    against the other back end.
# ---------------------------------------------------------------------------
sigmoid_check() {   # <weight-form> <expected p> <label>
  printf '  %-52s ... ' "$3"
  printf '(OR A (NOT A))\n%s\n' "$1" >"$TMP/one.scnf"
  mcsat "$TMP/one.scnf" >"$TMP/one.out" 2>&1 || { fail "run failed"; return; }
  local got; got=$(marginal "$TMP/one.out" A)
  if [[ -n "$got" ]] && close "$got" "$2" "$TOL"; then pass; else fail "P(A)=$got, expected $2"; fi
}
# cost +1 when A true  -> P(A) = 1/(1+e^1) = 0.2689
sigmoid_check '(WEIGHT A 1)' 0.268941 "positive cost: P(A) = sigmoid(-1)"
# cost -1 when A true  -> P(A) = 1/(1+e^-1) = 0.7311
sigmoid_check '(WEIGHT A -1)' 0.731059 "negative cost flips it: P(A) = sigmoid(1)"

# ---------------------------------------------------------------------------
# 3. Pure hard clauses, no weights: uniform over the feasible set.  (OR A B) has
#    three models, so each atom is true in 2 of 3.
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "unweighted (or a b): uniform, P = 2/3"
printf '(OR A B)\n' >"$TMP/hard.scnf"
mcsat "$TMP/hard.scnf" >"$TMP/hard.out" 2>&1
pa=$(marginal "$TMP/hard.out" A); pb=$(marginal "$TMP/hard.out" B)
if [[ -n "$pa" && -n "$pb" ]] && close "$pa" 0.666667 "$TOL" && close "$pb" 0.666667 "$TOL"; then
  pass; else fail "P(A)=$pa P(B)=$pb, expected 0.6667"; fi

# ---------------------------------------------------------------------------
# 4. The weight scale recorded in the header is honoured (real cost = weight /
#    scale), as for every other back end.
# ---------------------------------------------------------------------------
agree "$REPO/Probability/test_coupled_reweighted.scnf" "learned weights honour the scale: header"

# ---------------------------------------------------------------------------
# 5. Formula-valued weights: the reified (WEIGHTED-FORMULA n) atoms are hidden
#    from the default listing and reported under --weighted-only, where
#    P(atom) = P(the reified formula).
# ---------------------------------------------------------------------------
cat >"$TMP/formula.wff" <<'WFF'
(weight (and a b) 3.0)
(weight (or c d) 2.0)
(weight (buy banana) 1.25)
WFF
sbcl --noinform --non-interactive \
     --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
     --eval "(instantiate \"$TMP/formula.wff\" :scnfile \"$TMP/formula.scnf\")" \
     >/dev/null 2>&1

printf '  %-52s ... ' "reified formula atoms hidden by default"
mcsat "$TMP/formula.scnf" >"$TMP/f.out" 2>&1
if grep -q '^(MARGINAL ' "$TMP/f.out" && ! grep -q 'WEIGHTED-FORMULA' "$TMP/f.out"; then
  pass; else fail "WEIGHTED-FORMULA leaked into the default listing"; fi

agree "$TMP/formula.scnf" "formula weights vs exact (--weighted-only)" --weighted-only

# ---------------------------------------------------------------------------
# 6. Evidence conditioning.  Sampling with --evidence '(p a)' must match exact
#    enumeration of the same theory with (OR (P A)) asserted as a hard clause.
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "--evidence matches exact conditioning"
printf '(OR (P A) (P B))\n(WEIGHT (P A) 0.4)\n(WEIGHT (P B) -0.7)\n' >"$TMP/ev.scnf"
cp "$TMP/ev.scnf" "$TMP/ev_asserted.scnf"
printf '(OR (P A))\n' >>"$TMP/ev_asserted.scnf"
mcsat "$TMP/ev.scnf" --evidence '(p a)' >"$TMP/ev.mc" 2>&1
exact "$TMP/ev_asserted.scnf" >"$TMP/ev.ex" 2>&1
mb=$(marginal "$TMP/ev.mc" "(P B)"); eb=$(marginal "$TMP/ev.ex" "(P B)")
ma=$(marginal "$TMP/ev.mc" "(P A)")
if [[ -n "$mb" && -n "$eb" ]] && close "$mb" "$eb" "$TOL" && close "$ma" 1.0 0.0001; then
  pass; else fail "P(B|A)=$mb vs exact $eb (and P(A)=$ma should be 1)"; fi

# ---------------------------------------------------------------------------
# 7. --unitprop is an optimization, not a change of distribution: it must give
#    the same answers (it fixes only variables forced in EVERY solution).
# ---------------------------------------------------------------------------
MC_EXTRA=(--unitprop)
agree "$REPO/Probability/test_marginals_reweighted.scnf" "--unitprop leaves the distribution alone"
MC_EXTRA=()

# ---------------------------------------------------------------------------
# 8. Reproducibility: the same --seed reproduces the marginals exactly.
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "same --seed reproduces marginals exactly"
mcsat "$REPO/Probability/test_coupled_reweighted.scnf" 2>/dev/null | grep '^(MARGINAL ' >"$TMP/r1"
mcsat "$REPO/Probability/test_coupled_reweighted.scnf" 2>/dev/null | grep '^(MARGINAL ' >"$TMP/r2"
if [[ -s "$TMP/r1" ]] && cmp -s "$TMP/r1" "$TMP/r2"; then pass; else fail "runs differ at a fixed seed"; fi

# ---------------------------------------------------------------------------
# 9. Diagnostics: the run reports its effective sample size, so a user can tell
#    a well-mixed chain from a frozen one.
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "reports effective sample size / efficiency"
if grep -q 'efficiency=' "$TMP/mc.out"; then pass; else fail "no ess diagnostic line"; fi

# ---------------------------------------------------------------------------
# 10. Unsatisfiable hard clauses must fail loudly, not return garbage marginals.
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "unsatisfiable hard clauses reported as an error"
printf '(OR A)\n(OR (NOT A))\n(WEIGHT A 1)\n' >"$TMP/unsat.scnf"
if mcsat "$TMP/unsat.scnf" --unitprop >"$TMP/u.out" 2>&1; then
  fail "exited 0 on an unsatisfiable theory"
elif grep -qi "unsat" "$TMP/u.out"; then pass
else fail "error message does not mention unsatisfiability"; fi

# ---------------------------------------------------------------------------
# 11. The initial assignment is seeded from the CDCL solver, and a CDCL UNSAT
#     verdict is a proof -- reported at once rather than after 100 futile tries
#     of local search.  (Case 10 above exercised the UNSAT path.)
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "initial assignment seeded from the SAT solver"
mcsat "$REPO/Probability/test_marginals_reweighted.scnf" >"$TMP/seed.out" 2>&1
if grep -q "seeded MC-SAT's initial assignment" "$TMP/seed.out"; then pass
else fail "no CDCL seeding reported"; fi

printf '  %-52s ... ' "seeding is optional (:seed-from-sat nil still works)"
sbcl --noinform --non-interactive \
     --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
     --eval "(load \"$FIFO_LISP/mcsat.lisp\")" \
     --eval "(marginals-mcsat \"$REPO/Probability/test_marginals_reweighted.scnf\"
                :seed 1 :samples 20000 :seed-from-sat nil)" >"$TMP/noseed.out" 2>&1
ns=$(marginal "$TMP/noseed.out" "(BUY MILK)")
if [[ -n "$ns" ]] && close "$ns" 0.935246 0.02 \
   && ! grep -q "seeded MC-SAT" "$TMP/noseed.out"; then pass
else fail "P(MILK)=$ns without seeding"; fi

# ---------------------------------------------------------------------------
# 12. The mixing diagnostic.  A frozen chain returns every marginal pinned at 0
#     or 1, which the ESS estimate cannot distinguish from a determined problem
#     (it has no non-deterministic variables to estimate from).  The Hamming
#     distance between consecutive samples can, and must not cry wolf on an
#     instance that really is determined.
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "reports mixing (Hamming distance between samples)"
if grep -q 'mixing: mean Hamming distance' "$TMP/mc.out"; then pass
else fail "no mixing diagnostic line"; fi

printf '  %-52s ... ' "a genuinely determined theory is not called frozen"
printf '(OR A)\n(OR (NOT B))\n(WEIGHT A 1)\n' >"$TMP/det.scnf"
mcsat "$TMP/det.scnf" --unitprop >"$TMP/det.out" 2>&1
if grep -q 'the distribution is deterministic' "$TMP/det.out" \
   && ! grep -q 'FROZEN' "$TMP/det.out"; then pass
else fail "misreported a determined theory"; fi

# ---------------------------------------------------------------------------
# 13. Wrong-version guard: a WalkSAT without -mcsat must be refused, not silently
#     ignored (v57 and earlier print their help text and exit).
# ---------------------------------------------------------------------------
printf '  %-52s ... ' "binary without -mcsat is refused"
cat >"$TMP/fake-walksat" <<'FAKE'
#!/bin/bash
echo "walksat version 57 November 2023"
echo "  -cutoff N = bound on the number of flips per trial"
exit 1
FAKE
chmod +x "$TMP/fake-walksat"
if bash "$MARGINALS" "$REPO/Probability/test_coupled_reweighted.scnf" \
        --walksat-bin "$TMP/fake-walksat" >"$TMP/v.out" 2>&1; then
  fail "accepted a binary with no -mcsat option"
elif grep -q "version 58" "$TMP/v.out"; then pass
else fail "unhelpful message: $(head -1 "$TMP/v.out")"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
