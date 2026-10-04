#!/bin/bash
#
# run-test-paths.sh -- where the scripts find the lisp library and PDDL domains.
#
# Two rules, each in ONE place:
#
#   the lisp (bin/fifo-lisp.sh, sourced by every script):
#       FIFO_LISP if set; else <script dir>/../lisp if it holds FiFO.lisp; else
#       ~/lib/fifo/lisp.
#
#   a domain named only by the problem's (:domain <name>) (resolve-domain-file in
#   lisp/pddl2fifo.lisp): <name>.pddl beside the problem, then in the current
#   directory, then in the domain library $FIFO_LISP/../pddl.  An explicit bare
#   --domain name not in the current directory is looked up in the library too.
#
# The ORDER is what most of this checks, and each order case is built so the
# wrong order FAILS rather than merely reporting a different path: the file a
# correct search must skip is broken PDDL, so reading it is an error.
#
# Also: make install puts the library where the Lisp looks for it; an installed
# recognize.sh works with FIFO_LISP unset (it used to default to ~/bin/../lisp);
# and learn-pddl never writes a learned domain into the library.
#
# Run from anywhere:  bash tests/run-test-paths.sh
# Tests the working copy by default; set FIFO_LISP to test another lisp.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LISP="${FIFO_LISP:-$REPO/lisp}"
LISP="$(cd "$LISP" && pwd -P)"
LIB="$(cd "$LISP/../pddl" 2>/dev/null && pwd -P)" || {
  echo "no domain library beside $LISP (expected $LISP/../pddl)" >&2; exit 2; }
BIN="$REPO/bin"
command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
name() { printf '  %-62s ... ' "$1"; }
pass() { echo PASS; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP+1)); }

# planner.sh validates its solvers before translating anything, even for
# --stop-after wff, so the domain cases need them installed.
HAVE_SOLVERS=1
command -v kissat >/dev/null 2>&1 && command -v tt-open-wbo-inc-Glucose4_1 >/dev/null 2>&1 \
  || HAVE_SOLVERS=0

echo "=== where the lisp is found ==="

name "a checkout script, FIFO_LISP unset: the checkout's lisp"
GOT="$(env -u FIFO_LISP HOME="$TMP/nohome" /bin/bash -c "source '$BIN/fifo-lisp.sh'; echo \"\$FIFO_LISP\"")"
[[ "$(cd "$GOT" && pwd -P)" == "$REPO/lisp" ]] && pass || fail "got $GOT"

name "FIFO_LISP set wins over the checkout"
GOT="$(env FIFO_LISP=/some/where /bin/bash -c "source '$BIN/fifo-lisp.sh'; echo \"\$FIFO_LISP\"")"
[[ "$GOT" == "/some/where" ]] && pass || fail "got $GOT"

name "FIFO_LISP is exported to child processes"
GOT="$(env -u FIFO_LISP /bin/bash -c "source '$BIN/fifo-lisp.sh'; /bin/bash -c 'echo \"\$FIFO_LISP\"'")"
[[ -n "$GOT" ]] && pass || fail "child saw nothing"

# An installed copy: make install into a throwaway HOME.  BINDIR and LISPDIR are
# passed explicitly too: the Makefile's `?=` would otherwise take them from the
# caller's environment, and a user who exports them would have this test install
# the working tree over their real copy.
H="$TMP/home"
if make -s -C "$REPO" install HOME="$H" BINDIR="$H/bin" LISPDIR="$H/lib/fifo/lisp" \
     >"$TMP/install.log" 2>&1; then
  INSTALLED=1
else
  INSTALLED=0
fi

name "make install puts the domain library beside the lisp"
if [[ $INSTALLED -eq 1 && -f "$H/lib/fifo/pddl/clara-logistics.pddl" ]]; then pass
else fail "$(head -3 "$TMP/install.log")"; fi

name "make install installs ppgen and evgen with their lisp"
if [[ -x "$H/bin/ppgen.sh" && -x "$H/bin/evgen.sh" && -f "$H/lib/fifo/lisp/ppgen.lisp" \
      && -f "$H/lib/fifo/lisp/evgen.lisp" ]]; then pass; else fail "missing files"; fi

name "an installed script, FIFO_LISP unset: ~/lib/fifo/lisp"
GOT="$(env -u FIFO_LISP HOME="$H" /bin/bash -c "source '$H/bin/fifo-lisp.sh'; echo \"\$FIFO_LISP\"")"
[[ "$GOT" == "$H/lib/fifo/lisp" ]] && pass || fail "got $GOT"

name "a ../lisp WITHOUT FiFO.lisp is not taken for the library"
mkdir -p "$H/lisp"
GOT="$(env -u FIFO_LISP HOME="$H" /bin/bash -c "source '$H/bin/fifo-lisp.sh'; echo \"\$FIFO_LISP\"")"
rmdir "$H/lisp"
[[ "$GOT" == "$H/lib/fifo/lisp" ]] && pass || fail "got $GOT"

# recognize.sh used to default FIFO_LISP to <script dir>/../lisp -- ~/lisp for an
# installed copy -- and export it, so every script it ran failed on solvers.dat.
name "installed recognize.sh runs with FIFO_LISP unset"
OUT="$(cd "$TMP" && env -u FIFO_LISP HOME="$H" "$H/bin/recognize.sh" \
        clara-logistics.pddl "$TMP/no-such-problem.pddl" "$TMP/no-such-ev.txt" 2>&1)"
if grep -q "solvers.dat" <<<"$OUT"; then fail "still looks in the wrong lisp: $(head -1 <<<"$OUT")"
elif grep -q "no such file: $TMP/no-such-problem.pddl" <<<"$OUT"; then pass
else fail "unexpected: $(head -2 <<<"$OUT")"; fi

name "installed ppgen.sh runs with FIFO_LISP unset"
if (cd "$TMP" && env -u FIFO_LISP HOME="$H" "$H/bin/ppgen.sh" --style clique --clique-size 3 \
      --number-cliques 2 --truck-goals --seed 3 -o "$TMP/inst.pddl") >/dev/null 2>&1 \
   && grep -q '(:domain clara-logistics)' "$TMP/inst.pddl"; then pass
else fail "no problem generated"; fi

# An installed generator pointed at a CHECKOUT's lisp: ppgen.lisp is not in
# lisp/ there but in SatPlan/, and the installed script must still find it.
name "installed ppgen.sh with FIFO_LISP at a checkout's lisp/"
mkdir -p "$TMP/bare/bin"; cp "$H/bin/ppgen.sh" "$H/bin/fifo-lisp.sh" "$TMP/bare/bin/"
if (cd "$TMP" && env FIFO_LISP="$REPO/lisp" HOME="$TMP/nohome" "$TMP/bare/bin/ppgen.sh" \
      --style clique --clique-size 3 --number-cliques 2 --truck-goals --seed 3 \
      -o "$TMP/bare.pddl") >"$TMP/bare.log" 2>&1 && [[ -s "$TMP/bare.pddl" ]]; then pass
else fail "$(tail -1 "$TMP/bare.log")"; fi

echo
echo "=== where the domain file is found ==="

# A problem naming (:domain clara-logistics), alone in its own directory.
mkdir -p "$TMP/prob" "$TMP/work" "$TMP/empty"
FIFO_LISP="$LISP" bash "$REPO/SatPlan/ppgen.sh" --style clique --clique-size 3 \
  --number-cliques 2 --truck-goals --seed 3 -o "$TMP/prob/p.pddl" >/dev/null 2>&1
BROKEN='(define (domain clara-logistics) (:requirements :strips) (:action broken'

# translate <cwd> [args...] : planner.sh --stop-after wff from <cwd>; stderr+stdout
translate() { local d="$1"; shift
  (cd "$d" && env FIFO_LISP="$LISP" "$BIN/planner.sh" "$TMP/prob/p.pddl" --stop-after wff "$@" 2>&1); }
used() { sed -n 's/^; domain clara-logistics: //p' <<<"$1" | head -1; }

if [[ $HAVE_SOLVERS -eq 0 ]]; then
  for c in library cwd beside miss bare slash bare-miss; do
    name "domain lookup ($c)"; skip "kissat / tt-open-wbo-inc not installed"; done
else
  name "nothing beside, nothing in cwd: the domain library"
  OUT="$(translate "$TMP/empty")"
  [[ "$(used "$OUT")" == "$LIB/clara-logistics.pddl" && -f "$TMP/prob/p.wff" ]] && pass \
    || fail "used '$(used "$OUT")': $(tail -2 <<<"$OUT")"

  name "the current directory comes before the library"
  cp "$LIB/clara-logistics.pddl" "$TMP/work/"
  OUT="$(translate "$TMP/work")"
  [[ "$(used "$OUT")" == "$TMP/work/clara-logistics.pddl" ]] && pass || fail "used '$(used "$OUT")'"

  # Beside the problem must win, and the cwd copy is BROKEN, so a search that
  # tried the cwd first would not just report another path -- it would fail.
  name "beside the problem comes before the current directory"
  cp "$LIB/clara-logistics.pddl" "$TMP/prob/"
  printf '%s\n' "$BROKEN" > "$TMP/work/clara-logistics.pddl"
  OUT="$(translate "$TMP/work")"
  [[ "$(used "$OUT")" == "$TMP/prob/clara-logistics.pddl" ]] && grep -q "Wrote" <<<"$OUT" && pass \
    || fail "used '$(used "$OUT")': $(tail -2 <<<"$OUT")"
  rm -f "$TMP/prob/clara-logistics.pddl" "$TMP/work/clara-logistics.pddl"

  name "a miss is an error listing all three places"
  mkdir -p "$TMP/nolib"; cp -R "$LISP" "$TMP/nolib/lisp"     # no ../pddl beside it
  OUT="$(cd "$TMP/empty" && env FIFO_LISP="$TMP/nolib/lisp" "$BIN/planner.sh" \
          "$TMP/prob/p.pddl" --stop-after wff 2>&1)"
  if grep -q "No domain file for (:domain clara-logistics)" <<<"$OUT" \
     && grep -q "$TMP/prob/clara-logistics.pddl" <<<"$OUT" \
     && grep -q "$TMP/empty/clara-logistics.pddl" <<<"$OUT" \
     && grep -q "nolib/pddl/clara-logistics.pddl" <<<"$OUT"; then pass
  else fail "$(grep -i -m2 'domain' <<<"$OUT")"; fi

  # The cwd must be parsed as a native name: SBCL reads "[old]" or "a*b" in a
  # namestring as WILD, and probe-file on a wild pathname errors rather than
  # returning nil -- so the lookup died instead of falling through.
  name "a cwd whose name has [ ] or * falls through to the library"
  mkdir -p "$TMP/[old]" "$TMP/exp*2"
  OUT1="$(translate "$TMP/[old]")"; OUT2="$(translate "$TMP/exp*2")"
  [[ "$(used "$OUT1")" == "$LIB/clara-logistics.pddl" \
     && "$(used "$OUT2")" == "$LIB/clara-logistics.pddl" ]] && pass \
    || fail "$(grep -m1 -i 'wild\|error' <<<"$OUT1$OUT2")"

  name "--domain <bare name> not in cwd: taken from the library"
  OUT="$(translate "$TMP/empty" --domain clara-logistics.pddl)"
  [[ -f "$TMP/prob/p.wff" ]] && grep -q "Wrote" <<<"$OUT" && pass || fail "$(tail -2 <<<"$OUT")"

  name "--domain with a '/' is literal, never searched for"
  OUT="$(translate "$TMP/empty" --domain ./clara-logistics.pddl)"
  grep -q "domain file not found: ./clara-logistics.pddl" <<<"$OUT" \
    && ! grep -q "Wrote" <<<"$OUT" && pass || fail "$(tail -2 <<<"$OUT")"

  name "--domain <bare name> missing everywhere names the library"
  OUT="$(translate "$TMP/empty" --domain nosuch.pddl)"
  grep -q "looked in the current directory and in the domain library $LIB" <<<"$OUT" \
    && pass || fail "$(tail -2 <<<"$OUT")"
fi

# learn-pddl writes <domain>_learned.pddl beside the domain -- but a LIBRARY
# domain must not be written into: the copy goes beside the problem.
name "learn-pddl: a learned LIBRARY domain goes beside the problem"
mkdir -p "$TMP/plib/pddl" "$TMP/pprob"; cp -R "$LISP" "$TMP/plib/lisp"
cat > "$TMP/plib/pddl/pswitch.pddl" <<'EOF'
(define (domain pswitch)
   (:requirements :strips :negative-preconditions)
   (:predicates (on ?x))
   (:action turn-on :parameters (?x) :precondition (not (on ?x)) :effect (on ?x)
      :probability 0.7)
   (:action turn-off :parameters (?x) :precondition (on ?x) :effect (not (on ?x))))
EOF
cat > "$TMP/pprob/ps.pddl" <<'EOF'
(define (problem ps)
   (:domain pswitch)
   (:objects s1 s2)
   (:init (on s1))
   (:goal (and (on s2))))
EOF
OUT="$(cd "$TMP/empty" && env FIFO_LISP="$TMP/plib/lisp" "$BIN/learn-pddl.sh" "$TMP/pprob/ps.pddl" 2>&1)"
if [[ -f "$TMP/pprob/pswitch_learned.pddl" && ! -e "$TMP/plib/pddl/pswitch_learned.pddl" ]]; then pass
else fail "$(grep -m2 -i 'learned\|error' <<<"$OUT")"; fi

# evgen resolves (:domain ...) by the same function, and records the file it
# used in its settings block.
name "evgen finds a library domain and records it"
if [[ $HAVE_SOLVERS -eq 0 ]]; then skip "kissat / tt-open-wbo-inc not installed"
else
  (cd "$TMP/empty" && env FIFO_LISP="$LISP" "$BIN/planner.sh" "$TMP/prob/p.pddl" >/dev/null 2>&1)
  OUT="$(cd "$TMP/empty" && env FIFO_LISP="$LISP" bash "$REPO/SatPlan/evgen.sh" \
          --problem "$TMP/prob/p.pddl" --evidence "$TMP/ev.txt" --slices 1 2>&1)"
  grep -qx ";;   --domain $LIB/clara-logistics.pddl" "$TMP/ev.txt" 2>/dev/null && pass \
    || fail "$(tail -2 <<<"$OUT")"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
[[ $FAIL -eq 0 ]]
