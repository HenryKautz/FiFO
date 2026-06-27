#!/bin/bash
#
# wmc.sh -- exact weighted model count (partition function Z) of a weighted .scnf,
# via the ADDMC weighted model counter.
#
# Reads an instantiated .scnf (hard (OR ...) clauses plus (WEIGHT literal w)
# costs), emits an MCC-2020 weighted CNF, runs ADDMC, and prints
#
#     (WMC <Z>)
#
# where Z = sum over the feasible set (the assignments satisfying the hard
# clauses) of exp(-(sum of the weights of the true literals)).  Unlike the
# brute-force enumeration in marginals.sh, this scales via algebraic decision
# diagrams.
#
# The FiFO lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).  The
# ADDMC binary is found via --addmc, else the ADDMC environment variable, else
# 'addmc' on PATH.

set -euo pipefail

FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: wmc.sh <file.scnf> [options]

Compute the exact weighted model count (partition function Z) of a weighted .scnf
via ADDMC, and print  (WMC <Z>).  Z is the sum over the feasible set of
exp(-(sum of the weights of the true literals)).

  --addmc <path>   path to the ADDMC binary (else $ADDMC, else 'addmc' on PATH)
  --scale <n>      divide integer weights by n (real cost = weight / n) before
                   exponentiating; default reads the 'scale: N' the weight-learning
                   pipeline records in the .scnf header (1 if absent).  Use
                   --scale 1 to count with the raw integer weights.
  --wcnf <file>    write the intermediate MCC weighted CNF here (and keep it)
  --keep-wcnf      keep the intermediate .wcnf scratch file instead of deleting it
  -h, --help       show this help

The FiFO lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.

ADDMC is a separate executable (https://github.com/HenryKautz/ADDMC, a macOS
fork of vardigroup/ADDMC).  Build it, then either put 'addmc' on your PATH, set
ADDMC=/path/to/addmc, or pass --addmc /path/to/addmc.
EOF
}

die() { echo "wmc.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

SCNF=""
WCNF=""
SCALE=""
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    print_usage; exit 0 ;;
    --addmc)      [[ $# -ge 2 ]] || die "--addmc needs an argument"; export ADDMC="$2"; shift 2 ;;
    --scale)      [[ $# -ge 2 ]] || die "--scale needs an argument"; SCALE="$2"; shift 2 ;;
    --wcnf)       [[ $# -ge 2 ]] || die "--wcnf needs an argument"; WCNF="$2"; shift 2 ;;
    --keep-wcnf)  KEEP=1; shift ;;
    -*)           die "unknown option: $1" ;;
    *)            if [[ -z "$SCNF" ]]; then SCNF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$SCNF" ]] || die "no .scnf file given"
[[ -f "$SCNF" ]] || die "input file not found: $SCNF"
if [[ -n "$SCALE" && ! "$SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--scale must be a positive number, got: $SCALE"; fi
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

# Resolve the ADDMC binary up front for a clear error.
ADDMC_BIN="${ADDMC:-addmc}"
if ! command -v "$ADDMC_BIN" >/dev/null 2>&1 && [[ ! -x "$ADDMC_BIN" ]]; then
  die "ADDMC binary not found: '$ADDMC_BIN' (set --addmc, the ADDMC env var, or put 'addmc' on PATH)"
fi

KW=""
[[ -n "$WCNF" ]] && KW="$KW :wcnf-file \"$WCNF\""
[[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"
[[ "$KEEP" -eq 1 ]] && KW="$KW :keep-wcnf t"

exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
  --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
  --eval "(handler-case (progn (wmc \"$SCNF\" $KW) (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"wmc.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
