#!/bin/bash
#
# cleanupfifo.sh -- delete FiFO intermediate/scratch files.
#
# Removes the regenerable byproducts of the FiFO pipeline -- .scnf .cnf .wcnf
# .map .satout .soln .answer -- wherever they have piled up.  Runnable from
# anywhere: with no argument it cleans the current directory AND sweeps the whole
# FiFO checkout, which it locates from its own path (or, for an installed copy in
# ~/bin, from the git repository the current directory sits in).
#
# Two guards decide what it will never delete:
#
#   1. Anything git tracks.  This is the load-bearing one.  Checked-in fixtures
#      carry exactly these extensions -- gold_instantiate/*_gold.scnf,
#      Probability/*.scnf, SatPlan/Examples/**/intermediates/*.wcnf, and the
#      committed .scnf/.answer under tests_instantiate/ and tests_solve/ -- so a
#      sweep by extension alone would delete the test suite's expected outputs.
#
#   2. Everything under the checkout's tests/ tree, tracked or not, so the
#      regression-test directories cannot lose a file even by accident.  An
#      explicit target inside tests/ is refused rather than silently skipped.
#
# Source files (.wff, .pddl, .lisp, ...) are never candidates in the first place:
# a .wff may be hand-written, so no extension that can hold source is listed.
#
set -euo pipefail

# Regenerable pipeline byproducts.  NOTE: .wff is NOT here -- see above.
EXTS=(scnf cnf wcnf map satout soln answer)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

print_usage() {
  cat <<EOF
usage: cleanupfifo.sh [<dir>|<file>]... [-r|--recursive] [-n|--dry-run] [-h|--help]

Delete FiFO intermediate/scratch files:
  ${EXTS[*]/#/.}

With no argument, cleans the current directory and sweeps the FiFO checkout
recursively.  With arguments, cleans exactly those directories (a file argument
means the directory containing it); add -r to recurse into them.

Never deleted: anything git tracks, and anything under the checkout's tests/
tree.  Source files (.wff, .pddl, .lisp, ...) are never candidates.

  -r, --recursive   recurse into the directories named on the command line
                    (the no-argument checkout sweep is always recursive)
  -n, --dry-run     list what would be deleted, without deleting
  -h, --help        show this help
EOF
}

DRY=0
RECURSIVE=0
TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      print_usage; exit 0 ;;
    -n|--dry-run)   DRY=1; shift ;;
    -r|--recursive) RECURSIVE=1; shift ;;
    -*)             echo "cleanupfifo.sh: unknown option: $1" >&2; echo >&2; print_usage >&2; exit 2 ;;
    *)              TARGETS+=("$1"); shift ;;
  esac
done

# --------------------------------------------------------------- the checkout

# Beside the script when it is run from the checkout's bin/; else the directory
# above $FIFO_LISP; else the git toplevel of the current directory, so an
# installed copy in ~/bin still finds the checkout when run from inside one.
# A candidate must be a git repository as well as a FiFO tree: the tracked-file
# guard is what makes sweeping safe, and outside a repository nothing is tracked.
# That also keeps an INSTALLED ~/lib/fifo -- which has lisp/FiFO.lisp but no
# .git, and no byproducts to collect -- from being swept.  Empty if none applies,
# in which case only the named (or current) directories are cleaned.
is_checkout() { [[ -n "$1" && -f "$1/lisp/FiFO.lisp" && -e "$1/.git" ]]; }
find_repo() {
  local c
  c="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)" || c=""
  if is_checkout "$c"; then printf '%s' "$c"; return; fi
  if [[ -n "${FIFO_LISP:-}" ]]; then
    c="$(cd "$FIFO_LISP/.." 2>/dev/null && pwd -P)" || c=""
    if is_checkout "$c"; then printf '%s' "$c"; return; fi
  fi
  c="$(git rev-parse --show-toplevel 2>/dev/null)" || c=""
  if [[ -n "$c" ]]; then c="$(cd "$c" && pwd -P)"; fi
  if is_checkout "$c"; then printf '%s' "$c"; return; fi
  printf ''
}
REPO="$(find_repo)"

# protected <abs-path> : true for anything under the checkout's tests/ tree
protected() {
  [[ -n "$REPO" ]] || return 1
  case "$1" in
    "$REPO"/tests|"$REPO"/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------- git-tracked files

TRACKED="$(mktemp)"; TOPS="$(mktemp)"
trap 'rm -f "$TRACKED" "$TOPS"' EXIT

# load_tracked <dir> : record every path git tracks in <dir>'s repository, once
# per repository.  A directory outside any repository contributes nothing, which
# is correct -- there is no tracked file there to protect.
load_tracked() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$top" ]] || return 0
  top="$(cd "$top" && pwd -P)"
  grep -qxF "$top" "$TOPS" 2>/dev/null && return 0
  printf '%s\n' "$top" >> "$TOPS"
  (cd "$top" && git ls-files) | sed "s|^|$top/|" >> "$TRACKED"
}

# ------------------------------------------------------------ collect files

NAME_ARGS=()
for ext in "${EXTS[@]}"; do
  [[ ${#NAME_ARGS[@]} -gt 0 ]] && NAME_ARGS+=(-o)
  NAME_ARGS+=(-name "*.$ext")
done

CANDIDATES="$(mktemp)"
trap 'rm -f "$TRACKED" "$TOPS" "$CANDIDATES"' EXIT

# collect <dir> <recursive 0|1> : append matching files, skipping .git and the
# protected tests/ tree
collect() {
  local dir="$1" rec="$2"
  load_tracked "$dir"
  if [[ "$rec" -eq 1 ]]; then
    if [[ -n "$REPO" ]]; then
      find "$dir" -name .git -prune -o -path "$REPO/tests" -prune -o \
           -type f \( "${NAME_ARGS[@]}" \) -print 2>/dev/null >> "$CANDIDATES"
    else
      find "$dir" -name .git -prune -o \
           -type f \( "${NAME_ARGS[@]}" \) -print 2>/dev/null >> "$CANDIDATES"
    fi
  else
    find "$dir" -maxdepth 1 -type f \( "${NAME_ARGS[@]}" \) -print 2>/dev/null >> "$CANDIDATES"
  fi
}

SKIPPED_PROTECTED=""

if [[ ${#TARGETS[@]} -gt 0 ]]; then
  for t in "${TARGETS[@]}"; do
    if [[ -d "$t" ]]; then dir="$(cd "$t" && pwd -P)"
    elif [[ -e "$t" ]]; then dir="$(cd "$(dirname "$t")" && pwd -P)"
    else echo "cleanupfifo.sh: no such file or directory: $t" >&2; exit 2; fi
    if protected "$dir"; then
      echo "cleanupfifo.sh: refusing to clean $dir" >&2
      echo "  the regression-test tree under $REPO/tests is never cleaned." >&2
      exit 2
    fi
    collect "$dir" "$RECURSIVE"
  done
  WHERE="the directories named"
else
  HERE="$(pwd -P)"
  if protected "$HERE"; then
    SKIPPED_PROTECTED="$HERE"
  else
    collect "$HERE" "$RECURSIVE"
  fi
  if [[ -n "$REPO" ]]; then
    collect "$REPO" 1
    case "$HERE" in
      "$REPO"|"$REPO"/*) WHERE="the FiFO checkout at $REPO" ;;
      *)                 WHERE="$HERE and the FiFO checkout at $REPO" ;;
    esac
  else
    WHERE="$HERE"
  fi
fi

# ------------------------------------------------------------------- filter

# Drop duplicates (the current directory is usually inside the swept checkout),
# then drop everything git tracks.
FILES="$(mktemp)"
trap 'rm -f "$TRACKED" "$TOPS" "$CANDIDATES" "$FILES"' EXIT
sort -u "$CANDIDATES" | { grep -Fxv -f "$TRACKED" || true; } > "$FILES"

COUNT=$(wc -l < "$FILES" | tr -d ' ')
KEPT=$(( $(sort -u "$CANDIDATES" | wc -l | tr -d ' ') - COUNT ))

if [[ -n "$SKIPPED_PROTECTED" ]]; then
  echo "Note: $SKIPPED_PROTECTED is inside the protected tests/ tree and was not cleaned."
fi

if [[ "$COUNT" -eq 0 ]]; then
  echo "No FiFO scratch files in $WHERE"
  [[ "$KEPT" -gt 0 ]] && echo "  ($KEPT of the files found are git-tracked and were left alone)"
  exit 0
fi

if [[ $DRY -eq 1 ]]; then
  echo "Would delete $COUNT file(s) in $WHERE:"
else
  echo "Deleting $COUNT file(s) in $WHERE:"
fi
sed 's|^|  |' "$FILES"
[[ "$KEPT" -gt 0 ]] && echo "  ($KEPT of the files found are git-tracked and were left alone)"

if [[ $DRY -eq 0 ]]; then
  while IFS= read -r f; do rm -f "$f"; done < "$FILES"
fi
