#!/bin/bash
#
# run-test-sharpsat.sh -- regression tests for the SharpSAT-TD counter
# (marginals.sh --solver sharpsat-td, wmc.sh --counter sharpsat-td,
# planner.sh --counter sharpsat-td, lisp/wmc.lisp's marginals-sharpsat).
#
# Behavioural: every number is checked against an INDEPENDENT oracle -- a value
# computed by hand, or one of FiFO's own exact back ends (maxent enumeration,
# the ddnnf compiler), which share no code with the SharpSAT-TD path beyond the
# scnf reader.  maxent prints 6 decimals, so agreement with it is checked to
# 1e-6; hand values are checked tighter.
#
# The load-bearing case is the UNDERFLOW one: a theory whose Z is about 1e-348,
# below double range.  SharpSAT-TD carries an unbounded exponent and FiFO reads
# its count back as an exact rational, so the marginals must still be right
# there -- and wmc.sh must REFUSE to print Z rather than print 0, which would
# read as "unsatisfiable".  ADDMC, which counts in doubles, is shown failing on
# the same file, so the case cannot pass by the theory being easy.
#
# Run from anywhere:  bash tests/run-test-sharpsat.sh
# Skips cleanly (exit 0) when no sharpSAT is on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
M="$REPO/bin/marginals.sh"
W="$REPO/bin/wmc.sh"
P="$REPO/bin/planner.sh"

if ! command -v sharpSAT >/dev/null 2>&1; then
  echo "=== SharpSAT-TD: SKIPPED (no sharpSAT on PATH; bin/install-solvers.sh --only sharpsat-td) ==="
  exit 0
fi

PASS=0; FAIL=0
ok()  { printf '  %-60s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-60s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# "(MARGINAL <atom> <p>)" -> "<atom>\t<p>", sorted.  Atoms contain spaces, so
# the value is the LAST field and the atom everything before it.
split() {
  grep '^(MARGINAL' | sed -e 's/^(MARGINAL //' -e 's/)$//' \
    | awk '{ v = $NF; $NF = ""; sub(/ $/, ""); printf "%s\t%s\n", $0, v }' | sort
}
# agree A B TOL: same atoms, every value within TOL.  Prints "n:maxdiff" or an
# error word; also requires at least one value strictly between 0 and 1, so a
# comparison of all-0/1 marginals cannot pass vacuously.
agree() {
  if ! cmp -s <(cut -f1 "$1") <(cut -f1 "$2"); then echo "atom-sets-differ"; return 1; fi
  [[ -s "$1" ]] || { echo "empty"; return 1; }
  paste "$1" "$2" | awk -F'\t' -v t="$3" '
    { d = $2 - $4; if (d < 0) d = -d; if (d > mx) mx = d; n++
      if ($2 + 0 > 1e-9 && $2 + 0 < 1 - 1e-9) frac++ }
    END { printf "%d atoms, max diff %.2g", n, mx; exit !(mx <= t && frac > 0) }'
}
marg() { awk -F'\t' -v a="$2" '$1 == a { print $2; exit }' "$1"; }
close() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{ exit !(a != "" && a-b<t && b-a<t) }'; }

echo "=== SharpSAT-TD ($(command -v sharpSAT)) ==="

# --- 1. marginals agree with exact enumeration on the probability fixtures ---
for f in "$REPO"/Probability/*.scnf; do
  n="$(basename "$f")"
  bash "$M" "$f" --solver maxent 2>/dev/null | split > ref.m
  bash "$M" "$f" --solver sharpsat-td 2>/dev/null | split > st.m
  if r="$(agree ref.m st.m 1e-6)"; then ok "marginals = maxent on $n ($r)"
  else bad "marginals = maxent on $n" "$r"; fi
done

# --- 2. a SatPlan theory, against the ddnnf compiler ---------------------------
# Switch at 4 slices, NOT the tracked switchprob.scnf: that one is at the plan's
# own horizon, where every marginal is 0 or 1 and agreement proves nothing.
mkdir -p sw && cp "$REPO"/SatPlan/Examples/Switch/*.pddl sw/
bash "$P" sw/switchprob.pddl --domain sw/switches.pddl --numslices 4 --stop-after scnf >/dev/null 2>&1
SW="$TMP/sw/switchprob.scnf"
bash "$M" "$SW" --solver ddnnf 2>/dev/null | split > ref.m
bash "$M" "$SW" --solver sharpsat-td 2>/dev/null | split > st.m
if r="$(agree ref.m st.m 1e-6)"; then ok "SatPlan Switch marginals = ddnnf ($r)"
else bad "SatPlan Switch marginals = ddnnf" "$r"; fi

# --- 3. the abbreviation from solvers.dat resolves -----------------------------
bash "$M" "$REPO/Probability/test_marginals.scnf" --solver sharpsat 2>/dev/null | split > ab.m
bash "$M" "$REPO/Probability/test_marginals.scnf" --solver sharpsat-td 2>/dev/null | split > full.m
if [[ -s ab.m ]] && cmp -s ab.m full.m; then ok "--solver sharpsat (abbreviation) = sharpsat-td"
else bad "--solver sharpsat (abbreviation) = sharpsat-td" "outputs differ or empty"; fi

# --- 4. evidence conditions exactly as the ddnnf back end does ---------------
F="$REPO/Probability/test_marginals_reweighted.scnf"
EV='(not (buy milk))'
bash "$M" "$F" --solver ddnnf --evidence "$EV" 2>/dev/null | split > ref.m
bash "$M" "$F" --solver sharpsat-td --evidence "$EV" 2>/dev/null | split > st.m
if r="$(agree ref.m st.m 1e-6)"; then ok "--evidence conditions = ddnnf ($r)"
else bad "--evidence conditions = ddnnf" "$r"; fi
if [[ "$(marg st.m '(BUY MILK)')" == "0.0000000000000000e+0" ]]; then
  ok "--evidence actually binds: P(milk | not milk) = 0"
else bad "--evidence actually binds: P(milk | not milk) = 0" "got '$(marg st.m '(BUY MILK)')'"; fi

# --- 5. Z by hand, in the 2024 dialect, through wmc.sh ------------------------
# (OR A B), cost 1 on A:  models AB, A~B, ~AB  ->  Z = 2e^-1 + 1.
cat > hand.scnf <<'EOF'
(OR A B)
(WEIGHT A 1.0)
EOF
Z="$(bash "$W" hand.scnf --counter sharpsat-td --scale 1 2>/dev/null | sed -n 's/^(WMC \(.*\))$/\1/p')"
HAND="$(awk 'BEGIN{ printf "%.15g", 2*exp(-1)+1 }')"
if close "$Z" "$HAND" 1e-12; then ok "wmc.sh --counter sharpsat-td: Z = 2e^-1+1 ($Z)"
else bad "wmc.sh --counter sharpsat-td: Z = 2e^-1+1" "got '$Z', want $HAND"; fi
bash "$W" hand.scnf --counter sharpsat-td --scale 1 --wcnf kept.cnf >/dev/null 2>&1
if grep -q '^p cnf ' kept.cnf && grep -q '^c t wmc' kept.cnf && ! grep -q '^w ' kept.cnf; then
  ok "sharpsat-td is fed the MCC-2024 dialect"
else bad "sharpsat-td is fed the MCC-2024 dialect" "$(head -3 kept.cnf 2>/dev/null | tr '\n' '|')"; fi

# --- 6. UNDERFLOW: Z ~ 1e-348, below double range ----------------------------
# 40 atoms forced true at cost 20 each, and a free atom B at cost 1:
#   Z = e^-800 * (1 + e^-1)  ~ 1e-348,  P(B) = e^-1/(1+e^-1) = sigmoid(-1).
{ for i in $(seq 1 40); do echo "(OR (U $i))"; echo "(WEIGHT (U $i) 20.0)"; done
  echo "(OR B (NOT B))"; echo "(WEIGHT B 1.0)"; } > tiny.scnf
SIG="$(awk 'BEGIN{ printf "%.15g", exp(-1)/(1+exp(-1)) }')"
bash "$M" tiny.scnf --solver sharpsat-td --scale 1 2>/dev/null | split > st.m
PB="$(marg st.m B)"; PU="$(marg st.m '(U 7)')"
if close "$PB" "$SIG" 1e-12 && close "$PU" 1 1e-12; then
  ok "Z~1e-348: P(B) = sigmoid(-1) exactly, P(U 7) = 1"
else bad "Z~1e-348: P(B) = sigmoid(-1) exactly, P(U 7) = 1" "P(B)='$PB' P(U 7)='$PU', want $SIG and 1"; fi
OUT="$(bash "$W" tiny.scnf --counter sharpsat-td --scale 1 2>&1)"
if grep -q 'outside double-float range' <<<"$OUT" && ! grep -q '^(WMC' <<<"$OUT"; then
  ok "wmc.sh refuses an out-of-range Z rather than printing 0"
else bad "wmc.sh refuses an out-of-range Z rather than printing 0" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-120)"; fi
if command -v addmc >/dev/null 2>&1; then
  if bash "$M" tiny.scnf --solver addmc --scale 1 >/dev/null 2>&1; then
    bad "control: ADDMC (doubles) cannot count it" "addmc succeeded -- the case is not testing underflow"
  else ok "control: ADDMC (doubles) cannot count it"; fi
else
  echo "  (no addmc -- skipping the ADDMC control)"
fi

# --- 7. hypotheses: the hand-counted fixture of run-test-hypotheses.sh --------
# per-hypothesis given OBS: P(O|h1) = P(O|h2) = 1/2, P(O|h3) = 0  ->  1/2, 1/2, 0
cat > h.scnf <<'EOF'
(OR (H 1) (H 2) (H 3))
(OR (NOT (H 1)) (NOT (H 2)))
(OR (NOT (H 1)) (NOT (H 3)))
(OR (NOT (H 2)) (NOT (H 3)))
(OR (NOT (F 1)) (H 1))
(OR (NOT (F 2)) (H 1))
(OR (NOT (OBS 1)) (H 1) (H 2))
EOF
bash "$M" h.scnf --solver sharpsat-td --hypotheses '(H 1)' --hypotheses '(H 2)' --hypotheses '(H 3)' \
     --evidence '(OBS 1)' --baseline per-hypothesis > h.out 2>&1
post() { awk -v pat="(HYPOTHESIS $1 :posterior " 'index($0,pat)==1 {
           p=substr($0,length(pat)+1); sub(/ .*$/,"",p); sub(/\).*$/,"",p); print p; exit }' h.out; }
if close "$(post '(H 1)')" 0.5 1e-9 && close "$(post '(H 2)')" 0.5 1e-9 && close "$(post '(H 3)')" 0 1e-9; then
  ok "--hypotheses per-hypothesis: 1/2, 1/2, 0 (by hand)"
else bad "--hypotheses per-hypothesis: 1/2, 1/2, 0 (by hand)" "got $(post '(H 1)') $(post '(H 2)') $(post '(H 3)')"; fi

# --- 8. planner.sh --marginals --counter sharpsat-td = --counter maxent -------
mkdir -p pl && cp "$REPO"/SatPlan/Examples/Switch/*.pddl pl/
bash "$P" pl/switchprob.pddl --domain pl/switches.pddl --numslices 3 --marginals \
     --counter maxent 2>/dev/null | split > ref.m
bash "$P" pl/switchprob.pddl --domain pl/switches.pddl --numslices 3 --marginals \
     --counter sharpsat-td 2>/dev/null | split > st.m
if r="$(agree ref.m st.m 1e-6)"; then ok "planner.sh --counter sharpsat-td = maxent ($r)"
else bad "planner.sh --counter sharpsat-td = maxent" "$r"; fi

# --- 9. a missing flowcutter is named, not a mystery -------------------------
OUT="$(SHARPSAT_FLOWCUTTER=/nonexistent/flow_cutter_pace17 bash "$W" "$REPO/SatPlan/Examples/LogisticsCosts/intermediates/pb1.scnf" --counter sharpsat-td 2>&1)"
if grep -q 'could not run /nonexistent/flow_cutter_pace17' <<<"$OUT"; then
  ok "a missing flow_cutter_pace17 is reported by name"
else bad "a missing flow_cutter_pace17 is reported by name" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-160)"; fi

# --- 10. option guards ---------------------------------------------------------
F="$REPO/Probability/test_marginals.scnf"
refused() {  # refused <name> <expected-message-fragment> <command...>
  local name="$1" frag="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [[ $rc -ne 0 ]] && grep -q -- "$frag" <<<"$out"; then ok "$name"
  else bad "$name" "rc=$rc: $(tr '\n' ' ' <<<"$out" | cut -c1-100)"; fi
}
refused "--decot refused for another solver" "--decot applies to the sharpsat-td" bash "$M" "$F" --solver maxent --decot 2
refused "--cache-mb refused for another solver" "--cache-mb applies to the sharpsat-td" bash "$M" "$F" --solver addmc --cache-mb 100
refused "--epsilon refused for sharpsat-td" "--epsilon applies to the addmc" bash "$M" "$F" --solver sharpsat-td --epsilon 0.1
refused "--decot must be a number" "--decot must be a positive number" bash "$M" "$F" --solver sharpsat-td --decot fast
refused "wmc.sh refuses a counter with no Z" "must be addmc or sharpsat-td" bash "$W" "$F" --counter maxent
refused "wmc.sh --decot needs sharpsat-td" "--decot applies to the sharpsat-td" bash "$W" "$F" --decot 2

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
