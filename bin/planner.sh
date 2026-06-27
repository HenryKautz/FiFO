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
  echo "usage: planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] [--minslices <int>] [--maxslices <int>] [--solver <name>] [--stop-after <wff|scnf>]" >&2
  echo "                  [--evidence <formula>]... [--evidence-file <file>] [--marginals [--counter <name>]]" >&2
  echo "  A .pddl problem is translated with pddl2fifo; a .wff is used as-is." >&2
  echo "  Searches horizons for the smallest plan.  --minslices defaults to a reachability" >&2
  echo "  lower bound (2 for a .wff); --maxslices defaults to 2 * minslices." >&2
  echo "  --solver overrides the pure SAT (feasibility) solver; default: $SAT_SOLVER." >&2
  echo "  --stop-after wff   stops after writing the .wff (translation only, no solving)." >&2
  echo "  --stop-after scnf  stops after instantiating the .scnf at the smallest horizon" >&2
  echo "                     (or --numslices), without solving; with evidence, also leaves" >&2
  echo "                     the separate <root>-evidence.scnf." >&2
  echo "  --longer K   for a costed domain, also minimize cost at up to K horizons beyond" >&2
  echo "               the smallest feasible one, returning the cheapest plan (default 0)." >&2
  echo "  --evidence <formula>  condition on a FiFO formula (ground or quantified over the" >&2
  echo "               problem's domains); instantiated in the same env as the problem into a" >&2
  echo "               separate <root>-evidence.scnf and conjoined.  Repeatable." >&2
  echo "  --evidence-file <f>   a file of such formulas, conjoined with any --evidence." >&2
  echo "  --pddl-evidence <form>  evidence in the PDDL modal language (always | at-end |" >&2
  echo "               hold-during | occur-sometime | never | at, over PDDL predicate/action" >&2
  echo "               names), translated to FiFO by pddl2fifo.  Repeatable.  PDDL only." >&2
  echo "  --pddl-evidence-file <f>  a file of such PDDL modal forms." >&2
  echo "  --marginals  run weighted model counting instead of planning: print P(atom|evidence)" >&2
  echo "               at the working horizon (no plan search)." >&2
  echo "  --counter <name>  (with --marginals) the model counter: 'maxent' (default, built-in" >&2
  echo "               enumeration) or an ADDMC binary name/path." >&2
  exit 2
}

PROBLEM=""
DOMAIN=""
MINSLICES=""   # empty = let the planner default it from reachability analysis
MAXSLICES=""   # empty = let the planner default it to 2 * minslices
STOP_AFTER=""  # empty = run the full pipeline; "wff" or "scnf" stops early
LONGER=""      # empty = 0; search K horizons beyond the smallest feasible for a cheaper plan
EVFILE=""      # --evidence-file
EVIDENCE_FORMS=()  # --evidence (repeatable)
PDDL_EVFILE=""        # --pddl-evidence-file
PDDL_EVIDENCE_FORMS=()  # --pddl-evidence (repeatable)
MARGINALS=0    # --marginals: weighted model counting instead of planning
COUNTER=""     # --counter: model counter for --marginals (maxent | addmc binary)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    [[ $# -ge 2 ]] || usage; DOMAIN="$2";    shift 2 ;;
    --minslices) [[ $# -ge 2 ]] || usage; MINSLICES="$2"; shift 2 ;;
    --maxslices) [[ $# -ge 2 ]] || usage; MAXSLICES="$2"; shift 2 ;;
    --numslices) [[ $# -ge 2 ]] || usage; MINSLICES="$2"; MAXSLICES="$2"; shift 2 ;;  # fixed horizon
    --solver)    [[ $# -ge 2 ]] || usage; SAT_SOLVER="$2";  shift 2 ;;
    --stop-after) [[ $# -ge 2 ]] || usage; STOP_AFTER="$2"; shift 2 ;;
    --longer)    [[ $# -ge 2 ]] || usage; LONGER="$2";    shift 2 ;;
    --evidence)       [[ $# -ge 2 ]] || usage; EVIDENCE_FORMS+=("$2"); shift 2 ;;
    --evidence-file)  [[ $# -ge 2 ]] || usage; EVFILE="$2"; shift 2 ;;
    --pddl-evidence)      [[ $# -ge 2 ]] || usage; PDDL_EVIDENCE_FORMS+=("$2"); shift 2 ;;
    --pddl-evidence-file) [[ $# -ge 2 ]] || usage; PDDL_EVFILE="$2"; shift 2 ;;
    --marginals) MARGINALS=1; shift ;;
    --counter)   [[ $# -ge 2 ]] || usage; COUNTER="$2"; shift 2 ;;
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)           if [[ -z "$PROBLEM" ]]; then PROBLEM="$1"; shift; else echo "unexpected argument: $1" >&2; usage; fi ;;
  esac
done

[[ -n "$PROBLEM" ]] || usage
[[ -f "$PROBLEM" ]] || { echo "problem file not found: $PROBLEM" >&2; exit 2; }
if [[ -n "$STOP_AFTER" && "$STOP_AFTER" != "wff" && "$STOP_AFTER" != "scnf" ]]; then
  echo "--stop-after must be wff or scnf, got: $STOP_AFTER" >&2; exit 2
fi
if [[ -n "$LONGER" && ! "$LONGER" =~ ^[0-9]+$ ]]; then
  echo "--longer must be a non-negative integer, got: $LONGER" >&2; exit 2
fi
if [[ -n "$EVFILE" && ! -f "$EVFILE" ]]; then echo "evidence file not found: $EVFILE" >&2; exit 2; fi
if [[ -n "$PDDL_EVFILE" && ! -f "$PDDL_EVFILE" ]]; then echo "pddl-evidence file not found: $PDDL_EVFILE" >&2; exit 2; fi
if [[ -n "$COUNTER" && "$MARGINALS" -ne 1 ]]; then echo "--counter applies only with --marginals" >&2; exit 2; fi
if { [[ ${#PDDL_EVIDENCE_FORMS[@]} -gt 0 ]] || [[ -n "$PDDL_EVFILE" ]]; } && [[ "$PROBLEM" == *.wff ]]; then
  echo "--pddl-evidence requires a PDDL problem, not a .wff (use --evidence with FiFO forms)" >&2; exit 2
fi
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
if [[ -n "$EVFILE" ]]; then
  EVFILE="$(cd "$(dirname "$EVFILE")" && pwd)/$(basename "$EVFILE")"
fi
if [[ -n "$PDDL_EVFILE" ]]; then
  PDDL_EVFILE="$(cd "$(dirname "$PDDL_EVFILE")" && pwd)/$(basename "$PDDL_EVFILE")"
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
MAXENT="$FIFO_LISP/maxent.lisp"      # loaded only for --marginals (weighted model counting)
WMC="$FIFO_LISP/wmc.lisp"            #   "
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
STOP_KW=""
[[ -n "$STOP_AFTER" ]] && STOP_KW=":stop-after :$STOP_AFTER"
LONGER_KW=""
[[ -n "$LONGER" ]] && LONGER_KW=":longer $LONGER"
EVIDENCE_KW=""
[[ ${#EVIDENCE_FORMS[@]} -gt 0 ]] && EVIDENCE_KW=":evidence (quote ( ${EVIDENCE_FORMS[*]} ))"
EVFILE_KW=""
[[ -n "$EVFILE" ]] && EVFILE_KW=":evidence-file \"$EVFILE\""
PDDL_EVIDENCE_KW=""
[[ ${#PDDL_EVIDENCE_FORMS[@]} -gt 0 ]] && PDDL_EVIDENCE_KW=":pddl-evidence (quote ( ${PDDL_EVIDENCE_FORMS[*]} ))"
PDDL_EVFILE_KW=""
[[ -n "$PDDL_EVFILE" ]] && PDDL_EVFILE_KW=":pddl-evidence-file \"$PDDL_EVFILE\""
MARGINALS_KW=""
[[ "$MARGINALS" -eq 1 ]] && MARGINALS_KW=":marginals t"
COUNTER_KW=""
[[ -n "$COUNTER" ]] && COUNTER_KW=":counter \"$COUNTER\""

# Load FiFO and pddl2fifo; for --marginals also the weighted-model-counting code.
EVALS=( --eval "(load \"$FIFO\")" --eval "(load \"$PDDL2FIFO\")" )
[[ "$MARGINALS" -eq 1 ]] && EVALS+=( --eval "(load \"$MAXENT\")" --eval "(load \"$WMC\")" )
EVALS+=( --eval "(load \"$PLANNER\")" )
EVALS+=( --eval "(sb-ext:exit :code
            (plan-and-report \"$PROBLEM\"
              $MIN_KW $MAX_KW $STOP_KW $LONGER_KW
              $EVIDENCE_KW $EVFILE_KW $PDDL_EVIDENCE_KW $PDDL_EVFILE_KW
              $MARGINALS_KW $COUNTER_KW
              :sat-solver \"$SAT_SOLVER\" :weighted-solver \"$WEIGHTED_SOLVER\"
              :satplan-path \"$SATPLAN_REL\" $DOMAIN_KW))" )

exec sbcl --noinform --non-interactive "${EVALS[@]}"
