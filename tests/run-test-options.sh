#!/bin/bash
#
# run-test-options.sh -- the (option ...) / solving-policy boundary.
#
# A .wff says what the problem IS; how to attack it is the caller's.  So the
# generation options (*compact-encoding*, *tracing*, *satplan-numslices*) are
# settable in a file, and the solving ones (*solver*, *cnf-format*,
# *solver-timeout*, *preprocessor*, *preprocessor-techniques*, and the
# *solver-abbreviations* table that serves *solver*) are not.
#
# That split is worth a test because the failure it prevents is silent: while a
# file could set them, options ran during parsing and so beat everything.  A
# .wff could name a solver of the wrong kind for the format solve.sh/map.sh had
# just pinned -- those vet only their own command line -- and could override
# planner.lisp, which setqs *solver*/*cnf-format* and THEN parses the wff, so a
# file's choice won at every subsequent horizon.
#
# The other half is propositionalize's :cnf-format argument.  instantiate stamps
# the format it used into the .scnf as an (OPTION WEIGHTS ...) line and
# propositionalize reads it back from there -- NOT from the global -- so before
# the argument existed there was no way to emit an existing .scnf in a different
# dialect.  Asking for CNF got you weighted output, in a file named .cnf.
#
# Behavioral checks, not gold diffs.  No external solver is needed: nothing here
# runs one.
#
# Run from anywhere:  bash tests/run-test-options.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"

PASS=0; FAIL=0
ok()  { printf '  %-54s ... PASS\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  %-54s ... FAIL  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# One weighted theory, used throughout.  Nothing in it mentions a solver.
cat > g.wff <<'EOF'
(domain item (set banana steak milk))
(weight (buy banana) 1.25)
(weight (buy steak) 15.50)
(weight (buy milk) 3.10)
(or (buy steak) (buy milk))
EOF

# lisp <form> -- run one form against a freshly loaded FiFO, merging stderr.
lisp() {
  sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" --eval "$1" 2>&1
}

echo "=== option / solving-policy boundary ==="

# --- the five (plus the abbreviation table) are refused in a .wff -----------
for v in '*solver*' '*cnf-format*' '*solver-timeout*' '*preprocessor*' \
         '*preprocessor-techniques*' '*solver-abbreviations*'; do
  printf '(option %s x)\n(or (p a))\n' "$v" > bad.wff
  OUT="$(lisp '(instantiate "bad.wff")')"
  if [[ "$OUT" == *"$v"*"no longer supported"* ]]; then
    ok "(option $v ...) is refused in a .wff"
  else
    bad "(option $v ...) is refused in a .wff" "got: $(echo "$OUT" | tail -1)"
  fi
done

# The error must say where to set it instead -- a bare rejection would leave the
# reader stuck, since the replacement is not guessable from the option name.
OUT="$(printf '(option *solver* kissat)\n(or (p a))\n' > bad.wff; lisp '(instantiate "bad.wff")')"
if [[ "$OUT" == *":solver"* && "$OUT" == *"setq"* && "$OUT" == *"map.sh"* ]]; then
  ok "the refusal names the solve keyword, setq and the driver"
else
  bad "the refusal names the solve keyword, setq and the driver" "$(echo "$OUT" | tail -1)"
fi

# --- the generation options still work --------------------------------------
for v in '*compact-encoding* 0' '*tracing* 0' '*satplan-numslices* 3'; do
  printf '(option %s)\n(or (p a))\n' "$v" > gen.wff
  OUT="$(lisp '(instantiate "gen.wff")')"
  if [[ "$OUT" != *"no longer supported"* && "$OUT" != *"Unknown option"* ]]; then
    ok "(option ${v% *} ...) is still accepted"
  else
    bad "(option ${v% *} ...) is still accepted" "$(echo "$OUT" | tail -1)"
  fi
done

# An option that never existed must still be a plain unknown-option error, so a
# typo is not mistaken for a policy option that moved.
printf '(option *nonesuch* 1)\n(or (p a))\n' > typo.wff
OUT="$(lisp '(instantiate "typo.wff")')"
if [[ "$OUT" == *"Unknown option"* ]]; then
  ok "an unrecognised option is still 'Unknown option'"
else
  bad "an unrecognised option is still 'Unknown option'" "$(echo "$OUT" | tail -1)"
fi

echo
echo "=== a wff's options last only as long as the call that read it ==="

# An (option ...) form used to SETQ the global, so it outlived its file: after
# one wff turned the compact encoding off, every later instantiation in that
# Lisp ran with it off.  Each case runs two theories in ONE process, which is the
# situation that leaked.  (or (and a b c d) (and e f g)) is big enough that the
# compact encoding introduces a (TSEITIN n) selector: 4 x 3 = 12 > 4 + 3 + 1.
printf '(option *compact-encoding* 0)\n(or (and a b c d) (and e f g))\n' > off.wff
printf '(or (and a b c d) (and e f g))\n' > plain.wff

OUT="$(lisp '(progn (instantiate "off.wff" :scnfile "off.scnf")
                    (instantiate "plain.wff" :scnfile "plain.scnf")
                    (format t "~&GLOBAL ~S~%" *compact-encoding*))')"
if ! grep -q TSEITIN off.scnf && grep -q TSEITIN plain.scnf && grep -q '^GLOBAL T$' <<<"$OUT"; then
  ok "(option *compact-encoding* 0) does not outlive its file"
else
  bad "(option *compact-encoding* 0) does not outlive its file" \
      "off has TSEITIN: $(grep -c TSEITIN off.scnf), plain: $(grep -c TSEITIN plain.scnf); $(grep GLOBAL <<<"$OUT")"
fi

# The caller's own binding is still the starting value.
lisp '(let ((*compact-encoding* nil)) (instantiate "plain.wff" :scnfile "let.scnf"))' >/dev/null
if ! grep -q TSEITIN let.scnf; then ok "a caller's LET of *compact-encoding* still applies"
else bad "a caller's LET of *compact-encoding* still applies" "compact encoding used"; fi

# *satplan-numslices*: the wff's value applies inside, the caller's survives it,
# and an unbound variable is unbound again afterwards (the generated alias reads
# "unbound" as its default of 2, so leaving it bound changes later problems).
printf '(option *satplan-numslices* 3)\n(domain s (range 1 (lisp *satplan-numslices*)))\n(all x s true (q x))\n' > ns.wff
OUT="$(lisp '(progn (setq *satplan-numslices* 7)
                    (instantiate "ns.wff" :scnfile "ns.scnf")
                    (format t "~&AFTER ~S~%" *satplan-numslices*)
                    (makunbound (quote *satplan-numslices*))
                    (instantiate "ns.wff" :scnfile "ns2.scnf")
                    (format t "~&BOUND ~S~%" (boundp (quote *satplan-numslices*))))')"
if [[ "$(grep -c '(Q ' ns.scnf)" -eq 3 ]] && grep -q '^AFTER 7$' <<<"$OUT" \
   && grep -q '^BOUND NIL$' <<<"$OUT"; then
  ok "(option *satplan-numslices* N) is scoped to its file"
else
  bad "(option *satplan-numslices* N) is scoped to its file" \
      "Q atoms: $(grep -c '(Q ' ns.scnf); $(grep 'AFTER\|BOUND' <<<"$OUT" | tr '\n' ' ')"
fi

printf '(option *tracing* 1)\n(or (p a))\n' > tr.wff
OUT="$(lisp '(progn (instantiate "tr.wff" :scnfile "tr.scnf")
                    (format t "~&TRACING ~S~%" *tracing*))')"
if grep -q '\[TRACE\] Tracing enabled' <<<"$OUT" && grep -q '^TRACING NIL$' <<<"$OUT"; then
  ok "(option *tracing* 1) traces its file, then stops"
else
  bad "(option *tracing* 1) traces its file, then stops" "$(grep 'TRAC' <<<"$OUT" | tr '\n' ' ')"
fi

# parse-same-env CONTINUES a theory (planner evidence, the split monitor axioms),
# so it must run under that theory's options even though the call that parsed
# the theory has returned -- and must not inherit them from a different theory.
OUT="$(lisp '(progn
  (parse (quote ((option *compact-encoding* 0) (or (p x)))))
  (format t "~&OFF ~S~%" (search "TSEITIN" (format nil "~S" (parse-same-env (quote ((or (and a b c d) (and e f g))))))))
  (parse (quote ((or (p x)))))
  (format t "~&ON ~A~%" (if (search "TSEITIN" (format nil "~S" (parse-same-env (quote ((or (and a b c d) (and e f g))))))) "YES" "NO"))
  (format t "~&GLOBAL ~S~%" *compact-encoding*))')"
if grep -q '^OFF NIL$' <<<"$OUT" && grep -q '^ON YES$' <<<"$OUT" && grep -q '^GLOBAL T$' <<<"$OUT"; then
  ok "parse-same-env continues its theory's options, not another's"
else
  bad "parse-same-env continues its theory's options, not another's" \
      "$(grep 'OFF\|ON \|GLOBAL' <<<"$OUT" | tr '\n' ' ')"
fi

# solve with a prove form parses the QUERY after the theory's PARSE has returned;
# the wff's option must still hold there.  The query has to be one the compact
# encoding would split -- its negation is (or (and ~a ~b ~c ~d) (and ~e ~f ~g)) --
# or the case cannot tell (an earlier version used a one-literal query and passed
# with the query-time scope removed).  The theory itself has no such OR, so
# *tseitin-counter* (reset per parse, never bound) counts the QUERY's selectors.
printf '(option *compact-encoding* 0)\na\ne\n(prove () true (and (or a b c d) (or e f g)))\n' > pv.wff
printf 'a\ne\n(prove () true (and (or a b c d) (or e f g)))\n' > pv-on.wff
OUT="$(lisp '(progn (solve "pv.wff" :solnfile "pv.answer")
                    (format t "~&OFF ~S~%" *tseitin-counter*)
                    (solve "pv-on.wff" :solnfile "pv-on.answer")
                    (format t "~&ON ~S~%" *tseitin-counter*)
                    (format t "~&GLOBAL ~S~%" *compact-encoding*))')"
if grep -q PROVEN pv.answer && grep -q PROVEN pv-on.answer && grep -q '^OFF 0$' <<<"$OUT" \
   && grep -qE '^ON [1-9]' <<<"$OUT" && grep -q '^GLOBAL T$' <<<"$OUT"; then
  ok "solve: the prove query uses the file's encoding"
else
  bad "solve: the prove query uses the file's encoding" \
      "$(head -1 pv.answer 2>/dev/null); $(grep 'OFF\|ON \|GLOBAL' <<<"$OUT" | tr '\n' ' ')"
fi

# A continuation runs under the values the theory was BUILT with -- including a
# caller's LET around the original parse, though the continuation runs after
# it (as planner.lisp's evidence does).  Recording only what the FILE set would
# miss this: the file here sets nothing.
OUT="$(lisp '(progn
  (let ((*compact-encoding* nil) (*satplan-numslices* 5)) (parse (quote ((or (p x))))))
  (let ((c (parse-same-env (quote ((or (and a b c d) (and e f g))
                                   (domain s2 (range 1 (lisp *satplan-numslices*)))
                                   (all x s2 true (r x)))))))
    (format t "~&TSEITIN ~A~%" (if (search "TSEITIN" (format nil "~S" c)) "YES" "NO"))
    (format t "~&R ~D~%" (count-if (lambda (cl) (search "(R " (format nil "~S" cl))) c))))')"
if grep -q '^TSEITIN NO$' <<<"$OUT" && grep -q '^R 5$' <<<"$OUT"; then
  ok "parse-same-env continues a caller's LET around the parse"
else
  bad "parse-same-env continues a caller's LET around the parse" \
      "$(grep 'TSEITIN\|^R \|rror' <<<"$OUT" | head -3 | tr '\n' ' ')"
fi

# A FRESH theory parsed inside a scope where an earlier theory set an option
# starts from the caller's values, not that theory's.
OUT="$(lisp '(with-wff-option-scope ()
  (parse (quote ((option *compact-encoding* 0) (or (p x)))))
  (format t "~&SECOND ~A~%"
          (if (search "TSEITIN" (format nil "~S" (parse (quote ((or (and a b c d) (and e f g)))))))
              "COMPACT" "OFF")))')"
if grep -q '^SECOND COMPACT$' <<<"$OUT"; then
  ok "a fresh parse does not inherit an earlier theory's option"
else
  bad "a fresh parse does not inherit an earlier theory's option" "$(grep 'SECOND\|rror' <<<"$OUT" | head -2)"
fi

# parse-schema-list called directly (as REPL code and helpers do) takes an
# (option ...) for its own forms, without an error and without leaking.
OUT="$(lisp '(progn
  (setup-global-env)
  (format t "~&CLAUSES ~A~%"
          (if (search "TSEITIN" (format nil "~S" (clauses-with-definitions
             (lambda () (parse-schema-list (quote ((option *compact-encoding* 0)
                                                    (or (and a b c d) (and e f g)))))))))
              "COMPACT" "OFF"))
  (format t "~&GLOBAL ~S~%" *compact-encoding*))')"
if grep -q '^CLAUSES OFF$' <<<"$OUT" && grep -q '^GLOBAL T$' <<<"$OUT"; then
  ok "a direct parse-schema-list scopes its own option"
else
  bad "a direct parse-schema-list scopes its own option" "$(grep 'CLAUSES\|GLOBAL\|rror' <<<"$OUT" | head -3 | tr '\n' ' ')"
fi

echo
echo "=== propositionalize :cnf-format ==="

# instantiate records the format it was given; that is a generation-time fact
# about the file, and it is what propositionalize falls back on.
lisp '(progn (setq *cnf-format* (quote WCNF)) (instantiate "g.wff" :scnfile "g.scnf"))' >/dev/null
if grep -q '(OPTION WEIGHTS WCNF)' g.scnf; then
  ok "instantiate stamps the format into the .scnf"
else
  bad "instantiate stamps the format into the .scnf" "no (OPTION WEIGHTS ...) line"
fi

# The override: one .scnf, three dialects, no regeneration.
lisp '(progn
        (dolist (f (list (quote CNF) (quote WCNF) (quote WCNF-OLD)))
          (propositionalize "g.scnf" :cnf-format f
                            :cnffile (format nil "o-~A.out" f) :mapfile "o.map"))
        (propositionalize "g.scnf" :cnffile "o-DEFAULT.out" :mapfile "o.map"))' >/dev/null

# CNF: weights demoted to `cw` comment lines that a SAT solver ignores.
if head -1 o-CNF.out | grep -q '^p cnf' && grep -q '^cw ' o-CNF.out; then
  ok ":cnf-format CNF forces plain CNF over the file's WCNF"
else
  bad ":cnf-format CNF forces plain CNF over the file's WCNF" "$(head -1 o-CNF.out)"
fi
# WCNF: 2022 format, hard clauses prefixed h, no p-line.
if grep -q '^h ' o-WCNF.out && ! grep -q '^p ' o-WCNF.out; then
  ok ":cnf-format WCNF gives the 2022 'h' format"
else
  bad ":cnf-format WCNF gives the 2022 'h' format" "$(head -2 o-WCNF.out | tr '\n' ' ')"
fi
# WCNF-OLD: classic p wcnf header carrying a top weight.
if grep -q '^p wcnf .* [0-9]*$' o-WCNF-OLD.out; then
  ok ":cnf-format WCNF-OLD gives the classic 'p wcnf' header"
else
  bad ":cnf-format WCNF-OLD gives the classic 'p wcnf' header" "$(head -2 o-WCNF-OLD.out | tr '\n' ' ')"
fi
# Omitted: the file's own recorded format, so the round trip stays faithful.
if grep -q '^h ' o-DEFAULT.out; then
  ok "without the argument the .scnf's recorded format wins"
else
  bad "without the argument the .scnf's recorded format wins" "$(head -2 o-DEFAULT.out | tr '\n' ' ')"
fi

# The global is deliberately NOT consulted: silently overriding a format the
# file recorded would be the trap the explicit argument exists to avoid.
OUT="$(lisp '(progn (setq *cnf-format* (quote CNF))
                    (propositionalize "g.scnf" :cnffile "o-GLOBAL.out" :mapfile "o.map"))')"
if grep -q '^h ' o-GLOBAL.out; then
  ok "the global *cnf-format* does not override the .scnf"
else
  bad "the global *cnf-format* does not override the .scnf" "$(head -1 o-GLOBAL.out)"
fi

# A bad dialect is rejected up front, before any output file is opened.
OUT="$(lisp '(propositionalize "g.scnf" :cnf-format (quote BOGUS) :cnffile "o-BOGUS.out")')"
if [[ "$OUT" == *"Unknown :cnf-format"* && ! -f o-BOGUS.out ]]; then
  ok "an unknown :cnf-format is rejected, writing nothing"
else
  bad "an unknown :cnf-format is rejected, writing nothing" "$(echo "$OUT" | tail -1)"
fi

# The default output name follows the EFFECTIVE format, so a file cannot end up
# named .cnf while holding weighted clauses.
lisp '(propositionalize "g.scnf" :cnf-format (quote CNF) :mapfile "s.map")' >/dev/null
lisp '(propositionalize "g.scnf" :cnf-format (quote WCNF) :mapfile "s.map")' >/dev/null
if [[ -f g.cnf && -f g.wcnf ]] && head -1 g.cnf | grep -q '^p cnf' && grep -q '^h ' g.wcnf; then
  ok "the default extension follows the effective format"
else
  bad "the default extension follows the effective format" "cnf=$([[ -f g.cnf ]] && echo y) wcnf=$([[ -f g.wcnf ]] && echo y)"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
