#!/bin/bash
#
# run-test-solvers.sh -- the shared solver/counter table and the validation
# every CLI now does against it.
#
# The point of lisp/solvers.dat is that the shell and the Lisp cannot drift, so
# the load-bearing case is the one that proves the mechanism rather than the
# current contents: add an entry to a COPY of the table and check that BOTH
# sides pick it up with no code change anywhere.
#
# Most cases need no solver installed -- validation happens before anything is
# translated or solved, which is the other half of the point.
#
# Run from anywhere:  bash tests/run-test-solvers.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
BIN="$REPO/bin"
TABLE="$FIFO_LISP/solvers.dat"

PASS=0; FAIL=0
ok()  { printf '  %-58s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-58s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Capture rather than pipe: these commands exit non-zero by design, and under
# `set -o pipefail` a piped grep reports failure even when it matched.
says() {  # says <label> <pattern> <command...>
  local label="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if grep -q -- "$pat" <<<"$out"; then ok "$label"
  else bad "$label" "got: $(head -1 <<<"$out")"; fi
}

echo "=== the shared solvers.dat table ==="

# --- 1. the two sides agree, entry by entry ---------------------------------
MISMATCH=""
while read -r name canon; do
  [[ -n "$name" ]] || continue
  SH="$(/bin/bash -c "FIFO_LISP='$FIFO_LISP'; source '$BIN/fifo-solvers.sh'; _fifo_resolve_solver '$name'")"
  LI="$(sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
             --eval "(format t \"~A~%\" (resolve-solver-name \"$name\"))" 2>/dev/null | tail -1)"
  [[ "$SH" == "$canon" && "$LI" == "$canon" ]] || MISMATCH="$MISMATCH $name(sh=$SH,lisp=$LI,want=$canon)"
done < <(awk '$1=="solver" && $5!="-" { m=split($5,a,","); for(i=1;i<=m;i++) print a[i], $2 }' "$TABLE")
[[ -z "$MISMATCH" ]] && ok "shell and Lisp resolve every abbreviation identically" \
                     || bad "shell and Lisp resolve every abbreviation identically" "$MISMATCH"

# --- 2. the mechanism, not the contents -------------------------------------
# Add a solver to a copy of the table; both sides must know it with no code change.
cp -R "$FIFO_LISP" "$TMP/lisp"
printf 'solver     my-fake-maxsat   maxsat  exact  mfm  -\n' >> "$TMP/lisp/solvers.dat"
SH="$(/bin/bash -c "FIFO_LISP='$TMP/lisp'; source '$BIN/fifo-solvers.sh'; _fifo_resolve_solver mfm")"
LI="$(sbcl --noinform --non-interactive --eval "(load \"$TMP/lisp/FiFO.lisp\")" \
           --eval '(format t "~A~%" (resolve-solver-name "mfm"))' 2>/dev/null | tail -1)"
if [[ "$SH" == "my-fake-maxsat" && "$LI" == "my-fake-maxsat" ]]; then
  ok "a new table entry reaches BOTH sides with no code change"
else
  bad "a new table entry reaches BOTH sides with no code change" "shell=$SH lisp=$LI"
fi

# A counter added to the table is likewise known to the Lisp's counter list.
printf 'counter    my-fake-counter  exact   builtin  mfc  -\n' >> "$TMP/lisp/solvers.dat"
LI="$(sbcl --noinform --non-interactive --eval "(load \"$TMP/lisp/FiFO.lisp\")" \
           --eval '(format t "~A~%" (member "my-fake-counter" (counter-names) :test (function string=)))' 2>/dev/null | tail -1)"
[[ "$LI" != "NIL" ]] && ok "a new counter entry reaches the Lisp counter list" \
                     || bad "a new counter entry reaches the Lisp counter list" "got $LI"

# --- 3. a missing table is a named error, not "everything is unknown" -------
mv "$TMP/lisp/solvers.dat" "$TMP/lisp/solvers.dat.away"
says "a missing table names the file, from the shell" "solvers.dat not found" \
     env FIFO_LISP="$TMP/lisp" /bin/bash -c 'source '"$BIN"'/fifo-solvers.sh; _fifo_resolve_solver kissat'
OUT="$(sbcl --noinform --non-interactive --eval "(load \"$TMP/lisp/FiFO.lisp\")" 2>&1)"
grep -q "solver table is missing" <<<"$OUT" \
  && ok "a missing table names the file, from the Lisp" \
  || bad "a missing table names the file, from the Lisp" "$(head -1 <<<"$OUT")"
mv "$TMP/lisp/solvers.dat.away" "$TMP/lisp/solvers.dat"

echo
echo "=== validation at every entry point ==="

printf '(or (p a) (p b))\n' > "$TMP/t.wff"

# --- 4. solve.sh / map.sh ---------------------------------------------------
says "solve.sh refuses a MaxSAT solver"          "is a MaxSAT solver"    bash "$BIN/solve.sh" "$TMP/t.wff" --solver nuwls
says "map.sh refuses a plain SAT solver"         "is a plain SAT solver" bash "$BIN/map.sh"   "$TMP/t.wff" --solver kissat
says "solve.sh refuses an unknown solver"        "unknown solver"        bash "$BIN/solve.sh" "$TMP/t.wff" --solver kisat
says "the refusal says how to add one"           "solvers.dat"           bash "$BIN/solve.sh" "$TMP/t.wff" --solver kisat
says "map.sh refuses an unknown preprocessor"    "unknown preprocessor"  bash "$BIN/map.sh"   "$TMP/t.wff" --preprocessor maxpr

# --- 5. planner.sh: refused BEFORE anything is translated -------------------
mkdir -p "$TMP/pl" && cp "$REPO"/SatPlan/Examples/Switch/*.pddl "$TMP/pl/"
says "planner.sh refuses an unknown SAT solver"  "unknown solver" \
     bash "$BIN/planner.sh" "$TMP/pl/switchprob.pddl" --domain "$TMP/pl/switches.pddl" --solver kisat
if [[ -z "$(ls "$TMP/pl"/*.wff 2>/dev/null)" ]]; then
  ok "planner.sh fails before translating (no .wff written)"
else
  bad "planner.sh fails before translating (no .wff written)" "a .wff was written"
fi
says "planner.sh refuses a SAT solver for --weighted-solver" "is a plain SAT solver" \
     bash "$BIN/planner.sh" "$TMP/pl/switchprob.pddl" --domain "$TMP/pl/switches.pddl" --weighted-solver kissat

# --- 6. counters, and the one context asymmetry -----------------------------
says "planner.sh refuses max-term as a counter"  "not available here" \
     bash "$BIN/planner.sh" "$TMP/pl/switchprob.pddl" --domain "$TMP/pl/switches.pddl" --marginals --counter max-term
says "and names the counters it does accept"     "maxent" \
     bash "$BIN/planner.sh" "$TMP/pl/switchprob.pddl" --domain "$TMP/pl/switches.pddl" --marginals --counter max-term
says "marginals.sh refuses an unknown counter"   "unknown counter" \
     bash "$BIN/marginals.sh" "$REPO/Probability/test_coupled.scnf" --solver ddnf

OUT="$(bash "$BIN/marginals.sh" "$REPO/Probability/test_coupled.scnf" --solver dnnf 2>&1)"
grep -q "^(MARGINAL " <<<"$OUT" \
  && ok "marginals.sh accepts the counter abbreviation 'dnnf'" \
  || bad "marginals.sh accepts the counter abbreviation 'dnnf'" "$(head -1 <<<"$OUT")"

# --- 7. recognize.sh validates once, up front -------------------------------
REC="$REPO/SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts"
says "recognize.sh refuses a bad solver immediately" "unknown solver" \
     bash "$BIN/recognize.sh" "$REC/intrusion-detection-costs.pddl" "$REC/problem.pddl" \
          "$REC/evidence-1.txt" --solver kisat --horizon 3

# --- 8. paths are exempt from the recognised-name check ---------------------
OUT="$(/bin/bash -c "FIFO_LISP='$FIFO_LISP'; source '$BIN/fifo-solvers.sh'; _fifo_require_solver '$BIN/rc2-maxsat.py' maxsat t.sh" 2>&1)"
[[ "$OUT" == "$BIN/rc2-maxsat.py" ]] \
  && ok "an explicit path needs no table entry" \
  || bad "an explicit path needs no table entry" "got: $OUT"
says "a path to a nonexistent file is refused" "no such solver" \
     /bin/bash -c "FIFO_LISP='$FIFO_LISP'; source '$BIN/fifo-solvers.sh'; _fifo_require_solver ./nope/solver maxsat t.sh"

# The bundled rc2 lives in bin/, not on PATH, and must still resolve.
OUT="$(/bin/bash -c "FIFO_LISP='$FIFO_LISP'; source '$BIN/fifo-solvers.sh'; _fifo_require_solver rc2 maxsat t.sh" 2>&1)"
[[ "$OUT" == *rc2-maxsat.py ]] \
  && ok "the bundled rc2 resolves to bin/ rather than PATH" \
  || bad "the bundled rc2 resolves to bin/ rather than PATH" "got: $OUT"

# --- 9. bash 3.2 (/bin/bash on macOS) ---------------------------------------
if /bin/bash -c "FIFO_LISP='$FIFO_LISP'; source '$BIN/fifo-solvers.sh'
                 [[ \$(_fifo_resolve_solver nuwls) == nuwls-c ]] &&
                 [[ \$(_fifo_require_counter mcsat marginals t.sh) == mc-sat ]]" 2>/dev/null; then
  ok "fifo-solvers.sh works under /bin/bash ($(/bin/bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1))"
else
  bad "fifo-solvers.sh works under /bin/bash" "needs bash 4 features?"
fi
# planner.sh's --minslices error path used ${v,,}, which is bash 4.0+
says "planner.sh's numeric error path works under bash 3.2" "must be a non-negative integer" \
     /bin/bash "$BIN/planner.sh" "$TMP/pl/switchprob.pddl" --domain "$TMP/pl/switches.pddl" --minslices xyz

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
