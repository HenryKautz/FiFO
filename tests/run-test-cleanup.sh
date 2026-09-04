#!/bin/bash
#
# run-test-cleanup.sh -- regression tests for bin/cleanupfifo.sh.
#
# This script deletes files, so what is tested is mostly what it must NOT delete:
# git-tracked fixtures (which carry the same extensions as the byproducts) and
# anything under the checkout's tests/ tree.  The checkout itself is never used
# as a subject -- every destructive case runs against a throwaway git repository
# built in a temp directory, so a bug here cannot cost the real repo a file.
#
# Run from anywhere:  bash tests/run-test-cleanup.sh
# Needs no solver and no sbcl.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CLEANUP="$REPO/bin/cleanupfifo.sh"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
name() { printf '  %-54s ... ' "$1"; }
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }

# A throwaway FiFO-shaped checkout: cleanupfifo.sh recognizes a directory as one
# when it holds lisp/FiFO.lisp and a .git, and only then does it sweep or protect.
make_fake_repo() {   # make_fake_repo <dir>
  local d="$1"
  mkdir -p "$d/lisp" "$d/bin" "$d/tests/gold_instantiate" "$d/tests/tests_solve" \
           "$d/Probability" "$d/SatPlan/Examples/Sub"
  : > "$d/lisp/FiFO.lisp"
  cp "$CLEANUP" "$d/bin/"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  # tracked fixtures, in the extensions the sweep matches
  : > "$d/Probability/fixture.scnf"
  : > "$d/tests/gold_instantiate/x_gold.scnf"
  : > "$d/tests/tests_solve/committed.answer"
  : > "$d/SatPlan/Examples/Sub/tracked.wcnf"
  : > "$d/keep.wff"
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm init
}

# untracked byproducts, scattered
make_junk() {   # make_junk <repo-dir>
  local d="$1"
  : > "$d/scratch-1-2-3.scnf"; : > "$d/scratch-1-2-3.cnf"; : > "$d/stale.satout"
  : > "$d/Probability/junk.wcnf"
  : > "$d/SatPlan/Examples/Sub/junk.map"
  : > "$d/tests/gold_instantiate/STRAY.scnf"
  : > "$d/tests/tests_solve/STRAY.answer"
}

R="$TMP/repo"
make_fake_repo "$R"

echo "=== cleanupfifo.sh ==="

name "sweeps the checkout from its own bin/"
make_junk "$R"
(cd "$TMP" && bash "$R/bin/cleanupfifo.sh" >/dev/null 2>&1)
if [[ ! -e "$R/scratch-1-2-3.scnf" && ! -e "$R/stale.satout" \
      && ! -e "$R/Probability/junk.wcnf" && ! -e "$R/SatPlan/Examples/Sub/junk.map" ]]
then pass; else fail "byproducts survived"; fi

name "never deletes a git-tracked file"
if [[ -e "$R/Probability/fixture.scnf" && -e "$R/SatPlan/Examples/Sub/tracked.wcnf" ]]
then pass; else fail "a tracked fixture was deleted"; fi

name "never touches tests/, tracked or not"
if [[ -e "$R/tests/gold_instantiate/x_gold.scnf" \
      && -e "$R/tests/gold_instantiate/STRAY.scnf" \
      && -e "$R/tests/tests_solve/committed.answer" \
      && -e "$R/tests/tests_solve/STRAY.answer" ]]
then pass; else fail "a file under tests/ was deleted"; fi

name "leaves source files alone"
if [[ -e "$R/keep.wff" && -e "$R/lisp/FiFO.lisp" ]]; then pass
else fail "a source file was deleted"; fi

name "an explicit target inside tests/ is refused"
out="$(cd "$R" && bash "$R/bin/cleanupfifo.sh" tests/gold_instantiate 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && echo "$out" | grep -q "refusing to clean"; then pass
else fail "rc=$rc out=$out"; fi

name "run from inside tests/: says so, and sweeps the rest"
make_junk "$R"
out="$(cd "$R/tests/gold_instantiate" && bash "$R/bin/cleanupfifo.sh" 2>&1)"
if echo "$out" | grep -q "protected tests/ tree" \
   && [[ -e "$R/tests/gold_instantiate/STRAY.scnf" && ! -e "$R/scratch-1-2-3.cnf" ]]
then pass; else fail "$out"; fi

name "--dry-run deletes nothing"
make_junk "$R"
(cd "$R" && bash "$R/bin/cleanupfifo.sh" -n >/dev/null 2>&1)
if [[ -e "$R/scratch-1-2-3.scnf" && -e "$R/Probability/junk.wcnf" ]]; then pass
else fail "dry run deleted files"; fi
(cd "$R" && bash "$R/bin/cleanupfifo.sh" >/dev/null 2>&1)

name "cleans a plain directory outside any repository"
D="$TMP/plain"; mkdir -p "$D/sub"; : > "$D/a.scnf"; : > "$D/sub/b.cnf"; : > "$D/s.wff"
(cd "$D" && bash "$CLEANUP" "$D" >/dev/null 2>&1)
if [[ ! -e "$D/a.scnf" && -e "$D/sub/b.cnf" && -e "$D/s.wff" ]]; then pass
else fail "non-recursive clean of a named directory is wrong"; fi

name "-r recurses into a named directory"
: > "$D/a.scnf"
(cd "$TMP" && bash "$CLEANUP" -r "$D" >/dev/null 2>&1)
if [[ ! -e "$D/a.scnf" && ! -e "$D/sub/b.cnf" && -e "$D/s.wff" ]]; then pass
else fail "-r did not recurse"; fi

name "an installed copy with no checkout cleans only the target"
IB="$TMP/installed-bin"; mkdir -p "$IB"; cp "$CLEANUP" "$IB/"
: > "$D/a.scnf"; : > "$R/scratch-9-9-9.scnf"
(cd "$D" && env -u FIFO_LISP bash "$IB/cleanupfifo.sh" >/dev/null 2>&1)
if [[ ! -e "$D/a.scnf" && -e "$R/scratch-9-9-9.scnf" ]]; then pass
else fail "an installed copy swept something it should not have"; fi

name "FIFO_LISP lets an installed copy find the checkout"
: > "$D/a.scnf"
(cd "$D" && FIFO_LISP="$R/lisp" bash "$IB/cleanupfifo.sh" >/dev/null 2>&1)
if [[ ! -e "$D/a.scnf" && ! -e "$R/scratch-9-9-9.scnf" ]]; then pass
else fail "FIFO_LISP did not locate the checkout"; fi

name "a missing target is an error, not a silent no-op"
out="$(bash "$CLEANUP" "$TMP/nope" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && echo "$out" | grep -q "no such file"; then pass
else fail "rc=$rc out=$out"; fi

name "reports cleanly when there is nothing to delete"
out="$(cd "$R" && bash "$R/bin/cleanupfifo.sh" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -q "No FiFO scratch files"; then pass
else fail "rc=$rc out=$out"; fi

name "runs under bash 3.2 (what the shebang gets on macOS)"
if [[ -x /bin/bash ]]; then
  : > "$D/a.scnf"
  if (cd "$D" && /bin/bash "$IB/cleanupfifo.sh" >/dev/null 2>&1) && [[ ! -e "$D/a.scnf" ]]
  then pass; else fail "failed under /bin/bash"; fi
else echo "SKIP (no /bin/bash)"; fi

# ------------------------------------------------------- scratch-file roots ---

echo
echo "=== scratch file roots ==="

name "a scratch root carries the pid, so runs cannot collide"
if command -v sbcl >/dev/null 2>&1; then
  roots="$(for i in 1 2 3 4; do
             ( sbcl --noinform --disable-debugger \
                    --eval "(load \"$REPO/lisp/FiFO.lisp\")" \
                    --eval '(progn (princ (make-scratch-file-root)) (terpri))' \
                    --quit 2>/dev/null | grep '^scratch-' ) &
           done; wait)"
  n=$(echo "$roots" | grep -c '^scratch-')
  u=$(echo "$roots" | sort -u | grep -c '^scratch-')
  # 4 concurrent processes, all within the same second: before the pid was added
  # they collapsed to ONE root and overwrote each other's .cnf/.satout.
  if [[ "$n" -eq 4 && "$u" -eq 4 ]]; then pass
  else fail "$n root(s), only $u distinct"; fi
else echo "SKIP (no sbcl)"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
