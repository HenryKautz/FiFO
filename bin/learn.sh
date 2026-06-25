#!/bin/bash
#
# learn.sh -- run the FiFO weight-learning pipeline.
#
# Reads an instantiated .scnf file whose (PROBABILITY literal p [gid]) lines give
# target marginal probabilities, and writes a reweighted .scnf in which those
# targets have become integer (WEIGHT literal w) costs.  Two estimators are
# available: the independent log-odds closed form (default) and exact iterative
# maximum entropy over the feasible set.  Optionally also writes the learned
# weights back into a copy of the source .wff (--wff).
#
# The lisp is found in the installed lisp directory ($HOME/lib/fifo/lisp by
# default; override with the FIFO_LISP environment variable).

set -euo pipefail

FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: learn.sh <input.scnf> [options]

Run the FiFO weight-learning pipeline on an instantiated .scnf containing
(PROBABILITY ...) target marginals, producing a reweighted .scnf with integer
(WEIGHT ...) costs (and, with --wff, a weighted copy of the source .wff).

Estimator:
  --method <log-odds|maxent>  estimator to use (default: log-odds)
  --maxent                    shorthand for --method maxent

Common options:
  --out <file>                output .scnf            (default: <root>_reweighted.scnf)
  --scale <int>               integer weight resolution; real weight = w/scale
                              (default: 100)
  --wff <file>                also write the learned weights back into a copy of
                              this source .wff (the one that produced the .scnf)
  --wff-out <file>            write-back path         (default: <wff-root>_weighted.wff)

MaxEnt-only options (with --method maxent):
  --eta <float>               damped-Newton step size (default: 1.0)
  --tol <float>               convergence tolerance   (default: 1e-5)
  --max-iters <int>           iteration cap           (default: 5000)
  --no-consider-weights       ignore existing explicit (WEIGHT ...) lines while
                              fitting (they are still passed through); by default
                              they are held fixed so the fit accounts for them
  --quiet                     suppress the per-group target-vs-achieved report

  -h, --help                  show this help

Estimators:
  log-odds  closed form theta = log((1-p)/p) per atom; ignores clause coupling.
  maxent    exact fit over the feasible set; matches each tie group's mean
            marginal to its target (small instances only -- it enumerates).

The lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.
EOF
}

# bad-input helper: message + full usage to stderr, exit 2.
die() { echo "learn.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

METHOD="log-odds"
INPUT=""
OUT=""; SCALE="100"; WFF=""; WFFOUT=""
ETA=""; TOL=""; MAXITERS=""; CONSIDER=1; QUIET=0
MAXENT_OPT_GIVEN=0          # track maxent-only options, to reject under log-odds

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)             print_usage; exit 0 ;;
    --method)              [[ $# -ge 2 ]] || die "--method needs an argument"; METHOD="$2"; shift 2 ;;
    --maxent)              METHOD="maxent"; shift ;;
    --out)                 [[ $# -ge 2 ]] || die "--out needs an argument"; OUT="$2"; shift 2 ;;
    --scale)               [[ $# -ge 2 ]] || die "--scale needs an argument"; SCALE="$2"; shift 2 ;;
    --wff)                 [[ $# -ge 2 ]] || die "--wff needs an argument"; WFF="$2"; shift 2 ;;
    --wff-out)             [[ $# -ge 2 ]] || die "--wff-out needs an argument"; WFFOUT="$2"; shift 2 ;;
    --eta)                 [[ $# -ge 2 ]] || die "--eta needs an argument"; ETA="$2"; MAXENT_OPT_GIVEN=1; shift 2 ;;
    --tol)                 [[ $# -ge 2 ]] || die "--tol needs an argument"; TOL="$2"; MAXENT_OPT_GIVEN=1; shift 2 ;;
    --max-iters)           [[ $# -ge 2 ]] || die "--max-iters needs an argument"; MAXITERS="$2"; MAXENT_OPT_GIVEN=1; shift 2 ;;
    --no-consider-weights) CONSIDER=0; MAXENT_OPT_GIVEN=1; shift ;;
    --quiet)               QUIET=1; MAXENT_OPT_GIVEN=1; shift ;;
    --)                    shift; break ;;
    -*)                    die "unknown option: $1" ;;
    *)                     if [[ -z "$INPUT" ]]; then INPUT="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

# --- validate -------------------------------------------------------------
[[ -n "$INPUT" ]]   || die "no input .scnf file given"
[[ -f "$INPUT" ]]   || die "input file not found: $INPUT"
case "$METHOD" in log-odds|maxent) ;; *) die "--method must be log-odds or maxent, got: $METHOD" ;; esac
[[ "$SCALE" =~ ^[0-9]+$ && "$SCALE" -gt 0 ]] || die "--scale must be a positive integer, got: $SCALE"
if [[ -n "$MAXITERS" ]]; then [[ "$MAXITERS" =~ ^[0-9]+$ && "$MAXITERS" -gt 0 ]] || die "--max-iters must be a positive integer, got: $MAXITERS"; fi
if [[ -n "$ETA" ]]; then [[ "$ETA" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--eta must be a number, got: $ETA"; fi
if [[ -n "$TOL" ]]; then [[ "$TOL" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || die "--tol must be a number, got: $TOL"; fi
if [[ "$METHOD" == "log-odds" && "$MAXENT_OPT_GIVEN" -eq 1 ]]; then
  die "--eta/--tol/--max-iters/--no-consider-weights/--quiet apply only to --method maxent"
fi
[[ -n "$WFF" && ! -f "$WFF" ]] && die "source .wff not found: $WFF"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

# --- build the keyword arguments ------------------------------------------
KW=":scale $SCALE"
[[ -n "$OUT"    ]] && KW="$KW :out-file \"$OUT\""
[[ -n "$WFF"    ]] && KW="$KW :wff \"$WFF\""
[[ -n "$WFFOUT" ]] && KW="$KW :wff-out \"$WFFOUT\""

if [[ "$METHOD" == "maxent" ]]; then
  LISP="$FIFO_LISP/maxent.lisp"; FUNC="maxent-reweight"
  [[ -n "$ETA"      ]] && KW="$KW :eta $ETA"
  [[ -n "$TOL"      ]] && KW="$KW :tol $TOL"
  [[ -n "$MAXITERS" ]] && KW="$KW :max-iters $MAXITERS"
  [[ "$CONSIDER" -eq 0 ]] && KW="$KW :consider-weights nil"
  [[ "$QUIET"    -eq 1 ]] && KW="$KW :verbose nil"
else
  LISP="$FIFO_LISP/reweight.lisp"; FUNC="reweight"
fi

# Default write-back path, for the closing message (mirrors rw--default-wff-out).
WFF_MSG=""
if [[ -n "$WFF" ]]; then WFF_MSG="${WFFOUT:-${WFF%.*}_weighted.wff}"; fi

# Load in its own --eval so the function is defined before the form that calls it
# is compiled (avoids an undefined-function style warning), then run it.
exec sbcl --noinform --non-interactive \
  --eval "(handler-case (load \"$LISP\")
            (error (e) (format *error-output* \"learn.sh: ~A~%\" e) (sb-ext:exit :code 1)))" \
  --eval "(handler-case
            (progn
              (format t \"Reweighted SCNF: ~A~%\" ($FUNC \"$INPUT\" $KW))
              $( [[ -n "$WFF_MSG" ]] && echo "(format t \"Weighted WFF:    ~A~%\" \"$WFF_MSG\")" )
              (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"learn.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
