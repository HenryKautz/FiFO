#!/usr/bin/env python3
"""rc2-maxsat.py -- an EXACT weighted MaxSAT solver for FiFO, via PySAT's RC2.

FiFO's max-term marginals are a DIFFERENCE of two minimum costs, so a solver
that returns a good-but-unproven solution is not merely imprecise -- the two
upper bounds do not cancel, and the difference is meaningless.  The anytime
solvers FiFO uses elsewhere (tt-open-wbo-inc, nuwls-c) never print
"s OPTIMUM FOUND": they are the incomplete-track solvers and report the best
assignment they happened to reach.

RC2 (Ignatiev, Morgado & Marques-Silva) is core-guided and complete, so it
terminates with a proof.  This wrapper gives it the plain command-line interface
the rest of FiFO expects -- one wcnf path in, DIMACS-style s/o/v lines out --
and is deliberately tiny so there is nothing to go wrong between the two.

    rc2-maxsat.py <file.wcnf>

Output:
    o <cost>            the proven minimum
    s OPTIMUM FOUND     (or s UNSATISFIABLE when the hard clauses have no model)
    v <bitstring>       one character per variable, as tt-open-wbo-inc prints

Needs:  pip install python-sat
"""
import sys

def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip()); return 2
    try:
        from pysat.formula import WCNF
        from pysat.examples.rc2 import RC2
    except ImportError:
        sys.stderr.write("rc2-maxsat.py: python-sat is not installed "
                         "(pip install python-sat)\n")
        return 1

    wcnf = WCNF(from_file=argv[1])
    nv = wcnf.nv
    with RC2(wcnf) as rc2:
        model = rc2.compute()
        if model is None:
            print("s UNSATISFIABLE")
            return 20
        print("o %d" % rc2.cost)
        print("s OPTIMUM FOUND")
        # RC2's model omits variables it does not care about; absent means false,
        # which matches FiFO's reading of a partial assignment.
        truth = set(l for l in model if l > 0)
        print("v " + "".join("1" if v in truth else "0" for v in range(1, nv + 1)))
    return 30

if __name__ == "__main__":
    sys.exit(main(sys.argv))
