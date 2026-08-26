#!/bin/bash
#
# run-test-maxterm.sh -- regression tests for the max-term marginals back end.
#
# Behavioural, against instances whose answers are known by hand or computable
# exactly with the maxent enumerator.  The interesting cases are the two where
# max-term is exactly right (backbone atoms, and exclusive groups after
# renormalisation) and the one where it is exactly uninformative (an unweighted
# theory, where it returns 0.5 for everything) -- that last is DOCUMENTED
# behaviour, not a bug, and the test pins it so it cannot drift silently.
#
# Run from anywhere:  bash tests/run-test-maxterm.sh
# Skips cleanly (exit 0) when no MaxSAT solver is installed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
M="$REPO/bin/marginals.sh"

PASS=0; FAIL=0
ok()  { printf '  %-52s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-52s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

SOLVER=""
for s in tt-open-wbo-inc-Glucose4_1 tt-open-wbo-inc-IntelSATSolver nuwls-c; do
  command -v "$s" >/dev/null 2>&1 && { SOLVER="$s"; break; }
done
[[ -n "$SOLVER" ]] || { echo "no MaxSAT solver found -- skipping"; exit 0; }
export MAXTERM_SOLVER="$SOLVER"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# value of an atom in the output, e.g.  val out.txt "(P A)"
val() { awk -v pat="(MAXTERM-MARGINAL $2 " 'index($0,pat)==1 {
          p=substr($0,length(pat)+1); sub(/\).*$/,"",p); print p; exit }' "$1"; }
close() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{ exit !(a-b<t && b-a<t) }'; }

printf '(OR (P A) (P B))\n(WEIGHT (P A) 1.0986123)\n'                        > w.scnf
printf '(OR (P A) (P B))\n'                                                  > u.scnf
printf '(OR (P A) (P B) (P C))\n(OR (NOT (P A)) (NOT (P B)))\n(OR (NOT (P A)) (NOT (P C)))\n(OR (NOT (P B)) (NOT (P C)))\n' > x3.scnf
printf '(OR (P A))\n(OR (P A) (P B))\n'                                      > bb.scnf

echo "=== max-term marginals (solver: $SOLVER) ==="

# 1. The hand-computable case: cost log 3 on A gives sigma(-log 3) = 0.25.
bash "$M" w.scnf --solver max-term --query all --scale 1 >o1 2>/dev/null
if close "$(val o1 '(P A)')" 0.25 0.001 && close "$(val o1 '(P B)')" 0.75 0.001; then
  ok "weighted theory: sigma(-log 3) = 0.25 / 0.75"
else
  bad "weighted theory: sigma(-log 3) = 0.25 / 0.75" "got $(val o1 '(P A)') / $(val o1 '(P B)')"
fi

# 2. Degeneracy blindness, pinned deliberately: no weights => no information.
bash "$M" u.scnf --solver max-term --query all --scale 1 >o2 2>/dev/null
if close "$(val o2 '(P A)')" 0.5 0.001; then
  ok "unweighted theory returns 0.5 (documented blind spot)"
else
  bad "unweighted theory returns 0.5 (documented blind spot)" "got $(val o2 '(P A)')"
fi

# 3. Independent atoms are incoherent over an exclusive group...
bash "$M" x3.scnf --solver max-term --query all --scale 1 --groups none >o3 2>/dev/null
S3=$(awk '/MAXTERM/{p=$0; sub(/.* /,"",p); sub(/\)$/,"",p); s+=p} END{print s}' o3)
if close "$S3" 1.5 0.01; then
  ok "ungrouped exclusive atoms sum to 1.5, not 1"
else
  bad "ungrouped exclusive atoms sum to 1.5, not 1" "sum $S3"
fi

# 4. ... and renormalising over the group detected FROM THE THEORY fixes it,
#    recovering the exact 1/3 that maxent gives.
bash "$M" x3.scnf --solver max-term --query all --scale 1 >o4 2>/dev/null
if close "$(val o4 '(P A)')" 0.333333 0.001 && grep -q "exclusive group" o4; then
  ok "group detected from the theory; renormalised to exact 1/3"
else
  bad "group detected from the theory; renormalised to exact 1/3" "got $(val o4 '(P A)')"
fi

# 5. Semantic verification agrees with the syntactic scan.
bash "$M" x3.scnf --solver max-term --query all --scale 1 --verify-groups >o5 2>/dev/null
if close "$(val o5 '(P A)')" 0.333333 0.001; then
  ok "--verify-groups proves the group and agrees"
else
  bad "--verify-groups proves the group and agrees" "got $(val o5 '(P A)')"
fi

# 6. A backbone atom is exact, and says so.
bash "$M" bb.scnf --solver max-term --query all --scale 1 >o6 2>/dev/null
if close "$(val o6 '(P A)')" 1.0 0.0001 && grep -q '(P A) 1.000000) \[proved\]' o6; then
  ok "backbone atom is 1.0 and flagged [proved]"
else
  bad "backbone atom is 1.0 and flagged [proved]" "$(grep 'P A' o6)"
fi

# 7. A post-hoc prior reproduces the same prior compiled into the theory, for the
#    atom it is on -- the factoring identity, and the reason no re-solve is needed.
bash "$M" u.scnf --solver max-term --query all --scale 1 --prior "(P A)=0.25" >o7 2>/dev/null
if close "$(val o7 '(P A)')" "$(val o1 '(P A)')" 0.001; then
  ok "post-hoc prior equals the same weight in the theory"
else
  bad "post-hoc prior equals the same weight in the theory" "got $(val o7 '(P A)') vs $(val o1 '(P A)')"
fi

# 8. ... but only for that atom: B is untouched, where the in-theory weight moved it.
if close "$(val o7 '(P B)')" 0.5 0.001 && close "$(val o1 '(P B)')" 0.75 0.001; then
  ok "a post-hoc prior does not reach other atoms"
else
  bad "a post-hoc prior does not reach other atoms" "B: $(val o7 '(P B)') vs $(val o1 '(P B)')"
fi

# 9. The label is deliberately not MARGINAL.
if grep -q "MAXTERM-MARGINAL" o1 && ! grep -qE "^\(MARGINAL " o1; then
  ok "labelled MAXTERM-MARGINAL, not MARGINAL"
else
  bad "labelled MAXTERM-MARGINAL, not MARGINAL" "$(head -1 o1)"
fi

# 10. --query is required: one MaxSAT solve per atom is not something to default into.
if bash "$M" x3.scnf --solver max-term >/dev/null 2>e10; grep -qi "needs --query" e10; then
  ok "--query is required"
else
  bad "--query is required" "$(head -1 e10)"
fi

# 11. beta scales the log-odds: doubling it squares the odds ratio.
bash "$M" w.scnf --solver max-term --query all --scale 1 --beta 2 >o11 2>/dev/null
E=$(awk 'BEGIN{ o=0.25/0.75; o2=o*o; print o2/(1+o2) }')
if close "$(val o11 '(P A)')" "$E" 0.001; then
  ok "--beta scales the log-odds"
else
  bad "--beta scales the log-odds" "got $(val o11 '(P A)'), expected $E"
fi

# 12. Determined atoms agree with the exact enumerator on a real instance.
if [[ -f "$REPO/Probability/test_marginals_reweighted.scnf" ]]; then
  bash "$M" "$REPO/Probability/test_marginals_reweighted.scnf" --solver max-term --query all >o12 2>/dev/null
  if close "$(val o12 '(BUY BREAD)')" 1.0 0.0001 && close "$(val o12 '(BUY SPAM)')" 0.0 0.0001; then
    ok "determined atoms match the exact back end"
  else
    bad "determined atoms match the exact back end" "$(grep -E 'BREAD|SPAM' o12 | tr '\n' ' ')"
  fi
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
