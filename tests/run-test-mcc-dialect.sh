#!/bin/bash
#
# run-test-mcc-dialect.sh -- wmc.lisp's two weighted-CNF dialects.
#
# lisp/wmc.lisp can emit MCC-2020 (ADDMC's --wf 4, the long-standing default) or
# MCC-2024 (the competition format from 2021 on, which SharpSAT-TD reads).  The
# two are NOT textually interconvertible: they disagree about what an unstated
# literal polarity means.  ADDMC defaults the missing side to 1.0; SharpSAT-TD
# INFERS it as 1 - w from the side that is given, and refuses outright when the
# given side lies outside [0,1].  FiFO's model is W(L true) = exp(-theta),
# W(L false) = 1, which is ADDMC's rule and not SharpSAT-TD's -- so the 2024
# emitter states BOTH polarities of every variable explicitly.
#
# The load-bearing cases are therefore not about syntax.  They are:
#
#   * the two emitted files must denote the SAME Z, each read under its OWN
#     parser's rules -- checked with tests/mcc-reference-count.py, a brute-force
#     counter that shares no code with FiFO (comparing FiFO against itself would
#     just share any misunderstanding), and anchored to Z computed BY HAND;
#
#   * a faithful line-by-line TRANSLATION of the 2020 file -- same literals, new
#     syntax, which is what a naive converter would produce -- must come out
#     DIFFERENT (1.367879 against the true 1.735759) and must be REFUSED outright
#     when a cost is negative.  Without those two cases the suite would pass just
#     as happily on an emitter that wrote one polarity, which is the whole bug.
#
# Run from anywhere:  bash tests/run-test-mcc-dialect.sh
# Needs sbcl and python3; the real-counter cases skip when their binaries are absent.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
REF="$SCRIPT_DIR/mcc-reference-count.py"
command -v sbcl    >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH" >&2; exit 2; }
[[ -f "$REF" ]] || { echo "missing $REF" >&2; exit 2; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

PASS=0; FAIL=0
ok()  { printf '  %-58s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-58s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
# near <a> <b> -- relative agreement to 1e-9, for numbers we compute ourselves
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b;if(d<0)d=-d;m=(b<0?-b:b);if(m<1)m=1;exit !(d/m<1e-9)}'; }
# near_printed -- 1e-5, for a number PARSED BACK from a solver's stdout.  ADDMC
# prints ~6 significant digits ('1.73576'), so a tighter bound would fail on its
# output formatting rather than on any disagreement about the count.
near_printed() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b;if(d<0)d=-d;m=(b<0?-b:b);if(m<1)m=1;exit !(d/m<1e-5)}'; }

# emit <scnf> <root> [extra lisp keys] -- writes <root>2020.wcnf and <root>2024.cnf
# FiFO.lisp first, then wmc.lisp: the evidence path calls FiFO's (parse ...), so
# wmc.lisp alone is not enough.  This is the order bin/wmc.sh and marginals.sh use.
emit() {
  local scnf="$1" root="$2" extra="${3:-}"
  sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
    --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
    --eval "(progn (wmc-write-wcnf \"$scnf\" \"${root}2020.wcnf\" :dialect :mcc-2020 :verbose nil $extra)
                   (wmc-write-wcnf \"$scnf\" \"${root}2024.cnf\"  :dialect :mcc-2024 :verbose nil $extra)
                   (sb-ext:exit))" >"${root}.log" 2>&1
}
zref() { python3 "$REF" "$1" "$2" 2>&1 | awk '/^Z /{print $2}'; }
# xlate <2020 file> <out> -- the naive converter: same literals, 2024 syntax
xlate() {
  { echo "c t wmc"
    awk '/^p wcnf /{printf "p cnf %s %s\n",$3,$4; next} /^w /{next} {print}' "$1"
    awk '/^w /{printf "c p weight %s %s 0\n",$2,$3}' "$1"
  } > "$2"
}

echo "=== wmc.lisp: MCC-2020 vs MCC-2024 ==="

# --- 1. the anchor: Z computed BY HAND ---------------------------------------
# (OR A B) has three models; W(A)=e^-1, everything else 1.  So
# Z = e^-1 + e^-1 + 1 = 1.735758882343.  Pinning the ORACLE to arithmetic first,
# so the agreement cases below cannot pass by two readers being wrong alike.
printf '(OR A B)\n(WEIGHT A 1.0)\n' > t.scnf
emit t.scnf t ":scale 1"
HAND=$(python3 -c 'import math;print("%.12e"%(2*math.exp(-1)+1))')
Z20=$(zref 2020 t2020.wcnf); Z24=$(zref 2024 t2024.cnf)
near "${Z20:-0}" "$HAND" && ok "2020 file counts to the hand-computed Z" \
                         || bad "2020 file counts to the hand-computed Z" "got ${Z20:-none}, want $HAND"
near "${Z24:-0}" "$HAND" && ok "2024 file counts to the hand-computed Z" \
                         || bad "2024 file counts to the hand-computed Z" "got ${Z24:-none}, want $HAND"

# --- 2. THE case: the two dialects denote the same distribution --------------
for f in "(OR A B)|(WEIGHT A 1.0)" \
         "(OR A B)|(WEIGHT A 1.0)|(WEIGHT (NOT B) 2.5)" \
         "(OR A B)|(OR (NOT A) C)|(WEIGHT A 0.5)|(WEIGHT C -1.25)" \
         "(OR A B C)|(OR (NOT B) (NOT C))|(WEIGHT (NOT A) 3.0)"; do
  printf '%s\n' "$f" | tr '|' '\n' > m.scnf
  emit m.scnf m ":scale 1"
  A=$(zref 2020 m2020.wcnf); B=$(zref 2024 m2024.cnf)
  if [[ -n "$A" && -n "$B" ]] && near "$A" "$B"; then
    ok "same Z in both dialects: ${f:0:28}"
  else
    bad "same Z in both dialects: ${f:0:28}" "2020=${A:-none} 2024=${B:-none}"
  fi
done

# --- 3. the hazard, quantified ----------------------------------------------
# A naive converter keeps the 2020 file's literals and changes only the syntax.
# Under SharpSAT-TD's rules the absent polarity of A becomes 1-e^-1, not 1, so Z
# is wrong -- silently.  This is the case that justifies emitting 2V lines.
xlate t2020.wcnf xlate.cnf
ZX=$(zref 2024 xlate.cnf)
NAIVE=$(python3 -c 'import math;e=math.exp(-1);print("%.12e"%(e+e+(1-e)))')
if [[ -n "$ZX" ]] && near "$ZX" "$NAIVE" && ! near "$ZX" "$HAND"; then
  ok "a naive textual translation is WRONG (1.367879 vs 1.735759)"
else
  bad "a naive textual translation is WRONG" "got ${ZX:-none}, expected $NAIVE and not $HAND"
fi

# --- 4. the other hazard: a negative cost is REFUSED, not mis-counted -------
# exp(-theta) > 1 for theta < 0, which a learned weight or (weight ... :odds r>1)
# produces.  SharpSAT-TD cannot infer the missing side at all there.
printf '(OR A B)\n(WEIGHT A -1.0)\n' > neg.scnf
emit neg.scnf neg ":scale 1"
HANDNEG=$(python3 -c 'import math;print("%.12e"%(2*math.exp(1)+1))')
NA=$(zref 2020 neg2020.wcnf); NB=$(zref 2024 neg2024.cnf)
if [[ -n "$NB" ]] && near "$NB" "$HANDNEG" && near "${NA:-0}" "$HANDNEG"; then
  ok "a negative cost counts correctly in both dialects (2e+1)"
else
  bad "a negative cost counts correctly in both dialects" "2020=${NA:-none} 2024=${NB:-none} want $HANDNEG"
fi
xlate neg2020.wcnf negx.cnf
OUTX="$(python3 "$REF" 2024 negx.cnf 2>&1)"
grep -q 'cannot be inferred' <<<"$OUTX" \
  && ok "translating a negative cost is refused, not mis-counted" \
  || bad "translating a negative cost is refused" "got: $(head -1 <<<"$OUTX")"

# --- 5. syntax the real parsers require -------------------------------------
head -1 t2024.cnf | grep -qx 'c t wmc' && ok "2024 declares 'c t wmc'" \
                                      || bad "2024 declares 'c t wmc'" "got: $(head -1 t2024.cnf)"
grep -qx 'p cnf 2 1' t2024.cnf   && ok "2024 problem line is 'p cnf'" \
                                 || bad "2024 problem line is 'p cnf'" "$(grep '^p ' t2024.cnf)"
grep -qx 'p wcnf 2 1' t2020.wcnf && ok "2020 problem line is still 'p wcnf'" \
                                 || bad "2020 problem line is still 'p wcnf'" "$(grep '^p ' t2020.wcnf)"
# SharpSAT-TD matches a weight line on EXACTLY 6 tokens, so the trailing 0 is
# mandatory -- where ADDMC accepted 3 or 4.
if [[ -z "$(awk '/^c p weight /&&NF!=6{print}' t2024.cnf)" ]]; then
  ok "every 2024 weight line has exactly 6 tokens"
else
  bad "every 2024 weight line has exactly 6 tokens" "$(awk '/^c p weight /&&NF!=6{print;exit}' t2024.cnf)"
fi
# Both polarities of every variable: this is the fix itself.
NV=$(awk '/^p cnf /{print $3}' t2024.cnf)
MISS=""
for ((v=1; v<=NV; v++)); do
  grep -qx "c p weight $v .* 0"  t2024.cnf || MISS="$MISS +$v"
  grep -qx "c p weight -$v .* 0" t2024.cnf || MISS="$MISS -$v"
done
[[ -z "$MISS" ]] && ok "2024 states both polarities of all $NV variables" \
                 || bad "2024 states both polarities of all $NV variables" "missing:$MISS"
grep -q '^c p weight' t2020.wcnf && bad "2020 has no 'c p weight' lines" "found one" \
                                 || ok "2020 has no 'c p weight' lines"
# The default must stay 2020, or every existing caller changes format silently.
sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
     --eval '(progn (wmc-write-wcnf "t.scnf" "dflt.wcnf" :scale 1 :verbose nil) (sb-ext:exit))' \
     >/dev/null 2>&1
grep -qx 'p wcnf 2 1' dflt.wcnf && ok "the default dialect is still MCC-2020" \
                                || bad "the default dialect is still MCC-2020" "$(head -2 dflt.wcnf | tr '\n' ' ')"

# --- 6. scale and evidence reach both dialects alike ------------------------
printf '(OR A B)\n(WEIGHT A 100.0)\n' > s.scnf
emit s.scnf s ":scale 100"
SA=$(zref 2020 s2020.wcnf); SB=$(zref 2024 s2024.cnf)
if [[ -n "$SA" && -n "$SB" ]] && near "$SA" "$SB" && near "$SA" "$HAND"; then
  ok "--scale is applied identically in both dialects"
else
  bad "--scale is applied identically in both dialects" "2020=${SA:-none} 2024=${SB:-none} want $HAND"
fi
emit t.scnf e ":scale 1 :evidence '((NOT A))"
EA=$(zref 2020 e2020.wcnf); EB=$(zref 2024 e2024.cnf)
# Conditioning on ~A leaves one model (~A,B) of weight 1.
if [[ -n "$EA" && -n "$EB" ]] && near "$EA" "$EB" && near "$EB" 1.0; then
  ok "evidence conditions both dialects identically (Z=1)"
else
  bad "evidence conditions both dialects identically" "2020=${EA:-none} 2024=${EB:-none} want 1.0"
fi

# --- 7. a real repo fixture -------------------------------------------------
FIX="$REPO/Probability/test_coupled_reweighted.scnf"
if [[ -f "$FIX" ]]; then
  emit "$FIX" fx ""
  FA=$(zref 2020 fx2020.wcnf); FB=$(zref 2024 fx2024.cnf)
  if [[ -n "$FA" && -n "$FB" ]] && near "$FA" "$FB"; then
    ok "same Z on a real fixture (learned weights, header scale)"
  else
    bad "same Z on a real fixture" "2020=${FA:-none} 2024=${FB:-none}"
  fi
else
  echo "  (no $FIX -- skipping the real-fixture case)"
fi

# --- 8. the real counters, when installed -----------------------------------
# The reference reader is the oracle above; these check that the actual binaries
# agree with it, which is what makes the dialects' claims about THEM meaningful.
if command -v addmc >/dev/null 2>&1; then
  RA=$(addmc --cf t2020.wcnf --wf 4 2>/dev/null | awk '/^s /{print $3}')
  if [[ -n "$RA" ]] && near_printed "$RA" "$HAND"; then
    ok "real ADDMC agrees with the 2020 file ($RA)"
  else
    bad "real ADDMC agrees with the 2020 file" "addmc said '${RA:-nothing}', want $HAND"
  fi
else
  echo "  (no addmc -- skipping the real-ADDMC case)"
fi
SHARP="$(command -v sharpSAT || true)"
if [[ -n "$SHARP" ]]; then
  RS=$("$SHARP" -WE -decot 1 -decow 100 -tmpdir . -cs 500 -prec 15 t2024.cnf 2>/dev/null \
       | awk '/^c s exact arb float /{print $NF}')
  if [[ -n "$RS" ]] && near_printed "$RS" "$HAND"; then
    ok "real SharpSAT-TD agrees with the 2024 file ($RS)"
  else
    bad "real SharpSAT-TD agrees with the 2024 file" "sharpSAT said '${RS:-nothing}', want $HAND"
  fi
else
  echo "  (no sharpSAT on PATH -- skipping the real-SharpSAT-TD case)"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
