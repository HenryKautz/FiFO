#!/bin/bash
#
# wmc.sh -- exact weighted model count (partition function Z) of a weighted .scnf,
# via the ADDMC weighted model counter (default) or SharpSAT-TD.
#
# Reads an instantiated .scnf (hard (OR ...) clauses plus (WEIGHT literal w)
# costs), emits a weighted CNF in the counter's dialect, runs it, and prints
#
#     (WMC <Z>)
#
# where Z = sum over the feasible set (the assignments satisfying the hard
# clauses) of exp(-(sum of the weights of the true literals)).  Unlike the
# brute-force enumeration in marginals.sh, this scales via algebraic decision
# diagrams.
#
# The FiFO lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).  ADDMC
# is found on PATH as 'addmc', SharpSAT-TD as 'sharpSAT'.

set -euo pipefail

FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: wmc.sh <file.scnf> [options]

Compute the exact weighted model count (partition function Z) of a weighted .scnf
via ADDMC or SharpSAT-TD, and print  (WMC <Z>).  Z is the sum over the feasible
set of exp(-(sum of the weights of the true literals)).

  --counter <name> addmc (default) or sharpsat-td.  Both are exact; SharpSAT-TD
                   is guided by a tree decomposition and carries an unbounded
                   exponent, though Z is still printed as a double, so a Z
                   outside about 2.2e-308..1.8e308 is an error rather than a 0
  --decot <s>      (sharpsat-td only) seconds of tree-decomposition search, in
                   (0.0001, 10000) (default 1)
  --cache-mb <n>   (sharpsat-td only) component-cache limit in MB (default 4000)
  --scale <n>      divide integer weights by n (real cost = weight / n) before
                   exponentiating; default reads the 'scale: N' the weight-learning
                   pipeline records in the .scnf header (1 if absent).  Use
                   --scale 1 to count with the raw integer weights.
  --epsilon <e>    (addmc only) ADDMC's CUDD terminal-merging tolerance (--ep);
                   default 0 = exact (full double precision).  A positive value
                   trades exactness for speed/memory.
  --evidence <form>   condition on a GROUND FiFO formula (clausified and conjoined
                      with the theory as a hard constraint), so Z becomes the count
                      conditioned on it.  Repeatable; conjoined.
  --evidence-file <f> a file of ground FiFO formulas to condition on.  Evidence
                      must be ground (over atoms already in the scnf).
  --wcnf <file>    write the intermediate weighted CNF here (and keep it); it is
                   in the counter's dialect -- MCC 2020 for addmc, 2024 for
                   sharpsat-td -- and the two are NOT interchangeable
  --keep-wcnf      keep the intermediate .wcnf scratch file instead of deleting it
  --options <file> splice the options listed in <file> in at this point (one
                   logical line, wrappable with a trailing backslash; if the file
                   has more than one line only the first is used)
  -h, --help       show this help

The FiFO lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.

ADDMC is a separate executable (https://github.com/HenryKautz/ADDMC, a macOS
fork of vardigroup/ADDMC), found on PATH as 'addmc'.  SharpSAT-TD
(https://github.com/HenryKautz/sharpsat-td) is found as 'sharpSAT', with its
flow_cutter_pace17 beside it.  bin/install-solvers.sh builds and installs both;
to use a different build, put it earlier on PATH.
EOF
}

die() { echo "wmc.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

SCNF=""
WCNF=""
SCALE=""
EPSILON=""
COUNTER="addmc"
DECOT=""
CACHE_MB=""
EVFILE=""
EVIDENCE_FORMS=()
KEEP=0

# Expand any --options FILE into the options it contains (see fifo-options.sh).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fifo-options.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fifo-solvers.sh"
_fifo_options_die() { die "$1"; }
_fifo_expand_options "$@"
set -- ${FIFO_EXPANDED_ARGS[@]+"${FIFO_EXPANDED_ARGS[@]}"}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    print_usage; exit 0 ;;
    --scale)      [[ $# -ge 2 ]] || die "--scale needs an argument"; SCALE="$2"; shift 2 ;;
    --epsilon)    [[ $# -ge 2 ]] || die "--epsilon needs an argument"; EPSILON="$2"; shift 2 ;;
    --counter)    [[ $# -ge 2 ]] || die "--counter needs an argument (addmc or sharpsat-td)"; COUNTER="$2"; shift 2 ;;
    --decot)      [[ $# -ge 2 ]] || die "--decot needs an argument"; DECOT="$2"; shift 2 ;;
    --cache-mb)   [[ $# -ge 2 ]] || die "--cache-mb needs an argument"; CACHE_MB="$2"; shift 2 ;;
    --evidence)       [[ $# -ge 2 ]] || die "--evidence needs an argument"; EVIDENCE_FORMS+=("$2"); shift 2 ;;
    --evidence-file)  [[ $# -ge 2 ]] || die "--evidence-file needs an argument"; EVFILE="$2"; shift 2 ;;
    --wcnf)       [[ $# -ge 2 ]] || die "--wcnf needs an argument"; WCNF="$2"; shift 2 ;;
    --keep-wcnf)  KEEP=1; shift ;;
    -*)           die "unknown option: $1" ;;
    *)            if [[ -z "$SCNF" ]]; then SCNF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$SCNF" ]] || die "no .scnf file given"
[[ -f "$SCNF" ]] || die "input file not found: $SCNF"
if [[ -n "$SCALE" && ! "$SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--scale must be a positive number, got: $SCALE"; fi
if [[ -n "$EPSILON" && ! "$EPSILON" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then die "--epsilon must be a non-negative number, got: $EPSILON"; fi
[[ -z "$EVFILE" || -f "$EVFILE" ]] || die "evidence file not found: $EVFILE"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

# Only the two counters that compute a Z on their own belong here.  Check that
# against the CANONICAL name (abbreviations resolved through lisp/solvers.dat)
# BEFORE checking the binary, so a counter this script refuses anyway is not
# first answered with an install instruction.  An unknown name falls through to
# _fifo_require_counter's own message.
CLINE="$(_fifo_lookup counter "$COUNTER")"
if [[ -n "$CLINE" ]]; then
  CANON="$(_fifo_field "$CLINE" 2)"
  [[ "$CANON" == "addmc" || "$CANON" == "sharpsat-td" ]] \
    || die "--counter must be addmc or sharpsat-td for a partition function, got: $COUNTER"
fi
COUNTER="$(_fifo_require_counter "$COUNTER" marginals wmc.sh)" || exit 2
# Same open interval wmc--run-sharpsat enforces, so the error comes before SBCL
# loads rather than after.
if [[ -n "$DECOT" ]] && ! awk -v d="$DECOT" 'BEGIN { exit !(d ~ /^([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ && d+0 > 0.0001 && d+0 < 10000) }'; then
  die "--decot must be a number of seconds in (0.0001, 10000), got: $DECOT"
fi
if [[ -n "$CACHE_MB" && ! "$CACHE_MB" =~ ^[1-9][0-9]*$ ]]; then die "--cache-mb must be a positive integer, got: $CACHE_MB"; fi
[[ -z "$EPSILON" || "$COUNTER" == "addmc" ]] || die "--epsilon applies to the addmc counter only"
[[ -z "$DECOT" || "$COUNTER" == "sharpsat-td" ]] || die "--decot applies to the sharpsat-td counter only"
[[ -z "$CACHE_MB" || "$COUNTER" == "sharpsat-td" ]] || die "--cache-mb applies to the sharpsat-td counter only"

KW=":counter :$COUNTER"
[[ -n "$DECOT" ]] && KW="$KW :decot $DECOT"
[[ -n "$CACHE_MB" ]] && KW="$KW :cache-mb $CACHE_MB"
[[ -n "$WCNF" ]] && KW="$KW :wcnf-file \"$WCNF\""
[[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"
[[ -n "$EPSILON" ]] && KW="$KW :epsilon $EPSILON"
[[ ${#EVIDENCE_FORMS[@]} -gt 0 ]] && KW="$KW :evidence (quote ( ${EVIDENCE_FORMS[*]} ))"
[[ -n "$EVFILE" ]] && KW="$KW :evidence-file \"$EVFILE\""
[[ "$KEEP" -eq 1 ]] && KW="$KW :keep-wcnf t"

exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
  --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
  --eval "(handler-case (progn (wmc \"$SCNF\" $KW) (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"wmc.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
