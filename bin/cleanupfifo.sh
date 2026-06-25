#!/bin/bash
#
# cleanupfifo.sh -- delete FiFO intermediate/scratch files from a directory.
#
# Removes the regenerable byproducts of the FiFO pipeline -- .scnf .cnf .wcnf .map
# .satout .soln .answer -- from a single directory (not recursive).  Source files
# (.wff, .pddl, .lisp, ...) are never touched.
#
# With no argument it cleans the current directory.  If the argument is a
# directory, that directory is cleaned; if it is a file, the directory containing
# the file is cleaned.

set -euo pipefail

# Regenerable pipeline byproducts.  NOTE: .wff is NOT here -- a .wff may be
# hand-written source, so it is never deleted.
EXTS=(scnf cnf wcnf map satout soln answer)

print_usage() {
  cat <<EOF
usage: cleanupfifo.sh [<dir>|<file>] [--dry-run]

Delete FiFO intermediate/scratch files from a directory (not recursive):
  ${EXTS[*]/#/.}

With no argument, cleans the current directory.  If the argument is a directory,
that directory is cleaned; if it is a file, the directory the file is in is
cleaned.  Source files (.wff, .pddl, .lisp, ...) are never deleted.

  -n, --dry-run   list what would be deleted, without deleting
  -h, --help      show this help
EOF
}

DRY=0
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    print_usage; exit 0 ;;
    -n|--dry-run) DRY=1; shift ;;
    -*)           echo "cleanupfifo.sh: unknown option: $1" >&2; echo >&2; print_usage >&2; exit 2 ;;
    *)            if [[ -z "$TARGET" ]]; then TARGET="$1"; shift
                  else echo "cleanupfifo.sh: unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done

# Resolve the directory to clean.
if [[ -z "$TARGET" ]]; then
  DIR="."
elif [[ -d "$TARGET" ]]; then
  DIR="$TARGET"
elif [[ -e "$TARGET" ]]; then
  DIR="$(dirname "$TARGET")"
else
  echo "cleanupfifo.sh: no such file or directory: $TARGET" >&2; exit 2
fi

# Collect matching files (non-recursive).
shopt -s nullglob
files=()
for ext in "${EXTS[@]}"; do
  for f in "$DIR"/*."$ext"; do files+=("$f"); done
done
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No FiFO scratch files in $DIR"
  exit 0
fi

if [[ $DRY -eq 1 ]]; then
  echo "Would delete ${#files[@]} file(s) in $DIR:"
else
  rm -f "${files[@]}"
  echo "Deleted ${#files[@]} file(s) in $DIR:"
fi
printf '  %s\n' "${files[@]}"
