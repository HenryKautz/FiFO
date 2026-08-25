#!/bin/bash
#
# run-test-cli.sh -- regression tests for the solve.sh / map.sh drivers.
#
# Covers the output contract, which has to serve two readers at once:
#
#   * humans     a leading ';' line saying what the verdict means and what the
#                lines under it are -- "(X ALICE)" is a variable binding after
#                PROVEN and a true atom after SAT, and nothing in the payload
#                says which
#   * machines   everything that is not a ';' comment is the .answer file,
#                byte for byte, so existing parsers keep working
#
# All five verdicts are exercised, including both answer-extraction outcomes
# (PROVEN with bindings, NOANSWER without), since those are the cases where the
# payload used not to be printed at all.
#
# Run from anywhere:  bash tests/run-test-cli.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
BIN="$REPO/bin"

PASS=0; FAIL=0
ok()  { printf '  %-52s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-52s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

command -v kissat >/dev/null 2>&1 || { echo "kissat not found -- skipping"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# --- fixtures, one per verdict ----------------------------------------------
cat > sat.wff <<'EOF'
(p a)
(or (q b) (q c))
EOF
cat > unsat.wff <<'EOF'
(p a)
(not (p a))
EOF
cat > proven.wff <<'EOF'
(domain person (set alice bob))
(shorter alice bob)
(prove ((x person)) true (shorter x bob))
EOF
cat > noanswer.wff <<'EOF'
(domain person (set alice john))
(exists x person true (happy x))
(prove ((y person)) true (happy y))
EOF
cat > counter.wff <<'EOF'
(domain person (set alice bob))
(happy alice)
(prove () true (happy bob))
EOF

verdict_of() { grep -v '^;' "$1" | head -1; }

echo "=== solve.sh / map.sh output tests ==="

# 1-5.  Each verdict is reported, and reported on stdout rather than only in
#       the answer file.
for pair in "sat.wff SAT" "unsat.wff UNSAT" "proven.wff PROVEN" \
            "noanswer.wff NOANSWER" "counter.wff COUNTEREXAMPLE"; do
  set -- $pair
  wff="$1"; want="$2"
  bash "$BIN/solve.sh" "$wff" > "$wff.out" 2>/dev/null
  got="$(verdict_of "$wff.out")"
  if [[ "$got" == "$want" ]]; then
    ok "solve.sh reports $want on stdout"
  else
    bad "solve.sh reports $want on stdout" "got: '$got'"
  fi
done

# 6.  Answer extraction: the BINDING must appear on stdout, not just the
#     verdict.  This is the case the drivers originally dropped.
if grep -q '^(X ALICE)$' proven.wff.out; then
  ok "extracted binding (X ALICE) is printed"
else
  bad "extracted binding (X ALICE) is printed" "$(tr '\n' ' ' < proven.wff.out)"
fi

# 7.  ... and it is labelled, so a reader knows it is a binding and not an atom.
if grep -q '^;.*binding' proven.wff.out; then
  ok "bindings are labelled as bindings, not atoms"
else
  bad "bindings are labelled as bindings, not atoms" "no ';' line mentions bindings"
fi

# 8.  A model is labelled as a model.
if grep -qi '^;.*true in a model' sat.wff.out; then
  ok "a SAT model is labelled as a model"
else
  bad "a SAT model is labelled as a model" "$(head -1 sat.wff.out)"
fi

# 9.  Machine-readable contract: stdout minus ';' lines IS the answer file.
allok=1
for w in sat unsat proven noanswer counter; do
  grep -v '^;' "$w.wff.out" > "$w.stripped"
  cmp -s "$w.stripped" "$w.answer" || { allok=0; break; }
done
if [[ "$allok" -eq 1 ]]; then
  ok "stdout minus ';' lines equals the .answer file"
else
  bad "stdout minus ';' lines equals the .answer file" "differs for $w"
fi

# 10. Every commentary line is a ';' comment, so stripping them is well defined.
if ! grep -v '^;' proven.wff.out | grep -qv '^[A-Z(]'; then
  ok "non-comment output is only verdict and s-expressions"
else
  bad "non-comment output is only verdict and s-expressions" \
      "$(grep -v '^;' proven.wff.out | grep -v '^[A-Z(]' | head -1)"
fi

# 11. The verdict-detection fix: a solver banner containing "MaxSAT" must not be
#     read as a SAT verdict.  Before, satisfy scanned the whole file for the
#     substring "SAT", so a banner alone reported SAT -- which on a prove form
#     silently turned an entailment into a COUNTEREXAMPLE.
cat > banner.satout <<'EOF'
c MaxSAT Evaluation 2024
c SAT-based solver Open-WBO-Inc
EOF
V="$(sbcl --noinform --disable-debugger --load "$FIFO_LISP/FiFO.lisp" --eval '(progn
  (format t "~S~%" (solver-verdict "banner.satout")) (sb-ext:exit))' 2>/dev/null | tail -1)"
if [[ "$V" == "NIL" ]]; then
  ok "a MaxSAT banner alone is not read as a SAT verdict"
else
  bad "a MaxSAT banner alone is not read as a SAT verdict" "got: $V"
fi

# 12. ... while a real verdict without an 's' line still works.
printf 'SATISFIABLE\n' > plain.satout
V="$(sbcl --noinform --disable-debugger --load "$FIFO_LISP/FiFO.lisp" --eval '(progn
  (format t "~S~%" (solver-verdict "plain.satout")) (sb-ext:exit))' 2>/dev/null | tail -1)"
if [[ "$V" == "SAT" ]]; then
  ok "a bare SATISFIABLE line is still honoured"
else
  bad "a bare SATISFIABLE line is still honoured" "got: $V"
fi

# 13. Wrong-kind solvers are refused by both drivers.
#     Capture the output rather than piping it into grep: the driver exits 2, and
#     `grep -q` closes the pipe on its first match, so under `set -o pipefail` a
#     piped check reports failure even when the message is there.
OUT="$(bash "$BIN/solve.sh" sat.wff --solver nuwls 2>&1 || true)"
if grep -qi "is a MaxSAT solver" <<<"$OUT"; then
  ok "solve.sh refuses a MaxSAT solver"
else
  bad "solve.sh refuses a MaxSAT solver" "no explanation printed"
fi
OUT="$(bash "$BIN/map.sh" sat.wff --solver kissat 2>&1 || true)"
if grep -qi "is a plain SAT solver" <<<"$OUT"; then
  ok "map.sh refuses a SAT solver"
else
  bad "map.sh refuses a SAT solver" "no explanation printed"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
