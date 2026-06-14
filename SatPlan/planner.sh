#!/bin/bash
#
# planner.sh -- thin CLI wrapper around planner.lisp.
#
# Usage:
#   planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] \
#              [--minslices <int>] [--maxslices <int>]
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
  echo "usage: planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] [--minslices <int>] [--maxslices <int>]" >&2
  echo "  A .pddl problem is translated with pddl2fifo; a .wff is used as-is." >&2
  echo "  Searches horizons --minslices (default 2) .. --maxslices (default 6) for the smallest plan." >&2
  exit 2
}

PROBLEM=""
DOMAIN=""
MINSLICES=2
MAXSLICES=6

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    [[ $# -ge 2 ]] || usage; DOMAIN="$2";    shift 2 ;;
    --minslices) [[ $# -ge 2 ]] || usage; MINSLICES="$2"; shift 2 ;;
    --maxslices) [[ $# -ge 2 ]] || usage; MAXSLICES="$2"; shift 2 ;;
    --numslices) [[ $# -ge 2 ]] || usage; MINSLICES="$2"; MAXSLICES="$2"; shift 2 ;;  # fixed horizon
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)           if [[ -z "$PROBLEM" ]]; then PROBLEM="$1"; shift; else echo "unexpected argument: $1" >&2; usage; fi ;;
  esac
done

[[ -n "$PROBLEM" ]] || usage
[[ -f "$PROBLEM" ]] || { echo "problem file not found: $PROBLEM" >&2; exit 2; }
for v in MINSLICES MAXSLICES; do
  if [[ ! "${!v}" =~ ^[0-9]+$ ]]; then echo "--${v,,} must be a non-negative integer, got: ${!v}" >&2; exit 2; fi
done
if (( MINSLICES > MAXSLICES )); then
  echo "--minslices ($MINSLICES) must not exceed --maxslices ($MAXSLICES)" >&2; exit 2
fi

# Resolve paths to absolutes so the run is independent of the current directory.
PROBLEM="$(cd "$(dirname "$PROBLEM")" && pwd)/$(basename "$PROBLEM")"
DIR="$(dirname "$PROBLEM")"
if [[ -n "$DOMAIN" ]]; then
  [[ -f "$DOMAIN" ]] || { echo "domain file not found: $DOMAIN" >&2; exit 2; }
  DOMAIN="$(cd "$(dirname "$DOMAIN")" && pwd)/$(basename "$DOMAIN")"
fi

# Locate FiFO, pddl2fifo, planner.lisp, and the SatPlan axioms.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO="$SCRIPT_DIR/../FiFO.lisp"
PDDL2FIFO="$SCRIPT_DIR/pddl2fifo.lisp"
PLANNER="$SCRIPT_DIR/planner.lisp"
SATPLAN="$SCRIPT_DIR/satplan.wff"

# The (include ...) path written into a generated wff is computed relative to the
# problem directory so it stays portable; unused for .wff input.
SATPLAN_REL="$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$SATPLAN" "$DIR")"

DOMAIN_KW=""
[[ -n "$DOMAIN" ]] && DOMAIN_KW=":domain-file \"$DOMAIN\""

exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO\")" \
  --eval "(load \"$PDDL2FIFO\")" \
  --eval "(load \"$PLANNER\")" \
  --eval "(sb-ext:exit :code
            (plan-and-report \"$PROBLEM\"
              :minslices $MINSLICES :maxslices $MAXSLICES
              :sat-solver \"$SAT_SOLVER\" :weighted-solver \"$WEIGHTED_SOLVER\"
              :satplan-path \"$SATPLAN_REL\" $DOMAIN_KW))"
