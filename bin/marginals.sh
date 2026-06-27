#!/bin/bash
#
# marginals.sh -- compute the exact marginal probability of every atom in a
# weighted .scnf file.
#
# Reads an instantiated .scnf (hard (OR ...) clauses plus (WEIGHT literal w)
# costs) and prints, for EVERY atom -- weighted or not -- the marginal P(atom =
# true) under the Gibbs distribution P(x) proportional to exp(-(sum of the weights
# of the true literals)) over the feasible set.  Exact enumeration, so this is for
# small instances.
#
# The lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).

set -euo pipefail

FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: marginals.sh <file.scnf> [options]

Compute the exact marginal probability P(atom = true) of every atom in a weighted
.scnf, under the Gibbs distribution defined by its (WEIGHT ...) costs over the
feasible set (the assignments satisfying its hard (OR ...) clauses).  All atoms
are reported, weighted or not (e.g. SatPlan Holds state atoms, not just Occurs
action atoms).  Exact enumeration -- intended for small instances.

  --solver <name>     marginal-inference back end (default: maxent):
                        maxent  exact Lisp enumeration of the feasible set --
                                simple but exponential; for small instances
                        addmc   the ADDMC weighted model counter (algebraic
                                decision diagrams) -- exact and scales far past
                                enumeration (one ADDMC run for Z plus one per atom)
  --weighted-only     report (and enumerate) only the weighted atoms, not every
                      atom -- much cheaper on instances with many state atoms
  --out <file>        also write the (MARGINAL ...) lines to <file>
  --node-limit <int>  (maxent only) cap on enumeration nodes (default: 5000000)
  --addmc-bin <path>  path to the ADDMC binary (else $ADDMC, else 'addmc' on PATH);
                      implies --solver addmc
  --scale <n>         (addmc only) divide integer weights by n before
                      exponentiating; default reads the 'scale: N' the weight-
                      learning pipeline records in the header (1 if absent).  The
                      pipeline scales costs by an integer factor (100 by default)
                      for MaxSAT, which would otherwise distort the marginals;
                      --scale 1 uses raw weights.
  --epsilon <e>       (addmc only) ADDMC's CUDD terminal-merging tolerance (--ep);
                      default 0 = exact (full double precision).  A positive value
                      trades exactness for speed/memory.
  --evidence <form>   (addmc only) condition on a GROUND FiFO formula: it is
                      clausified and conjoined with the theory as a hard
                      constraint, so the reported marginals become P(atom | form).
                      Repeatable; multiple --evidence are conjoined.  E.g.
                      --evidence '(not (occurs (turn-on s1) 1))'
                      --evidence '(implies (holds (on s1) 1) (p a))'
  --evidence-file <f> (addmc only) a file of ground FiFO formulas to condition on,
                      conjoined with any --evidence forms.  Evidence must be ground
                      (over atoms already in the scnf); quantified evidence needs
                      the .wff (re-instantiate with the assertion added).
  -h, --help          show this help

Each line of output is  (MARGINAL <atom> <probability>).

The lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.

ADDMC is a separate executable (https://github.com/HenryKautz/ADDMC, a macOS
fork of vardigroup/ADDMC); build it and put 'addmc' on PATH, set ADDMC, or pass
--addmc-bin.
EOF
}

die() { echo "marginals.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

SCNF=""
OUT=""
NODE_LIMIT=""
WEIGHTED_ONLY=0
SOLVER="maxent"
SCALE=""
EPSILON=""
EVFILE=""
EVIDENCE_FORMS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        print_usage; exit 0 ;;
    --solver)         [[ $# -ge 2 ]] || die "--solver needs an argument (maxent or addmc)"; SOLVER="$2"; shift 2 ;;
    --weighted-only)  WEIGHTED_ONLY=1; shift ;;
    --out)            [[ $# -ge 2 ]] || die "--out needs an argument"; OUT="$2"; shift 2 ;;
    --node-limit)     [[ $# -ge 2 ]] || die "--node-limit needs an argument"; NODE_LIMIT="$2"; shift 2 ;;
    --addmc-bin)      [[ $# -ge 2 ]] || die "--addmc-bin needs an argument"; export ADDMC="$2"; SOLVER="addmc"; shift 2 ;;
    --scale)          [[ $# -ge 2 ]] || die "--scale needs an argument"; SCALE="$2"; shift 2 ;;
    --epsilon)        [[ $# -ge 2 ]] || die "--epsilon needs an argument"; EPSILON="$2"; shift 2 ;;
    --evidence)       [[ $# -ge 2 ]] || die "--evidence needs an argument"; EVIDENCE_FORMS+=("$2"); shift 2 ;;
    --evidence-file)  [[ $# -ge 2 ]] || die "--evidence-file needs an argument"; EVFILE="$2"; shift 2 ;;
    -*)               die "unknown option: $1" ;;
    *)                if [[ -z "$SCNF" ]]; then SCNF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$SCNF" ]] || die "no .scnf file given"
[[ -f "$SCNF" ]] || die "input file not found: $SCNF"
[[ "$SOLVER" == "maxent" || "$SOLVER" == "addmc" ]] || die "--solver must be maxent or addmc, got: $SOLVER"
if [[ -n "$NODE_LIMIT" && ! "$NODE_LIMIT" =~ ^[0-9]+$ ]]; then die "--node-limit must be a non-negative integer, got: $NODE_LIMIT"; fi
if [[ -n "$SCALE" && ! "$SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--scale must be a positive number, got: $SCALE"; fi
if [[ -n "$EPSILON" && ! "$EPSILON" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then die "--epsilon must be a non-negative number, got: $EPSILON"; fi
[[ -z "$SCALE" || "$SOLVER" == "addmc" ]] || die "--scale applies to the addmc solver only"
[[ -z "$EPSILON" || "$SOLVER" == "addmc" ]] || die "--epsilon applies to the addmc solver only"
if [[ ${#EVIDENCE_FORMS[@]} -gt 0 || -n "$EVFILE" ]]; then
  [[ "$SOLVER" == "addmc" ]] || die "--evidence/--evidence-file apply to the addmc solver only"
fi
[[ -z "$EVFILE" || -f "$EVFILE" ]] || die "evidence file not found: $EVFILE"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

if [[ "$SOLVER" == "addmc" ]]; then
  [[ -z "$NODE_LIMIT" ]] || die "--node-limit applies to the maxent solver, not addmc"
  ADDMC_BIN="${ADDMC:-addmc}"
  if ! command -v "$ADDMC_BIN" >/dev/null 2>&1 && [[ ! -x "$ADDMC_BIN" ]]; then
    die "ADDMC binary not found: '$ADDMC_BIN' (set --addmc-bin, the ADDMC env var, or put 'addmc' on PATH)"
  fi
  KW=""
  [[ -n "$OUT" ]] && KW="$KW :out-file \"$OUT\""
  [[ "$WEIGHTED_ONLY" -eq 1 ]] && KW="$KW :weighted-only t"
  [[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"
  [[ -n "$EPSILON" ]] && KW="$KW :epsilon $EPSILON"
  [[ ${#EVIDENCE_FORMS[@]} -gt 0 ]] && KW="$KW :evidence (quote ( ${EVIDENCE_FORMS[*]} ))"
  [[ -n "$EVFILE" ]] && KW="$KW :evidence-file \"$EVFILE\""
  exec sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
    --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
    --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
    --eval "(handler-case (progn (marginals-addmc \"$SCNF\" $KW) (sb-ext:exit :code 0))
              (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
fi

KW=""
[[ -n "$OUT" ]] && KW="$KW :out-file \"$OUT\""
[[ -n "$NODE_LIMIT" ]] && KW="$KW :node-limit $NODE_LIMIT"
[[ "$WEIGHTED_ONLY" -eq 1 ]] && KW="$KW :weighted-only t"

# Load in separate --evals so the call is compiled after marginals is defined.
exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
  --eval "(handler-case (progn (marginals \"$SCNF\" $KW) (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
