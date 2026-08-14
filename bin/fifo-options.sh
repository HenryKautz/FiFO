#!/bin/bash
#
# fifo-options.sh -- shared "--options FILE" preprocessing for the FiFO CLIs.
#
# This file is meant to be *sourced*, not executed.  It provides one function,
#
#     _fifo_expand_options "$@"
#
# which scans an argument list for any occurrence of
#
#     --options FILE
#
# and replaces it, in place, with the options read from FILE.  FILE is a plain
# text file holding a single logical line of options; that line may be wrapped
# across several physical lines with a trailing backslash (as in a shell
# script).  The logical line is parsed exactly as if it had been typed on the
# command line -- shell quoting and whitespace are honored -- so, for example,
#
#     --domain d.pddl --pddl-evidence '(occur-in-order a b)'
#
# splits into the right words even though the evidence form contains spaces.
# If FILE contains more than one logical line, a warning is printed and only
# the first is used.
#
# The expanded argument list is left in the global array FIFO_EXPANDED_ARGS.
# A caller typically does, right before its own option-parsing loop:
#
#     _fifo_expand_options "$@"
#     set -- ${FIFO_EXPANDED_ARGS[@]+"${FIFO_EXPANDED_ARGS[@]}"}
#
# Expansion is not recursive: a --options inside FILE is not re-expanded.
#
# On a bad --options argument, _fifo_options_die is called.  A script may
# predefine it (e.g. to also print usage); otherwise the default below is used.

if ! declare -f _fifo_options_die >/dev/null 2>&1; then
  _fifo_options_die() { echo "${0##*/}: $1" >&2; exit 2; }
fi

# Read FILE, join backslash-continued physical lines into logical lines, and
# print exactly two lines: the count of non-empty logical lines, then the first
# non-empty logical line verbatim (internal spacing preserved).
_fifo_options_read() {
  awk '
    { line = $0
      sub(/\r$/, "", line)                       # tolerate CRLF
      if (line ~ /\\$/) {                         # trailing backslash = continue
        buf = buf substr(line, 1, length(line) - 1)
        next
      }
      buf = buf line
      logical[++n] = buf
      buf = ""
    }
    END {
      if (buf != "") logical[++n] = buf           # file ended on a continuation
      cnt = 0; first = ""
      for (i = 1; i <= n; i++) {
        t = logical[i]; gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t != "") { cnt++; if (cnt == 1) first = logical[i] }
      }
      print cnt
      print first
    }' "$1"
}

_fifo_expand_options() {
  FIFO_EXPANDED_ARGS=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--options" ]]; then
      [[ $# -ge 2 ]] || _fifo_options_die "--options needs a FILE argument"
      local file="$2"; shift 2
      [[ -f "$file" ]] || _fifo_options_die "--options file not found: $file"
      local cnt="" first=""
      { read -r cnt; IFS= read -r first; } < <(_fifo_options_read "$file")
      if [[ -n "$cnt" && "$cnt" -gt 1 ]]; then
        echo "${0##*/}: warning: --options file '$file' has $cnt lines; using only the first" >&2
      fi
      if [[ -n "$first" ]]; then
        local -a extra=()
        eval "extra=( $first )" 2>/dev/null \
          || _fifo_options_die "could not parse options in '$file' (unbalanced quotes?)"
        FIFO_EXPANDED_ARGS+=( ${extra[@]+"${extra[@]}"} )
      fi
    else
      FIFO_EXPANDED_ARGS+=( "$1" ); shift
    fi
  done
}
