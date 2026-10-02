#!/usr/bin/env python3
"""mcc-reference-count.py -- brute-force weighted model counter, one dialect each.

An INDEPENDENT oracle for lisp/wmc.lisp's two emitters.  It shares no code with
FiFO: it reads a weighted CNF, applies the DEFAULT-WEIGHT RULES OF THE NAMED
DIALECT'S REAL PARSER, enumerates all 2^V assignments, and sums the product of
the true literals' weights over the satisfying ones.  Exponential by design --
these are toy fixtures, and the point is to be obviously right rather than fast.

Why it exists: the two dialects disagree about what an UNSTATED literal polarity
means, so the same weights written in the two formats can denote different
distributions.  Only a reader that implements each parser's own rule can show
that FiFO's two output files mean the same thing.  Comparing FiFO against itself
could not: it would share the misunderstanding.

The rules below are transcribed from the parsers, not from the format documents:

  2020 -- ADDMC, src/implementation/formula.cpp
    problem line  'p wcnf V C'                       (:279-286, 'wcnf' enforced)
    weight line   'w <lit> <w>' | 'w <lit> <w> 0'    (:308-321, 3 or 4 tokens)
    missing side  1.0, silently                      (:402-408, MCC_DEFAULT_...)

  2024 -- SharpSAT-TD, src/preprocessor/instance.cpp
    track line    'c t wmc' (if present, must say wmc for a weighted run) (:143-153)
    problem line  'p cnf V C'                                            (:156-159)
    weight line   'c p weight <lit> <w> 0'  -- EXACTLY 6 tokens           (:124)
    missing side  neither given        -> both 1                         (:185-191)
                  one given, in [0,1]  -> other is 1 - w                 (:192-196)
                  one given, otherwise -> hard error                     (:197-201)

Usage:  mcc-reference-count.py <dialect:2020|2024> <file>
Prints  'Z <value>' on success, or 'ERROR <reason>' and exits 3 -- which is
itself an expected outcome the test suite asserts on, since one of the rules
above is a refusal.
"""

import sys
from itertools import product


def tokens(line):
    return line.split()


def parse(path, dialect):
    """-> (nvars, clauses, weights) with weights[lit] fully determined.

    Raises ValueError for anything the real parser rejects.
    """
    nvars = None
    clauses = []
    given = {}          # lit -> weight, only those explicitly stated
    cur = []
    pline_word = "wcnf" if dialect == "2020" else "cnf"

    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            t = tokens(raw)
            if not t:
                continue

            # --- weight lines, dialect-specific ---------------------------------
            if dialect == "2024" and len(t) == 6 and t[:3] == ["c", "p", "weight"]:
                if nvars is None:
                    raise ValueError(f"weight line {lineno} before the problem line")
                lit, w = int(t[3]), float(t[4])
                if lit == 0 or abs(lit) > nvars:
                    raise ValueError(f"literal {lit} out of range -- line {lineno}")
                given[lit] = w
                continue

            if t[0] == "c":
                # 'c t wmc' / 'c t mc' declares the track.  A weighted run on a file
                # claiming 'mc' is an error in SharpSAT-TD; we only ever count
                # weighted, so anything but wmc is wrong.
                if dialect == "2024" and len(t) == 3 and t[1] == "t" and t[2] != "wmc":
                    raise ValueError(f"track line says '{t[2]}', not 'wmc' -- line {lineno}")
                continue        # every other comment is ignored, weights included

            if t[0] == "p":
                if len(t) != 4:
                    raise ValueError(f"problem line {lineno} has {len(t)} words (want 4)")
                if t[1] != pline_word:
                    raise ValueError(f"expected '{pline_word}', found '{t[1]}' -- line {lineno}")
                nvars = int(t[2])
                continue

            if dialect == "2020" and t[0] == "w":
                if nvars is None:
                    raise ValueError(f"weight line {lineno} before the problem line")
                if not (len(t) == 3 or (len(t) == 4 and t[3] == "0")):
                    raise ValueError(f"malformed 2020 weight line {lineno}: {raw.strip()!r}")
                lit, w = int(t[1]), float(t[2])
                if lit == 0 or abs(lit) > nvars:
                    raise ValueError(f"literal {lit} out of range -- line {lineno}")
                given[lit] = w
                continue

            # --- clause lines ---------------------------------------------------
            for tok in t:
                v = int(tok)
                if v == 0:
                    clauses.append(cur)
                    cur = []
                else:
                    if abs(v) > nvars:
                        raise ValueError(f"literal {v} out of range -- line {lineno}")
                    cur.append(v)

    if nvars is None:
        raise ValueError("no problem line")
    if cur:
        raise ValueError("file ends mid-clause (no terminating 0)")

    # --- complete the weights by the dialect's own rule ----------------------
    weights = {}
    for v in range(1, nvars + 1):
        pos, neg = given.get(v), given.get(-v)
        if dialect == "2020":
            # Absent means 1.0, each polarity independently.
            weights[v] = 1.0 if pos is None else pos
            weights[-v] = 1.0 if neg is None else neg
        else:
            if pos is None and neg is None:
                weights[v] = weights[-v] = 1.0
            elif pos is None or neg is None:
                have = pos if neg is None else neg
                missing = -v if neg is None else v
                if not (0.0 <= have <= 1.0):
                    raise ValueError(
                        f"no weight given for {missing} and it cannot be inferred "
                        f"(the stated side is {have}, outside [0,1])")
                weights[missing] = 1.0 - have
                weights[v if pos is not None else -v] = have
            else:
                weights[v], weights[-v] = pos, neg
    return nvars, clauses, weights


def count(nvars, clauses, weights):
    """Z = sum over satisfying assignments of the product of true literals' weights."""
    z = 0.0
    for bits in product((False, True), repeat=nvars):
        assign = {v + 1: bits[v] for v in range(nvars)}
        if all(any((lit > 0) == assign[abs(lit)] for lit in cl) for cl in clauses):
            w = 1.0
            for v in range(1, nvars + 1):
                w *= weights[v] if assign[v] else weights[-v]
            z += w
    return z


def main(argv):
    if len(argv) != 3 or argv[1] not in ("2020", "2024"):
        print(__doc__.rstrip())
        return 2
    try:
        nvars, clauses, weights = parse(argv[2], argv[1])
    except (ValueError, OSError) as e:
        print(f"ERROR {e}")
        return 3
    if nvars > 22:
        print(f"ERROR too many variables for brute force: {nvars}")
        return 3
    print(f"Z {count(nvars, clauses, weights):.12e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
