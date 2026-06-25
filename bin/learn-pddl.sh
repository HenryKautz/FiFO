#!/bin/bash
#
# learn-pddl.sh -- end-to-end PDDL weight learning.
#
# Translates a PDDL problem + domain to a FiFO wff, instantiates it at a small
# learning horizon, learns weights for the (:probability ...) action specs, and
# writes a copy of the domain with each :probability replaced by the learned
# :cost.  Costs already in the domain are left untouched.
#
# The lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).

set -euo pipefail

FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: learn-pddl.sh <problem.pddl> [--domain <domain.pddl>] [options]

Translate a PDDL problem + domain, learn weights for its (:probability ...)
action specs, and write a copy of the domain with :probability replaced by the
learned :cost.

Options:
  --domain <file>       domain file (default: <name>.pddl from the problem's
                        (:domain <name>) form, next to the problem)
  --method <log-odds|maxent>  estimator (default: log-odds)
  --maxent              shorthand for --method maxent
  --scale <int>         integer weight resolution; real weight = w/scale (default: 100)
  --numslices <int>     instantiation horizon used for learning (default: 3).
                        For --maxent the problem must be feasible at this horizon;
                        log-odds is horizon-independent.
  --domain-out <file>   learned domain path (default: <domain-root>_learned.pddl)
  -h, --help            show this help

An action specifies a probability with a :probability <p> slot (0<p<1), the
learnable alternative to :cost.  All ground instances of one action schema share
one learned weight; the result is written as :cost <w> (which may be negative when
the action is favored, p>0.5).

The lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.
EOF
}

die() { echo "learn-pddl.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

PROBLEM=""; DOMAIN=""; METHOD="log-odds"; SCALE="100"; NUMSLICES="3"; DOMAIN_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     print_usage; exit 0 ;;
    --domain)      [[ $# -ge 2 ]] || die "--domain needs an argument"; DOMAIN="$2"; shift 2 ;;
    --method)      [[ $# -ge 2 ]] || die "--method needs an argument"; METHOD="$2"; shift 2 ;;
    --maxent)      METHOD="maxent"; shift ;;
    --scale)       [[ $# -ge 2 ]] || die "--scale needs an argument"; SCALE="$2"; shift 2 ;;
    --numslices)   [[ $# -ge 2 ]] || die "--numslices needs an argument"; NUMSLICES="$2"; shift 2 ;;
    --domain-out)  [[ $# -ge 2 ]] || die "--domain-out needs an argument"; DOMAIN_OUT="$2"; shift 2 ;;
    --)            shift; break ;;
    -*)            die "unknown option: $1" ;;
    *)             if [[ -z "$PROBLEM" ]]; then PROBLEM="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$PROBLEM" ]] || die "no problem.pddl given"
[[ -f "$PROBLEM" ]] || die "problem file not found: $PROBLEM"
[[ -n "$DOMAIN" && ! -f "$DOMAIN" ]] && die "domain file not found: $DOMAIN"
case "$METHOD" in log-odds) M=":log-odds" ;; maxent) M=":maxent" ;; *) die "--method must be log-odds or maxent, got: $METHOD" ;; esac
[[ "$SCALE" =~ ^[0-9]+$ && "$SCALE" -gt 0 ]] || die "--scale must be a positive integer, got: $SCALE"
[[ "$NUMSLICES" =~ ^[0-9]+$ && "$NUMSLICES" -ge 2 ]] || die "--numslices must be an integer >= 2, got: $NUMSLICES"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

# Absolute paths so the run is independent of the working directory.
PROBLEM="$(cd "$(dirname "$PROBLEM")" && pwd)/$(basename "$PROBLEM")"
[[ -n "$DOMAIN" ]] && DOMAIN="$(cd "$(dirname "$DOMAIN")" && pwd)/$(basename "$DOMAIN")"

DOMAIN_KW="";    [[ -n "$DOMAIN" ]]     && DOMAIN_KW=":domain-file \"$DOMAIN\""
DOMAIN_OUT_KW=""; [[ -n "$DOMAIN_OUT" ]] && DOMAIN_OUT_KW=":domain-out \"$DOMAIN_OUT\""

# maxent.lisp loads reweight.lisp, so loading it provides both estimators.
exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(load \"$FIFO_LISP/pddl2fifo.lisp\")" \
  --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
  --eval "(load \"$FIFO_LISP/plearn.lisp\")" \
  --eval "(handler-case
            (progn
              (learn-pddl \"$PROBLEM\" $DOMAIN_KW :method $M :scale $SCALE
                          :numslices $NUMSLICES :satplan-path \"$FIFO_LISP/satplan.wff\"
                          $DOMAIN_OUT_KW)
              (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"learn-pddl.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
