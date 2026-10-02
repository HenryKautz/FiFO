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

# --- 6. UNDERFLOW: Z ~ 1e-336, below double range, with NOTHING forced -------
# 40 pairs (OR (U i) (V i)), cost 20 on every U and V, plus a free B at cost 1.
# Unit propagation forces nothing, so folding cannot help: Z is a genuine product
#   Z = (2e^-20 + e^-40)^40 * (1 + e^-1)  ~  1e-336,
# and only an unbounded exponent can carry it.  Closed forms:
#   P(B) = sigmoid(-1),   P(U i) = (1 + e^-20) / (2 + e^-20).
{ for i in $(seq 1 40); do
    echo "(OR (U $i) (V $i))"; echo "(WEIGHT (U $i) 20.0)"; echo "(WEIGHT (V $i) 20.0)"
  done
  echo "(OR B (NOT B))"; echo "(WEIGHT B 1.0)"; } > tiny.scnf
SIG="$(awk 'BEGIN{ printf "%.15g", exp(-1)/(1+exp(-1)) }')"
PUW="$(awk 'BEGIN{ printf "%.15g", (1+exp(-20))/(2+exp(-20)) }')"
bash "$M" tiny.scnf --solver sharpsat-td --scale 1 2>/dev/null | split > st.m
PB="$(marg st.m B)"; PU="$(marg st.m '(U 7)')"
if close "$PB" "$SIG" 1e-12 && close "$PU" "$PUW" 1e-12; then
  ok "Z~1e-336 unforced: P(B) = sigmoid(-1), P(U 7) exact"
else bad "Z~1e-336 unforced: P(B) = sigmoid(-1), P(U 7) exact" "P(B)='$PB' P(U 7)='$PU', want $SIG and $PUW"; fi
OUT="$(bash "$W" tiny.scnf --counter sharpsat-td --scale 1 2>&1)"
if grep -q 'outside the normal double-float range' <<<"$OUT" && ! grep -q '^(WMC' <<<"$OUT"; then
  ok "wmc.sh refuses an out-of-range Z rather than printing 0"
else bad "wmc.sh refuses an out-of-range Z rather than printing 0" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-120)"; fi
if command -v addmc >/dev/null 2>&1; then
  if bash "$M" tiny.scnf --solver addmc --scale 1 >/dev/null 2>&1; then
    bad "control: ADDMC (doubles) cannot count it" "addmc succeeded -- the case is not testing underflow"
  else ok "control: ADDMC (doubles) cannot count it"; fi
else
  echo "  (no addmc -- skipping the ADDMC control)"
fi

# --- 6b. a single huge cost on a FORCED literal is folded out, not zeroed -----
# U forced true at cost 800, V forced false, B free at cost 1.  exp(-800) is 0 as
# a double, which the writer used to emit -- making a soft cost hard and Z = 0
# ("unsatisfiable").  Folded out, it is a constant factor, so the marginals are
# exact for BOTH counters, and a clamp of the forced-false V is refuted by unit
# propagation (P = 0) without running anything.
printf '(OR U)\n(WEIGHT U 800.0)\n(OR (NOT V))\n(WEIGHT V 3.0)\n(OR B (NOT B))\n(WEIGHT B 1.0)\n' > forced.scnf
# ADDMC prints ~6-7 significant digits (as in run-test-mcc-dialect.sh), so it is
# held to 1e-6 here where SharpSAT-TD is held to 1e-12.
tol() { [[ "$1" == addmc ]] && echo 1e-6 || echo 1e-12; }
for s in sharpsat-td addmc; do
  command -v "$( [[ $s == addmc ]] && echo addmc || echo sharpSAT )" >/dev/null 2>&1 || continue
  bash "$M" forced.scnf --solver "$s" --scale 1 2>/dev/null | split > f.m
  if close "$(marg f.m B)" "$SIG" "$(tol $s)" && close "$(marg f.m U)" 1 1e-12 && close "$(marg f.m V)" 0 1e-12; then
    ok "$s: forced cost 800 folded -- P(B)=sigmoid(-1), U=1, V=0"
  else bad "$s: forced cost 800 folded -- P(B)=sigmoid(-1), U=1, V=0" "B='$(marg f.m B)' U='$(marg f.m U)' V='$(marg f.m V)'"; fi
done
# Z through the folding: forced costs 700 and -650 give Z = e^-50 (1 + e^-1),
# well inside double range although neither factor's exp alone is safe to write.
printf '(OR U)\n(WEIGHT U 700.0)\n(OR W)\n(WEIGHT W -650.0)\n(OR B (NOT B))\n(WEIGHT B 1.0)\n' > fz.scnf
ZW="$(awk 'BEGIN{ printf "%.15g", exp(-50)*(1+exp(-1)) }')"
for c in sharpsat-td addmc; do
  command -v "$( [[ $c == addmc ]] && echo addmc || echo sharpSAT )" >/dev/null 2>&1 || continue
  Z="$(bash "$W" fz.scnf --counter "$c" --scale 1 2>/dev/null | sed -n 's/^(WMC \(.*\))$/\1/p')"
  if awk -v a="$Z" -v b="$ZW" -v t="$(tol $c)" 'BEGIN{ exit !(a != "" && (a-b)/b < t && (b-a)/b < t) }'; then
    ok "$c: Z = e^-50 (1+e^-1) through forced costs 700, -650"
  else bad "$c: Z = e^-50 (1+e^-1) through forced costs 700, -650" "got '$Z', want $ZW"; fi
done
# A SUBNORMAL Z is refused like an underflowed one: forced cost 725 -> Z = e^-725.
printf '(OR U)\n(WEIGHT U 725.0)\n' > sub.scnf
OUT="$(bash "$W" sub.scnf --counter sharpsat-td --scale 1 2>&1)"
if grep -q 'outside the normal double-float range' <<<"$OUT"; then
  ok "a subnormal Z (e^-725) is refused, not printed"
else bad "a subnormal Z (e^-725) is refused, not printed" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-120)"; fi

# --- 6c. a weight that cannot be written is an error NAMING the literal --------
# A FREE atom at cost 720 (relative weight e^-720, subnormal) or -750 (e^750,
# overflow): neither folds, and writing it used to give 0, a sharpSAT abort, or
# a Lisp overflow.  Now it names the atom.
printf '(OR (BIG 1) (NOT (BIG 1)))\n(WEIGHT (BIG 1) 720.0)\n' > big.scnf
printf '(OR (NEG 1) (NOT (NEG 1)))\n(WEIGHT (NEG 1) -750.0)\n' > neg.scnf
for pair in "big.scnf:(BIG 1)" "neg.scnf:(NEG 1)"; do
  f="${pair%%:*}"; a="${pair#*:}"
  OUT="$(bash "$M" "$f" --solver sharpsat-td --scale 1 2>&1)"
  if grep -q 'outside double range' <<<"$OUT" && grep -qF "$a" <<<"$OUT"; then
    ok "an unwritable weight on a free atom names it: $a"
  else bad "an unwritable weight on a free atom names it: $a" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-140)"; fi
done
# The EXPORTED file is never folded (it must denote the theory's own Z), so the
# forced cost 800 that counting folds away is refused there rather than written as 0.
OUT="$(bash "$W" forced.scnf --counter sharpsat-td --scale 1 --wcnf exported.cnf 2>&1)"
if grep -q 'outside double range' <<<"$OUT" && ! grep -q 'weight 1 0.0e+0' exported.cnf 2>/dev/null; then
  ok "--wcnf export refuses rather than writing weight 0"
else bad "--wcnf export refuses rather than writing weight 0" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-140)"; fi

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

# --- 9b. --hypotheses counts only the hypotheses -----------------------------
# A sharpSAT wrapper earlier on PATH logs each invocation.  The fixture has 6
# atoms and 3 hypotheses; per-hypothesis needs a conditioned and an unconditioned
# run, so clamping only the hypotheses is at most 2 x (1 + 3) = 8 calls, where
# clamping every atom was 2 x (1 + 6) = 14.  It is in fact 7: under the evidence,
# clamping (H 3) is refuted by unit propagation alone, so that count is 0
# without a run.  (The wrapper execs the real binary by its absolute path, so
# flowcutter is still found beside it.)
REAL="$(command -v sharpSAT)"
mkdir -p wrap
printf '#!/bin/sh\necho call >> %s/calls.log\nexec "%s" "$@"\n' "$TMP" "$REAL" > wrap/sharpSAT
chmod +x wrap/sharpSAT
: > calls.log
PATH="$TMP/wrap:$PATH" bash "$M" h.scnf --solver sharpsat-td --hypotheses '(H 1)' --hypotheses '(H 2)' \
     --hypotheses '(H 3)' --evidence '(OBS 1)' --baseline per-hypothesis > h2.out 2>&1
N="$(wc -l < calls.log | tr -d ' ')"
if [[ "$N" == 7 ]] && cmp -s <(grep '^(HYPOTHESIS' h.out) <(grep '^(HYPOTHESIS' h2.out); then
  ok "--hypotheses clamps only the hypotheses (7 sharpSAT calls, not 14)"
else bad "--hypotheses clamps only the hypotheses (7 sharpSAT calls, not 14)" "$N calls"; fi

# --- 9c. ADDMC is bounded by *solver-timeout* too ------------------------------
# A stand-in 'addmc' that never finishes: before, wmc--run-addmc had no timeout
# and this hung forever.
mkdir -p slow
printf '#!/bin/sh\nexec sleep 60\n' > slow/addmc
chmod +x slow/addmc
OUT="$(PATH="$TMP/slow:$PATH" sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
  --eval "(handler-case (let ((*solver-timeout* 2) (*solver-kill-grace* 1)) (wmc \"hand.scnf\" :scale 1))
            (error (e) (format t \"ERROR: ~A~%\" e)))" 2>&1)"
if grep -q 'ADDMC timed out after 2 s' <<<"$OUT"; then ok "ADDMC is bounded by *solver-timeout*"
else bad "ADDMC is bounded by *solver-timeout*" "$(tr '\n' ' ' <<<"$OUT" | tail -c 140)"; fi

# --- 9d. the installer's usability check agrees with sharpSAT's own lookup ------
# sharpSAT uses $SHARPSAT_FLOWCUTTER whenever it is set, without checking it, so
# a stale value must make the installer call it NOT usable.
LIST="$(SHARPSAT_FLOWCUTTER=/nonexistent/flow_cutter_pace17 bash "$REPO/bin/install-solvers.sh" --list 2>&1)"
if grep -Eq '^sharpsat-td +missing' <<<"$LIST"; then ok "a stale SHARPSAT_FLOWCUTTER makes sharpsat-td 'missing'"
else bad "a stale SHARPSAT_FLOWCUTTER makes sharpsat-td 'missing'" "$(grep sharpsat-td <<<"$LIST" | head -1)"; fi

# --- 9e. wmc.sh refuses a no-Z counter BEFORE asking for it to be installed -----
OUT="$(PATH=/usr/bin:/bin bash "$W" "$REPO/Probability/test_marginals.scnf" --counter d4 2>&1)"
if grep -q 'must be addmc or sharpsat-td' <<<"$OUT" && ! grep -q 'Install it with' <<<"$OUT"; then
  ok "wmc.sh --counter d4 is refused, not sent to install d4"
else bad "wmc.sh --counter d4 is refused, not sent to install d4" "$(tr '\n' ' ' <<<"$OUT" | cut -c1-120)"; fi

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
refused "--decot must be a number" "--decot must be a number of seconds" bash "$M" "$F" --solver sharpsat-td --decot fast
refused "--decot 0 refused before Lisp loads" "in (0.0001, 10000)" bash "$M" "$F" --solver sharpsat-td --decot 0
refused "--decot 10000 refused before Lisp loads" "in (0.0001, 10000)" bash "$W" "$F" --counter sharpsat-td --decot 10000
refused "wmc.sh refuses a counter with no Z" "must be addmc or sharpsat-td" bash "$W" "$F" --counter maxent
refused "wmc.sh --decot needs sharpsat-td" "--decot applies to the sharpsat-td" bash "$W" "$F" --decot 2

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
