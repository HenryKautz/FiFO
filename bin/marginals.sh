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

  --out <file>        also write the (MARGINAL ...) lines to <file>
  --node-limit <int>  cap on enumeration nodes (default: 5000000)
  -h, --help          show this help

Each line of output is  (MARGINAL <atom> <probability>).

The lisp is located via FIFO_LISP (default: $HOME/lib/fifo/lisp); run
'make install' or set FIFO_LISP to a source checkout's lisp/ directory.
EOF
}

die() { echo "marginals.sh: $1" >&2; echo >&2; print_usage >&2; exit 2; }

SCNF=""
OUT=""
NODE_LIMIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     print_usage; exit 0 ;;
    --out)         [[ $# -ge 2 ]] || die "--out needs an argument"; OUT="$2"; shift 2 ;;
    --node-limit)  [[ $# -ge 2 ]] || die "--node-limit needs an argument"; NODE_LIMIT="$2"; shift 2 ;;
    -*)            die "unknown option: $1" ;;
    *)             if [[ -z "$SCNF" ]]; then SCNF="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[[ -n "$SCNF" ]] || die "no .scnf file given"
[[ -f "$SCNF" ]] || die "input file not found: $SCNF"
if [[ -n "$NODE_LIMIT" && ! "$NODE_LIMIT" =~ ^[0-9]+$ ]]; then die "--node-limit must be a non-negative integer, got: $NODE_LIMIT"; fi
[[ -d "$FIFO_LISP" ]] || die "FiFO lisp directory not found: $FIFO_LISP (run 'make install' or set FIFO_LISP)"

KW=""
[[ -n "$OUT" ]] && KW="$KW :out-file \"$OUT\""
[[ -n "$NODE_LIMIT" ]] && KW="$KW :node-limit $NODE_LIMIT"

# Load in separate --evals so the call is compiled after marginals is defined.
exec sbcl --noinform --non-interactive \
  --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
  --eval "(load \"$FIFO_LISP/maxent.lisp\")" \
  --eval "(handler-case (progn (marginals \"$SCNF\" $KW) (sb-ext:exit :code 0))
            (error (e) (format *error-output* \"marginals.sh: ~A~%\" e) (sb-ext:exit :code 1)))"
