#!/bin/bash
#
# run-test-ppgen.sh -- regression tests for SatPlan/ppgen.sh, the clara-logistics
# problem generator.
#
# Structural checks against the specification (SatPlan/ppgen-specs.txt) plus a
# solvability check per style: the generated problems are random, so the tests
# assert the invariants the spec states -- even distribution over cliques, roads
# between every pair within a clique, adjacency-only roads on a grid, airports
# maximally spread -- rather than diffing against fixed output.  Seeds are fixed
# so a failure is reproducible.
#
# Run from anywhere:  bash tests/run-test-ppgen.sh
# The solvability cases need a MaxSAT solver and skip cleanly without one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
PPGEN="$REPO/SatPlan/ppgen.sh"; export PPGEN   # the python checks below shell out to it
DOMAIN="$REPO/SatPlan/clara-logistics.pddl"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }

PASS=0; FAIL=0
name() { printf '  %-54s ... ' "$1"; }
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }

gen() { bash "$PPGEN" "$@" 2>/dev/null; }
generr() { bash "$PPGEN" "$@" 2>&1 >/dev/null | head -1; }

# check <label> <python-expr-file> : run a python check over a generated problem
pycheck() { python3 - "$@"; }

# ------------------------------------------------------------------ clique ---

name "clique: one airport per clique, all places present"
gen --style clique --clique-size 4 --number-cliques 3 --seed 1 > "$TMP/c.pddl"
if pycheck "$TMP/c.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
air=re.search(r'^\s+(.*) - airport$',t,re.M).group(1).split()
pl=re.search(r'^\s+(.*) - place$',t,re.M).group(1).split()
assert len(air)==3, air
assert sorted(air)==sorted(f'c{i}-air' for i in (1,2,3)), air
assert len(pl)==9, pl          # 3 cliques x (4-1) non-airport places
EOF
then pass; else fail "airports/places wrong"; fi

name "clique: roads join every pair within a clique, both ways"
if pycheck "$TMP/c.pddl" <<'EOF'
import sys,re,itertools
t=open(sys.argv[1]).read()
roads=set(re.findall(r'\(road ([\w-]+) ([\w-]+)\)',t))
for c in (1,2,3):
    places=[f'c{c}-air']+[f'c{c}-p{i}' for i in (1,2,3)]
    for a,b in itertools.permutations(places,2):
        assert (a,b) in roads, (a,b)
# and no road between cliques
for (a,b) in roads:
    assert a.split('-')[0]==b.split('-')[0], (a,b)
EOF
then pass; else fail "clique roads wrong"; fi

name "clique: packages spread evenly over cliques"
if pycheck <<'EOF'
import subprocess,re,collections,os
ok=True
for seed in (1,2,3,4,5):
    t=subprocess.run(['bash',os.environ['PPGEN'],'--style','clique','--clique-size','4',
                      '--number-cliques','3','--packages','7','--seed',str(seed)],
                     capture_output=True,text=True).stdout
    init=t.split('(:goal')[0]
    c=collections.Counter(m.group(1) for m in re.finditer(r'\(at pkg\d+ (c\d+)-',init))
    assert sum(c.values())==7, c
    v=sorted(c.values()); ok &= (max(v)-min(v))<=1
assert ok
EOF
then pass; else fail "packages not evenly spread"; fi

name "clique: airplanes spread evenly over airports"
if pycheck <<'EOF'
import subprocess,re,collections,os
t=subprocess.run(['bash',os.environ['PPGEN'],'--style','clique','--clique-size','4',
                  '--number-cliques','3','--airplanes','5','--seed','1'],
                 capture_output=True,text=True).stdout
init=t.split('(:goal')[0]
c=collections.Counter(m.group(1) for m in re.finditer(r'\(at plane\d+ ([\w-]+)\)',init))
assert sum(c.values())==5, c
assert all(k.endswith('-air') for k in c), c
v=sorted(c.values()); assert max(v)-min(v)<=1, c
EOF
then pass; else fail "airplanes not evenly spread over airports"; fi

name "clique: counts default to the number of cliques"
if pycheck "$TMP/c.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
for kind in ('truck','airplane','package'):
    n=len(re.search(rf'^\s+(.*) - {kind}\)?$',t,re.M).group(1).split())
    assert n==3, (kind,n)
EOF
then pass; else fail "defaults wrong"; fi

# -------------------------------------------------------------------- grid ---

name "grid: roads join orthogonally adjacent cells only"
gen --style grid --dimensions 4 5 --airports 3 --seed 2 > "$TMP/g.pddl"
if pycheck "$TMP/g.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
roads=set(re.findall(r'\(road p(\d+)-(\d+) p(\d+)-(\d+)\)',t))
exp=set()
for r in range(1,5):
    for c in range(1,6):
        for dr,dc in ((0,1),(1,0),(0,-1),(-1,0)):
            r2,c2=r+dr,c+dc
            if 1<=r2<=4 and 1<=c2<=5: exp.add((str(r),str(c),str(r2),str(c2)))
assert roads==exp, (len(roads),len(exp))
EOF
then pass; else fail "grid roads wrong"; fi

name "grid: airports maximize their minimum separation"
if pycheck "$TMP/g.pddl" <<'EOF'
import sys,re,itertools
t=open(sys.argv[1]).read()
air=[tuple(map(int,a.split('-')[0:2])) for a in
     [x[1:] for x in re.search(r'^\s+(.*) - airport$',t,re.M).group(1).split()]]
def d(a,b): return abs(a[0]-b[0])+abs(a[1]-b[1])
got=min(d(a,b) for a,b in itertools.combinations(air,2))
cells=[(r,c) for r in range(1,5) for c in range(1,6)]
best=max(min(d(a,b) for a,b in itertools.combinations(t3,2))
         for t3 in itertools.combinations(cells,3))
assert got==best, (air,got,best)
EOF
then pass; else fail "airports not maximally dispersed"; fi

name "grid: defaults -- 2 airports, counts follow airports"
gen --style grid --dimensions 3 3 --seed 4 > "$TMP/gd.pddl"
if pycheck "$TMP/gd.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
assert len(re.search(r'^\s+(.*) - airport$',t,re.M).group(1).split())==2
for kind in ('truck','airplane','package'):
    n=len(re.search(rf'^\s+(.*) - {kind}\)?$',t,re.M).group(1).split())
    assert n==2, (kind,n)
EOF
then pass; else fail "grid defaults wrong"; fi

# ------------------------------------------------------------------ shared ---

name "every pair of airports is joined by a two-way route"
if pycheck "$TMP/g.pddl" <<'EOF'
import sys,re,itertools
t=open(sys.argv[1]).read()
air=re.search(r'^\s+(.*) - airport$',t,re.M).group(1).split()
routes=set(re.findall(r'\(route ([\w-]+) ([\w-]+)\)',t))
for a,b in itertools.permutations(air,2): assert (a,b) in routes,(a,b)
assert len(routes)==len(air)*(len(air)-1), len(routes)
EOF
then pass; else fail "routes incomplete"; fi

name "no package starts where its goal is"
gen --style grid --dimensions 4 4 --packages 6 --seed 9 > "$TMP/gg.pddl"
if pycheck "$TMP/gg.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
init=dict(re.findall(r'\(at (pkg\d+) ([\w-]+)\)',t.split('(:goal')[0]))
goal=dict(re.findall(r'\(at (pkg\d+) ([\w-]+)\)',t.split('(:goal')[1]))
assert len(goal)==6, goal
assert not [p for p in goal if init[p]==goal[p]]
EOF
then pass; else fail "a package is already at its goal"; fi

name "costs default to drive 1 / fly 3, and --drive-cost overrides"
if grep -q '(= (drive-cost) 1)' "$TMP/c.pddl" && grep -q '(= (fly-cost) 3)' "$TMP/c.pddl" &&
   gen --style clique --clique-size 3 --number-cliques 2 --drive-cost 2.5 --fly-cost 9 --seed 1 |
     grep -q '(= (drive-cost) 2.5)'
then pass; else fail "cost defaults/overrides wrong"; fi

name "same seed reproduces, different seed differs"
a=$(gen --style clique --clique-size 4 --number-cliques 3 --seed 11)
b=$(gen --style clique --clique-size 4 --number-cliques 3 --seed 11)
c=$(gen --style clique --clique-size 4 --number-cliques 3 --seed 12)
if [ "$a" = "$b" ] && [ "$a" != "$c" ]; then pass; else fail "seeding is not reproducible"; fi

name "--output writes a file and prints nothing to stdout"
out=$(bash "$PPGEN" --style grid --dimensions 3 3 --seed 1 -o "$TMP/o.pddl" 2>/dev/null)
if [ -z "$out" ] && [ -s "$TMP/o.pddl" ] && grep -q '(define (problem' "$TMP/o.pddl"
then pass; else fail "--output misbehaved"; fi

# ------------------------------------------------------------------ errors ---

err() { name "$1"; shift; local want="$1"; shift
        local got; got="$(generr "$@")"
        if echo "$got" | grep -qi "$want"; then pass; else fail "got: $got"; fi; }

err "missing --clique-size is reported"    "needs --clique-size"  --style clique --number-cliques 2
err "missing --dimensions is reported"     "needs --dimensions"   --style grid --airports 2
err "an unknown style is reported"         "must be 'grid'"       --style hex --dimensions 3 3
err "--airports is rejected for clique"    "grid style"           --style clique --clique-size 3 --number-cliques 2 --airports 2
err "--clique-size is rejected for grid"   "clique style"         --style grid --dimensions 3 3 --clique-size 4
err "too many airports for the grid"       "Cannot place"         --style grid --dimensions 2 2 --airports 9
err "zero packages is rejected"            "at least 1"           --style clique --clique-size 3 --number-cliques 2 --packages 0
err "a non-numeric count is rejected"      "expects a non-negative" --style grid --dimensions 3 x
err "an unknown flag is rejected"          "unknown option"       --style grid --dimensions 3 3 --bogus 1

# ------------------------------------------------------------ solvability ---

SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}"
if command -v "$SOLVER" >/dev/null 2>&1; then
  for style in clique grid; do
    name "$style: a generated problem translates and solves"
    if [ "$style" = clique ]; then
      gen --style clique --clique-size 3 --number-cliques 2 --packages 1 --seed 3 > "$TMP/s.pddl"
    else
      gen --style grid --dimensions 3 3 --airports 2 --packages 1 --seed 5 > "$TMP/s.pddl"
    fi
    if WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" "$TMP/s.pddl" \
         --domain "$DOMAIN" --maxslices 10 >"$TMP/s.log" 2>&1 &&
       grep -q 'SOLVED' "$TMP/s.log" &&
       grep -q '(\*OBJECTIVE\*' "$TMP/s.answer"
    then pass; else fail "did not solve; see $TMP/s.log"; fi
  done
else
  echo "  (skipping solvability: no MaxSAT solver '$SOLVER' on PATH)"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
