#!/bin/bash
#
# recognize.sh -- Ramirez & Geffner plan recognition over a FiFO/SatPlan
# recognition instance, using cheapest-plan (MaxSAT) computations only.
#
# For a costed domain, a problem whose goal is a disjunction of hypotheses, and
# an observation sequence O given as an evidence file, this computes, for each
# hypothesis G_i, the two optimal plan costs
#
#     c(G_i, O)   -- cheapest plan achieving G_i that COMPLIES with O
#     c(G_i, ~O)  -- cheapest plan achieving G_i that does NOT comply with O
#
# at a fixed horizon H, and forms the R&G likelihood and posterior:
#
#     d_i     = c(G_i,~O) - c(G_i,O)
#     P(O|G_i) ~ sigmoid(beta * d_i)        (c(G_i,O)=inf -> 0 ; c(G_i,~O)=inf -> 1)
#     P(G_i|O) = pi_i * P(O|G_i) / sum_j pi_j * P(O|G_j)      (hypotheses disjoint)
#
# This is the tractable (optimization) approximation to the Z_G-normalized
# posterior: each partition function is replaced by its cheapest-plan term.
#
# The problem is instantiated ONCE at H and the 2n costs come from clamping each
# hypothesis atom on that single scnf (via marginals.sh --hypotheses).  Clamping
# it in the disjunctive theory selects the same models as rewriting the goal to
# G_i, since the atom implies the disjunction -- the same computation as 2n
# planner.sh runs, which --method plan-runs still offers.
#
# Usage:
#   recognize.sh <costs-domain.pddl> <problem.pddl> <evidence-file> \
#        [--horizon H] [--beta B] [--out DIR] [--solver NAME] [--counter NAME] \
#        [--baseline B] [--maxsat-solver NAME] [--method M] [--timeout SECS] \
#        [--prior H=W ...] [--priors FILE] [--priors-from-preferences] \
#        [--create-hypothesis-atoms] [--stop-after scnf]
#
#   The HYPOTHESES are the disjuncts of ONE (or ...) in the problem's :goal,
#   read by parsing it.  Each is scored as a single atom:
#     (hyp0)             a nullary atom, typically a derived predicate as
#                        make-recognition-instance.lisp writes, used as is;
#     (at truck1 p3-2)   a ground goal literal, used as is;
#     anything else      a closed formula, given a DERIVED nullary atom
#                        (:derived (rechypI) <formula>) -- with a WARNING.
#   Goal order is the reported order.  A hypothesis is named by its atom --
#   hyp0, or at-truck1-p3-2 for a literal -- and --prior uses that name.
#   The goal may be the (or ...) alone, or an (and ...) of it with
#   preferences and exclusivity clauses (or (not hi) (not hj) ...) over the
#   hypotheses.  The exclusivity clauses are IGNORED (dropped from the problem
#   both methods score, so each hypothesis is scored on its own); preferences
#   stay in the costs, on both methods.  Refused, with the reason: a second
#   (or ...) of hypotheses (several sets are not supported yet), a plain
#   conjunction such as (and (hyp0) (hyp1)) -- a goal requiring BOTH, not a
#   choice -- and another hard goal beside the hypotheses.
#
#   --create-hypothesis-atoms
#                 give EVERY hypothesis that is not already nullary a derived
#                 atom, ground literals included.  A derived atom is defined by
#                 a biconditional, so the costs -- and the posterior -- are the
#                 same either way; this is for checking that, or for matching
#                 an instance built the derived way.
#
#   --horizon H   fixed horizon (default: max over hypotheses of the smallest
#                 feasible horizon, and >= observations+1, so no hypothesis is
#                 excluded).
#   --beta B      inverse temperature in the sigmoid (default 1.0); beta = 1/scale
#                 in the Boltzmann model -- larger beta sharpens the likelihood.
#   --prior H=W   prior weight W on hypothesis H, BY NAME; repeatable.  Weights are
#                 relative and renormalized -- 2 and 1 mean 2/3 and 1/3.  A
#                 hypothesis not named keeps weight 1.  A name that is not one of
#                 the goal's hypotheses is an error listing the ones that are.
#   --priors F    the same, one 'H = W' per line; '#' and ';' comment.  (The old
#                 format -- n bare numbers matched BY LINE NUMBER -- is refused:
#                 a misordered or short file silently moved every weight onto the
#                 wrong hypothesis.)  Default: uniform.
#   --priors-from-preferences
#                 take the prior from (preference <name> (hypI) w) forms in the
#                 goal, as  pi_i  proportional to  exp(w_i).  w is a VIOLATION
#                 penalty, so escaping it is worth odds exp(w), and a hypothesis
#                 with no preference is w = 0, hence pi proportional to 1.  The
#                 :odds spelling composes exactly here -- (preference h0 (hyp0)
#                 :odds 2) is w = ln 2, so it IS prior weight 2.  Those
#                 preferences are STRIPPED from the cost model under this flag, so
#                 the weight means exactly one thing -- the prior -- with no
#                 residual cost.  Needs --baseline per-hypothesis, and cannot be
#                 combined with --prior/--priors.  Only an INLINE weight is read.
#   --out DIR     output directory (default: <problem-dir>/runs/recognize).
#   --solver NAME override the SAT feasibility solver passed to planner.sh.
#   --evidence-kind pddl|fifo  which evidence language the file is written in.
#                 'pddl' (default) is the modal language -- (occur-in-order ...)
#                 and friends, horizon-INDEPENDENT, which is what R&G assumes.
#                 'fifo' is slice-pinned FiFO forms as SatPlan/evgen.sh --recognition
#                 writes them; the file must hold a SINGLE form, since the
#                 not-comply case is built by wrapping the whole file in (not ...).
#                 Slice-pinned evidence is horizon-DEPENDENT: the horizon is
#                 forced to at least the largest slice observed, and a fluent
#                 observed at the final slice means "at the end" only at the
#                 horizon it came from -- prefer --observe over action names.
#   --counter NAME  the inference back end (default max-term, R&G's estimator).
#                 The exact counters (maxent, ddnnf, d4, addmc, sharpsat-td) are available but
#                 are small-instance-only: counting does not reach the horizons
#                 planning does.  NOT the same thing as --solver.
#   --baseline B  per-hypothesis (default, = R&G) or best-rival.  per-hypothesis
#                 divides out the theory's own mass on each hypothesis and applies
#                 --priors; best-rival leaves that implicit prior in place, so a
#                 hypothesis that is merely CHEAP TO REACH scores well.
#   --maxsat-solver NAME  the solver that produces the COSTS, on both methods.
#                 Default bin/rc2-maxsat.py, which is EXACT.  Deliberately not an
#                 anytime solver: the score is a DIFFERENCE of two minima, and two
#                 upper bounds do not cancel.
#   --method M    fast (default) or plan-runs.  plan-runs is the older
#                 implementation -- 2n full planner.sh runs -- kept as the
#                 reference the fast path is tested against.  It always computes
#                 R&G's difference, so --counter and --baseline are refused with it.
#   --timeout S   (fast method) limit on EACH solver run inside the inference --
#                 every exact count, every MaxSAT solve, the d4 compilation of
#                 --counter d4 (a stopped one is an error) -- passed to marginals.sh
#                 --timeout; 0, -1 or none for no limit.  Default: FiFO's
#                 *solver-timeout*, 600 s, so one SharpSAT-TD count over 10
#                 minutes fails the run however long the run itself may take.
#   --stop-after scnf  (fast method) stop once the theory is instantiated at the
#                 horizon: DIR/rec-problem.scnf is written and the horizon is
#                 printed, but no hypothesis is scored -- for a caller that wants
#                 the theory itself, e.g. to compile it, without the 2n solves.
#                 The evidence: with --evidence-kind fifo, apart in
#                 DIR/rec-problem-evidence.scnf; with pddl (the default), the
#                 observation monitor's axioms are IN rec-problem.scnf
#                 (count-neutral, so it still conditions on nothing) and the one
#                 literal to condition on is in DIR/rec-problem-assertion.txt.
#                 The MaxSAT solver and counter names are checked, but not that
#                 they are installed (neither runs).
#   --options F   splice the options listed in file F in at this point (one logical
#                 line, wrappable with a trailing backslash; if F has more than one
#                 line only the first is used).

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sets and exports FIFO_LISP, so planner.sh and marginals.sh get the same lisp.
# (This used to default to $SELF/../lisp, which for an installed copy in ~/bin
# is ~/lisp: the installed recognize.sh failed unless FIFO_LISP was set.)
source "$SELF/fifo-lisp.sh"
PLANNER="$SELF/planner.sh"
[[ -x "$PLANNER" || -f "$PLANNER" ]] || { echo "planner.sh not found at $PLANNER" >&2; exit 2; }
command -v sbcl >/dev/null || { echo "sbcl not found on PATH" >&2; exit 2; }

# The header comment, line 2 up to the first blank line.
usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

# Expand any --options FILE into the options it contains (see fifo-options.sh).
source "$SELF/fifo-options.sh"
source "$SELF/fifo-solvers.sh"
_fifo_options_die() { echo "recognize.sh: $1" >&2; usage; }
_fifo_expand_options "$@"
set -- ${FIFO_EXPANDED_ARGS[@]+"${FIFO_EXPANDED_ARGS[@]}"}

[[ $# -ge 3 ]] || usage

DOMAIN="$1"; PROBLEM="$2"; EVIDENCE="$3"; shift 3
HORIZON=""; BETA="1.0"; PRIORS=""; OUT=""; SOLVER=""; EVKIND="pddl"
COUNTER="max-term"; BASELINE="per-hypothesis"; METHOD="fast"; MAXSAT_SOLVER=""
PRIORS_KV=(); PRIORS_FROM_PREFS=0; CREATE_ATOMS=0; SOLVER_TIMEOUT=""; STOP_AFTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --horizon) HORIZON="$2"; shift 2;;
    --beta)    BETA="$2"; shift 2;;
    --priors)  PRIORS="$2"; shift 2;;
    --out)     OUT="$2"; shift 2;;
    --solver)  SOLVER="$2"; shift 2;;
    --evidence-kind) EVKIND="$2"; shift 2;;
    --counter) COUNTER="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --method)  METHOD="$2"; shift 2;;
    --maxsat-solver) MAXSAT_SOLVER="$2"; shift 2;;
    --timeout) SOLVER_TIMEOUT="$2"; shift 2;;
    --prior)  PRIORS_KV+=("$2"); shift 2;;
    --priors-from-preferences) PRIORS_FROM_PREFS=1; shift;;
    --create-hypothesis-atoms) CREATE_ATOMS=1; shift;;
    --stop-after) STOP_AFTER="$2"; shift 2;;
    -h|--help) usage 0;;
    *) echo "unexpected argument: $1" >&2; usage;;
  esac
done
case "$EVKIND" in
  pddl) EV_FLAG="--pddl-evidence-file" ;;
  fifo) EV_FLAG="--evidence-file" ;;
  *) echo "--evidence-kind must be 'pddl' or 'fifo', got: $EVKIND" >&2; exit 2;;
esac
case "$METHOD" in
  fast|plan-runs) ;;
  *) echo "--method must be 'fast' or 'plan-runs', got: $METHOD" >&2; exit 2;;
esac
# plan-runs is the fixed R&G computation -- it has no counter and no choice of
# baseline.  Accepting those flags and then ignoring them would report numbers
# that are not what was asked for, with nothing to say so.
if [[ "$METHOD" == "plan-runs" ]]; then
  [[ "$COUNTER" == "max-term" ]] || { echo "--counter has no meaning with --method plan-runs (it always computes R&G's cheapest-plan difference); drop one of them" >&2; exit 2; }
  [[ "$BASELINE" == "per-hypothesis" ]] || { echo "--baseline has no meaning with --method plan-runs (it is always per-hypothesis); drop one of them" >&2; exit 2; }
  [[ -z "$SOLVER_TIMEOUT" ]] || { echo "--timeout applies to --method fast only (plan-runs bounds each planner.sh run as a whole, and a MaxSAT solve stopped early would put an upper bound into the cost difference); drop one of them" >&2; exit 2; }
  [[ -z "$STOP_AFTER" ]] || { echo "--stop-after applies to --method fast only (plan-runs instantiates no single theory); drop one of them" >&2; exit 2; }
fi
[[ -z "$STOP_AFTER" || "$STOP_AFTER" == "scnf" ]] || { echo "--stop-after must be 'scnf', got: $STOP_AFTER" >&2; exit 2; }
# Checked here, not left to marginals.sh: that runs only after the horizon search
# and the instantiation, which can take minutes.
# the shared rule (fifo-solvers.sh): a positive number, or exactly 0 / -1 / none
if [[ -n "$SOLVER_TIMEOUT" ]]; then
  SOLVER_TIMEOUT="$(_fifo_check_timeout "$SOLVER_TIMEOUT" recognize.sh)" || exit 2
fi
# Forwarded to marginals.sh AND to every planner.sh run of the fast method (the
# horizon search and the instantiation): a SAT solve the default 600 s cap stops
# in the horizon search would read as "unreachable" and leave H too short.
TIMEOUT_MARG=(); [[ -n "$SOLVER_TIMEOUT" ]] && TIMEOUT_MARG=(--timeout "$SOLVER_TIMEOUT")
case "$BASELINE" in
  per-hypothesis|best-rival) ;;
  *) echo "--baseline must be 'per-hypothesis' or 'best-rival', got: $BASELINE" >&2; exit 2;;
esac
# The domain may be a bare name in the domain library ($FIFO_LISP/../pddl).
DOMAIN="$(_fifo_find_domain "$DOMAIN")" || exit 2
for f in "$PROBLEM" "$EVIDENCE"; do
  [[ -f "$f" ]] || { echo "no such file: $f" >&2; exit 2; }
done
DOMAIN="$(cd "$(dirname "$DOMAIN")" && pwd)/$(basename "$DOMAIN")"
PROBLEM="$(cd "$(dirname "$PROBLEM")" && pwd)/$(basename "$PROBLEM")"
EVIDENCE="$(cd "$(dirname "$EVIDENCE")" && pwd)/$(basename "$EVIDENCE")"
[[ -n "$OUT" ]] || OUT="$(dirname "$PROBLEM")/runs/recognize"
mkdir -p "$OUT"

# Validate the solver ONCE, here, rather than letting an unchecked name be
# forwarded into 3n planner.sh runs and fail in each of them.
SOLVER_ARG=()
if [[ -n "$SOLVER" ]]; then
  SOLVER="$(_fifo_require_solver "$SOLVER" sat recognize.sh)" || exit 2
  SOLVER_ARG=(--solver "$SOLVER")
fi
# --stop-after scnf runs neither the counter nor the MaxSAT solver, so it must not
# be refused for a missing one (CLARA's compile-d4.py needs no python-sat) -- but
# their NAMES are still checked: a typo is refused, run or no run.
NAMES_ONLY=""; [[ -n "$STOP_AFTER" ]] && NAMES_ONLY="names-only"
# The counter too, before anything is translated or instantiated.
COUNTER="$(_fifo_require_counter "$COUNTER" marginals recognize.sh $NAMES_ONLY)" || exit 2

# The MaxSAT solver that produces the COSTS.  It must be EXACT by default, and
# the same one on both paths.  R&G's score is c(~O) - c(O), a DIFFERENCE of two
# minima: with an anytime solver those are two upper bounds, which do not cancel
# -- the hazard maxterm.lisp documents, and which the plan-runs path silently had
# because planner.sh's default weighted solver is anytime.  It also made the two
# paths disagree run to run, since an anytime solver need not return the same
# cost twice.
MAXSAT_SOLVER="${MAXSAT_SOLVER:-$SELF/rc2-maxsat.py}"
MAXSAT_SOLVER="$(_fifo_require_solver "$MAXSAT_SOLVER" maxsat recognize.sh $NAMES_ONLY)" || exit 2
# A path is only checked for executability, and bin/rc2-maxsat.py always is --
# so without python-sat every solve fails, every cost comes back NA, and the run
# would report a confident table of zeros.  Check it can actually run.
if [[ -z "$STOP_AFTER" ]]; then
  case "$MAXSAT_SOLVER" in
    *rc2-maxsat.py)
      python3 -c "import pysat" >/dev/null 2>&1 || {
        echo "recognize.sh: $MAXSAT_SOLVER needs python-sat, which is not installed." >&2
        echo "  It is the default because R&G's score is a DIFFERENCE of two minima: an" >&2
        echo "  anytime solver returns upper bounds, and two of those do not cancel." >&2
        echo "  Install it:            bin/install-solvers.sh --only rc2" >&2
        echo "  or name another EXACT solver:  --maxsat-solver wmaxcdcl" >&2
        exit 2; } ;;
  esac
fi

# --- run a planner.sh invocation in its own process group with a timeout ------
TIMEOUT=900
run_planner() {           # run_planner <logfile> <extra planner args...>
  local log="$1"; shift
  local pid rc elapsed=0
  set -m
  bash "$PLANNER" "$@" >"$log" 2>&1 &
  pid=$!
  # A POLLING watchdog, not a background `sleep N; kill` subshell.  That pattern
  # leaks its sleep, and killing the sleep merely lets the subshell fall through
  # to the kill -- firing SIGKILL at a process group whose leader was just
  # reaped, on every call.  Polling means the kill can only happen while the
  # planner is known to be alive, and there is nothing left running afterwards.
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; elapsed=$(( elapsed + 1 ))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      echo "recognize.sh: planner exceeded ${TIMEOUT}s -- killing it" >&2
      kill -9 -"$pid" 2>/dev/null
      break
    fi
  done
  wait "$pid" 2>/dev/null; rc=$?
  set +m
  # Reap any solver the planner left behind -- in ITS OWN process group only (set
  # -m above made the planner a group leader).  This was a global
  # `pkill -f kissat` / `pkill -f open-wbo`, which killed every other run's
  # solvers too: recognize.sh runs in parallel then corrupted each other's costs.
  kill -9 -- -"$pid" 2>/dev/null
  return "$rc"
}
# optimal cost printed by planner.sh ("... time slices: cost C"), else "inf"
cost_of() {               # cost_of <logfile>
  local c
  c=$(sed -n 's/.*time slices: cost \([0-9][0-9.]*\).*/\1/p' "$1" | tail -1)
  if [[ -n "$c" ]]; then echo "$c"
  elif grep -qiE "unsatisfiable|no plan exists|unreachable" "$1"; then echo inf
  else echo NA; fi
}


# --- the hypotheses, from the parsed goal ------------------------------------
# lisp/recognition-goal.lisp reads the goal (its header has the rules): ONE
# (or ...) of hypotheses, each a nullary atom, a ground atom such as
# (at truck1 p3-2), or a closed formula that is given a DERIVED nullary atom --
# with a warning, or for every hypothesis under --create-hypothesis-atoms.
# Exclusivity clauses over the hypotheses are dropped and preferences kept; a
# second hypothesis set, a plain conjunction, or another hard goal is an error
# saying so.  It writes the problem both methods score (plus a domain carrying
# any derived atoms) and prints, tab separated:
#   PROBLEM <file>   DOMAIN <file or ->   HYP <name> <atom> ...   PRIOR <name> <w> ...
# A hypothesis is scored by clamping (holds <atom> H); its NAME labels it in the
# report and is what --prior/--priors refer to.
RG_LISP="$FIFO_LISP/recognition-goal.lisp"
[[ -f "$RG_LISP" ]] || { echo "recognize.sh: not found: $RG_LISP" >&2; exit 2; }
# A Lisp string literal, " and \ escaped, so a path reads as itself.
lisp_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }
rg_call() {   # rg_call <form> : evaluate FORM with recognition-goal.lisp loaded
  sbcl --noinform --non-interactive --eval "(load $(lisp_quote "$RG_LISP"))" --eval "$1"
}
if [[ "$PRIORS_FROM_PREFS" -eq 1 ]]; then
  [[ "$BASELINE" == "per-hypothesis" ]] || {
    echo "recognize.sh: --priors-from-preferences needs --baseline per-hypothesis." >&2
    echo "  Under best-rival the preference weight is not cancelled -- it already moves" >&2
    echo "  the answer through the model -- so reading it back as a prior counts it twice." >&2
    exit 2; }
  [[ ${#PRIORS_KV[@]} -eq 0 && -z "$PRIORS" ]] || {
    echo "recognize.sh: give priors EITHER in the problem's preferences or with --prior/--priors, not both." >&2
    exit 2; }
fi
lisp_bool() { if [[ "$1" -eq 1 ]]; then echo t; else echo nil; fi; }
MANIFEST="$(rg_call "(rg-prepare $(lisp_quote "$PROBLEM") $(lisp_quote "$DOMAIN") $(lisp_quote "$OUT/") :create-atoms $(lisp_bool "$CREATE_ATOMS") :priors-from-preferences $(lisp_bool "$PRIORS_FROM_PREFS"))")" || {
  echo "  ($PROBLEM is not a recognition problem recognize.sh can read.)" >&2
  exit 2; }
# NB: a read loop, not `mapfile` -- mapfile is bash 4.0+ and this script's
# #!/bin/bash is 3.2 on macOS, where it is simply not a builtin.
HYPS=(); HYP_ATOMS=(); PREF_PRIORS=()
while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    PROBLEM) PROBLEM="$a" ;;
    DOMAIN)  [[ "$a" == "-" ]] || DOMAIN="$a" ;;
    HYP)     HYPS+=("$a"); HYP_ATOMS+=("$b") ;;
    PRIOR)   PREF_PRIORS+=("$a $b") ;;
  esac
done <<<"$MANIFEST"
N=${#HYPS[@]}
if [[ "$N" -eq 0 ]]; then
  echo "recognize.sh: $PROBLEM names no hypotheses in its goal." >&2
  exit 2
fi

# --- priors, matched by NAME ---------------------------------------------------
# The old format was n bare weights matched by LINE NUMBER to a list derived from
# the problem TEXT, so anything that perturbed that list silently moved every
# weight onto the wrong hypothesis.
PRIOR_ARR=()
i=0; while [[ "$i" -lt "$N" ]]; do PRIOR_ARR[$i]=1; i=$(( i + 1 )); done
# Whether any prior was actually GIVEN.  It is not enough to compare PRIOR_ARR
# against all-1s: a uniform prior is not the same as no prior downstream, since
# max-term applies one as a per-atom log-odds shift rather than a factor that
# cancels on normalisation.
PRIORS_GIVEN=0

hyp_index() {   # hyp_index <name> -> its position in HYPS, or failure
  local n="$1" i=0
  while [[ "$i" -lt "${#HYPS[@]}" ]]; do
    [[ "${HYPS[$i]}" == "$n" ]] && { echo "$i"; return 0; }
    i=$(( i + 1 ))
  done
  return 1
}
set_prior() {   # set_prior <name> <weight> <source>
  local n="$1" w="$2" src="$3" idx
  if ! idx="$(hyp_index "$n")"; then
    { echo "recognize.sh: $src names '$n', which is not a hypothesis of this problem."
      echo "  The hypotheses, in goal order, are: ${HYPS[*]}"; } >&2
    exit 2
  fi
  case "$w" in
    ""|*[!0-9.eE+-]*) echo "recognize.sh: $src gives '$n' a non-numeric weight '$w'" >&2; exit 2;;
  esac
  PRIOR_ARR[$idx]="$w"
  PRIORS_GIVEN=1
}

if [[ "$PRIORS_FROM_PREFS" -eq 1 ]]; then
  # The weight is a VIOLATION penalty, so escaping it is worth odds exp(w); a
  # hypothesis with no preference is w=0, hence pi proportional to 1.  The
  # preferences were read -- and removed from the problem -- by rg-prepare: left
  # in the theory a weight would also be charged as a cost, which cancels between
  # c(G,O) and c(G,~O) only when the hypotheses are mutually exclusive.
  if [[ ${#PREF_PRIORS[@]} -eq 0 ]]; then
    { echo "recognize.sh: --priors-from-preferences, but the goal has no preference on a hypothesis."
      echo "  Write e.g. (:goal (and (or (hyp0) (hyp1)) (preference h0 (hyp0) 2)))"; } >&2
    exit 2
  fi
  for pp in "${PREF_PRIORS[@]}"; do
    pn="${pp%% *}"; pw="${pp#* }"
    set_prior "$pn" "$(awk -v w="$pw" 'BEGIN{printf "%.10g", exp(w)}')" "a preference in the goal"
    echo "; prior from a preference on $pn ($pw): weight $(awk -v w="$pw" 'BEGIN{printf "%.4g", exp(w)}')" >&2
  done
  echo "; hypothesis preferences removed from the cost model (they are the prior now)" >&2
fi

if [[ -n "$PRIORS" ]]; then
  while IFS= read -r pline; do
    pline="${pline%%#*}"; pline="${pline%%;*}"
    [[ -z "${pline// /}" ]] && continue
    if [[ "$pline" != *=* ]]; then
      { echo "recognize.sh: $PRIORS is not in the expected form."
        echo "  Priors are given BY NAME, one per line:"
        echo "      hyp0 = 2"
        echo "      hyp1 = 1"
        echo "  (a file of bare numbers matched by position is no longer accepted -- a"
        echo "   reordered line silently moved every weight onto the wrong hypothesis)"; } >&2
      exit 2
    fi
    set_prior "$(tr -d '[:space:]' <<<"${pline%%=*}")" "$(tr -d '[:space:]' <<<"${pline##*=}")" "$PRIORS"
  done < "$PRIORS"
fi
for kv in ${PRIORS_KV[@]+"${PRIORS_KV[@]}"}; do
  [[ "$kv" == *=* ]] || { echo "recognize.sh: --prior wants <hypothesis>=<weight>, got: $kv" >&2; exit 2; }
  set_prior "${kv%%=*}" "${kv##*=}" "--prior"
done
[[ $N -ge 1 ]] || { echo "recognize.sh: no hypotheses in the goal of $PROBLEM" >&2; exit 2; }

# --- build the negated evidence file: (not <the one evidence form>) ----------
# Wrapping the file's whole contents only negates what it says if the file holds
# exactly ONE form.  (not A B) is not an error downstream -- it is silently read
# as (not A), so the second observation vanishes from the not-comply case while
# the comply case still uses it, and the two costs stop being comparable.
# Measured: (not A) and (not A B) both UNSAT where (not (A B)) costs 14.
# evgen.sh --recognition 1 conjoins its literals for this reason.
#
# One reader pass gives the form count, the number of observations and (for
# slice-pinned evidence) the largest slice named -- counted from the PARSED forms.
# They were grepped from the raw text, so a comment containing "(...)" -- as an
# evgen header line does -- counted as an observation and raised the horizon.
# Observations are the atoms the evidence names: (holds/occurs X s) literals for
# fifo, and for pddl the action/fluent atoms under the modal operators.
EV_STATS=$(sbcl --noinform --non-interactive --eval "(let ((*read-eval* nil) (forms '()) (nobs 0) (maxs nil))
    (with-open-file (i $(lisp_quote "$EVIDENCE"))
      (loop for f = (read i nil :eof) until (eq f :eof) do (push f forms)))
    (labels ((opp (s) (and (symbolp s)
                           (member (symbol-name s)
                                   '(\"AND\" \"OR\" \"NOT\" \"IMPLY\" \"FORALL\" \"EXISTS\" \"OCCUR-IN-ORDER\"
                                     \"OCCUR-IN-NONSTRICT-ORDER\" \"NEVER\" \"AT\" \"ALWAYS\" \"AT-END\"
                                     \"HOLD-DURING\" \"OCCUR-SOMETIME\" \"SOMETIME\" \"WITHIN\" \"HOLD-AFTER\"
                                     \"AT-MOST-ONCE\" \"SOMETIME-AFTER\" \"SOMETIME-BEFORE\" \"ALWAYS-WITHIN\")
                                   :test (function string=))))
             (walk (f)
               (when (and (consp f) (symbolp (first f)))
                 (let ((h (symbol-name (first f))))
                   (cond ((member h '(\"HOLDS\" \"OCCURS\") :test (function string=))
                          (incf nobs)
                          (when (integerp (third f)) (setf maxs (max (or maxs 0) (third f)))))
                         ((opp (first f)) (mapc (function walk) (rest f)))
                         ((char= (char h 0) #\\?))            ; a quantifier's variable list
                         ((string= \"$EVKIND\" \"pddl\") (incf nobs)))))))
      (mapc (function walk) forms))
    (format t \"~d ~d ~a~%\" (length forms) nobs (or maxs \"-\")))" 2>/dev/null | tail -1)
read -r NFORMS NOBS MAXSLICE <<<"$EV_STATS"
[[ "$MAXSLICE" == "-" ]] && MAXSLICE=""
[[ "$EVKIND" == fifo ]] || MAXSLICE=""
if [[ -z "$NFORMS" ]]; then
  echo "recognize.sh: could not read the evidence file $EVIDENCE" >&2
  exit 2
fi
if [[ "$NFORMS" != "1" ]]; then
  echo "evidence file holds $NFORMS forms; it must hold exactly one." >&2
  echo "  The not-comply case is (not <the evidence>), and (not A B) is not a formula." >&2
  [[ "$EVKIND" == fifo ]] && echo "  Regenerate with: evgen.sh ... --recognition 1" >&2
  exit 2
fi
NEG_EV="$OUT/evidence-negated.txt"
{ echo "(not"; grep -v '^[[:space:]]*;;' "$EVIDENCE"; echo ")"; } > "$NEG_EV"

# --- rewrite the problem goal to a single hypothesis -------------------------
# Only the (or ...) of hypotheses is replaced; the goal's preferences stay, so
# plan-runs scores the same problem the fast method does.  (It used to replace
# the whole goal with (hypI), dropping every preference from the costs.)
# A failure is fatal: planning a missing or stale file would give that
# hypothesis no cost, and so a silent posterior of 0.
single_goal_problem() {   # single_goal_problem <hypothesis index> <out.pddl>
  local err
  rm -f "$2"
  if ! err="$(rg_call "(rg-single-goal $(lisp_quote "$PROBLEM") $(lisp_quote "${HYP_ATOMS[$1]}") $(lisp_quote "$2"))" 2>&1)" \
     || [[ ! -s "$2" ]]; then
    echo "recognize.sh: could not write the single-goal problem for ${HYPS[$1]}:" >&2
    echo "$err" | grep -v '^;' | sed 's/^/  /' >&2
    exit 2
  fi
}

# --- determine the horizon ---------------------------------------------------
if [[ -z "$HORIZON" ]]; then
  echo "Finding per-hypothesis feasible horizons (n=$N)..." >&2
  H=$(( NOBS + 1 ))
  for i in "${!HYPS[@]}"; do
    hyp="${HYPS[$i]}"; p="$OUT/sg-$hyp.pddl"; single_goal_problem "$i" "$p"
    run_planner "$OUT/horizon-$hyp.log" "$p" --domain "$DOMAIN" --minslices 2 --maxslices 30 ${SOLVER_ARG[@]+"${SOLVER_ARG[@]}"} \
        ${TIMEOUT_MARG[@]+"${TIMEOUT_MARG[@]}"}
    n=$(sed -n 's/.*Found a plan with \([0-9][0-9]*\) time slices.*/\1/p; s/.*SOLVED with \([0-9][0-9]*\) time slices.*/\1/p' "$OUT/horizon-$hyp.log" | head -1)
    [[ -n "$n" && "$n" -gt "$H" ]] && H="$n"
    echo "  $hyp -> ${n:-unreachable}" >&2
  done
  HORIZON="$H"
fi
# Slice-pinned evidence cannot be satisfied at a horizon shorter than the largest
# slice it names: every c(O) would come back infinite and every posterior 0.
if [[ -n "$MAXSLICE" && "$HORIZON" -lt "$MAXSLICE" ]]; then
  echo "Raising horizon $HORIZON -> $MAXSLICE (the largest slice the evidence names)" >&2
  HORIZON="$MAXSLICE"
fi
echo "Horizon H = $HORIZON (observations = $NOBS)" >&2

# --- the 2n costs ------------------------------------------------------------
SUM="$OUT/summary.tsv"
printf 'hyp\tc_O\tc_notO\tdelta\tlikelihood\tprior\tposterior\n' > "$SUM"
CO=(); CN=()

if [[ "$METHOD" == "fast" ]]; then
  # ONE instantiated theory serves every hypothesis and both polarities.
  #
  # Clamping hypI in the disjunctive theory selects the same models as rewriting
  # the goal to G_i -- hypI implies the disjunction, so T_or ^ hypI == T_i -- so
  # this computes exactly what the plan-runs method does, from 2n clamped solves
  # on one scnf instead of 2n translate-instantiate-solve cycles.
  echo "Instantiating once at $HORIZON slices..." >&2
  # Clear last run's artifacts first.  $OUT defaults to a PERSISTENT directory,
  # and the guard below is "does the scnf exist" -- so a stale scnf from an
  # earlier, different run would satisfy it and this run would silently report
  # the previous run's numbers.  The assertion file too: its guard below is
  # "does it exist", so a stale one would condition on the PREVIOUS evidence.
  # And the last run's posteriors, which --stop-after would otherwise leave
  # beside a theory they were not computed from.
  rm -f "$OUT"/rec-problem.* "$OUT"/rec-problem-assertion.txt \
        "$OUT"/rec-problem-evidence.scnf "$OUT"/hypotheses.txt "$OUT"/hypotheses.err 2>/dev/null
  P1="$OUT/rec-problem.pddl"; cp "$PROBLEM" "$P1"
  SPLIT_ARG=()
  if [[ "$EVKIND" == "pddl" ]]; then
    # (occur-in-order ...) compiles to monitor atoms that live only in the
    # evidence scnf, so they cannot be conditioned on.  --split-evidence folds
    # the (determined, count-neutral) axioms into the theory and leaves the one
    # assertion literal apart, which IS an atom of the theory and so can be.
    SPLIT_ARG=(--split-evidence)
  fi
  run_planner "$OUT/instantiate.log" "$P1" --domain "$DOMAIN" \
      --numslices "$HORIZON" "$EV_FLAG" "$EVIDENCE" --stop-after scnf \
      ${SPLIT_ARG[@]+"${SPLIT_ARG[@]}"} ${SOLVER_ARG[@]+"${SOLVER_ARG[@]}"} \
      ${TIMEOUT_MARG[@]+"${TIMEOUT_MARG[@]}"}
  INST_RC=$?
  SCNF="$OUT/rec-problem.scnf"
  if [[ "$INST_RC" -ne 0 || ! -f "$SCNF" ]]; then
    echo "recognize.sh: instantiation failed (planner.sh exit $INST_RC)" >&2
    tail -3 "$OUT/instantiate.log" >&2
    exit 2
  fi
  # Checked before --stop-after returns: evidence a full run refuses must not
  # pass for a usable theory.
  if [[ "$EVKIND" == "pddl" ]]; then
    ASSERT_FILE="$OUT/rec-problem-assertion.txt"
    [[ -f "$ASSERT_FILE" ]] || { echo "recognize.sh: no assertion literal was written --" >&2
        echo "  --split-evidence handles a SINGLE (occur-in-order ...) form; this evidence is not one." >&2
        exit 2; }
    EV_MARG=(--evidence "$(cat "$ASSERT_FILE")")
  else
    EV_MARG=(--evidence-file "$EVIDENCE")
  fi
  if [[ "$STOP_AFTER" == "scnf" ]]; then
    # no summary.tsv: a header with no rows must not pass for a result
    rm -f "$SUM"
    echo "Stopped after instantiation (--stop-after scnf): $SCNF" >&2
    if [[ "$EVKIND" == "pddl" ]]; then
      echo "  the observation monitor's axioms are in it; condition on the literal in $ASSERT_FILE" >&2
    else
      echo "  the evidence is apart, in $OUT/rec-problem-evidence.scnf" >&2
    fi
    exit 0
  fi

  HYP_ARGS=()
  for i in "${!HYPS[@]}"; do HYP_ARGS+=(--hypotheses "(holds ${HYP_ATOMS[$i]} $HORIZON)"); done
  MT_ARG=(); [[ "$COUNTER" == "max-term" ]] && MT_ARG=(--maxsat-solver "$MAXSAT_SOLVER")
  # When marginals.sh's own posterior is what gets reported (any counter but
  # max-term, or --baseline best-rival), the priors have to reach IT -- the awk
  # below never runs, so applying them here would drop them silently.  Translate
  # recognize.sh's positional file (n weights, hyp order) into the atom=p form.
  #
  # Two conversions matter here.  recognize.sh's priors are RELATIVE WEIGHTS
  # (2 and 1 mean 2/3 and 1/3); marginals.sh --prior wants a PROBABILITY, and
  # max-term turns it into a log-odds shift -- so forwarding the raw weight 1
  # asks for logit(1) = infinity and pins every marginal at 1.0.  Normalise.
  # And forward NOTHING when the user gave no prior: a uniform shift does not
  # cancel in log-odds space, so "uniform" and "absent" are different answers.
  PRIOR_MARG=()
  if [[ "$PRIORS_GIVEN" -eq 1 && "$COUNTER$BASELINE" != "max-termper-hypothesis" ]]; then
    PSUM=$(printf '%s\n' ${PRIOR_ARR[@]+"${PRIOR_ARR[@]}"} | awk '{s+=$1} END{print s}')
    pi=0
    while [[ "$pi" -lt "$N" ]]; do
      PRIOR_MARG+=(--prior "(holds ${HYP_ATOMS[$pi]} $HORIZON)=$(awk -v w="${PRIOR_ARR[$pi]}" -v s="$PSUM" 'BEGIN{printf "%.10g", w/s}')")
      pi=$(( pi + 1 ))
    done
  fi
  bash "$SELF/marginals.sh" "$SCNF" ${HYP_ARGS[@]+"${HYP_ARGS[@]}"} \
       --baseline "$BASELINE" --solver "$COUNTER" --beta "$BETA" \
       ${MT_ARG[@]+"${MT_ARG[@]}"} ${PRIOR_MARG[@]+"${PRIOR_MARG[@]}"} \
       ${TIMEOUT_MARG[@]+"${TIMEOUT_MARG[@]}"} \
       ${EV_MARG[@]+"${EV_MARG[@]}"} > "$OUT/hypotheses.txt" 2>"$OUT/hypotheses.err" || {
    echo "recognize.sh: the hypothesis posterior failed:" >&2; cat "$OUT/hypotheses.err" >&2; exit 2; }
  grep '^;' "$OUT/hypotheses.txt" >&2 || true

  # max-term + per-hypothesis reports the two costs, so the SAME awk below
  # produces the summary and the output is directly comparable with plan-runs.
  # Other combinations do not have c(O)/c(~O) to report.
  for i in "${!HYPS[@]}"; do
    # -i: the goal is written hyp0 but FiFO prints atoms upper-cased, (HYP0).
    row=$(grep -Fi "(HYPOTHESIS (HOLDS ${HYP_ATOMS[$i]} $HORIZON) " "$OUT/hypotheses.txt")
    [[ -n "$row" ]] || { echo "recognize.sh: no posterior reported for ${HYPS[$i]} -- see $OUT/hypotheses.txt" >&2; exit 2; }
    CO[$i]=$(sed -n 's/.*:c-o \([^ )]*\).*/\1/p' <<<"$row"); CO[$i]="${CO[$i]:-NA}"
    CN[$i]=$(sed -n 's/.*:c-not-o \([^ )]*\).*/\1/p' <<<"$row"); CN[$i]="${CN[$i]:-NA}"
    [[ "${CO[$i]}" == "inf" || "${CO[$i]}" == "NA" ]] || CO[$i]=$(printf '%g' "${CO[$i]}")
    [[ "${CN[$i]}" == "inf" || "${CN[$i]}" == "NA" ]] || CN[$i]=$(printf '%g' "${CN[$i]}")
    echo "  ${HYPS[$i]}: c(O)=${CO[$i]}  c(~O)=${CN[$i]}" >&2
  done
  # Only max-term under the per-hypothesis baseline yields c(O)/c(~O).  For any
  # other combination marginals.sh has already computed the posterior, and its
  # numbers must be reported directly: feeding the missing costs into the sigmoid
  # below would silently make every likelihood -- and so every posterior -- zero.
  [[ "$COUNTER" == "max-term" && "$BASELINE" == "per-hypothesis" ]] || USE_MARGINALS_POSTERIOR=1
else
  for i in "${!HYPS[@]}"; do
    hyp="${HYPS[$i]}"; p="$OUT/sg-$hyp.pddl"; single_goal_problem "$i" "$p"
    run_planner "$OUT/$hyp-comply.log"    "$p" --domain "$DOMAIN" --minslices "$HORIZON" --maxslices "$HORIZON" "$EV_FLAG" "$EVIDENCE" ${SOLVER_ARG[@]+"${SOLVER_ARG[@]}"} --weighted-solver "$MAXSAT_SOLVER"
    run_planner "$OUT/$hyp-notcomply.log" "$p" --domain "$DOMAIN" --minslices "$HORIZON" --maxslices "$HORIZON" "$EV_FLAG" "$NEG_EV"   ${SOLVER_ARG[@]+"${SOLVER_ARG[@]}"} --weighted-solver "$MAXSAT_SOLVER"
    CO[$i]=$(cost_of "$OUT/$hyp-comply.log")
    CN[$i]=$(cost_of "$OUT/$hyp-notcomply.log")
    # drop this hypothesis's heavy intermediates once its costs are read
    rm -f "$OUT/sg-$hyp".{pddl,wff,scnf,cnf,wcnf,map,satout,soln,answer} \
          "$OUT/sg-$hyp"-*.scnf "$OUT/$hyp-comply.log" "$OUT/$hyp-notcomply.log" 2>/dev/null
    echo "  $hyp: c(O)=${CO[$i]}  c(~O)=${CN[$i]}" >&2
  done
fi

# --- priors ------------------------------------------------------------------

# --- likelihoods, posterior ---------------------------------------------------
if [[ "${USE_MARGINALS_POSTERIOR:-0}" -eq 1 ]]; then
  for i in "${!HYPS[@]}"; do
    row=$(grep -Fi "(HYPOTHESIS (HOLDS ${HYP_ATOMS[$i]} $HORIZON) " "$OUT/hypotheses.txt")
    po=$(sed -n 's/.*:posterior \([^ )]*\).*/\1/p' <<<"$row")
    pr=$(sed -n 's/.*:prior \([^ )]*\).*/\1/p' <<<"$row")
    lk=$(sed -n 's/.*:likelihood \([^ )]*\).*/\1/p' <<<"$row")
    awk -v h="${HYPS[$i]}" -v l="${lk:--}" -v p="${pr:-1}" -v q="${po:-0}" -v OFS='\t' \
        'BEGIN{ printf "%s\t-\t-\t-\t%s\t%.4f\t%.4f\n", h, (l=="-"?"-":sprintf("%.4f",l)), p, q }' >> "$SUM"
  done
else
{ for i in "${!HYPS[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "${HYPS[$i]}" "${CO[$i]}" "${CN[$i]}" "${PRIOR_ARR[$i]:-}"
  done
} | awk -v beta="$BETA" -v OFS='\t' '
  function sigmoid(x){ if(x>40)return 1; if(x<-40)return 0; return 1/(1+exp(-x)) }
  { hyp[NR]=$1; co[NR]=$2; cn[NR]=$3; pr[NR]=($4==""?1:$4); n=NR }
  END{
    Z=0
    for(i=1;i<=n;i++){
      if(co[i]=="inf"||co[i]=="NA") L=0
      else if(cn[i]=="inf") L=1
      else { d[i]=cn[i]-co[i]; L=sigmoid(beta*d[i]) }
      lik[i]=L; u[i]=pr[i]*L; Z+=u[i]
    }
    for(i=1;i<=n;i++){
      post=(Z>0? u[i]/Z : 0)
      dd=((co[i]=="inf"||co[i]=="NA"||cn[i]=="inf")?"-":sprintf("%g",d[i]))
      printf "%s\t%s\t%s\t%s\t%.4f\t%.4f\t%.4f\n", hyp[i],co[i],cn[i],dd,lik[i],pr[i],post
    }
  }' >> "$SUM"
fi

# Every posterior zero is not an answer.  It means no hypothesis had a finite
# complying cost -- a horizon too short for the observations, or a solver that
# produced no costs at all -- and printing an argmax of 0.0000 would present that
# as a result.
if ! awk -F'\t' 'NR>1 && $7+0>0 {f=1} END{exit !f}' "$SUM"; then
  {
    echo "recognize.sh: every posterior is zero, so there is no recognition result."
    echo "  No hypothesis has a finite complying cost.  Usually the horizon is too"
    echo "  short for the observations (try a larger --horizon), or the MaxSAT solver"
    echo "  returned no cost -- see the logs in $OUT."
  } >&2
  exit 2
fi

# --- clean remaining intermediates; keep summary.tsv (+ the negated evidence) --
rm -f "$OUT"/sg-*.* "$OUT"/horizon-*.log 2>/dev/null

# --- report ------------------------------------------------------------------
echo
column -t -s$'\t' "$SUM"
best=$(awk -F'\t' 'NR>1 && $7+0>=m{m=$7+0; b=$1" P="$7} END{print b}' "$SUM")
echo
echo "Recognized (argmax posterior): $best"
echo "Full results: $SUM"
