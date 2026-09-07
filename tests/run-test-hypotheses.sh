#!/bin/bash
#
# run-test-hypotheses.sh -- regression tests for marginals.sh --hypotheses and
# the --baseline best-rival | per-hypothesis choice.
#
# Behavioural, against a fixture small enough to count by hand, because the
# whole point of the per-hypothesis baseline is a specific number and not a
# vibe.  The fixture:
#
#   (H 1) (H 2) (H 3)  exclusive and exhaustive
#   (F 1) (F 2)        free ONLY when (H 1) holds  -- so h1 has 4x the models
#   (OBS 1)            possible only under (H 1) or (H 2)
#
#   models:  h1 -> 4 f-combos * 2 obs = 8      P(h1|T) = 8/11
#            h2 -> 1          * 2     = 2      P(h2|T) = 2/11
#            h3 -> 1          * 1     = 1      P(h3|T) = 1/11   (obs must be false)
#   given OBS: h1 -> 4, h2 -> 1, h3 -> 0       P(.|T,O) = 4/5, 1/5, 0
#
# So P(O|h1) = 4/8 = 0.5 and P(O|h2) = 1/2 = 0.5: the evidence supports h1 and
# h2 EQUALLY, and h1's fourfold lead under best-rival is entirely the theory's
# own mass -- the implicit prior the per-hypothesis baseline divides out.  That
# contrast is the suite's centre of gravity.
#
# Run from anywhere:  bash tests/run-test-hypotheses.sh
# The maxent and ddnnf back ends need no binary, so the core cases always run;
# addmc / d4 / max-term cases skip cleanly when their solver is absent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
M="$REPO/bin/marginals.sh"

PASS=0; FAIL=0
ok()  { printf '  %-56s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-56s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# posterior of an atom from the output:  post out.txt "(H 1)"
post() { awk -v pat="(HYPOTHESIS $2 :posterior " 'index($0,pat)==1 {
           p=substr($0,length(pat)+1); sub(/ .*$/,"",p); sub(/\).*$/,"",p); print p; exit }' "$1"; }
# any :key of a row:  field out.txt "(H 1)" uncond
field() { awk -v h="(HYPOTHESIS $2 " -v k=":$3" 'index($0,h)==1 {
            for(i=1;i<=NF;i++) if($i==k){ v=$(i+1); sub(/\).*$/,"",v); print v; exit } }' "$1"; }
close() { awk -v a="$1" -v b="$2" -v t="${3:-0.0005}" 'BEGIN{ exit !(a-b<t && b-a<t) }'; }

H=(--hypotheses '(H 1)' --hypotheses '(H 2)' --hypotheses '(H 3)')

cat > t.scnf <<'EOF'
(OR (H 1) (H 2) (H 3))
(OR (NOT (H 1)) (NOT (H 2)))
(OR (NOT (H 1)) (NOT (H 3)))
(OR (NOT (H 2)) (NOT (H 3)))
(OR (NOT (F 1)) (H 1))
(OR (NOT (F 2)) (H 1))
(OR (NOT (OBS 1)) (H 1) (H 2))
EOF

# A weighted fixture for max-term: h_i needs action a_i, and OBS needs a1.
#   c(O,h1)=1  c(~O,h1)=1  -> delta  0
#   c(O,h2)=6  c(~O,h2)=5  -> delta -1        (likewise h3)
cat > w.scnf <<'EOF'
(OR (H 1) (H 2) (H 3))
(OR (NOT (H 1)) (NOT (H 2)))
(OR (NOT (H 1)) (NOT (H 3)))
(OR (NOT (H 2)) (NOT (H 3)))
(OR (NOT (H 1)) (A 1))
(OR (NOT (H 2)) (A 2))
(OR (NOT (H 3)) (A 3))
(OR (NOT (OBS 1)) (A 1))
(WEIGHT (A 1) 1)
(WEIGHT (A 2) 5)
(WEIGHT (A 3) 5)
(OPTION WEIGHTS WCNF)
EOF

# A symmetric fixture: the three hypotheses have IDENTICAL model counts, so the
# implicit prior is uniform and the two baselines must agree exactly.
cat > s.scnf <<'EOF'
(OR (H 1) (H 2) (H 3))
(OR (NOT (H 1)) (NOT (H 2)))
(OR (NOT (H 1)) (NOT (H 3)))
(OR (NOT (H 2)) (NOT (H 3)))
(OR (NOT (OBS 1)) (H 1) (H 2))
EOF

echo "=== marginals.sh --hypotheses / --baseline ==="

# --- 1. the numbers, against the hand computation ---------------------------
bash "$M" t.scnf "${H[@]}" --baseline best-rival --evidence '(OBS 1)' > br.txt 2>err1.txt
if close "$(post br.txt '(H 1)')" 0.8 && close "$(post br.txt '(H 2)')" 0.2 \
   && close "$(post br.txt '(H 3)')" 0.0; then
  ok "best-rival reproduces P(h|T,O) = 4/5, 1/5, 0"
else
  bad "best-rival reproduces P(h|T,O) = 4/5, 1/5, 0" "got $(post br.txt '(H 1)') $(post br.txt '(H 2)') $(post br.txt '(H 3)')"
fi

bash "$M" t.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' > ph.txt 2>err2.txt
if close "$(post ph.txt '(H 1)')" 0.5 && close "$(post ph.txt '(H 2)')" 0.5 \
   && close "$(post ph.txt '(H 3)')" 0.0; then
  ok "per-hypothesis reproduces P(O|h) = 0.5, 0.5, 0"
else
  bad "per-hypothesis reproduces P(O|h) = 0.5, 0.5, 0" "got $(post ph.txt '(H 1)') $(post ph.txt '(H 2)') $(post ph.txt '(H 3)')"
fi

# The identity is the whole implementation, so check it against P(O|T /\ h)
# computed a DIFFERENT way: condition on h and read the marginal of the
# evidence atom, which needs no ratio and no second run.
direct() {
  printf '%s\n(OR %s)\n' "$(cat t.scnf)" "$1" > d.scnf
  bash "$M" d.scnf 2>/dev/null | awk 'index($0,"(MARGINAL (OBS 1) ")==1 {
      p=substr($0,20); sub(/\).*$/,"",p); print p; exit }'
}
D1="$(direct '(H 1)')"; D2="$(direct '(H 2)')"; D3="$(direct '(H 3)')"
if close "$D1" 0.5 && close "$D2" 0.5 && close "$D3" 0.0; then
  ok "identity anchor: P(O|h) computed directly is 0.5, 0.5, 0"
else
  bad "identity anchor: P(O|h) computed directly is 0.5, 0.5, 0" "got $D1 $D2 $D3"
fi

# --- 2. the controls --------------------------------------------------------
# Negative control: the baselines must DIFFER, and in the stated direction --
# best-rival inflates the hypothesis with more models.
if awk -v a="$(post br.txt '(H 1)')" -v b="$(post ph.txt '(H 1)')" 'BEGIN{exit !(a>b+0.1)}'; then
  ok "unequal difficulty: best-rival inflates the model-rich hypothesis"
else
  bad "unequal difficulty: best-rival inflates the model-rich hypothesis" \
      "best-rival $(post br.txt '(H 1)') vs per-hypothesis $(post ph.txt '(H 1)')"
fi

# Positive control: made symmetric, they must agree -- proving the difference
# above is the implicit prior and not an implementation artifact.
bash "$M" s.scnf "${H[@]}" --baseline best-rival     --evidence '(OBS 1)' > sbr.txt 2>/dev/null
bash "$M" s.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' > sph.txt 2>/dev/null
if close "$(post sbr.txt '(H 1)')" "$(post sph.txt '(H 1)')" \
   && close "$(post sbr.txt '(H 2)')" "$(post sph.txt '(H 2)')"; then
  ok "equal difficulty: the two baselines agree exactly"
else
  bad "equal difficulty: the two baselines agree exactly" \
      "$(post sbr.txt '(H 1)') vs $(post sph.txt '(H 1)')"
fi

# --- 3. priors --------------------------------------------------------------
bash "$M" t.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' \
     --prior '(H 1)=0.8' --prior '(H 2)=0.1' --prior '(H 3)=0.1' > pr.txt 2>/dev/null
# h1 and h2 have equal likelihood, so the posterior ratio is just the prior
# ratio 0.8 : 0.1, i.e. 8/9 and 1/9.
if close "$(post pr.txt '(H 1)')" 0.888889 && close "$(post pr.txt '(H 2)')" 0.111111; then
  ok "priors compose with equal likelihoods as Bayes says"
else
  bad "priors compose with equal likelihoods as Bayes says" \
      "got $(post pr.txt '(H 1)') $(post pr.txt '(H 2)')"
fi

printf '(H 1) = 1\n(H 2) = 1\n(H 3) = 1\n' > uni.txt
bash "$M" t.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' \
     --priors uni.txt > up.txt 2>/dev/null
if close "$(post up.txt '(H 1)')" "$(post ph.txt '(H 1)')"; then
  ok "a uniform --priors file is a no-op"
else
  bad "a uniform --priors file is a no-op" "$(post up.txt '(H 1)') vs $(post ph.txt '(H 1)')"
fi

# --- 4. cross-back-end agreement -------------------------------------------
for be in ddnnf addmc d4; do
  case "$be" in
    addmc) command -v addmc >/dev/null 2>&1 || { echo "  (addmc absent -- skipped)"; continue; } ;;
    d4)    command -v d4    >/dev/null 2>&1 || { echo "  (d4 absent -- skipped)";    continue; } ;;
  esac
  bash "$M" t.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' \
       --solver "$be" > "b-$be.txt" 2>/dev/null
  if close "$(post "b-$be.txt" '(H 1)')" 0.5 && close "$(post "b-$be.txt" '(H 2)')" 0.5; then
    ok "$be agrees with maxent on the per-hypothesis posterior"
  else
    bad "$be agrees with maxent on the per-hypothesis posterior" \
        "got $(post "b-$be.txt" '(H 1)') $(post "b-$be.txt" '(H 2)')"
  fi
done

# mc-sat is the one back end where the ratio's denominator matters: it divides
# two ESTIMATES.  Loose tolerance on purpose -- this pins that the sampled path
# runs and lands in the right place, not that Monte Carlo is exact.
WS=0
if command -v walksat >/dev/null 2>&1; then
  WSH="$(walksat -help </dev/null 2>&1 || true)"
  grep -q -- "-mcsat" <<<"$WSH" && WS=1
fi
if [[ "$WS" -eq 1 ]]; then
  bash "$M" t.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' \
       --solver mc-sat --seed 7 --samples 20000 --unitprop > mcs.txt 2>/dev/null
  if close "$(post mcs.txt '(H 1)')" 0.5 0.12 && close "$(post mcs.txt '(H 3)')" 0.0 0.02; then
    ok "mc-sat approximates the per-hypothesis posterior"
  else
    bad "mc-sat approximates the per-hypothesis posterior" \
        "got $(post mcs.txt '(H 1)') $(post mcs.txt '(H 3)')"
  fi
else
  echo "  (walksat v58 absent -- mc-sat case skipped)"
fi

# --- 5. reported detail and the exclusivity header --------------------------
if close "$(field ph.txt '(H 1)' uncond)" 0.727273 && close "$(field ph.txt '(H 1)' cond)" 0.8; then
  ok ":cond and :uncond are reported, not just the posterior"
else
  bad ":cond and :uncond are reported, not just the posterior" \
      "cond=$(field ph.txt '(H 1)' cond) uncond=$(field ph.txt '(H 1)' uncond)"
fi

grep -q "the theory entails the hypotheses are exclusive and exhaustive" ph.txt \
  && ok "exclusivity detected from the theory is reported as entailed" \
  || bad "exclusivity detected from the theory is reported as entailed" "$(grep '^;' ph.txt | head -2 | tr '\n' ' ')"

# Drop the at-most-one clauses: exclusivity is no longer entailed and the header
# must say so rather than quietly normalising as if it were.
grep -v 'NOT (H' t.scnf > loose.scnf
bash "$M" loose.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' > lo.txt 2>/dev/null
grep -q "ASSUMED" lo.txt \
  && ok "without at-most-one clauses the header says ASSUMED" \
  || bad "without at-most-one clauses the header says ASSUMED" "$(grep '^;' lo.txt | head -2 | tr '\n' ' ')"

grep -q "^(MARGINAL " ph.txt \
  && bad "labelled HYPOTHESIS, not MARGINAL" "a (MARGINAL ...) line leaked into the output" \
  || ok "labelled HYPOTHESIS, not MARGINAL"

# --- 6. max-term ------------------------------------------------------------
MT_OK=0
python3 -c "import pysat" >/dev/null 2>&1 && MT_OK=1
if [[ "$MT_OK" -eq 1 ]]; then
  bash "$M" w.scnf "${H[@]}" --baseline per-hypothesis --evidence '(OBS 1)' \
       --solver max-term > mt.txt 2>/dev/null
  if close "$(field mt.txt '(H 1)' delta)" 0 && close "$(field mt.txt '(H 2)' delta)" -1; then
    ok "max-term computes R&G's delta = c(~O,h) - c(O,h)"
  else
    bad "max-term computes R&G's delta = c(~O,h) - c(O,h)" \
        "got $(field mt.txt '(H 1)' delta) $(field mt.txt '(H 2)' delta)"
  fi
  if close "$(post mt.txt '(H 1)')" 0.48175 && close "$(post mt.txt '(H 2)')" 0.259125; then
    ok "max-term posterior is sigma(beta*delta) * prior, normalised"
  else
    bad "max-term posterior is sigma(beta*delta) * prior, normalised" \
        "got $(post mt.txt '(H 1)') $(post mt.txt '(H 2)')"
  fi
  # The guard at marginals.sh used to refuse --evidence for max-term, which hid
  # a real bug: WEIGHTS is FiFO's global special and (parse ...) inside
  # wmc--evidence-clauses reset it, so max-term with evidence silently lost
  # every weight and returned its unweighted answer, 0.5, for everything.
  bash "$M" w.scnf --solver max-term --query '(A 2)' --evidence '(OBS 1)' > mq.txt 2>/dev/null
  MQ="$(awk 'index($0,"(MAXTERM-MARGINAL (A 2) ")==1 { p=substr($0,25); sub(/\).*$/,"",p); print p; exit }' mq.txt)"
  if close "$MQ" 0.006693; then
    ok "max-term keeps its weights under --evidence (0.5 = the old bug)"
  else
    bad "max-term keeps its weights under --evidence (0.5 = the old bug)" "got $MQ"
  fi
else
  echo "  (python-sat absent -- 3 max-term cases skipped)"
fi

# --- 7. errors --------------------------------------------------------------
# Capture before matching rather than piping: these commands exit non-zero by
# design, and under 'set -o pipefail' that makes the whole pipeline fail even
# when grep matched -- the same trap marginals.sh notes for the walksat probe.
expect_err() {   # expect_err <label> <pattern> <marginals.sh args...>
  local label="$1" pat="$2"; shift 2
  local out; out="$(bash "$M" "$@" 2>&1)"
  if grep -q -- "$pat" <<<"$out"; then ok "$label"
  else bad "$label" "got: $(head -1 <<<"$out")"; fi
}

expect_err "per-hypothesis without --hypotheses is refused" "needs --hypotheses" \
  t.scnf --baseline per-hypothesis

expect_err "per-hypothesis without evidence is refused" "needs evidence" \
  t.scnf --hypotheses '(H 1)' --baseline per-hypothesis

expect_err "a hypothesis atom absent from the theory is refused" "does not occur in" \
  t.scnf --hypotheses '(H 9)' --evidence '(OBS 1)' --baseline per-hypothesis

# The same silent-vacuous-evidence class the hypothesis check covers: an unknown
# atom would be minted fresh, occur in no clause, constrain nothing, and leave
# the answer unconditioned with no warning at all.
expect_err "evidence naming an unknown atom is refused, not silently vacuous" \
  "the theory does not contain" \
  t.scnf "${H[@]}" --evidence '(NOSUCH 1)' --baseline per-hypothesis

expect_err "an unknown --baseline is refused" "must be best-rival or per-hypothesis" \
  t.scnf "${H[@]}" --baseline bogus

expect_err "priors under best-rival on an exact counter are refused" \
  "no defined meaning under the best-rival baseline" \
  t.scnf "${H[@]}" --evidence '(OBS 1)' --prior '(H 1)=0.5'

expect_err "a partial prior specification is refused" "give all of them or none" \
  t.scnf "${H[@]}" --evidence '(OBS 1)' --baseline per-hypothesis --prior '(H 1)=0.5'

# --- 8. the default path is untouched ---------------------------------------
bash "$M" t.scnf > plain.txt 2>/dev/null
grep -q "^(MARGINAL (H 1) " plain.txt \
  && ok "without --hypotheses marginals.sh is unchanged" \
  || bad "without --hypotheses marginals.sh is unchanged" "$(head -2 plain.txt)"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
