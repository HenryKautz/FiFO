#!/bin/bash
#
# planner.sh -- solve a PDDL planning problem with FiFO + a MaxSAT solver.
#
# Usage:
#   planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] [--numslices <int>] [--solver <name>]
#
# A .pddl problem is translated to a FiFO wff with pddl2fifo (the generated
# (include ...) path to satplan.wff is written relative to the problem directory);
# a .wff problem is used directly.  Generates the FiFO wff for the problem, instantiates it in
# WCNF format, solves it with the given solver (default tt-open-wbo-inc-Glucose4_1),
# and interprets the result into an answer file.  All intermediate files
# (.wff .scnf .wcnf .map .satout) and the .answer file are written next to the
# problem file and are left in place.  Prints whether the problem was solved or
# proven unsatisfiable; on success it prints the answer file to stdout.

set -euo pipefail

usage() {
  echo "usage: planner.sh <problem.pddl|problem.wff> [--domain <domain.pddl>] [--numslices <int>] [--solver <name>]" >&2
  echo "  A .pddl problem is translated with pddl2fifo; a .wff is used as-is." >&2
  exit 2
}

PROBLEM=""
DOMAIN=""
NUMSLICES=""
SOLVER="tt-open-wbo-inc-Glucose4_1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    [[ $# -ge 2 ]] || usage; DOMAIN="$2";    shift 2 ;;
    --numslices) [[ $# -ge 2 ]] || usage; NUMSLICES="$2"; shift 2 ;;
    --solver)    [[ $# -ge 2 ]] || usage; SOLVER="$2";    shift 2 ;;
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)           if [[ -z "$PROBLEM" ]]; then PROBLEM="$1"; shift; else echo "unexpected argument: $1" >&2; usage; fi ;;
  esac
done

[[ -n "$PROBLEM" ]] || usage
[[ -f "$PROBLEM" ]] || { echo "problem file not found: $PROBLEM" >&2; exit 2; }
if [[ -n "$NUMSLICES" && ! "$NUMSLICES" =~ ^[0-9]+$ ]]; then
  echo "--numslices must be a non-negative integer, got: $NUMSLICES" >&2
  exit 2
fi

# Resolve paths to absolutes so the run is independent of the current directory.
PROBLEM="$(cd "$(dirname "$PROBLEM")" && pwd)/$(basename "$PROBLEM")"
DIR="$(dirname "$PROBLEM")"
STEM_NAME="$(basename "$PROBLEM")"; STEM_NAME="${STEM_NAME%.*}"
STEM="$DIR/$STEM_NAME"
WFF="$STEM.wff"; SCNF="$STEM.scnf"; WCNF="$STEM.wcnf"; MAP="$STEM.map"
SATOUT="$STEM.satout"; ANSWER="$STEM.answer"

if [[ -n "$DOMAIN" ]]; then
  [[ -f "$DOMAIN" ]] || { echo "domain file not found: $DOMAIN" >&2; exit 2; }
  DOMAIN="$(cd "$(dirname "$DOMAIN")" && pwd)/$(basename "$DOMAIN")"
fi

# Locate FiFO, pddl2fifo, and the SatPlan axioms relative to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO="$SCRIPT_DIR/../FiFO.lisp"
PDDL2FIFO="$SCRIPT_DIR/pddl2fifo.lisp"
SATPLAN="$SCRIPT_DIR/satplan.wff"

# Optional Lisp forms.
DOMAIN_FORM=""
[[ -n "$DOMAIN" ]] && DOMAIN_FORM=":domain-file \"$DOMAIN\""
NUMSLICES_FORM="nil"
[[ -n "$NUMSLICES" ]] && NUMSLICES_FORM="(setq *satplan-numslices* $NUMSLICES)"

# Build the wff: translate a PDDL problem with pddl2fifo, or use a .wff directly.
# The include path written into a generated wff is computed relative to the
# problem directory so it is portable (e.g. ../satplan.wff) rather than absolute.
EXT="$(printf '%s' "${PROBLEM##*.}" | tr '[:upper:]' '[:lower:]')"
if [[ "$EXT" == "wff" ]]; then
  GENERATE_FORM="nil"
else
  SATPLAN_REL="$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$SATPLAN" "$DIR")"
  GENERATE_FORM="(unless (pddl2fifo \"$PROBLEM\" $DOMAIN_FORM :satplan-path \"$SATPLAN_REL\")
                 (error \"wff generation failed\"))"
fi

OUTPUT="$(sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO\")" \
  --eval "(load \"$PDDL2FIFO\")" \
  --eval "(handler-case
             (progn
               (setq *cnf-format* 'wcnf)
               (setq *solver* \"$SOLVER\")
               $NUMSLICES_FORM
               $GENERATE_FORM
               (unless (instantiate \"$WFF\" :scnfile \"$SCNF\")
                 (error \"instantiation failed\"))
               (unless (propositionalize \"$SCNF\" :cnffile \"$WCNF\" :mapfile \"$MAP\")
                 (error \"propositionalization failed\"))
               (let ((result (satisfy \"$WCNF\" :satoutfile \"$SATOUT\")))
                 (cond ((eql result 'sat)
                         (interpret \"$SATOUT\" :mapfile \"$MAP\" :solnfile \"$ANSWER\")
                         (format t \"PLANNER_STATUS=SAT~%\"))
                       ((eql result 'unsat)
                         (format t \"PLANNER_STATUS=UNSAT~%\"))
                       (t (format t \"PLANNER_STATUS=FAILED~%\")))))
             (error (e)
               (format t \"PLANNER_STATUS=ERROR~%\")
               (format *error-output* \"planner: ~A~%\" e)))" 2>&1)" || true

STATUS="$(printf '%s\n' "$OUTPUT" | sed -n 's/^PLANNER_STATUS=//p' | tail -1)"

case "$STATUS" in
  SAT)
    echo "SOLVED: a plan was found (problem is satisfiable)."
    echo "Answer file: $ANSWER"
    echo "----------------------------------------"
    cat "$ANSWER"
    ;;
  UNSAT)
    echo "UNSATISFIABLE: the solver determined there is no plan at this time horizon."
    ;;
  *)
    echo "FAILED: the problem could not be solved (solver error or translation failure)." >&2
    printf '%s\n' "$OUTPUT" >&2
    exit 1
    ;;
esac
