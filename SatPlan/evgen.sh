#!/bin/bash
#
# evgen.sh -- build a plan-recognition evidence file from a solved problem.
#
# Reads the .answer file planner.sh wrote for a PDDL problem and writes out the
# fluents and actions true at a chosen set of time slices, as FiFO evidence forms
# that planner.sh --evidence-file consumes directly:
#
#   (holds (at pkg1 c1-p2) 3)
#   (occurs (fly plane1 c2-air c1-air) 4)
#   (not (holds (in pkg1 truck2) 3))         # only with --negative-evidence 1
#
# Everything written is checked against the problem's real ground universe.  That
# matters because slice-pinned evidence fails SILENTLY downstream: a slice past
# the horizon or a misspelled predicate becomes a fresh unconstrained atom and
# the planner returns its UNCONDITIONED answer with no error.  So an unknown
# --observe name, an out-of-range slice, and an empty result are errors here.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EVGEN="$SCRIPT_DIR/evgen.lisp"

# The lisp: the installed copy by default, overridden by FIFO_LISP -- the same
# convention planner.sh uses.
FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: evgen.sh --problem <file.pddl> --evidence <file> --slices <spec> [options]

  --problem <file>        the PDDL problem instance (required)
  --evidence <file>       where to write the evidence (required)
  --slices "<spec>"       which slices are observed (required): integers and
                          A-B ranges separated by commas, e.g. "1-3,5".
                          Slices are numbered from 1.  Fluents run 1..N and
                          actions 1..N-1, so the last slice yields fluents only
  --solution <file>       the planner's answer file, default <problem>.answer
  --domain <file>         the PDDL domain, default the (:domain ...) named in
                          the problem, resolved as <name>.pddl beside it
  --observe "<names>"     restrict to these fluent and action names, comma
                          separated, e.g. "fly,in".  Default "" = no
                          restriction.  A name matching nothing is an error
  --negative-evidence <0|1>
                          0 (default) records only what is true.  1 also records
                          (not ...) for everything false at those slices --
                          restricted by --observe, which is usually essential:
                          unrestricted, a toy 3-package problem yields ~1700
                          literals.  Note this asserts COMPLETE observability,
                          a much stronger claim than "more evidence"
  --recognition <0|1>     1 emits ONE (and ...) form instead of a literal per line,
                          which is what recognize.sh needs: it builds the
                          not-comply case by wrapping the whole file in (not ...),
                          and that is only valid for a single form.  Refuses
                          --negative-evidence 1, which would collapse the
                          posterior.  Pair it with --observe over ACTION names:
                          an action at slice s means slice s at any horizon, while
                          a fluent at the FINAL slice means "at the end" only at
                          the horizon it came from
  --help, -h              this message

examples:
  evgen.sh --problem pb.pddl --evidence ev.txt --slices "1-3,5"
  evgen.sh --problem pb.pddl --evidence ev.txt --slices "2" --observe "fly,in"
  evgen.sh --problem pb.pddl --evidence ev.txt --slices "1-2" \
           --observe "fly" --negative-evidence 1
  evgen.sh --problem pb.pddl --evidence ev.txt --slices "1-5" \
           --observe "drive,fly" --recognition 1

  planner.sh pb.pddl --domain d.pddl --numslices <N> --evidence-file ev.txt

The evidence file records every setting used, defaults included, so it can be
regenerated exactly.
EOF
}

PROBLEM="" SOLUTION="" DOMAIN="" EVIDENCE="" SLICES="" OBSERVE="" NEGATIVE="0"
RECOGNITION="0"

die() { echo "evgen.sh: $1" >&2; exit 2; }
need() { [[ $# -ge 2 ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --problem)           need "$@"; PROBLEM="$2";  shift 2 ;;
    --solution)          need "$@"; SOLUTION="$2"; shift 2 ;;
    --domain)            need "$@"; DOMAIN="$2";   shift 2 ;;
    --evidence)          need "$@"; EVIDENCE="$2"; shift 2 ;;
    --slices)            need "$@"; SLICES="$2";   shift 2 ;;
    --observe)           need "$@"; OBSERVE="$2";  shift 2 ;;
    --negative-evidence) need "$@"; NEGATIVE="$2"; shift 2 ;;
    --recognition)       need "$@"; RECOGNITION="$2"; shift 2 ;;
    -h|--help)           print_usage; exit 0 ;;
    *)                   die "unknown option '$1' (try --help)" ;;
  esac
done

[[ -n "$PROBLEM"  ]] || { print_usage >&2; exit 2; }
[[ -n "$EVIDENCE" ]] || die "--evidence is required: the file to write"
[[ -n "$SLICES"   ]] || die "--slices is required, e.g. --slices \"1-3,5\""
if [[ "$NEGATIVE" != "0" && "$NEGATIVE" != "1" ]]; then
  die "--negative-evidence must be 0 or 1, got '$NEGATIVE'"
fi
if [[ "$RECOGNITION" != "0" && "$RECOGNITION" != "1" ]]; then
  die "--recognition must be 0 or 1, got '$RECOGNITION'"
fi
if [[ "$RECOGNITION" == "1" && "$NEGATIVE" == "1" ]]; then
  die "--recognition and --negative-evidence 1 do not go together: negative evidence asserts complete observability, which pins the trajectory, so every hypothesis' cost becomes 0 or infinite and the posterior loses its gradation"
fi
[[ -f "$PROBLEM" ]] || die "problem file not found: $PROBLEM"
if [[ -n "$SOLUTION" && ! -f "$SOLUTION" ]]; then die "solution file not found: $SOLUTION"; fi
if [[ -n "$DOMAIN"   && ! -f "$DOMAIN"   ]]; then die "domain file not found: $DOMAIN"; fi

command -v sbcl >/dev/null 2>&1 || die "sbcl not found on PATH"
[[ -f "$EVGEN" ]] || die "generator not found: $EVGEN"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP
  run 'make install', or set FIFO_LISP to your lisp/ directory."
FIFO="$FIFO_LISP/FiFO.lisp"
PDDL2FIFO="$FIFO_LISP/pddl2fifo.lisp"
SATPLAN="$FIFO_LISP/satplan.wff"
for f in "$FIFO" "$PDDL2FIFO" "$SATPLAN"; do
  [[ -f "$f" ]] || die "not found: $f"
done

# Absolute paths, so the run does not depend on the working directory.  pwd -P,
# not pwd: the satplan path below is written into the generated wff's
# (include ...) and resolved against that file's truename, so a path measured
# through a symlink -- /tmp, which is /private/tmp on macOS -- would not resolve.
abspath() { echo "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"; }
PROBLEM="$(abspath "$PROBLEM")"
[[ -n "$SOLUTION" ]] && SOLUTION="$(abspath "$SOLUTION")"
[[ -n "$DOMAIN"   ]] && DOMAIN="$(abspath "$DOMAIN")"
SATPLAN="$(abspath "$SATPLAN")"
mkdir -p "$(dirname "$EVIDENCE")"
EVIDENCE="$(cd "$(dirname "$EVIDENCE")" && pwd -P)/$(basename "$EVIDENCE")"

# Lisp string literals for the optional arguments; NIL when not given, so the
# generator applies its own default.
lisp_string() { if [[ -n "$1" ]]; then printf '"%s"' "$1"; else printf 'nil'; fi; }

sbcl --noinform --disable-debugger \
     --eval "(load \"$FIFO\")" \
     --eval "(load \"$PDDL2FIFO\")" \
     --eval "(load \"$EVGEN\")" \
     --eval "(handler-case
                 (multiple-value-bind (file n horizon)
                     (evgen :problem \"$PROBLEM\"
                            :solution $(lisp_string "$SOLUTION")
                            :domain $(lisp_string "$DOMAIN")
                            :evidence \"$EVIDENCE\"
                            :slices \"$SLICES\"
                            :observe \"$OBSERVE\"
                            :negative-evidence $NEGATIVE
                            :recognition $([[ "$RECOGNITION" == 1 ]] && echo t || echo nil)
                            :satplan \"$SATPLAN\")
                   (format *error-output* \"Wrote ~a (~d literal~:p, horizon ~d)~%\"
                           file n horizon))
               (error (e) (format *error-output* \"evgen.sh: ~a~%\" e)
                          (sb-ext:exit :code 2)))" \
     --quit >/dev/null
