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

# ------------------------------------------------------------- preferences ---

name "default goal is a conjunction with no preferences"
if ! grep -q '(preference' "$TMP/c.pddl" && grep -q '(:goal (and' "$TMP/c.pddl" &&
   ! grep -q '(or (at' "$TMP/c.pddl"
then pass; else fail "default should be a plain conjunctive goal"; fi

name "--preferences none is the same as omitting it"
a=$(gen --style clique --clique-size 4 --number-cliques 3 --seed 21)
b=$(gen --style clique --clique-size 4 --number-cliques 3 --preferences none --seed 21)
if [ "$a" = "$b" ]; then pass; else fail "--preferences none changed the output"; fi

name "--preferences L H makes the goal a disjunction, one preference each"
gen --style grid --dimensions 4 4 --packages 3 --preferences 1 5 --seed 42 > "$TMP/p.pddl"
if pycheck "$TMP/p.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
goal=t.split('(:goal')[1]
dis=re.search(r'\(or ((?:\(at \w+ [\w-]+\) ?)+)\)',goal)
assert dis, goal
assert len(re.findall(r'\(at \w+ [\w-]+\)',dis.group(1)))==3, goal
prefs=re.findall(r'\(preference ([\w-]+) (\(at \w+ [\w-]+\)) ([\d.]+)\)',goal)
assert len(prefs)==3, prefs
# every disjunct carries exactly one preference
assert sorted(p[1] for p in prefs)==sorted(re.findall(r'\(at \w+ [\w-]+\)',dis.group(1)))
EOF
then pass; else fail "disjunctive goal / preferences malformed"; fi

name "preference values are equally spaced from L to H"
if pycheck <<'EOF'
import subprocess,re,os
def vals(n,lo,hi,seed):
    t=subprocess.run(['bash',os.environ['PPGEN'],'--style','grid','--dimensions','4','4',
                      '--packages',str(n),'--preferences',str(lo),str(hi),'--seed',str(seed)],
                     capture_output=True,text=True).stdout
    v=[float(x) for x in re.findall(r'\(preference [\w-]+ \(at \w+ [\w-]+\) ([\d.]+)\)',t)]
    return sorted(v)
assert vals(1,1,5,2)==[1.0]
assert vals(2,1,5,2)==[1.0,5.0]
assert vals(3,1,5,2)==[1.0,3.0,5.0]
assert vals(5,1,5,2)==[1.0,2.0,3.0,4.0,5.0]
assert vals(3,0,1,2)==[0.0,0.5,1.0]
EOF
then pass; else fail "values not equally spaced"; fi

name "preference values are assigned in a random order"
if pycheck <<'EOF'
import subprocess,re,os
def order(seed):
    t=subprocess.run(['bash',os.environ['PPGEN'],'--style','grid','--dimensions','5','5',
                      '--packages','5','--preferences','1','5','--seed',str(seed)],
                     capture_output=True,text=True).stdout
    return re.findall(r'\(preference [\w-]+ \(at \w+ [\w-]+\) ([\d.]+)\)',t)
seen={tuple(order(s)) for s in range(1,12)}
assert len(seen)>1, seen          # not always the same permutation
EOF
then pass; else fail "assignment order looks fixed"; fi

# ---------------------------------------------------------------- maxgoals ---

name "no --maxgoals: records the package count, constrains nothing"
gen --style clique --clique-size 3 --number-cliques 2 --packages 4 --seed 1 > "$TMP/m0.pddl"   # no --maxgoals
if grep -q '^;;   --maxgoals 4$' "$TMP/m0.pddl" && ! grep -q '(not (and' "$TMP/m0.pddl"
then pass; else fail "default maxgoals should impose no constraint"; fi

name "--maxgoals equal to the package count constrains nothing"
gen --style grid --dimensions 4 4 --packages 3 --preferences 1 5 --maxgoals 3 --seed 1 > "$TMP/m1.pddl"
if ! grep -q '(not (and' "$TMP/m1.pddl"; then pass
else fail "a cap at the package count should be vacuous"; fi

name "--maxgoals N forbids every (N+1)-subset of the goals"
gen --style grid --dimensions 4 4 --packages 4 --preferences 1 7 --maxgoals 2 --seed 3 > "$TMP/m2.pddl"
if pycheck "$TMP/m2.pddl" <<'EOF'
import sys,re,itertools
t=open(sys.argv[1]).read(); goal=t.split('(:goal')[1]
atoms=re.findall(r'\(preference [\w-]+ (\(at \w+ [\w-]+\))',goal)
assert len(atoms)==4, atoms
nots=re.findall(r'\(not \(and ((?:\(at \w+ [\w-]+\) ?)+)\)\)',goal)
got={tuple(sorted(re.findall(r'\(at \w+ [\w-]+\)',n))) for n in nots}
exp={tuple(sorted(c)) for c in itertools.combinations(atoms,3)}
assert got==exp, (len(got),len(exp))
EOF
then pass; else fail "at-most-N encoding wrong"; fi

name "the cap holds in an actual solution"
if command -v "${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" >/dev/null 2>&1; then
  gen --style clique --clique-size 3 --number-cliques 2 --packages 4       --preferences 1 7 --maxgoals 2 --seed 6 > "$TMP/m3.pddl"
  if WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" bash "$REPO/bin/planner.sh"         "$TMP/m3.pddl" --domain "$DOMAIN" --maxslices 8 >"$TMP/m3.log" 2>&1 &&
     pycheck "$TMP/m3.pddl" "$TMP/m3.answer" <<'EOF'
import sys,re
prob=open(sys.argv[1]).read(); ans=open(sys.argv[2]).read()
goals=re.findall(r'\(preference [\w-]+ \(at (\w+) ([\w-]+)\)',prob)
last=max(int(m) for m in re.findall(r'\(HOLDS \(AT \w+ [\w-]+\) (\d+)\)',ans))
held={(p.lower(),l.lower()) for p,l in re.findall(rf'\(HOLDS \(AT (\w+) ([\w-]+)\) {last}\)',ans)}
assert len([g for g in goals if g in held])<=2
EOF
  then pass; else fail "solution exceeded the cap; see $TMP/m3.log"; fi
else echo "SKIP (no MaxSAT solver)"; fi

# ------------------------------------------------- recorded settings / seed ---

name "the file records every setting, defaults included"
if pycheck "$TMP/c.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
p=dict(re.findall(r'^;;   (--[\w-]+) (.+)$',t,re.M))
for f in ('--style','--clique-size','--number-cliques','--trucks','--airplanes',
          '--packages','--drive-cost','--fly-cost','--preferences','--maxgoals','--seed'):
    assert f in p, (f,p)
assert p['--style']=='clique' and p['--drive-cost']=='1' and p['--fly-cost']=='3'
assert p['--preferences']=='none'
assert '--dimensions' not in p and '--airports' not in p   # grid-only settings
EOF
then pass; else fail "settings block incomplete"; fi

name "a grid file records the grid settings, not the clique ones"
if pycheck "$TMP/g.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
p=dict(re.findall(r'^;;   (--[\w-]+) (.+)$',t,re.M))
assert p['--style']=='grid' and p['--dimensions']=='4 5' and p['--airports']=='3'
assert '--clique-size' not in p and '--number-cliques' not in p
EOF
then pass; else fail "grid settings block wrong"; fi

name "an unseeded run records the seed it used"
gen --style clique --clique-size 3 --number-cliques 2 > "$TMP/u1.pddl"
SEED_USED=$(grep -oE '^;;   --seed [0-9]+' "$TMP/u1.pddl" | awk '{print $3}')
if [ -n "$SEED_USED" ]; then pass; else fail "no seed recorded"; fi

name "replaying the recorded seed reproduces the file exactly"
gen --style clique --clique-size 3 --number-cliques 2 --seed "$SEED_USED" > "$TMP/u2.pddl"
if diff -q "$TMP/u1.pddl" "$TMP/u2.pddl" >/dev/null; then pass
else fail "recorded seed did not reproduce the run"; fi

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
err "--preferences with one bound is rejected" "two numbers"       --style grid --dimensions 3 3 --preferences 5
err "--preferences with a non-number is rejected" "expects a number" --style grid --dimensions 3 3 --preferences lo hi
err "--maxgoals above 3 is rejected"       "capped at 3"          --style grid --dimensions 4 4 --packages 5 --preferences 1 5 --maxgoals 4
err "--maxgoals 0 is rejected"             "at least 1"           --style grid --dimensions 4 4 --packages 3 --preferences 1 5 --maxgoals 0
err "--maxgoals without --preferences is rejected" "needs --preferences" --style grid --dimensions 4 4 --packages 4 --maxgoals 2
err "--maxgoals = packages still needs --preferences" "needs --preferences" --style grid --dimensions 4 4 --packages 3 --maxgoals 3

# ------------------------------------------------------------ solvability ---

SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}"
if command -v "$SOLVER" >/dev/null 2>&1; then
  name "a preference problem translates and solves"
  gen --style clique --clique-size 3 --number-cliques 2 --packages 3 \
      --preferences 1 5 --seed 8 > "$TMP/pr.pddl"
  if WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" "$TMP/pr.pddl" \
       --domain "$DOMAIN" --maxslices 8 >"$TMP/pr.log" 2>&1 &&
     grep -q 'SOLVED' "$TMP/pr.log" && grep -q '(\*OBJECTIVE\*' "$TMP/pr.answer"
  then pass; else fail "preference problem did not solve; see $TMP/pr.log"; fi

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
