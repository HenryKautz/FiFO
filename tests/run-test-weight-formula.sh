#!/bin/bash
#
# run-test-weight-formula.sh -- regression tests for formula-valued weight and
# probability forms: (weight <formula> w) / (probability <formula> p) reify the
# formula into a fresh determined atom (WEIGHTED-FORMULA n) via the count-neutral
# biconditional A <=> formula, and attach the weight/target to that atom.
#
# These are behavioral checks (the reified biconditional appears; illegal nesting
# raises the contextual error; the learned marginal of the formula hits its
# target).  Byte-exact instantiate output is covered by the gold_instantiate/
# cases test_weight_formula and test_probability_formula in run_regression_tests.
#
# Run from anywhere:  bash tests/run-test-weight-formula.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2          # keep learn/marginals scratch files out of the repo

if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

PASS=0; FAIL=0
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }

# instantiate <wff-text> -> writes $TMP/out.scnf, prints combined stdout+stderr
instantiate() {
  printf '%s\n' "$1" > "$TMP/in.wff"
  sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO\")" \
    --eval "(instantiate \"$TMP/in.wff\" :scnfile \"$TMP/out.scnf\")" 2>&1
}

echo "=== formula-valued weight/probability ==="

# 1. A compound weight argument reifies: biconditional clauses + WEIGHT on the
#    fresh atom; the literal case stays a bare (WEIGHT <literal> ...) line.
printf '  %-52s ... ' "weight (and a b) reifies to WEIGHTED-FORMULA"
instantiate '(weight (and a b) 3.0)' >/dev/null
if grep -q '(WEIGHT (WEIGHTED-FORMULA 1) 3)' "$TMP/out.scnf" \
   && grep -q '(OR (NOT A) (NOT B) (WEIGHTED-FORMULA 1))' "$TMP/out.scnf" \
   && grep -q '(OR (NOT (WEIGHTED-FORMULA 1)) A)' "$TMP/out.scnf" \
   && grep -q '(OR (NOT (WEIGHTED-FORMULA 1)) B)' "$TMP/out.scnf"; then pass; else fail "missing biconditional or weight"; fi

printf '  %-52s ... ' "probability (or a b) reifies with a target line"
instantiate '(probability (or a b) 0.8)' >/dev/null
if grep -q '(PROBABILITY (WEIGHTED-FORMULA 1) 0.8 1)' "$TMP/out.scnf" \
   && grep -q '(OR (NOT (WEIGHTED-FORMULA 1)) A B)' "$TMP/out.scnf"; then pass; else fail "missing biconditional or probability"; fi

printf '  %-52s ... ' "literal weight stays a bare (WEIGHT literal w)"
instantiate '(weight (buy milk) 2.5)' >/dev/null
if grep -q '(WEIGHT (BUY MILK) 2.5)' "$TMP/out.scnf" \
   && ! grep -q 'WEIGHTED-FORMULA' "$TMP/out.scnf"; then pass; else fail "literal case changed"; fi

# 2. Illegal nesting inside or/not/implies/equiv must raise the contextual error.
for form in '(or x (weight y 1))' \
            '(not (weight y 1))' \
            '(implies a (weight b 1))' \
            '(equiv a (probability b 0.5))'; do
  printf '  %-52s ... ' "reject: $form"
  if instantiate "$form" | grep -q 'may not appear inside or/not/implies/equiv'; then pass; else fail "no rejection"; fi
done

# 3. End-to-end: maxent learns the weight so P(formula) hits its target.
printf '  %-52s ... ' "maxent learns P((or a b)) = 0.8"
instantiate '(probability (or a b) 0.8)' >/dev/null
cp "$TMP/out.scnf" "$TMP/sem.scnf"
bash "$REPO/bin/learn.sh" "$TMP/sem.scnf" --maxent --out "$TMP/sem_rw.scnf" >/dev/null 2>&1
m=$(bash "$REPO/bin/marginals.sh" "$TMP/sem_rw.scnf" --solver maxent --weighted-only 2>/dev/null \
      | sed -n 's/.*(WEIGHTED-FORMULA 1) \([0-9.]*\).*/\1/p')
if [[ -n "$m" ]] && awk -v m="$m" 'BEGIN{exit !(m>0.79 && m<0.81)}'; then pass; else fail "P=$m not ~0.8"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
