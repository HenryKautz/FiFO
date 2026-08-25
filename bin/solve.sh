#!/bin/bash
#
# solve.sh -- solve a FiFO problem for SATISFIABILITY.
#
# Runs FiFO's `solve` with the plain DIMACS CNF format and a pure SAT solver,
# and prints the answer.  This is the satisfiability question: is there a model,
# and what is it.  To minimize the total weight of the true weighted literals
# instead -- MAP inference -- use map.sh, which writes the weighted format and
# runs a MaxSAT solver.
#
# The CNF format is fixed by this script and is deliberately NOT an option: it
# is what distinguishes solve.sh from map.sh.  Everything else `solve` accepts
# is exposed below.
#
# The lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

SOLVER="kissat"
TIMEOUT=""
SOLNFILE=""
STATICFILE=""
WFF=""

print_usage() {
  cat <<EOF
usage: solve.sh <problem.wff> [options]

Solve a FiFO problem for satisfiability: instantiate it, write a plain DIMACS
CNF file, run a SAT solver, and translate the model back into symbolic literals.
The answer is printed and written to the .answer file.

  --solver <name>     SAT solver to run (default: $SOLVER).  A MaxSAT solver is
                      rejected -- see map.sh
  --timeout <secs>    stop the solver after this many seconds (SIGTERM, then
                      SIGKILL after a grace period).  0, -1 or 'none' mean no
                      limit.  Default: FiFO's *solver-timeout*, 600 s
  --out <file>        answer file (default: <problem>.answer)
  --staticfile <file> file of static ground facts to instantiate against
  --options <file>    splice the options listed in <file> in at this point (one
                      logical line, wrappable with a trailing backslash)
  -h, --help          show this help

The answer file's first line is SAT or UNSAT, followed by the true atoms of the
model.  A weighted problem solved this way is NOT optimized: its weights are
written as 'cw' comment lines that a SAT solver ignores, so you get some model
rather than the cheapest one.  Use map.sh when the weights are meant to matter.

The lisp is located via FIFO_LISP (default: \$HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.
EOF
}

die() { echo "solve.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

# Expand any --options FILE into the options it contains (see fifo-options.sh).
source "$SELF_DIR/fifo-options.sh"
source "$SELF_DIR/fifo-solvers.sh"
_fifo_options_die() { die "$1"; }
_fifo_expand_options "$@"
set -- ${FIFO_EXPANDED_ARGS[@]+"${FIFO_EXPANDED_ARGS[@]}"}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     print_usage; exit 0 ;;
    --solver)      [[ $# -ge 2 ]] || die "--solver needs an argument"; SOLVER="$2"; shift 2 ;;
    --timeout)     [[ $# -ge 2 ]] || die "--timeout needs an argument"; TIMEOUT="$2"; shift 2 ;;
    --out|--solnfile)
                   [[ $# -ge 2 ]] || die "--out needs an argument"; SOLNFILE="$2"; shift 2 ;;
    --staticfile|--obsfile)
                   [[ $# -ge 2 ]] || die "--staticfile needs an argument"; STATICFILE="$2"; shift 2 ;;
    --cnf-format)  die "--cnf-format is not an option here: solve.sh is the plain-CNF driver.
  Use map.sh for the weighted (MaxSAT) format." ;;
    --preprocessor|--preprocessor-techniques)
                   die "$1 applies to MaxSAT only.  MaxPre is a MaxSAT preprocessor and
  has nothing to do on a plain CNF; use map.sh $1 ..." ;;
    -*)            die "unknown option: $1" ;;
    *)             if [[ -z "$WFF" ]]; then WFF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$WFF" ]] || die "no problem.wff given"
[[ -f "$WFF" ]] || die "file not found: $WFF"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"
[[ -z "$STATICFILE" || -f "$STATICFILE" ]] || die "static file not found: $STATICFILE"

# Refuse a solver that cannot answer this question.
_fifo_require_solver_kind "$SOLVER" sat solve.sh map.sh || exit 2

SOLVER_BIN="$(_fifo_resolve_solver "$SOLVER")"
if ! command -v "$SOLVER_BIN" >/dev/null 2>&1 && [[ ! -x "$SOLVER_BIN" ]]; then
  die "SAT solver not found: '$SOLVER_BIN'
  Install one with:  bin/install-solvers.sh --only kissat"
fi

# 'none' is a friendlier spelling of the 0 / -1 that FiFO takes for "no limit".
[[ "$TIMEOUT" == "none" ]] && TIMEOUT="-1"
if [[ -n "$TIMEOUT" && ! "$TIMEOUT" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
  die "--timeout must be a number of seconds (or 0/-1/none for no limit), got: $TIMEOUT"
fi

KW=":cnf-format (quote CNF) :solver \"$SOLVER\""
[[ -n "$TIMEOUT"    ]] && KW="$KW :timeout $TIMEOUT"
[[ -n "$SOLNFILE"   ]] && KW="$KW :solnfile \"$SOLNFILE\""
[[ -n "$STATICFILE" ]] && KW="$KW :staticfile \"$STATICFILE\""

exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(handler-case
             (let ((r (solve \"$WFF\" $KW)))
               (format t \"~&~A~%\" r)
               (sb-ext:exit :code (if r 0 1)))
           (error (e) (format *error-output* \"solve.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
