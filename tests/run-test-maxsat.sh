#!/bin/bash
#
# run-test-maxsat.sh -- regression tests for the MaxSAT side of `solve`: the
# solver options, the *solver-timeout* limit, and MaxPre 2 preprocessing.
#
# These are behavioral checks against a tiny instance whose optimum is known by
# hand, not gold-file diffs.  The grocery instance below has
#
#     (weight (buy banana)  1.25)   (weight (buy steak) 15.50)
#     (weight (buy milk)    3.10)   (or (buy steak) (buy milk))
#
# so the cheapest model buys milk and nothing else.  Weights are scaled by 20 to
# make them integral, hence a solver objective of 62 = 3.10 * 20.
#
# The MaxPre cases matter most: MaxPre renumbers and eliminates variables (it
# collapses this instance from three variables to one), so a model of the
# preprocessed instance is meaningless against the original .map file.  Without
# the reconstruction step the answer comes back as (BUY STEAK) -- a plausible
# looking wrong answer rather than a crash, which is exactly the kind of
# regression that needs a test.
#
# Run from anywhere:  bash tests/run-test-maxsat.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.
#
# Skips cleanly (exit 0) when the MaxSAT solver is not installed, like the other
# optional-dependency suites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"

PASS=0; FAIL=0

ok()   { printf '  %-52s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  %-52s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# --- optional dependencies --------------------------------------------------
SOLVER=""
for s in tt-open-wbo-inc-Glucose4_1 tt-open-wbo-inc-IntelSATSolver nuwls-c; do
  if command -v "$s" >/dev/null 2>&1; then SOLVER="$s"; break; fi
done
if [[ -z "$SOLVER" ]]; then
  echo "no MaxSAT solver found (tt-open-wbo-inc-* or nuwls-c) -- skipping"
  exit 0
fi
HAVE_MAXPRE=0
command -v maxpre >/dev/null 2>&1 && HAVE_MAXPRE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

cat > groceries.wff <<'EOF'
(domain item (set banana steak milk))
(weight (buy banana) 1.25)
(weight (buy steak) 15.50)
(weight (buy milk) 3.10)
(or (buy steak) (buy milk))
EOF

# run_solve <answer-file> <extra solve keywords...> ; prints nothing, writes the file
run_solve() {
  local out="$1"; shift
  sbcl --noinform --disable-debugger --load "$FIFO" \
       --eval "(progn (solve \"groceries.wff\" :solnfile \"$out\" $*) (sb-ext:exit))" \
       >/dev/null 2>&1
}

objective() { grep -o '(\*OBJECTIVE\* [0-9]*)' "$1" 2>/dev/null | grep -o '[0-9]*' | head -1; }
has_atom()  { grep -qi "^($2)$" "$1"; }

echo "=== MaxSAT solve tests (solver: $SOLVER) ==="

# 1. Baseline: weighted solve finds the known optimum.
run_solve base.answer ":solver \"$SOLVER\" :cnf-format (quote WCNF)"
if [[ "$(objective base.answer)" == "62" ]] && has_atom base.answer "BUY MILK"; then
  ok "weighted solve finds the optimum (62 = 3.10 x 20)"
else
  bad "weighted solve finds the optimum (62 = 3.10 x 20)" "got: $(tr '\n' ' ' < base.answer)"
fi

# 2. The optimal model must NOT contain the expensive items.
if ! has_atom base.answer "BUY STEAK" && ! has_atom base.answer "BUY BANANA"; then
  ok "optimum excludes the costlier items"
else
  bad "optimum excludes the costlier items" "$(tr '\n' ' ' < base.answer)"
fi

# 3. Solver abbreviations resolve through the :solver keyword.
if command -v nuwls-c >/dev/null 2>&1; then
  run_solve nuwls.answer ":solver \"nuwls\" :cnf-format (quote WCNF)"
  if [[ "$(objective nuwls.answer)" == "62" ]]; then
    ok "solve :solver \"nuwls\" resolves the abbreviation"
  else
    bad "solve :solver \"nuwls\" resolves the abbreviation" "got: $(tr '\n' ' ' < nuwls.answer)"
  fi
else
  printf '  %-52s ... SKIP  (nuwls-c not installed)\n' "solve :solver \"nuwls\" resolves the abbreviation"
fi

# 4. A plain SAT solve still works -- no weights, no timeout interference.
run_solve plain.answer ":solver \"kissat\""
if grep -qi "^SAT$" plain.answer; then
  ok "unweighted solve is unaffected"
else
  bad "unweighted solve is unaffected" "$(head -1 plain.answer)"
fi

# 5. NIL, 0 and -1 all mean "no limit".
LIMITS="$(sbcl --noinform --disable-debugger --load "$FIFO" --eval '(progn
  (format t "~S ~S ~S ~S~%" (solver-time-limit nil) (solver-time-limit 0)
          (solver-time-limit -1) (solver-time-limit 30)) (sb-ext:exit))' 2>/dev/null | tail -1)"
if [[ "$LIMITS" == "NIL NIL NIL 30" ]]; then
  ok "timeout of NIL / 0 / -1 all mean no limit"
else
  bad "timeout of NIL / 0 / -1 all mean no limit" "got: $LIMITS"
fi

# 6. The default limit is 10 minutes.
DEFAULT="$(sbcl --noinform --disable-debugger --load "$FIFO" \
           --eval '(progn (format t "~S~%" *solver-timeout*) (sb-ext:exit))' 2>/dev/null | tail -1)"
if [[ "$DEFAULT" == "600" ]]; then
  ok "*solver-timeout* defaults to 600 seconds"
else
  bad "*solver-timeout* defaults to 600 seconds" "got: $DEFAULT"
fi

# 7. A generous timeout does not disturb a solve that finishes on its own.
run_solve timed.answer ":solver \"$SOLVER\" :cnf-format (quote WCNF) :timeout 120"
if [[ "$(objective timed.answer)" == "62" ]]; then
  ok "a timeout larger than the solve is a no-op"
else
  bad "a timeout larger than the solve is a no-op" "got: $(tr '\n' ' ' < timed.answer)"
fi

# 8. Asking for a preprocessor on an UNweighted problem is an error, not a
#    silent hand-off of plain CNF to a MaxSAT preprocessor.
if [[ "$HAVE_MAXPRE" -eq 1 ]]; then
  ERR="$(sbcl --noinform --disable-debugger --load "$FIFO" --eval '(progn
    (setq *solver* "kissat" *cnf-format* (quote CNF) *preprocessor* "maxpre")
    (satisfy "nosuch.cnf") (sb-ext:exit))' 2>&1)"
  run_solve pre-cnf.answer ":solver \"kissat\" :preprocessor \"maxpre\""
  if grep -qi "preprocessor" pre-cnf.answer 2>/dev/null || [[ ! -s pre-cnf.answer ]] \
     || grep -qi "cnf-format" <<<"$ERR"; then
    ok "preprocessor + unweighted CNF is rejected"
  else
    bad "preprocessor + unweighted CNF is rejected" "$(tr '\n' ' ' < pre-cnf.answer)"
  fi
else
  printf '  %-52s ... SKIP  (maxpre not installed)\n' "preprocessor + unweighted CNF is rejected"
fi

# --- MaxPre preprocessing ---------------------------------------------------
if [[ "$HAVE_MAXPRE" -eq 1 ]]; then
  # 9. Preprocessing must give the SAME answer as not preprocessing.  This is
  #    the reconstruction test: MaxPre reduces this instance to one variable, so
  #    without mapping the model back the answer would be (BUY STEAK).
  run_solve pre.answer ":solver \"$SOLVER\" :cnf-format (quote WCNF) :preprocessor \"maxpre\""
  if [[ "$(objective pre.answer)" == "62" ]] && has_atom pre.answer "BUY MILK" \
     && ! has_atom pre.answer "BUY STEAK"; then
    ok "MaxPre + reconstruction reproduces the exact answer"
  else
    bad "MaxPre + reconstruction reproduces the exact answer" "got: $(tr '\n' ' ' < pre.answer)"
  fi

  # 10. The preprocessed instance really is smaller -- otherwise case 9 proves
  #     nothing about reconstruction.  Compare the width of the 'v' bit string
  #     before and after reconstruction: that is the model, one character per
  #     variable, so it measures the renumbering directly (counting integers in
  #     the .wcnf would instead pick up soft-clause weights).
  PRE_SAT="$(ls scratch-*-pre.satout 2>/dev/null | head -1)"
  POST_SAT="$(ls scratch-*.satout 2>/dev/null | grep -v -- '-pre\.satout' | head -1)"
  if [[ -n "$PRE_SAT" && -n "$POST_SAT" ]]; then
    PRE_BITS=$(grep '^v ' "$PRE_SAT"  | tail -1 | sed 's/^v //;s/ //g' | tr -d '\n' | wc -c | tr -d ' ')
    POST_BITS=$(grep '^v ' "$POST_SAT" | tail -1 | sed 's/^v //;s/ //g' | tr -d '\n' | wc -c | tr -d ' ')
    if [[ "$PRE_BITS" -gt 0 && "$POST_BITS" -eq 3 && "$PRE_BITS" -lt "$POST_BITS" ]]; then
      ok "MaxPre renumbered ($PRE_BITS-var model -> $POST_BITS-var model)"
    else
      bad "MaxPre renumbered" "preprocessed model $PRE_BITS bits, reconstructed $POST_BITS"
    fi
  else
    bad "MaxPre renumbered" "no scratch-*-pre.satout was written"
  fi
else
  printf '  %-52s ... SKIP  (maxpre not installed)\n' "MaxPre + reconstruction reproduces the exact answer"
  printf '  %-52s ... SKIP  (maxpre not installed)\n' "MaxPre actually renumbered"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
