#!/bin/bash
#
# run_regression_tests.sh -- run all FiFO regression tests and report results.
#
# For every gold file under tests/gold_instantiate/ and tests/gold_solve/, the
# corresponding .wff source (looked up in passed_*/ then tests_*/) is run through
# `instantiate` or `solve` and the output is compared against the gold file.
#
# Each test runs in its own SBCL process, so a crash, hang, or option-state in
# one test cannot affect the others.  If SBCL crashes or is killed, the script
# reports it and keeps going.  Exit status is 0 only if every test passes.
#
# Gensym symbols (#:XXnnnn) are renumbered by order of first appearance before
# comparison, since their absolute numbers differ from one SBCL session to the next.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO="$ROOT/FiFO.lisp"
TESTS="$ROOT/tests"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use a timeout wrapper if one is available, so a hung test cannot stall the run.
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 180";
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 180"; fi

PASS=0; FAIL=0; CRASH=0; TOTAL=0

# Canonicalize an scnf/answer file for comparison: renumber gensyms (#:XXnnnn) by
# order of first appearance, then collapse all whitespace and put one top-level
# form per line.  This makes the comparison insensitive both to the absolute
# gensym numbers and to pretty-printer line wrapping (which shifts when gensym
# token widths differ between sessions).  stdin -> stdout.
normalize() {
  awk '{
    line=$0; out="";
    while (match(line, /#:XX[0-9]+/)) {
      tok=substr(line,RSTART,RLENGTH);
      if (!(tok in m)) m[tok]="#:G" (++n);
      out=out substr(line,1,RSTART-1) m[tok];
      line=substr(line,RSTART+RLENGTH);
    }
    print out line;
  }' | perl -0pe 's/\s+/ /g; s/\) \(/)\n(/g; s/^ //; s/ $//'
}

# Locate a test wff: prefer the verified passed_<kind>/ copy, fall back to tests_<kind>/.
find_wff() {
  local kind="$1" name="$2"
  if   [[ -f "$TESTS/passed_$kind/$name.wff" ]]; then echo "$TESTS/passed_$kind/$name.wff"
  elif [[ -f "$TESTS/tests_$kind/$name.wff"  ]]; then echo "$TESTS/tests_$kind/$name.wff"
  fi
}

# run_one <instantiate|solve> <name> <goldfile>
run_one() {
  local kind="$1" name="$2" gold="$3"
  TOTAL=$((TOTAL+1))
  printf '  %-12s %-32s ... ' "[$kind]" "$name"

  local wff; wff="$(find_wff "$kind" "$name")"
  if [[ -z "$wff" ]]; then
    echo "FAIL (no .wff source found)"; FAIL=$((FAIL+1)); return
  fi

  local outfile="$TMP/$name.out" log="$TMP/$name.log" form
  if [[ "$kind" == "instantiate" ]]; then
    form="(instantiate \"$wff\" :scnfile \"$outfile\")"
  else
    form="(solve \"$wff\" :solnfile \"$outfile\")"
  fi

  $TIMEOUT sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO\")" --eval "$form" >"$log" 2>&1
  local rc=$?

  if [[ $rc -eq 124 ]]; then
    echo "CRASH (timed out)"; CRASH=$((CRASH+1)); return
  fi
  if [[ $rc -gt 128 ]]; then
    echo "CRASH (killed by signal $((rc-128)))"; sed 's/^/      | /' "$log" | tail -8; CRASH=$((CRASH+1)); return
  fi
  if [[ $rc -ne 0 ]]; then
    echo "CRASH (sbcl exit $rc)"; sed 's/^/      | /' "$log" | tail -8; CRASH=$((CRASH+1)); return
  fi
  if [[ ! -f "$outfile" ]]; then
    echo "FAIL (no output produced)"; sed 's/^/      | /' "$log" | tail -8; FAIL=$((FAIL+1)); return
  fi

  if diff <(normalize <"$gold") <(normalize <"$outfile") >"$TMP/$name.diff" 2>&1; then
    echo "PASS"; PASS=$((PASS+1))
  else
    echo "FAIL (output differs from gold)"
    sed 's/^/      | /' "$TMP/$name.diff" | head -15
    FAIL=$((FAIL+1))
  fi
}

if [[ ! -f "$FIFO" ]]; then echo "FiFO.lisp not found at $FIFO" >&2; exit 2; fi
if ! command -v sbcl >/dev/null 2>&1; then echo "sbcl not found on PATH" >&2; exit 2; fi

echo "=== instantiate regression tests ==="
for gold in "$TESTS"/gold_instantiate/*_gold.scnf; do
  [[ -e "$gold" ]] || continue
  name="$(basename "$gold")"; name="${name%_gold.scnf}"
  run_one instantiate "$name" "$gold"
done

echo
echo "=== solve regression tests ==="
for gold in "$TESTS"/gold_solve/*_gold.answer; do
  [[ -e "$gold" ]] || continue
  name="$(basename "$gold")"; name="${name%_gold.answer}"
  run_one solve "$name" "$gold"
done

echo
echo "=== summary: $PASS passed, $FAIL failed, $CRASH crashed (of $TOTAL tests) ==="
[[ $FAIL -eq 0 && $CRASH -eq 0 ]]
