#!/bin/bash
#
# map.sh -- MAP inference on a FiFO problem: find the MOST PROBABLE model.
#
# Runs FiFO's `solve` with the weighted CNF format and a MaxSAT solver, so the
# answer is the minimum-cost model rather than any model.  Because a FiFO theory
# defines P(x) proportional to exp(-cost(x)), minimizing cost IS maximizing
# probability -- see Probability/probability.md.
#
# For plain satisfiability, use solve.sh.
#
# The weighted format is fixed by this script and is deliberately NOT an option:
# it is what distinguishes map.sh from solve.sh.  Everything else `solve`
# accepts is exposed below.
#
# The lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

SOLVER="tt-open-wbo-inc-Glucose4_1"
FORMAT="WCNF"
TIMEOUT=""
SOLNFILE=""
STATICFILE=""
PREPROCESSOR=""
TECHNIQUES=""
KEEP=0
WFF=""

print_usage() {
  cat <<EOF
usage: map.sh <problem.wff> [options]

MAP inference: find the most probable model of a weighted FiFO theory, i.e. the
one of minimum total weight.  The problem is instantiated, written as a weighted
CNF, handed to a MaxSAT solver, and the model translated back into symbolic
literals.

  --solver <name>     MaxSAT solver to run (default: $SOLVER).
                      Abbreviations work: tt-glucose, tt-intelsat, nuwls.
                      A plain SAT solver is rejected -- see solve.sh
  --old-format        write the classic "p wcnf <v> <c> <top>" format instead of
                      the 2022 format with 'h' lines.  Needed by older solvers
  --timeout <secs>    stop the solver after this many seconds (SIGTERM, then
                      SIGKILL after a grace period).  Anytime MaxSAT solvers
                      print their best solution so far when stopped this way, so
                      a timeout yields a usable -- if not provably optimal --
                      answer.  0, -1 or 'none' mean no limit.  Default: FiFO's
                      *solver-timeout*, 600 s
  --preprocessor <p>  preprocess with a MaxPre 2 binary before solving, and
                      reconstruct the model afterwards (usually: --preprocessor maxpre)
  --preprocessor-techniques <s>
                      MaxPre's -techniques= string; default is MaxPre's own
  --out <file>        answer file (default: <problem>.answer)
  --staticfile <file> file of static ground facts to instantiate against
  --keep              keep the intermediate .cnf/.map/.satout files
  --options <file>    splice the options listed in <file> in at this point (one
                      logical line, wrappable with a trailing backslash)
  -h, --help          show this help

The answer file carries (*OBJECTIVE* N), the solver's RAW cost.  map.sh also
prints the true cost, correcting N by the weight scale and shift that the
weighted formats require:  true cost = N / scale + offset.

The lisp is located via FIFO_LISP (default: \$HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.

MaxSAT solvers are not installed by default; bin/install-solvers.sh builds
tt-open-wbo-inc and nuwls-c, and MaxPre 2 for --preprocessor.
EOF
}

die() { echo "map.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

source "$SELF_DIR/fifo-options.sh"
source "$SELF_DIR/fifo-solvers.sh"
_fifo_options_die() { die "$1"; }
_fifo_expand_options "$@"
set -- ${FIFO_EXPANDED_ARGS[@]+"${FIFO_EXPANDED_ARGS[@]}"}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      print_usage; exit 0 ;;
    --solver)       [[ $# -ge 2 ]] || die "--solver needs an argument"; SOLVER="$2"; shift 2 ;;
    --old-format)   FORMAT="WCNF-OLD"; shift ;;
    --timeout)      [[ $# -ge 2 ]] || die "--timeout needs an argument"; TIMEOUT="$2"; shift 2 ;;
    --preprocessor) [[ $# -ge 2 ]] || die "--preprocessor needs an argument"; PREPROCESSOR="$2"; shift 2 ;;
    --preprocessor-techniques)
                    [[ $# -ge 2 ]] || die "--preprocessor-techniques needs an argument"; TECHNIQUES="$2"; shift 2 ;;
    --out|--solnfile)
                    [[ $# -ge 2 ]] || die "--out needs an argument"; SOLNFILE="$2"; shift 2 ;;
    --staticfile|--obsfile)
                    [[ $# -ge 2 ]] || die "--staticfile needs an argument"; STATICFILE="$2"; shift 2 ;;
    --keep)         KEEP=1; shift ;;
    --cnf-format)   die "--cnf-format is not an option here: map.sh is the weighted driver.
  Use --old-format for the classic 'p wcnf' variant, or solve.sh for plain CNF." ;;
    -*)             die "unknown option: $1" ;;
    *)              if [[ -z "$WFF" ]]; then WFF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$WFF" ]] || die "no problem.wff given"
[[ -f "$WFF" ]] || die "file not found: $WFF"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"
[[ -z "$STATICFILE" || -f "$STATICFILE" ]] || die "static file not found: $STATICFILE"

# Refuse a solver that cannot answer this question.
_fifo_require_solver_kind "$SOLVER" maxsat map.sh solve.sh || exit 2

SOLVER_BIN="$(_fifo_resolve_solver "$SOLVER")"
if ! command -v "$SOLVER_BIN" >/dev/null 2>&1 && [[ ! -x "$SOLVER_BIN" ]]; then
  die "MaxSAT solver not found: '$SOLVER_BIN'${SOLVER_BIN:+$([[ "$SOLVER_BIN" != "$SOLVER" ]] && echo " (from '$SOLVER')")}
  Install one with:  bin/install-solvers.sh --only tt-open-wbo-inc
  or:                bin/install-solvers.sh --only nuwls-c"
fi
if [[ -n "$PREPROCESSOR" ]] && ! command -v "$PREPROCESSOR" >/dev/null 2>&1 \
   && [[ ! -x "$PREPROCESSOR" ]]; then
  die "preprocessor not found: '$PREPROCESSOR'
  Install MaxPre 2 with:  bin/install-solvers.sh --only maxpre"
fi

[[ "$TIMEOUT" == "none" ]] && TIMEOUT="-1"
if [[ -n "$TIMEOUT" && ! "$TIMEOUT" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
  die "--timeout must be a number of seconds (or 0/-1/none for no limit), got: $TIMEOUT"
fi

# Pin the scratch root so the intermediate weighted CNF can be found afterwards:
# it carries the 'c weights scaled by' / 'c weight shift offset' comment lines
# needed to turn the solver's raw objective into the real cost.
#
# The root must contain no '.' -- FiFO derives the .satout/.map names from the
# .cnf name with a regex that replaces from the FIRST dot in the path, so a root
# like ".map-123" would send the solver's output somewhere the reader does not
# look.  (For the same reason this breaks if the containing directory has a dot
# in its name, which is why the root is kept beside the problem file.)
ROOT="$(cd "$(dirname "$WFF")" && pwd)/map-$$-scratch"
case "$(basename "$ROOT")" in *.*) die "internal: scratch root must not contain a dot" ;; esac

KW=":cnf-format (quote $FORMAT) :solver \"$SOLVER\""
[[ -n "$TIMEOUT"      ]] && KW="$KW :timeout $TIMEOUT"
[[ -n "$SOLNFILE"     ]] && KW="$KW :solnfile \"$SOLNFILE\""
[[ -n "$STATICFILE"   ]] && KW="$KW :staticfile \"$STATICFILE\""
[[ -n "$PREPROCESSOR" ]] && KW="$KW :preprocessor \"$PREPROCESSOR\""
[[ -n "$TECHNIQUES"   ]] && KW="$KW :preprocessor-techniques \"$TECHNIQUES\""

sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(setq scratch-file \"$ROOT\")" \
  --eval "(handler-case
             (let ((r (solve \"$WFF\" $KW)))
               (format t \"~&~A~%\" r)
               (sb-ext:exit :code (if r 0 1)))
           (error (e) (format *error-output* \"map.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
STATUS=$?

# --- report the true cost ----------------------------------------------------
# The weighted DIMACS formats need positive integer weights, so propositionalize
# scales all weights by an integer and, when an atom carries weight in both
# polarities, shifts them; each transformation is recorded as a comment line.
ANSWER="${SOLNFILE:-${WFF%.*}.answer}"
if [[ "$STATUS" -eq 0 && -f "$ANSWER" ]]; then
  RAW="$(grep -o '(\*OBJECTIVE\* [0-9.]*)' "$ANSWER" 2>/dev/null | grep -o '[0-9.]*' | head -1)"
  if [[ -n "$RAW" ]]; then
    SCALE=1; OFFSET=0
    for f in "$ROOT.cnf" "$ROOT.wcnf"; do
      [[ -f "$f" ]] || continue
      S="$(sed -n 's/^c weights scaled by \([0-9.]*\):.*/\1/p' "$f" | head -1)"
      M="$(sed -n 's/^c weight shift offset \([0-9.-]*\):.*/\1/p' "$f" | head -1)"
      [[ -n "$S" ]] && SCALE="$S"
      [[ -n "$M" ]] && OFFSET="$M"
      break
    done
    TRUE="$(awk -v r="$RAW" -v s="$SCALE" -v o="$OFFSET" 'BEGIN{ printf "%g", r/s + o }')"
    if [[ "$SCALE" == "1" && "$OFFSET" == "0" ]]; then
      echo "true cost: $TRUE"
    else
      echo "true cost: $TRUE   (raw objective $RAW / scale $SCALE + offset $OFFSET)"
    fi
  fi
fi

[[ "$KEEP" -eq 1 ]] || rm -f "$ROOT".{cnf,wcnf,map,satout,soln,scnf} "$ROOT"-pre.* 2>/dev/null
exit "$STATUS"
