#!/bin/bash
#
# run-test-ddnnf-eval.sh -- the d-DNNF circuit evaluator and the d4 import guards.
#
# ddnnf-query's down pass gives each child of an AND node the product of its
# siblings' values as prefix * suffix (O(k) per node; the first version
# recomputed every sibling product, O(k^2), and took 25 s on a 7x7 SimpleGrid
# circuit whose smoothed AND nodes have up to 1,007 children).  The load-bearing
# case is the PROPERTY test (ddnnf-eval-property.lisp): random smooth d-DNNFs with
# random weights and evidence clamps, against brute-force enumeration sharing no
# code with the evaluator; some trials have a root AND of 17+ children, past the
# 16-slot scratch arrays.  It refuses to pass vacuously (no wide AND, no zeroed
# leaf, or only 0/1 marginals).  Mutation-checked: not copying the prefix
# products when the scratch arrays grow gives 48 mismatches; dropping the suffix
# factor gives 544.
#
# The import guards: a d4 dump with more than one parentless node (a truncated
# dump from a crashed d4) must be refused, not built from one arbitrary root; so
# must a dump or saved circuit naming a variable outside 1..nvars.  Mutation-
# checked: accepting any parentless node as the root (the old behaviour) builds
# the two-root dump below as Z = 4, silently, instead of refusing it.
#
# The circuit files (text .dnnf, binary .dnnfb): a hand-written text circuit
# against Z and marginals computed by hand, with atoms holding a ")" in a string
# and a |x y| symbol (the text reader scans small values as text before READ);
# text -> binary -> text -> binary keeping every value; marginals.sh
# --save-circuit writing both files and --circuit taking either, against maxent
# enumeration; --save-circuit x.dnnfb writing the binary alone, in x.dnnfb; and
# a truncated binary file and one with a forward child refused.  Also refused by
# name: a d4 node line with no id, and a saved circuit with no :NVARS.
# Mutation-checked: ignoring strings in the scanner fails the hand case;
# skipping the node checks loads both damaged files (and the out-of-range leaf
# above); not writing the binary fails the --save-circuit case; the old
# x.dnnfb -> x.dnnfb.dnnfb rule, dropping the node-line check, and allocating
# before the :NVARS check each fail their case.
#
# Run from anywhere:  bash tests/run-test-ddnnf-eval.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"
command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

PASS=0; FAIL=0
ok()  { printf '  %-62s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-62s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
lisp() { sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" \
              --eval "(load \"$FIFO_LISP/ddnnf.lisp\")" "$@" 2>&1; }

echo "=== circuit evaluator ==="

out="$(lisp --load "$SCRIPT_DIR/ddnnf-eval-property.lisp" | grep '^PROPERTY')"
case "$out" in
  "PROPERTY ok "*) ok "Z and marginals match brute force (${out#PROPERTY ok })" ;;
  *) bad "Z and marginals match brute force" "${out:-no result}" ;;
esac

echo "=== d4 import guards ==="

# A d4 dump: node lines "o|a|t|f ID 0", arc lines "SRC DST LITS... 0".
# import RESULT-FILE: build from dump.nnf over 3 variables, print Z or the error.
import() {
  lisp --eval '(let ((a2i (make-hash-table :test (quote equal))))
                 (loop for v from 1 to 3 do (setf (gethash (list (quote x) v) a2i) v))
                 (handler-case
                     (format t "~&Z ~,6F~%" (ddnnf-query (ddnnf--build-from-d4 "dump.nnf" 3 a2i
                                                          (make-hash-table) 1d0 nil)))
                   (error (e) (format t "~&ERR ~A~%" e))))' | grep -E '^(Z|ERR)'
}

# x1 OR x2 over 3 variables: 3 models of (x1,x2) times 2 for the unmentioned x3.
printf 'o 1 0\nt 2 0\n1 2 1 0\n1 2 -1 2 0\n' > dump.nnf
r="$(import)"
[ "$r" = "Z 6.000000" ] && ok "a well-formed dump imports (Z = 6)" || bad "a well-formed dump imports (Z = 6)" "$r"

# The same plus a stray parentless node: two roots.
printf 'o 1 0\nt 2 0\no 3 0\n1 2 1 0\n1 2 -1 2 0\n3 2 3 0\n' > dump.nnf
r="$(import)"
case "$r" in *"nodes with no parent"*) ok "a dump with two roots is refused" ;;
  *) bad "a dump with two roots is refused" "$r" ;; esac

# A truncated last line: a node line with no id.
printf 'o 1 0\nt 2 0\n1 2 1 0\n1 2 -1 2 0\no\n' > dump.nnf
r="$(import)"
case "$r" in *"malformed node line"*) ok "a node line with no id is refused by name" ;;
  *) bad "a node line with no id is refused by name" "$r" ;; esac

printf 'o 1 0\nt 2 0\n1 2 4 0\n1 2 -4 0\n' > dump.nnf
r="$(import)"
case "$r" in *"outside 1..3"*) ok "a dump naming variable 4 of 3 is refused" ;;
  *) bad "a dump naming variable 4 of 3 is refused" "$r" ;; esac

# A saved circuit whose leaf names variable 5 of 2.
cat > bad.dnnf <<'EOF'
(:fifo-ddnnf 1 :nvars 2 :root 2 :scale 1.0
 :atoms ((x 1) (x 2))
 :nodes ((:l 1) (:l 5) (:a 0 1))
 :leaf-cost () :clauses ())
EOF
r="$(lisp --eval '(handler-case (progn (ddnnf-load "bad.dnnf") (format t "~&LOADED~%"))
                    (error (e) (format t "~&ERR ~A~%" e)))' | grep -E '^(LOADED|ERR)')"
case "$r" in *"outside 1..2"*) ok "a saved circuit with an out-of-range leaf is refused" ;;
  *) bad "a saved circuit with an out-of-range leaf is refused" "$r" ;; esac

# ... and one with no :NVARS, by name rather than as a type error
cat > nonv.dnnf <<'EOF'
(:fifo-ddnnf 1 :root 2 :scale 1.0
 :atoms ((x 1) (x 2))
 :nodes ((:l 1) (:l 2) (:a 0 1))
 :leaf-cost () :clauses ())
EOF
r="$(lisp --eval '(handler-case (progn (ddnnf-load "nonv.dnnf") (format t "~&LOADED~%"))
                    (error (e) (format t "~&ERR ~A~%" e)))' | grep -E '^(LOADED|ERR)')"
case "$r" in *"bad :NVARS"*) ok "a saved circuit with no :NVARS is refused by name" ;;
  *) bad "a saved circuit with no :NVARS is refused by name" "$r" ;; esac

echo "=== circuit files: text and binary ==="

# A hand-written text circuit: free(1) AND free(2), cost 1 on +1, so by hand
#   Z = (e^-1 + 1) * 2,  P(1) = e^-1 / (1 + e^-1),  P(2) = 1/2.
# Its atoms hold a ")" inside a string and a symbol with a space: the text reader
# scans the small values as text before READ, and must not end a datum early.
cat > hand.dnnf <<'EOF'
(:fifo-ddnnf 1 :nvars 2 :root 6 :scale 1.0
 :atoms ((p "a)b") (q |x y|))
 :nodes ((:l 1) (:l -1) (:o 0 1)
         (:l 2) (:l -2) (:o 3 4) (:a 2 5))
 :leaf-cost ((1 1.0)) :clauses ())
EOF
# show FILE: Z, P(1), P(2) and the two atoms, from a load of FILE
show() {
  lisp --eval "(handler-case
                 (let ((c (ddnnf-load \"$1\")))
                   (multiple-value-bind (z zt) (ddnnf-query c)
                     (format t \"~&RES ~,12F ~,12F ~,12F ~S ~S~%\" z (/ (aref zt 1) z) (/ (aref zt 2) z)
                             (aref (ddnnf-i2a c) 1) (aref (ddnnf-i2a c) 2))))
                 (error (e) (format t \"~&ERR ~A~%\" e)))" | grep -E '^(RES|ERR)'
}
WANT="RES $(awk 'BEGIN{ printf "%.12f %.12f %.12f", 2*(exp(-1)+1), exp(-1)/(1+exp(-1)), 0.5 }') (P \"a)b\") (Q |x y|)"
r="$(show hand.dnnf)"
[ "$r" = "$WANT" ] && ok "a hand-written text circuit: Z, marginals and atoms by hand" \
                   || bad "a hand-written text circuit: Z, marginals and atoms by hand" "$r"
# text -> binary -> text -> binary: every load gives the same numbers and atoms
lisp --eval '(let ((c (ddnnf-load "hand.dnnf"))) (ddnnf-save-binary c "h1.dnnfb"))' >/dev/null
lisp --eval '(let ((c (ddnnf-load "h1.dnnfb"))) (ddnnf-save c "h2.dnnf"))' >/dev/null
lisp --eval '(let ((c (ddnnf-load "h2.dnnf"))) (ddnnf-save-binary c "h3.dnnfb"))' >/dev/null
r1="$(show h1.dnnfb)"; r2="$(show h2.dnnf)"; r3="$(show h3.dnnfb)"
if [ "$r1" = "$WANT" ] && [ "$r2" = "$WANT" ] && [ "$r3" = "$WANT" ]; then
  ok "text -> binary -> text -> binary keeps every value"
else bad "text -> binary -> text -> binary keeps every value" "$r1 | $r2 | $r3"; fi

# marginals.sh: --save-circuit writes BOTH files, and --circuit takes either,
# against exact enumeration (maxent) on the same theory -- an independent oracle.
F="$REPO/Probability/test_marginals_reweighted.scnf"
M="$REPO/bin/marginals.sh"
bash "$M" "$F" --solver maxent 2>/dev/null | grep '^(MARGINAL' > ref.m
bash "$M" "$F" --solver ddnnf --save-circuit c.dnnf 2>/dev/null | grep '^(MARGINAL' > direct.m
bash "$M" --circuit c.dnnf 2>/dev/null | grep '^(MARGINAL' > text.m
bash "$M" --circuit c.dnnfb 2>/dev/null | grep '^(MARGINAL' > bin.m
inner="$(awk '{ v = $NF; sub(/\)$/, "", v); if (v + 0 > 0.001 && v + 0 < 0.999) n++ } END { print n + 0 }' ref.m)"
if [ -s c.dnnf ] && [ -s c.dnnfb ] && [ -s ref.m ] && [ "$inner" -gt 0 ] \
   && cmp -s ref.m direct.m && cmp -s ref.m text.m && cmp -s ref.m bin.m; then
  ok "--save-circuit writes .dnnf + .dnnfb; --circuit either = maxent ($(wc -l < ref.m | tr -d ' ') atoms)"
else
  bad "--save-circuit writes .dnnf + .dnnfb; --circuit either = maxent" \
      "files: $(ls c.dnnf c.dnnfb 2>&1 | tr '\n' ' ') inner=$inner; $(diff ref.m bin.m | head -2 | tr '\n' ' ')"
fi

# --save-circuit x.dnnfb: the binary alone, in x.dnnfb itself (not text there
# plus a x.dnnfb.dnnfb), and it answers like the rest.
bash "$M" "$F" --solver ddnnf --save-circuit only.dnnfb >/dev/null 2>&1
bash "$M" --circuit only.dnnfb 2>/dev/null | grep '^(MARGINAL' > only.m
if [ "$(head -c 8 only.dnnfb 2>/dev/null)" = "FIFODNB1" ] && [ ! -e only.dnnfb.dnnfb ] \
   && cmp -s ref.m only.m; then
  ok "--save-circuit x.dnnfb writes the binary alone, = maxent"
else
  bad "--save-circuit x.dnnfb writes the binary alone, = maxent" \
      "magic '$(head -c 8 only.dnnfb 2>/dev/null)'; $(ls only.dnnfb* 2>&1 | tr '\n' ' ')"
fi

# A damaged binary file must be refused by name, not evaluated with safety off.
head -c "$(( $(wc -c < c.dnnfb) - 4 ))" c.dnnfb > short.dnnfb
r="$(lisp --eval '(handler-case (progn (ddnnf-load "short.dnnfb") (format t "~&LOADED~%"))
                    (error (e) (format t "~&ERR ~A~%" e)))' | grep -E '^(LOADED|ERR)')"
case "$r" in *"truncated or corrupt"*) ok "a truncated binary circuit is refused" ;;
  *) bad "a truncated binary circuit is refused" "$r" ;; esac
# ... and so must one whose sizes agree but whose child points forward
r="$(lisp --eval '(let* ((c (ddnnf-load "c.dnnfb")) (d (ddnnf-nodes c))
                         (i (loop for i from (1- (dns-n d)) downto 0
                                  when (> (dns-kids-end d i) (dns-kids-start d i)) return i)))
                    (setf (aref (dns-kids d) (dns-kids-start d i)) i)
                    (ddnnf-save-binary c "fwd.dnnfb")
                    (handler-case (progn (ddnnf-load "fwd.dnnfb") (format t "~&LOADED~%"))
                      (error (e) (format t "~&ERR ~A~%" e))))' | grep -E '^(LOADED|ERR)')"
case "$r" in *"does not precede it"*) ok "a binary circuit with a forward child is refused" ;;
  *) bad "a binary circuit with a forward child is refused" "$r" ;; esac

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
