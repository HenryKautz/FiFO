#!/bin/bash
#
# marginals.sh -- compute the marginal probability of every atom in a weighted
# .scnf file.
#
# Reads an instantiated .scnf (hard (OR ...) clauses plus (WEIGHT literal w)
# costs) and prints, for EVERY atom -- weighted or not -- the marginal P(atom =
# true) under the Gibbs distribution P(x) proportional to exp(-(sum of the weights
# of the true literals)) over the feasible set.  The default back end is exact
# enumeration, so it is for small instances; see --solver for the counters that
# scale further and for mc-sat, which samples rather than counts.
#
# The lisp is found via FIFO_LISP ($HOME/lib/fifo/lisp by default).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO_LISP="${FIFO_LISP:-$HOME/lib/fifo/lisp}"

print_usage() {
  cat <<'EOF'
usage: marginals.sh <file.scnf> [options]

Compute the marginal probability P(atom = true) of every atom in a weighted .scnf,
under the Gibbs distribution defined by its (WEIGHT ...) costs over the feasible
set (the assignments satisfying its hard (OR ...) clauses).  All atoms are
reported, weighted or not (e.g. SatPlan Holds state atoms, not just Occurs action
atoms).  Four of the back ends are exact (the default, maxent, is enumeration --
intended for small instances); mc-sat samples instead, for instances past the
reach of exact counting.

  --solver <name>     marginal-inference back end (default: maxent):
                        maxent  exact Lisp enumeration of the feasible set --
                                simple but exponential; for small instances
                        addmc   the ADDMC weighted model counter (algebraic
                                decision diagrams) -- exact and scales far past
                                enumeration (one ADDMC run for Z plus one per atom)
                        ddnnf   FiFO's own d-DNNF compiler -- compiles the theory
                                once, then gets ALL marginals from two circuit
                                passes; conditioning on literal evidence reuses the
                                compiled circuit (cheap for many evidence sets).
                                Pure Lisp, no external binary
                        d4      same circuit machinery as ddnnf (all marginals in
                                two passes, evidence reuse, --save-circuit/--circuit)
                                but the Boolean structure is compiled by the external
                                state-of-the-art d4 (d4v2) compiler -- for instances
                                too structured for the home-grown compiler
                        max-term  APPROXIMATE and NOT a Gibbs marginal: the
                                maximum-term approximation, sigma(beta*(cost with
                                the atom false - cost with it true)), from 1+n
                                MaxSAT solves.  Scales where counting cannot, but
                                it approximates what the WEIGHTS contribute and
                                discards what the COUNTING contributes -- on an
                                unweighted theory it returns 0.5 for everything.
                                Reported as (MAXTERM-MARGINAL ...), deliberately
                                not (MARGINAL ...).  Requires --query
                        mc-sat  APPROXIMATE: MC-SAT sampling (WalkSAT v58's -mcsat
                                mode) -- one run gives every marginal, so it scales
                                to instances the exact back ends cannot count, at
                                the price of Monte-Carlo error.  Use --seed for
                                reproducibility and --samples for accuracy, and
                                watch the reported sampling efficiency (see below)
  --weighted-only     report (and enumerate) only the weighted atoms, not every
                      atom -- much cheaper on instances with many state atoms
  --out <file>        also write the (MARGINAL ...) lines to <file>
  --node-limit <int>  cap on search effort before giving up: for maxent, the number
                      of enumeration nodes (default 5000000); for ddnnf, the number
                      of circuit nodes (default 2000000).  A blowup means the
                      instance is too structured for that back end -- try addmc
  --addmc-bin <path>  path to the ADDMC binary (else $ADDMC, else 'addmc' on PATH);
                      implies --solver addmc
  --d4-bin <path>     path to the d4 (d4v2) compiler binary (else $D4, else a sibling
                      d4v2 checkout); implies --solver d4
  --walksat-bin <p>   path to the WalkSAT v58 (MC-SAT) binary (else $WALKSAT, else a
                      sibling Walksat_v58_MC-SAT checkout, else 'walksat' on PATH);
                      implies --solver mc-sat
  --scale <n>         divide integer weights by n before exponentiating; default
                      reads the 'scale: N' the weight-learning pipeline records in
                      the header (1 if absent).  The pipeline scales costs by an
                      integer factor (100 by default) for MaxSAT, which would
                      otherwise distort the marginals; --scale 1 uses raw weights.
                      Applies to every solver.
  --epsilon <e>       (addmc only) ADDMC's CUDD terminal-merging tolerance (--ep);
                      default 0 = exact (full double precision).  A positive value
                      trades exactness for speed/memory.
  --samples <n>       (mc-sat only) number of retained samples (default 10000).
                      Monte-Carlo error falls as 1/sqrt(n)
  --burnin <n>        (mc-sat only) discarded warm-up samples (default 100)
  --seed <n>          (mc-sat only) seed the sampler; the same seed reproduces the
                      same marginals exactly.  Default: time-based (so runs differ)
  --unitprop          (mc-sat only) unit-propagate before each sample, fixing forced
                      variables and shrinking the search -- a large speedup on
                      instances with many unit clauses (SatPlan initial states)
  --walk-prob <r>     (mc-sat only) SampleSAT's probability of a WalkSAT (rather
                      than simulated-annealing) move, default 0.5
  --temp <r>          (mc-sat only) SampleSAT's annealing temperature, default 0.25
  --samplesat-cutoff <n>
                      (mc-sat only) flips of the SampleSAT walk per sample; default
                      100 + 10 * #atoms.  Raise it if the chain mixes poorly
  --init-cutoff <n>   (mc-sat only) flips per try for the INITIAL solve of the hard
                      clauses (default 100 * #atoms), and the budget to repair a
                      SampleSAT endpoint back onto a solution
  --init-tries <n>    (mc-sat only) random restarts allowed for that initial solve
                      (default 100)
  --no-sat-seed       (mc-sat only) do NOT seed the initial assignment from the CDCL
                      SAT solver.  By default the hard clauses are solved once with
                      kissat and its model starts the sampler, because local search
                      alone cannot reach a model of a structured (SatPlan) encoding
                      -- and a CDCL UNSAT verdict is then a proof, reported at once
  --query <atom>      (max-term only) atom to report; repeatable, or 'all' for
                      every atom.  Required, since the cost is one MaxSAT solve
                      per atom
  --query-file <f>    (max-term only) a file of atoms, one per line
  --beta <r>          (max-term only) inverse temperature; default 1/scale
  --prior <atom=p>    (max-term only) log-odds prior on an atom.  REPLACES that
                      atom's own weight rather than stacking on it, and needs no
                      re-solving, since a unit cost factors out of the
                      minimisation.  Repeatable
  --priors <file>     (max-term only) a file of 'atom = p' lines
  --groups auto|none  (max-term only) detect groups of queried atoms that the
                      THEORY makes mutually exclusive -- an at-least-one clause
                      plus the pairwise at-most-one clauses -- and renormalise
                      over each.  Exclusivity is a property of the theory, so it
                      is detected, not declared.  Default: auto
  --maxsat-bin <p>    (max-term only) the MaxSAT solver.  Default: bin/rc2-maxsat.py,
                      which is EXACT (core-guided RC2) and terminates with a proof
                      of optimality.  An anytime solver such as
                      tt-open-wbo-inc-Glucose4_1 may be given instead, but it
                      offers NO optimality guarantee -- and because max-term is a
                      DIFFERENCE of two minimum costs, two unproven upper bounds
                      do not cancel.  Unproven solves are counted and warned about
  --verify-groups     (max-term only) additionally PROVE each group's exclusivity
                      by SAT entailment, catching encodings the syntactic scan
                      misses (auxiliary-variable at-most-one, or exclusivity that
                      is entailed rather than stated)
  --evidence <form>   (addmc/ddnnf/d4/mc-sat/max-term) condition on a GROUND FiFO formula: it is
                      clausified and conjoined with the theory as a hard
                      constraint, so the reported marginals become P(atom | form).
                      Repeatable; multiple --evidence are conjoined.  E.g.
                      --evidence '(not (occurs (turn-on s1) 1))'
                      --evidence '(implies (holds (on s1) 1) (p a))'
                      With ddnnf, unit-literal evidence reuses the compiled circuit;
                      a non-unit form triggers a recompile.
  --evidence-file <f> (addmc/ddnnf/d4/mc-sat) a file of ground FiFO formulas to condition on,
                      conjoined with any --evidence forms.  Evidence must be ground
                      (over atoms already in the scnf); quantified evidence needs
                      the .wff (re-instantiate with the assertion added).
  --save-circuit <f>  (ddnnf only) after compiling, write the compiled circuit to
                      <f> for reuse; this run also reports marginals as usual.
  --circuit <f>       (ddnnf only) load a circuit saved by --save-circuit and query
                      it WITHOUT recompiling (give this instead of a .scnf file).
                      Unit-literal --evidence reuses it; non-unit evidence recompiles
                      from the stored clauses.  --scale re-weights it for free.
  --options <file>    splice the options listed in <file> in at this point (one
                      logical line, wrappable with a trailing backslash; if the
                      file has more than one line only the first is used)
  -h, --help          show this help

Each line of output is  (MARGINAL <atom> <probability>).

With --solver mc-sat the results are APPROXIMATE, and the run also prints the
sampler's diagnostics as ';' comment lines -- in particular the effective sample
size and its "efficiency" (mean ESS / samples, 1.0 = independent samples).  MC-SAT
mixes poorly on strongly coupled models (many large weights), where the chain
freezes in one mode; a very low efficiency means the marginals are unreliable
rather than merely noisy, and the run says so explicitly.

The lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.

ADDMC is a separate executable (https://github.com/HenryKautz/ADDMC, a macOS
fork of vardigroup/ADDMC); build it and put 'addmc' on PATH, set ADDMC, or pass
--addmc-bin.

MC-SAT needs WalkSAT version 58 or later (https://gitlab.com/HenryKautz/Walksat,
the Walksat_v58_MC-SAT directory); build it and set WALKSAT or pass --walksat-bin.
Earlier releases have no -mcsat option.
EOF
}

die() { echo "marginals.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

SCNF=""
OUT=""
NODE_LIMIT=""
WEIGHTED_ONLY=0
SOLVER="maxent"
QUERY=()
QUERY_FILE=""
BETA=""
PRIORS=()
PRIORS_FILE=""
# NB: not GROUPS -- bash owns that name (the user's group ids) and silently
# ignores assignments to it, which made every run see "20" here.
GROUP_MODE="auto"
MAXSAT_BIN=""
VERIFY_GROUPS=0
SCALE=""
EPSILON=""
EVFILE=""
EVIDENCE_FORMS=()
SAVE_CIRCUIT=""
CIRCUIT=""
SAMPLES=""
BURNIN=""
SEED=""
UNITPROP=0
WALK_PROB=""
TEMP=""
SS_CUTOFF=""
INIT_CUTOFF=""
INIT_TRIES=""
NO_SAT_SEED=0

# Expand any --options FILE into the options it contains (see fifo-options.sh).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fifo-options.sh"
_fifo_options_die() { die "$1"; }
_fifo_expand_options "$@"
set -- ${FIFO_EXPANDED_ARGS[@]+"${FIFO_EXPANDED_ARGS[@]}"}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        print_usage; exit 0 ;;
    --solver)         [[ $# -ge 2 ]] || die "--solver needs an argument (maxent, addmc, ddnnf, d4, mc-sat or max-term)"; SOLVER="$2"; shift 2 ;;
    --query)          [[ $# -ge 2 ]] || die "--query needs an argument"; QUERY+=("$2"); shift 2 ;;
    --query-file)     [[ $# -ge 2 ]] || die "--query-file needs an argument"; QUERY_FILE="$2"; shift 2 ;;
    --beta)           [[ $# -ge 2 ]] || die "--beta needs an argument"; BETA="$2"; shift 2 ;;
    --prior)          [[ $# -ge 2 ]] || die "--prior needs an argument"; PRIORS+=("$2"); shift 2 ;;
    --priors)         [[ $# -ge 2 ]] || die "--priors needs an argument"; PRIORS_FILE="$2"; shift 2 ;;
    --groups)         [[ $# -ge 2 ]] || die "--groups needs auto or none"; GROUP_MODE="$2"; shift 2 ;;
    --verify-groups)  VERIFY_GROUPS=1; shift ;;
    --maxsat-bin)     [[ $# -ge 2 ]] || die "--maxsat-bin needs an argument"; MAXSAT_BIN="$2"; SOLVER="max-term"; shift 2 ;;
    --weighted-only)  WEIGHTED_ONLY=1; shift ;;
    --out)            [[ $# -ge 2 ]] || die "--out needs an argument"; OUT="$2"; shift 2 ;;
    --node-limit)     [[ $# -ge 2 ]] || die "--node-limit needs an argument"; NODE_LIMIT="$2"; shift 2 ;;
    --addmc-bin)      [[ $# -ge 2 ]] || die "--addmc-bin needs an argument"; export ADDMC="$2"; SOLVER="addmc"; shift 2 ;;
    --d4-bin)         [[ $# -ge 2 ]] || die "--d4-bin needs an argument"; export D4="$2"; SOLVER="d4"; shift 2 ;;
    --walksat-bin)    [[ $# -ge 2 ]] || die "--walksat-bin needs an argument"; export WALKSAT="$2"; SOLVER="mc-sat"; shift 2 ;;
    --samples)        [[ $# -ge 2 ]] || die "--samples needs an argument"; SAMPLES="$2"; shift 2 ;;
    --burnin)         [[ $# -ge 2 ]] || die "--burnin needs an argument"; BURNIN="$2"; shift 2 ;;
    --seed)           [[ $# -ge 2 ]] || die "--seed needs an argument"; SEED="$2"; shift 2 ;;
    --unitprop)       UNITPROP=1; shift ;;
    --walk-prob)      [[ $# -ge 2 ]] || die "--walk-prob needs an argument"; WALK_PROB="$2"; shift 2 ;;
    --temp)           [[ $# -ge 2 ]] || die "--temp needs an argument"; TEMP="$2"; shift 2 ;;
    --samplesat-cutoff) [[ $# -ge 2 ]] || die "--samplesat-cutoff needs an argument"; SS_CUTOFF="$2"; shift 2 ;;
    --init-cutoff)    [[ $# -ge 2 ]] || die "--init-cutoff needs an argument"; INIT_CUTOFF="$2"; shift 2 ;;
    --init-tries)     [[ $# -ge 2 ]] || die "--init-tries needs an argument"; INIT_TRIES="$2"; shift 2 ;;
    --no-sat-seed)    NO_SAT_SEED=1; shift ;;
    --scale)          [[ $# -ge 2 ]] || die "--scale needs an argument"; SCALE="$2"; shift 2 ;;
    --epsilon)        [[ $# -ge 2 ]] || die "--epsilon needs an argument"; EPSILON="$2"; shift 2 ;;
    --evidence)       [[ $# -ge 2 ]] || die "--evidence needs an argument"; EVIDENCE_FORMS+=("$2"); shift 2 ;;
    --evidence-file)  [[ $# -ge 2 ]] || die "--evidence-file needs an argument"; EVFILE="$2"; shift 2 ;;
    --save-circuit)   [[ $# -ge 2 ]] || die "--save-circuit needs an argument"; SAVE_CIRCUIT="$2"; SOLVER="ddnnf"; shift 2 ;;
    --circuit)        [[ $# -ge 2 ]] || die "--circuit needs an argument"; CIRCUIT="$2"; SOLVER="ddnnf"; shift 2 ;;
    -*)               die "unknown option: $1" ;;
    *)                if [[ -z "$SCNF" ]]; then SCNF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ "$SOLVER" == "maxent" || "$SOLVER" == "addmc" || "$SOLVER" == "ddnnf" || "$SOLVER" == "d4" || "$SOLVER" == "mc-sat" || "$SOLVER" == "max-term" ]] || die "--solver must be maxent, addmc, ddnnf, d4, mc-sat or max-term, got: $SOLVER"
if [[ "$SOLVER" != "max-term" ]]; then
  [[ ${#QUERY[@]} -eq 0 ]] || die "--query applies to the max-term solver only"
  [[ -z "$QUERY_FILE" ]]   || die "--query-file applies to the max-term solver only"
  [[ -z "$BETA" ]]         || die "--beta applies to the max-term solver only"
  [[ ${#PRIORS[@]} -eq 0 ]] || die "--prior applies to the max-term solver only"
  [[ -z "$PRIORS_FILE" ]]  || die "--priors applies to the max-term solver only"
  [[ "$VERIFY_GROUPS" -eq 0 ]] || die "--verify-groups applies to the max-term solver only"
fi
if [[ -n "$CIRCUIT" || -n "$SAVE_CIRCUIT" ]]; then
  [[ "$SOLVER" == "ddnnf" || "$SOLVER" == "d4" ]] || die "--circuit/--save-circuit apply to the ddnnf and d4 solvers only"
fi
if [[ -n "$CIRCUIT" ]]; then
  [[ -f "$CIRCUIT" ]] || die "circuit file not found: $CIRCUIT"
  [[ -z "$SCNF" ]] || die "give either a .scnf file or --circuit, not both"
else
  [[ -n "$SCNF" ]] || die "no .scnf file given (or pass a saved circuit with --circuit)"
  [[ -f "$SCNF" ]] || die "input file not found: $SCNF"
fi
if [[ -n "$NODE_LIMIT" && ! "$NODE_LIMIT" =~ ^[0-9]+$ ]]; then die "--node-limit must be a non-negative integer, got: $NODE_LIMIT"; fi
if [[ -n "$SCALE" && ! "$SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--scale must be a positive number, got: $SCALE"; fi
if [[ -n "$EPSILON" && ! "$EPSILON" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then die "--epsilon must be a non-negative number, got: $EPSILON"; fi
[[ -z "$EPSILON" || "$SOLVER" == "addmc" ]] || die "--epsilon applies to the addmc solver only"
if [[ ${#EVIDENCE_FORMS[@]} -gt 0 || -n "$EVFILE" ]]; then
  [[ "$SOLVER" == "addmc" || "$SOLVER" == "ddnnf" || "$SOLVER" == "d4" || "$SOLVER" == "mc-sat" ]] || die "--evidence/--evidence-file apply to the addmc, ddnnf, d4, and mc-sat solvers only"
fi
if [[ "$SOLVER" != "mc-sat" ]]; then
  [[ -z "$SAMPLES"   ]] || die "--samples applies to the mc-sat solver only"
  [[ -z "$BURNIN"    ]] || die "--burnin applies to the mc-sat solver only"
  [[ -z "$SEED"      ]] || die "--seed applies to the mc-sat solver only"
  [[ -z "$WALK_PROB" ]] || die "--walk-prob applies to the mc-sat solver only"
  [[ -z "$TEMP"      ]] || die "--temp applies to the mc-sat solver only"
  [[ -z "$SS_CUTOFF" ]] || die "--samplesat-cutoff applies to the mc-sat solver only"
  [[ -z "$INIT_CUTOFF" ]] || die "--init-cutoff applies to the mc-sat solver only"
  [[ -z "$INIT_TRIES" ]] || die "--init-tries applies to the mc-sat solver only"
  [[ "$NO_SAT_SEED" -eq 0 ]] || die "--no-sat-seed applies to the mc-sat solver only"
  [[ "$UNITPROP" -eq 0 ]] || die "--unitprop applies to the mc-sat solver only"
fi
if [[ -n "$SAMPLES"   && ! "$SAMPLES"   =~ ^[0-9]+$ ]]; then die "--samples must be a non-negative integer, got: $SAMPLES"; fi
if [[ -n "$BURNIN"    && ! "$BURNIN"    =~ ^[0-9]+$ ]]; then die "--burnin must be a non-negative integer, got: $BURNIN"; fi
if [[ -n "$SEED"      && ! "$SEED"      =~ ^[0-9]+$ ]]; then die "--seed must be a non-negative integer, got: $SEED"; fi
if [[ -n "$SS_CUTOFF" && ! "$SS_CUTOFF" =~ ^[0-9]+$ ]]; then die "--samplesat-cutoff must be a non-negative integer, got: $SS_CUTOFF"; fi
if [[ -n "$INIT_CUTOFF" && ! "$INIT_CUTOFF" =~ ^[0-9]+$ ]]; then die "--init-cutoff must be a non-negative integer, got: $INIT_CUTOFF"; fi
if [[ -n "$INIT_TRIES" && ! "$INIT_TRIES" =~ ^[0-9]+$ ]]; then die "--init-tries must be a non-negative integer, got: $INIT_TRIES"; fi
if [[ -n "$WALK_PROB" && ! "$WALK_PROB" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--walk-prob must be a number in [0,1], got: $WALK_PROB"; fi
if [[ -n "$TEMP"      && ! "$TEMP"      =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--temp must be a positive number, got: $TEMP"; fi
[[ -z "$EVFILE" || -f "$EVFILE" ]] || die "evidence file not found: $EVFILE"
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

if [[ "$SOLVER" == "ddnnf" || "$SOLVER" == "d4" ]]; then
  if [[ "$SOLVER" == "d4" ]]; then
    [[ -z "$NODE_LIMIT" ]] || die "--node-limit applies to the ddnnf (home) compiler, not d4"
    D4_BIN="${D4:-}"
    if [[ -n "$D4_BIN" && ! -x "$D4_BIN" ]] && ! command -v "$D4_BIN" >/dev/null 2>&1; then
      die "d4 compiler not found: '$D4_BIN' (set --d4-bin or the D4 env var; build d4v2's demo/compiler)"
    fi
  fi
  KW=""
  [[ "$SOLVER" == "d4" ]] && KW="$KW :compiler :d4"
  [[ -n "$OUT" ]] && KW="$KW :out-file \"$OUT\""
  [[ "$WEIGHTED_ONLY" -eq 1 ]] && KW="$KW :weighted-only t"
  [[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"
  [[ ${#EVIDENCE_FORMS[@]} -gt 0 ]] && KW="$KW :evidence (quote ( ${EVIDENCE_FORMS[*]} ))"
  [[ -n "$EVFILE" ]] && KW="$KW :evidence-file \"$EVFILE\""
  [[ -n "$SAVE_CIRCUIT" ]] && KW="$KW :save-circuit \"$SAVE_CIRCUIT\""
  if [[ -n "$CIRCUIT" ]]; then
    SCNF_ARG="nil"; KW="$KW :circuit \"$CIRCUIT\""
  else
    SCNF_ARG="\"$SCNF\""
  fi
  NODE_EVAL="(progn)"
  [[ -n "$NODE_LIMIT" ]] && NODE_EVAL="(setf *ddnnf-node-limit* $NODE_LIMIT)"
  exec sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
    --eval "(load \"$FIFO_LISP/ddnnf.lisp\")" \
    --eval "$NODE_EVAL" \
    --eval "(handler-case (progn (ddnnf-marginals $SCNF_ARG $KW) (sb-ext:exit :code 0))
              (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
fi

if [[ "$SOLVER" == "max-term" ]]; then
  [[ -z "$NODE_LIMIT" ]] || die "--node-limit applies to the maxent and ddnnf solvers, not max-term"
  [[ ${#QUERY[@]} -gt 0 || -n "$QUERY_FILE" ]] || die "max-term needs --query <atom>... or --query all
  Each atom costs one MaxSAT solve, so the query set is not optional."
  [[ "$GROUP_MODE" == "auto" || "$GROUP_MODE" == "none" ]] || die "--groups must be auto or none, got: $GROUP_MODE"
  # max-term asks for minimum COSTS, so it needs a weighted solver.
  # An EXACT solver is the right default here.  max-term is a difference of two
  # minima, so an anytime solver's upper bounds do not cancel; rc2-maxsat.py
  # proves optimality, tt-open-wbo-inc does not.  Both remain selectable.
  MT_SOLVER="${MAXSAT_BIN:-${MAXTERM_SOLVER:-$SELF_DIR/rc2-maxsat.py}}"
  if ! command -v "$MT_SOLVER" >/dev/null 2>&1 && [[ ! -x "$MT_SOLVER" ]]; then
    die "MaxSAT solver not found: '$MT_SOLVER'
  max-term computes minimum costs, so it needs a weighted solver, not a SAT one,
  and one that PROVES optimality -- a difference of two upper bounds is not an
  upper bound on anything.
  The default, bin/rc2-maxsat.py, needs:  pip install python-sat
  Or pass --maxsat-bin <path> to choose another."
  fi
  KW=":solver \"$MT_SOLVER\""
  ALLQ=0
  for q in ${QUERY[@]+"${QUERY[@]}"}; do [[ "$q" == "all" ]] && ALLQ=1; done
  if [[ "$ALLQ" -eq 1 ]]; then
    KW="$KW :all-atoms t"
  else
    QL=""
    for q in ${QUERY[@]+"${QUERY[@]}"}; do QL="$QL $q"; done
    if [[ -n "$QUERY_FILE" ]]; then
      [[ -f "$QUERY_FILE" ]] || die "query file not found: $QUERY_FILE"
      QL="$QL $(grep -v '^[[:space:]]*;' "$QUERY_FILE" | tr '\n' ' ')"
    fi
    KW="$KW :query (quote ($QL))"
  fi
  [[ "$WEIGHTED_ONLY" -eq 1 ]] && KW="$KW :weighted-only t"
  [[ -n "$OUT" ]] && KW="$KW :out-file \"$OUT\""
  [[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"
  [[ -n "$BETA" ]] && KW="$KW :beta $BETA"
  [[ "$GROUP_MODE" == "none" ]] && KW="$KW :groups :none"
  [[ "$VERIFY_GROUPS" -eq 1 ]] && KW="$KW :verify-groups t"
  [[ ${#EVIDENCE_FORMS[@]} -gt 0 ]] && KW="$KW :evidence (quote ( ${EVIDENCE_FORMS[*]} ))"
  [[ -n "$EVFILE" ]] && KW="$KW :evidence-file \"$EVFILE\""
  # priors: "atom = p" pairs become an alist ((atom . p) ...)
  PL=""
  for pr in ${PRIORS[@]+"${PRIORS[@]}"}; do
    a="${pr%%=*}"; v="${pr##*=}"
    [[ "$a" != "$pr" ]] || die "--prior wants <atom>=<probability>, got: $pr"
    PL="$PL (cons (quote $a) $v)"
  done
  if [[ -n "$PRIORS_FILE" ]]; then
    [[ -f "$PRIORS_FILE" ]] || die "priors file not found: $PRIORS_FILE"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*\; ]] && continue
      a="${line%%=*}"; v="${line##*=}"
      PL="$PL (cons (quote $a) $v)"
    done < "$PRIORS_FILE"
  fi
  [[ -n "$PL" ]] && KW="$KW :priors (list $PL)"
  exec sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
    --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
    --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
    --eval "(load \"$FIFO_LISP/maxterm.lisp\")" \
    --eval "(handler-case (progn (marginals-maxterm \"$SCNF\" $KW) (sb-ext:exit :code 0))
              (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
fi

if [[ "$SOLVER" == "mc-sat" ]]; then
  [[ -z "$NODE_LIMIT" ]] || die "--node-limit applies to the maxent and ddnnf solvers, not mc-sat"
  # Resolve the binary the same way lisp/mcsat.lisp does, so the capability check
  # below tests the binary that will actually run.
  WALKSAT_BIN="${WALKSAT:-}"
  if [[ -z "$WALKSAT_BIN" ]]; then
    SIBLING="$FIFO_LISP/../../Walksat/Walksat_v58_MC-SAT/walksat"
    if [[ -x "$SIBLING" ]]; then WALKSAT_BIN="$SIBLING"; else WALKSAT_BIN="walksat"; fi
  fi
  if ! command -v "$WALKSAT_BIN" >/dev/null 2>&1 && [[ ! -x "$WALKSAT_BIN" ]]; then
    die "WalkSAT binary not found: '$WALKSAT_BIN' (set --walksat-bin, the WALKSAT env var, or put 'walksat' on PATH)"
  fi
  # v57 and earlier print their help and silently ignore -mcsat, so check for it.
  # (Capture first rather than piping: walksat exits non-zero after printing help,
  # and under 'set -o pipefail' that would masquerade as a failed check.)
  WS_HELP="$("$WALKSAT_BIN" -help </dev/null 2>&1 || true)"
  if ! grep -q -- "-mcsat" <<<"$WS_HELP"; then
    die "'$WALKSAT_BIN' has no -mcsat option -- MC-SAT needs WalkSAT version 58 or later (Walksat_v58_MC-SAT); set --walksat-bin or WALKSAT"
  fi
  export WALKSAT="$WALKSAT_BIN"
  KW=""
  [[ -n "$OUT" ]] && KW="$KW :out-file \"$OUT\""
  [[ "$WEIGHTED_ONLY" -eq 1 ]] && KW="$KW :weighted-only t"
  [[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"
  [[ -n "$SAMPLES" ]] && KW="$KW :samples $SAMPLES"
  [[ -n "$BURNIN" ]] && KW="$KW :burnin $BURNIN"
  [[ -n "$SEED" ]] && KW="$KW :seed $SEED"
  [[ -n "$WALK_PROB" ]] && KW="$KW :walk-prob $WALK_PROB"
  [[ -n "$TEMP" ]] && KW="$KW :temp $TEMP"
  [[ -n "$SS_CUTOFF" ]] && KW="$KW :cutoff $SS_CUTOFF"
  [[ -n "$INIT_CUTOFF" ]] && KW="$KW :init-cutoff $INIT_CUTOFF"
  [[ -n "$INIT_TRIES" ]] && KW="$KW :init-tries $INIT_TRIES"
  [[ "$NO_SAT_SEED" -eq 1 ]] && KW="$KW :seed-from-sat nil"
  [[ "$UNITPROP" -eq 1 ]] && KW="$KW :unitprop t"
  [[ ${#EVIDENCE_FORMS[@]} -gt 0 ]] && KW="$KW :evidence (quote ( ${EVIDENCE_FORMS[*]} ))"
  [[ -n "$EVFILE" ]] && KW="$KW :evidence-file \"$EVFILE\""
  exec sbcl --noinform --non-interactive \
    --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
    --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
    --eval "(load \"$FIFO_LISP/wmc.lisp\")" \
    --eval "(load \"$FIFO_LISP/mcsat.lisp\")" \
    --eval "(handler-case (progn (marginals-mcsat \"$SCNF\" $KW) (sb-ext:exit :code 0))
              (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
fi

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
[[ -n "$SCALE" ]] && KW="$KW :scale $SCALE"

# Load in separate --evals so the call is compiled after marginals is defined.
exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
  --eval "(handler-case (progn (marginals \"$SCNF\" $KW) (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
