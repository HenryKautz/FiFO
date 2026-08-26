#!/bin/bash
#
# fifo-solvers.sh -- shared solver classification for the FiFO CLIs.
#
# This file is meant to be *sourced*, not executed.  It provides
#
#     _fifo_solver_kind <name>     -> prints "sat", "maxsat", or "unknown"
#
# which the task-specific drivers (solve.sh, map.sh) use to reject a solver that
# cannot do the job asked of it.
#
# The distinction is not cosmetic: the two families read different files.  A
# plain SAT solver expects a DIMACS "p cnf" header and will choke on -- or
# silently misread -- a weighted CNF, while a MaxSAT solver needs the weighted
# format and has nothing to optimize without it.  Getting this wrong is quiet
# rather than loud (weights written into a plain .cnf become `cw` comment lines,
# which a SAT solver ignores while happily returning a non-optimal model), which
# is exactly why it is worth checking up front.
#
# Names are matched case-insensitively, and FiFO's own abbreviations
# (tt-glucose, tt-intelsat, nuwls) are recognised alongside the full binary
# names.  A name we do not recognise returns "unknown" and is allowed through:
# a locally built or renamed binary is the user's business, and refusing it
# would be worse than letting it fail with the solver's own error message.

# Known-SAT patterns: pure satisfiability solvers, DIMACS "p cnf" input.
_FIFO_SAT_PATTERNS='kissat cadical minisat glucose lingeling cryptominisat picosat mallob painless march plingeling treengeling'

# Known-MaxSAT patterns: weighted CNF input, minimize the total weight.
_FIFO_MAXSAT_PATTERNS='tt-open-wbo open-wbo tt-glucose tt-intelsat nuwls spb-maxsat maxhs uwrmaxsat evalmaxsat wmaxcdcl maxcdcl cashwmaxsat loandra rc2 maxino qmaxsat'

# _fifo_resolve_solver <name> -> the executable NAME actually refers to.
# Mirrors *solver-abbreviations* in lisp/FiFO.lisp, which the Lisp side resolves
# for itself; the shell needs the same mapping to check that the binary exists.
# Keep the two tables in step.
_fifo_resolve_solver() {
  case "${1:-}" in
    tt-glucose)  echo "tt-open-wbo-inc-Glucose4_1" ;;
    tt-intelsat) echo "tt-open-wbo-inc-IntelSATSolver" ;;
    nuwls)       echo "nuwls-c" ;;
    evalmaxsat)  echo "EvalMaxSAT_bin" ;;
    *)           echo "${1:-}" ;;
  esac
}

_fifo_solver_kind() {
  local name lower p
  name="${1:-}"
  # Compare on the basename, so a full path such as /opt/bin/nuwls-c classifies.
  name="${name##*/}"
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  # MaxSAT first: "tt-open-wbo-inc-Glucose4_1" contains "glucose", and it is a
  # MaxSAT solver that happens to be built on the Glucose SAT engine.
  for p in $_FIFO_MAXSAT_PATTERNS; do
    case "$lower" in *"$p"*) echo maxsat; return 0 ;; esac
  done
  for p in $_FIFO_SAT_PATTERNS; do
    case "$lower" in *"$p"*) echo sat; return 0 ;; esac
  done
  echo unknown
}

# _fifo_require_solver_kind <name> <wanted-kind> <this-script> <other-script>
# Prints an explanation and returns 1 when NAME is known to be the wrong kind.
_fifo_require_solver_kind() {
  local name="$1" want="$2" self="$3" other="$4" kind
  kind="$(_fifo_solver_kind "$name")"
  [[ "$kind" == "unknown" || "$kind" == "$want" ]] && return 0

  if [[ "$want" == "sat" ]]; then
    cat >&2 <<EOF
$self: '$name' is a MaxSAT solver, but $self solves for satisfiability.

  $self writes a plain DIMACS "p cnf" file, which has no weights to minimize --
  a MaxSAT solver has nothing to optimize there, and may not accept the file at
  all.

  To minimize the total weight of the true weighted literals (MAP inference),
  use $other, which writes the weighted format:

      $other <problem.wff> --solver $name
EOF
  else
    cat >&2 <<EOF
$self: '$name' is a plain SAT solver, but $self solves for minimum cost.

  $self writes a weighted CNF (hard clauses prefixed 'h', soft clauses prefixed
  by their weight).  A SAT solver cannot read that format, and even where it
  can it has no notion of an objective to minimize.

  For a satisfiability-only run, which writes a plain "p cnf" file, use:

      $other <problem.wff> --solver $name
EOF
  fi
  return 1
}
