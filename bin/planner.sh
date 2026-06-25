#!/bin/bash
#
# planner.sh -- thin CLI wrapper around planner.lisp.
#
# Usage:
#   planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] \
#              [--minslices <int>] [--maxslices <int>] [--solver <name>]
#
# Translates a .pddl problem with pddl2fifo (a .wff is used directly) and calls
# (plan-and-report ...) in planner.lisp, which searches horizons --minslices
# (default 2) .. --maxslices (default 6) for the smallest plan: a pure SAT solver
# tests feasibility on a plain-CNF encoding at each horizon, and if the domain
# has action costs the smallest feasible horizon is re-solved in WCNF with a
# weighted (MaxSAT) solver to minimize cost.  All intermediate files and the
# .answer file are left next to the problem file; the answer is printed on stdout.

set -euo pipefail

# --- Solver configuration ---------------------------------------------------
SAT_SOLVER="kissat"                            # pure SAT solver (feasibility)
WEIGHTED_SOLVER="tt-open-wbo-inc-Glucose4_1"   # weighted/MaxSAT solver (costs)
# ----------------------------------------------------------------------------

usage() {
  echo "usage: planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] [--minslices <int>] [--maxslices <int>] [--solver <name>]" >&2
  echo "  A .pddl problem is translated with pddl2fifo; a .wff is used as-is." >&2
  echo "  Searches horizons for the smallest plan.  --minslices defaults to a reachability" >&2
  echo "  lower bound (2 for a .wff); --maxslices defaults to 2 * minslices." >&2
  echo "  --solver overrides the pure SAT (feasibility) solver; default: $SAT_SOLVER." >&2
  exit 2
}

PROBLEM=""
DOMAIN=""
MINSLICES=""   # empty = let the planner default it from reachability analysis
MAXSLICES=""   # empty = let the planner default it to 2 * minslices

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    [[ $# -ge 2 ]] || usage; DOMAIN="$2";    shift 2 ;;
    --minslices) [[ $# -ge 2 ]] || usage; MINSLICES="$2"; shift 2 ;;
    --maxslices) [[ $# -ge 2 ]] || usage; MAXSLICES="$2"; shift 2 ;;
    --numslices) [[ $# -ge 2 ]] || usage; MINSLICES="$2"; MAXSLICES="$2"; shift 2 ;;  # fixed horizon
    --solver)    [[ $# -ge 2 ]] || usage; SAT_SOLVER="$2";  shift 2 ;;
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)           if [[ -z "$PROBLEM" ]]; then PROBLEM="$1"; shift; else echo "unexpected argument: $1" >&2; usage; fi ;;
  esac
done

[[ -n "$PROBLEM" ]] || usage
[[ -f "$PROBLEM" ]] || { echo "problem file not found: $PROBLEM" >&2; exit 2; }
for v in MINSLICES MAXSLICES; do
  if [[ -n "${!v}" && ! "${!v}" =~ ^[0-9]+$ ]]; then echo "--${v,,} must be a non-negative integer, got: ${!v}" >&2; exit 2; fi
done
if [[ -n "$MINSLICES" && -n "$MAXSLICES" ]] && (( MINSLICES > MAXSLICES )); then
  echo "--minslices ($MINSLICES) must not exceed --maxslices ($MAXSLICES)" >&2; exit 2
fi

# Resolve paths to absolutes so the run is independent of the current directory.
PROBLEM="$(cd "$(dirname "$PROBLEM")" && pwd)/$(basename "$PROBLEM")"
DIR="$(dirname "$PROBLEM")"
if [[ -n "$DOMAIN" ]]; then
  [[ -f "$DOMAIN" ]] || { echo "domain file not found: $DOMAIN" >&2; exit 2; }
  DOMAIN="$(cd "$(dirname "$DOMAIN")" && pwd)/$(basename "$DOMAIN")"
fi

# Locate FiFO, pddl2fifo, planner.lisp, and the SatPlan axioms.  They live in the
# installed lisp directory ($HOME/lib/fifo/lisp by default; override with the
# FIFO_LISP environment variable, e.g. to point at a source checkout's lisp/).
FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"
[[ -d "$FIFO_LISP" ]] || { echo "FiFO lisp directory not found: $FIFO_LISP" >&2
  echo "  run 'make install', or set FIFO_LISP to your lisp/ directory." >&2; exit 2; }
FIFO="$FIFO_LISP/FiFO.lisp"
PDDL2FIFO="$FIFO_LISP/pddl2fifo.lisp"
PLANNER="$FIFO_LISP/planner.lisp"
SATPLAN="$FIFO_LISP/satplan.wff"

# The (include ...) path written into a generated wff is computed relative to the
# problem directory so it stays portable; unused for .wff input.
SATPLAN_REL="$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$SATPLAN" "$DIR")"

# Pass slice bounds only when given; otherwise the planner computes them
# (minslices from pddl2fifo's reachability analysis, maxslices = 2 * minslices).
DOMAIN_KW=""
[[ -n "$DOMAIN" ]] && DOMAIN_KW=":domain-file \"$DOMAIN\""
MIN_KW=""
[[ -n "$MINSLICES" ]] && MIN_KW=":minslices $MINSLICES"
MAX_KW=""
[[ -n "$MAXSLICES" ]] && MAX_KW=":maxslices $MAXSLICES"

exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO\")" \
  --eval "(load \"$PDDL2FIFO\")" \
  --eval "(load \"$PLANNER\")" \
  --eval "(sb-ext:exit :code
            (plan-and-report \"$PROBLEM\"
              $MIN_KW $MAX_KW
              :sat-solver \"$SAT_SOLVER\" :weighted-solver \"$WEIGHTED_SOLVER\"
              :satplan-path \"$SATPLAN_REL\" $DOMAIN_KW))"
