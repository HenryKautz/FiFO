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
