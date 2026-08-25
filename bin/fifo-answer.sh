#!/bin/bash
#
# fifo-answer.sh -- shared rendering of a FiFO .answer file for the CLIs.
#
# This file is meant to be *sourced*, not executed.  It provides
#
#     _fifo_print_answer <answer-file>
#
# which writes the answer to stdout in a form that is readable both ways.
#
# The machine-readable part is the .answer file itself, verbatim and unchanged:
# a verdict on the first line, then zero or more s-expressions, one per line.
# That is the format `interpret` writes and the one the README documents, so
# anything already parsing .answer files keeps working on this stdout.
#
# The human-readable part is a leading ';' comment line saying what the verdict
# means and what the lines beneath it are -- because the payload is ambiguous
# without it.  After PROVEN, "(X ALICE)" is a variable binding; after SAT or
# COUNTEREXAMPLE, an identically shaped line is a true atom of a model.  ';' is
# the comment character in both Lisp and DIMACS, and is what the rest of FiFO
# already uses for commentary (marginals.sh, the MC-SAT diagnostics), so a
# reader can drop those lines without a special case.
#
# The five verdicts come from solve-schemas:
#
#   no prove form   SAT | UNSAT
#   prove form      PROVEN | NOANSWER | COUNTEREXAMPLE

_fifo_print_answer() {   # _fifo_print_answer <answer-file>
  local f="${1:-}" verdict n obj
  if [[ ! -f "$f" ]]; then
    echo "; no answer file was written -- the run did not get far enough to produce one" >&2
    return 1
  fi
  verdict="$(head -1 "$f" | tr -d '\r')"
  # Payload lines are the s-expressions after the verdict.  (*OBJECTIVE* N) is
  # metadata rather than part of the model, so it is counted separately.
  n=$(grep -c '^(' "$f" 2>/dev/null)
  obj=$(grep -c '^(\*OBJECTIVE\*' "$f" 2>/dev/null)
  n=$(( n - obj ))

  case "$verdict" in
    SAT)
      echo "; SAT -- the theory is satisfiable; the $n atom(s) below are true in a model" ;;
    UNSAT)
      echo "; UNSAT -- the theory has no model" ;;
    PROVEN)
      if [[ "$n" -gt 0 ]]; then
        echo "; PROVEN -- the theory entails the goal; the $n line(s) below are variable"
        echo ";           bindings, each (<variable> <value>), witnessing it"
      else
        echo "; PROVEN -- the theory entails the goal; the goal has no free variables,"
        echo ";           so there are no bindings to report"
      fi ;;
    NOANSWER)
      echo "; NOANSWER -- the theory entails the goal, but no variable binding could be"
      echo ";              extracted, so there is no witness to report" ;;
    COUNTEREXAMPLE)
      echo "; COUNTEREXAMPLE -- the goal does NOT follow from the theory; the $n atom(s)"
      echo ";                   below are true in a model that violates it" ;;
    "")
      echo "; the answer file is empty" >&2; return 1 ;;
    *)
      echo "; $verdict -- unrecognised verdict; the raw answer follows" ;;
  esac
  cat "$f"
}
