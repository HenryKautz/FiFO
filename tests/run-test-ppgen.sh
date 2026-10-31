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
DOMAIN="$REPO/pddl/clara-logistics.pddl"
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

name "--require some --preferences L H: one disjunction, one preference each"
gen --style grid --dimensions 4 4 --packages 3 --require some --preferences 1 5 --seed 42 > "$TMP/p.pddl"
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
                      '--packages',str(n),'--require','some',
                      '--preferences',str(lo),str(hi),'--seed',str(seed)],
                     capture_output=True,text=True).stdout
    v=[float(x) for x in re.findall(r'\(preference [\w-]+ \(at \w+ [\w-]+\) ([\d.]+)\)',t)]
    return sorted(v)
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
                      '--packages','5','--require','some','--preferences','1','5','--seed',str(seed)],
                     capture_output=True,text=True).stdout
    return re.findall(r'\(preference [\w-]+ \(at \w+ [\w-]+\) ([\d.]+)\)',t)
seen={tuple(order(s)) for s in range(1,12)}
assert len(seen)>1, seen          # not always the same permutation
EOF
then pass; else fail "assignment order looks fixed"; fi

# ------------------------------------------------------------------ require ---
#
# req_check <file> <low> <high|-> <kind> : a SEMANTIC oracle for --require,
# independent of how it is encoded.  For every subset S of the goal
# objects it puts each object in S at one of its destinations (the first, then
# again the last) and every other object nowhere, evaluates the goal's hard
# forms -- everything but the preferences -- and asserts they hold exactly when
# low <= |S| <= high.  Objects come from the :objects line, so an object with no
# goal at all would fail the check too.
cat > "$TMP/req_check.py" <<'EOF'
import sys,re,itertools
t=open(sys.argv[1]).read(); low=int(sys.argv[2])
high=None if sys.argv[3]=='-' else int(sys.argv[3]); kind=sys.argv[4]
objs=re.search(rf'^\s+(.*) - {kind}\)?$',t,re.M).group(1).split()
if high is None: high=len(objs)
def parse(s):
    toks=re.findall(r'\(|\)|[^\s()]+',s); pos=0
    def rd():
        nonlocal pos
        tok=toks[pos]; pos+=1
        if tok!='(': return tok
        out=[]
        while toks[pos]!=')': out.append(rd())
        pos+=1; return out
    return rd()
goal=parse(t.split('(:goal',1)[1].rsplit('(:metric',1)[0].strip()[:-1])
assert goal[0]=='and', goal[0]
hard=[f for f in goal[1:] if f[0]!='preference']
dest={}
for f in re.findall(r'\(at (\w+) ([\w-]+)\)',t.split('(:goal',1)[1]):
    dest.setdefault(f[0],[])
    if f[1] not in dest[f[0]]: dest[f[0]].append(f[1])
assert sorted(dest)==sorted(objs), (sorted(dest),objs)
def ev(f,at):
    if f[0]=='at': return at.get(f[1])==f[2]
    if f[0]=='and': return all(ev(g,at) for g in f[1:])
    if f[0]=='or': return any(ev(g,at) for g in f[1:])
    if f[0]=='not': return not ev(f[1],at)
    raise ValueError(f)
for k in range(len(objs)+1):
    for S in itertools.combinations(objs,k):
        for pick in (0,-1):
            at={o:dest[o][pick] for o in S}
            got=all(ev(f,at) for f in hard)
            assert got==(low<=k<=high), (S,pick,got,low,high)
EOF
req_check() { python3 "$TMP/req_check.py" "$@"; }

# all: every one of the G = 4 packages; some: at least one
REQ_BAD=""
for spec in "all:4" "some:1"; do
  IFS=: read -r r lo <<<"$spec"
  for d in 1 2 3; do
    for pref in "" "--preferences 1 9"; do
      # --require all with one destination forces every goal: weights refused
      [ "$r" = all ] && [ "$d" = 1 ] && [ -n "$pref" ] && continue
      gen --style grid --dimensions 4 4 --packages 4 --destinations $d --require "$r" $pref --seed 7 > "$TMP/rq.pddl"
      req_check "$TMP/rq.pddl" "$lo" - package 2>"$TMP/rq.err" \
        || { REQ_BAD="--require $r --destinations $d $pref: $(tail -1 "$TMP/rq.err")"; break 3; }
    done
  done
done
name "--require all / some hold exactly, every subset (1-3 dest., +/- weights)"
[ -z "$REQ_BAD" ] && pass || fail "$REQ_BAD"

name "--require some: a single (or ...) over every destination"
gen --style grid --dimensions 4 4 --packages 4 --destinations 2 --require some --seed 7 > "$TMP/rqs1.pddl"
if [ "$(grep -c '^        (or ' "$TMP/rqs1.pddl")" -eq 1 ] \
   && [ "$(grep -o '(at pkg' <<<"$(grep '^        (or ' "$TMP/rqs1.pddl")" | wc -l | tr -d ' ')" -eq 8 ]
then pass; else fail "$(sed -n '/(:goal/,$p' "$TMP/rqs1.pddl")"; fi

name "--require some works without --preferences"
! grep -q '(preference' "$TMP/rqs1.pddl" && pass || fail "preferences appeared"

name "the default records --require all and --destinations 1"
if grep -qx ';;   --require all' "$TMP/c.pddl" && grep -qx ';;   --destinations 1' "$TMP/c.pddl"
then pass; else fail "$(grep '^;;   --' "$TMP/c.pddl" | tr '\n' ' ')"; fi

if command -v "${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" >/dev/null 2>&1; then
  name "--require some holds in an actual solution"
  gen --style clique --clique-size 3 --number-cliques 2 --packages 4 --require some \
      --seed 6 > "$TMP/rqs.pddl"
  if WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" bash "$REPO/bin/planner.sh" \
       "$TMP/rqs.pddl" --domain "$DOMAIN" --maxslices 8 >"$TMP/rqs.log" 2>&1 &&
     pycheck "$TMP/rqs.pddl" "$TMP/rqs.answer" <<'EOF'
import sys,re
prob=open(sys.argv[1]).read(); ans=open(sys.argv[2]).read()
goals=re.findall(r'\(at (pkg\d+) ([\w-]+)\)',prob.split('(:goal')[1])
assert len(goals)==4, goals
last=max(int(m) for m in re.findall(r'\(HOLDS \(AT \w+ [\w-]+\) (\d+)\)',ans))
held={(p.lower(),l.lower()) for p,l in re.findall(rf'\(HOLDS \(AT (\w+) ([\w-]+)\) {last}\)',ans)}
# at least one delivered (zero-cost loads may carry another along)
assert len([g for g in goals if g in held])>=1, held
EOF
  then pass; else fail "solution delivered nothing; see $TMP/rqs.log"; fi
else
  name "--require some holds in an actual solution"; echo "SKIP (no MaxSAT solver)"
fi

# ------------------------------------------------------------ destinations ---

name "--destinations N gives each package N distinct destinations"
gen --style clique --clique-size 4 --number-cliques 2 --packages 3 \
    --require some --preferences 1 9 --destinations 3 --seed 5 > "$TMP/gp0.pddl"
if pycheck "$TMP/gp0.pddl" <<'EOF'
import sys,re,collections
t=open(sys.argv[1]).read(); goal=t.split('(:goal')[1]
prefs=re.findall(r'\(preference ([\w-]+) \(at (\w+) ([\w-]+)\) (\d+)\)',goal)
assert len(prefs)==9, prefs                      # 3 packages x 3 destinations
by=collections.defaultdict(list)
for nm,pkg,place,w in prefs: by[pkg].append(place)
assert sorted(by)==['pkg1','pkg2','pkg3'], list(by)
for pkg,places in by.items():
    assert len(places)==3 and len(set(places))==3, (pkg,places)   # distinct
# no destination is where the package already is
start=dict(re.findall(r'\(at (pkg\d+) ([\w-]+)\)',t.split('(:init')[1].split('(:goal')[0]))
for pkg,places in by.items():
    assert start[pkg] not in places, (pkg,start[pkg],places)
# the weights still span L..H, each used once
assert sorted(int(w) for _,_,_,w in prefs)==list(range(1,10))
EOF
then pass; else fail "per-package destinations wrong"; fi

name "several destinations get indexed preference names"
if pycheck "$TMP/gp0.pddl" <<'EOF'
import sys,re
goal=open(sys.argv[1]).read().split('(:goal')[1]
names=re.findall(r'\(preference ([\w-]+) ',goal)
assert sorted(names)==sorted(f'deliver-pkg{p}-{i}' for p in (1,2,3) for i in (1,2,3)), names
EOF
then pass; else fail "preference names not disambiguated"; fi

name "one destination keeps the unindexed preference name"
gen --style grid --dimensions 4 4 --packages 2 --require some --preferences 1 5 \
    --destinations 1 --seed 5 > "$TMP/gp1.pddl"
if pycheck "$TMP/gp1.pddl" <<'EOF'
import sys,re
goal=open(sys.argv[1]).read().split('(:goal')[1]
assert sorted(re.findall(r'\(preference ([\w-]+) ',goal))==['deliver-pkg1','deliver-pkg2']
EOF
then pass; else fail "single-destination naming changed"; fi

# Refused before --require existed: several destinations demanded --preferences.
name "--destinations without --preferences: one (or ...) per package"
gen --style grid --dimensions 4 4 --packages 3 --destinations 2 --seed 5 > "$TMP/gp2.pddl"
if ! grep -q '(preference' "$TMP/gp2.pddl" && req_check "$TMP/gp2.pddl" 3 - package \
   && [ "$(grep -c '^        (or (at pkg' "$TMP/gp2.pddl")" -eq 3 ]
then pass; else fail "$(sed -n '/(:goal/,$p' "$TMP/gp2.pddl")"; fi

if command -v "${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" >/dev/null 2>&1; then
  name "--require all with destinations: every package arrives"
  gen --style clique --clique-size 3 --number-cliques 2 --packages 2 --trucks 2 \
      --preferences 1 4 --destinations 2 --seed 11 > "$TMP/gp3.pddl"
  if WEIGHTED_SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}" bash "$REPO/bin/planner.sh" \
       "$TMP/gp3.pddl" --domain "$DOMAIN" --maxslices 10 >"$TMP/gp3.log" 2>&1 &&
     pycheck "$TMP/gp3.pddl" "$TMP/gp3.answer" <<'EOF'
import sys,re,collections
prob=open(sys.argv[1]).read(); ans=open(sys.argv[2]).read()
want=collections.defaultdict(set)
for pkg,place in re.findall(r'\(preference [\w-]+ \(at (\w+) ([\w-]+)\)',prob.split('(:goal')[1]):
    want[pkg].add(place)
last=max(int(m) for m in re.findall(r'\(HOLDS \(AT \w+ [\w-]+\) (\d+)\)',ans))
held={(p.lower(),l.lower()) for p,l in re.findall(rf'\(HOLDS \(AT (\w+) ([\w-]+)\) {last}\)',ans)}
# every package reached one of ITS OWN destinations, whatever it cost
for pkg,places in want.items():
    assert any((pkg,pl) in held for pl in places), (pkg,places)
EOF
  then pass; else fail "a package missed all its destinations; see $TMP/gp3.log"; fi
else
  name "--require all with destinations: every package arrives"; echo "SKIP (no MaxSAT solver)"
fi

# ------------------------------------------------------ truck goals (--packages 0) ---

name "--packages 0: no packages, no airplanes, one goal per truck"
gen --style clique --clique-size 4 --number-cliques 3 --trucks 5 --packages 0 --seed 21 > "$TMP/tg.pddl"
if pycheck "$TMP/tg.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
objs=t.split('(:objects')[1].split('(:init')[0]
assert '- package' not in objs and '- airplane' not in objs, objs
trucks=re.search(r'^\s+(.*) - truck\)?$',objs,re.M).group(1).split()
assert len(trucks)==5, trucks
goal=t.split('(:goal')[1]
atoms=re.findall(r'\(at (\w+) ([\w-]+)\)',goal)
assert sorted(a for a,_ in atoms)==sorted(trucks), atoms      # each truck exactly once
assert 'pkg' not in t.split('(:init')[1]
EOF
then pass; else fail "truck-goal problem malformed"; fi

name "--packages 0 (clique): destination in the truck's own clique, not its start"
# Roads never leave a clique, so a destination in another clique is unreachable.
# Checked over several seeds: one draw could land in the right clique by luck.
TG_BAD=""
for s in 1 2 3 4 5 6 7 8; do
  gen --style clique --clique-size 3 --number-cliques 3 --trucks 6 --packages 0 --seed $s > "$TMP/tgc.pddl"
  pycheck "$TMP/tgc.pddl" <<'EOF' || { TG_BAD=$s; break; }
import sys,re
t=open(sys.argv[1]).read()
init=t.split('(:init')[1].split('(:goal')[0]
start=dict(re.findall(r'\(at (truck\d+) ([\w-]+)\)',init))
goal=dict(re.findall(r'\(at (truck\d+) ([\w-]+)\)',t.split('(:goal')[1]))
for tr,dest in goal.items():
    assert dest!=start[tr], (tr,dest)
    assert dest.split('-')[0]==start[tr].split('-')[0], (tr,start[tr],dest)
EOF
done
if [ -z "$TG_BAD" ]; then pass; else fail "a truck sent out of its clique or to its start (seed $TG_BAD)"; fi

name "--packages 0 (grid): destinations differ from starts"
gen --style grid --dimensions 3 3 --trucks 4 --packages 0 --seed 22 > "$TMP/tgg.pddl"
if pycheck "$TMP/tgg.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
start=dict(re.findall(r'\(at (truck\d+) ([\w-]+)\)',t.split('(:init')[1].split('(:goal')[0]))
goal=dict(re.findall(r'\(at (truck\d+) ([\w-]+)\)',t.split('(:goal')[1]))
assert len(goal)==4 and all(goal[k]!=start[k] for k in goal), (start,goal)
EOF
then pass; else fail "grid truck goals wrong"; fi

# A road-only grid: no airports, so no airplanes and no routes.
name "--airports 0 --packages 0: a road-only grid"
gen --style grid --dimensions 3 3 --airports 0 --trucks 1 --packages 0 --seed 26 > "$TMP/tg0.pddl"
if pycheck "$TMP/tg0.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
objs=t.split('(:objects')[1].split('(:init')[0]
assert '- airport' not in objs and '- airplane' not in objs, objs
assert '(route ' not in t and ';; no airports;' in t, t[:400]
assert len(re.findall(r'\(at truck1 [\w-]+\)',t.split('(:goal')[1]))==1
EOF
then pass; else fail "zero-airport grid malformed"; fi

name "--packages 0 still takes --airplanes N"
# (the airplane line is the last object line here, so it carries the close paren)
if gen --style grid --dimensions 3 3 --packages 0 --airplanes 2 --seed 23 | grep -q ' - airplane)\{0,1\}$'
then pass; else fail "no airplanes emitted"; fi

name "--packages 0: every goal option applies per truck"
gen --style grid --dimensions 4 4 --trucks 3 --packages 0 --preferences 1 5 \
    --destinations 2 --seed 24 > "$TMP/tgp.pddl"
if pycheck "$TMP/tgp.pddl" <<'EOF'
import sys,re,collections
t=open(sys.argv[1]).read()
goal=t.split('(:goal')[1]
prefs=re.findall(r'\(preference ([\w-]+) \(at (truck\d+) ([\w-]+)\) [\d.]+\)',goal)
assert len(prefs)==6, prefs                                  # 3 trucks x 2 destinations
assert all(n==f'reach-{tr}-{i}' for (n,tr,_),i in zip(prefs,[1,2]*3)), prefs
per=collections.Counter(tr for _,tr,_ in prefs)
assert all(v==2 for v in per.values()), per
ors=re.findall(r'^\s+\(or \(at (truck\d+) [\w-]+\) \(at (truck\d+) [\w-]+\)\)$',goal,re.M)
assert len(ors)==3 and all(a==b for a,b in ors), ors           # require all: one OR per truck
EOF
then pass; else fail "goal options not applied per truck"; fi

name "--packages 0: --require some counts trucks"
gen --style grid --dimensions 4 4 --trucks 4 --packages 0 --require some --preferences 1 5 \
    --seed 25 > "$TMP/tgm.pddl"
req_check "$TMP/tgm.pddl" 1 - truck 2>"$TMP/tgm.err" && pass || fail "$(tail -1 "$TMP/tgm.err")"

name "--packages 0 is recorded"
if grep -qx ';;   --packages 0' "$TMP/tg.pddl"
then pass; else fail "$(grep '^;;   --' "$TMP/tg.pddl" | tr '\n' ' ')"; fi

# ---------------------------------------------------------------- knockout ---
#
# ko_check <knocked.pddl> <full.pddl> <N> : the knocked-out file against the SAME
# seed generated without --knockout.  Per road network (each clique, or the whole
# grid): the kept two-way roads are a subset of the full ones, exactly
# floor(E*(100-N)/100) of them, every one present in both directions, and the
# network still connected.  And nothing but the roads differs: every non-road,
# non-comment line is identical, since the knockout draws from its own stream.
cat > "$TMP/ko_check.py" <<'EOF'
import sys,re
ko,full,n=open(sys.argv[1]).read(),open(sys.argv[2]).read(),int(sys.argv[3])
def roads(t): return set(re.findall(r'^\s+\(road ([\w-]+) ([\w-]+)\)$',t,re.M))
def body(t): return [l for l in t.splitlines()
                     if not l.startswith(';;') and not re.match(r'^\s+\(road ',l)]
R,F=roads(ko),roads(full)
assert R<=F, R-F
assert all((b,a) in R for a,b in R), 'a road kept in one direction only'
assert body(ko)==body(full), 'something besides the roads changed'
und=lambda s:{frozenset(e) for e in s}
# networks: the connected components of the FULL road graph
adj={}
for a,b in F: adj.setdefault(a,set()).add(b)
seen,nets=set(),[]
for s in adj:
    if s in seen: continue
    comp,stack={s},[s]
    while stack:
        for y in adj[stack.pop()]:
            if y not in comp: comp.add(y); stack.append(y)
    seen|=comp; nets.append(comp)
for net in nets:
    fe=[e for e in und(F) if e<=net]; ke=[e for e in und(R) if e<=net]
    want=len(fe)*(100-n)//100
    assert len(ke)==want, (sorted(net)[0],len(ke),want,len(fe))
    reach,stack={min(net)},[min(net)]
    while stack:
        x=stack.pop()
        for e in ke:
            if x in e:
                (y,)=e-{x}
                if y not in reach: reach.add(y); stack.append(y)
    assert reach==net, ('disconnected',sorted(net-reach))
EOF
ko_check() { python3 "$TMP/ko_check.py" "$@"; }

name "--knockout (grid): exact count, two-way, connected, over seeds"
KO_BAD=""
for n in 10 25 37; do for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 5 5 --seed "$s" > "$TMP/kf.pddl"
  gen --style grid --dimensions 5 5 --seed "$s" --knockout "$n" > "$TMP/kk.pddl"
  ko_check "$TMP/kk.pddl" "$TMP/kf.pddl" "$n" 2>"$TMP/ko.err" || { KO_BAD="N=$n seed=$s: $(tail -1 "$TMP/ko.err")"; break 2; }
done; done
[ -z "$KO_BAD" ] && pass || fail "$KO_BAD"

name "--knockout (clique): each clique loses N%, stays connected"
KO_BAD=""
for n in 20 50 60; do for s in 1 2 3 4 5 6; do
  gen --style clique --clique-size 5 --number-cliques 3 --seed "$s" > "$TMP/kf.pddl"
  gen --style clique --clique-size 5 --number-cliques 3 --seed "$s" --knockout "$n" > "$TMP/kk.pddl"
  ko_check "$TMP/kk.pddl" "$TMP/kf.pddl" "$n" 2>"$TMP/ko.err" || { KO_BAD="N=$n seed=$s: $(tail -1 "$TMP/ko.err")"; break 2; }
done; done
[ -z "$KO_BAD" ] && pass || fail "$KO_BAD"

name "--knockout 0 is byte-identical to omitting it"
gen --style clique --clique-size 4 --number-cliques 2 --seed 11 > "$TMP/k0a.pddl"
gen --style clique --clique-size 4 --number-cliques 2 --seed 11 --knockout 0 > "$TMP/k0b.pddl"
cmp -s "$TMP/k0a.pddl" "$TMP/k0b.pddl" && pass || fail "--knockout 0 changed the file"

name "--knockout: different seeds knock out different roads"
for s in 1 2 3 4 5; do
  # one line per seed: its sorted road set, flattened
  gen --style grid --dimensions 4 4 --seed "$s" --knockout 30 | grep '(road ' | sort | tr -d '\n'
  echo
done | sort -u > "$TMP/ko.sets"
[ "$(wc -l < "$TMP/ko.sets" | tr -d ' ')" -ge 3 ] && pass \
  || fail "only $(wc -l < "$TMP/ko.sets" | tr -d ' ') distinct road sets over 5 seeds"

name "--knockout at exactly the spanning-tree bound is accepted"
# clique of 4: 6 roads, tree of 3 = 50%, so 50 keeps exactly the tree
gen --style clique --clique-size 4 --number-cliques 2 --seed 3 > "$TMP/kf.pddl"
gen --style clique --clique-size 4 --number-cliques 2 --seed 3 --knockout 50 > "$TMP/kk.pddl"
ko_check "$TMP/kk.pddl" "$TMP/kf.pddl" 50 2>"$TMP/ko.err" && pass || fail "$(tail -1 "$TMP/ko.err")"

# The bound is PER NETWORK.  Cliques are all one size today, so a global check
# happened to agree; with networks of different sizes a small tight one could
# borrow slack from a big one.  No style builds that, so call knockout-roads
# directly: a 3-place clique (3 roads, tree 2: 66.7%) and a 6-place one (15 roads,
# tree 5: 33.3%).  At 40% the global ratio (7/18 = 38.9%) would pass, but the
# small clique cannot keep 60% -- refused, naming the binding 66.7%.
name "--knockout: the tree bound is checked per network"
OUT="$(sbcl --noinform --non-interactive --eval "(load \"$REPO/SatPlan/ppgen.lisp\")" --eval '
  (let* ((small (list (quote a1) (quote a2) (quote a3)))
         (big (list (quote b1) (quote b2) (quote b3) (quote b4) (quote b5) (quote b6)))
         (roads (ppgen::clique-roads (list small big))))
    (handler-case (progn (ppgen::knockout-roads roads (list small big) 40 1)
                         (format t "~&ACCEPTED~%"))
      (error (e) (format t "~&ERROR ~a~%" e))))' 2>&1)"
grep -q 'ERROR Knockout value set too high, 66.7% required' <<<"$OUT" && pass \
  || fail "$(grep 'ACCEPTED\|ERROR' <<<"$OUT")"

# All of the seed feeds the knockout's random state: seeds that differ only
# above bit 64 used to knock out identical roads.  Grid place names do not
# depend on the seed, so the road sets compare directly.
name "--knockout: seeds differing above bit 64 knock out different roads"
R1="$(gen --style grid --dimensions 5 5 --knockout 30 --seed 1 | grep '(road ' | sort)"
R2="$(gen --style grid --dimensions 5 5 --knockout 30 --seed 18446744073709551617 | grep '(road ' | sort)"
[[ -n "$R1" && "$R1" != "$R2" ]] && pass || fail "identical road sets"

name "--knockout is recorded when set"
grep -qx ';;   --knockout 50' "$TMP/kk.pddl" && ! grep -q -- '--knockout' "$TMP/kf.pddl" && pass \
  || fail "$(grep -- '--knockout' "$TMP/kk.pddl" "$TMP/kf.pddl")"

# ------------------------------------------------------------------ oneway ---
#
# ow_check <oneway.pddl> <base.pddl> <N> : the --oneway file against the SAME seed
# and options without --oneway.  The oracle is its own graph code:
#   - every road of the base survives in at least one direction, and nothing but
#     road lines (and comments) differs;
#   - per road network (the components of the base's roads), at most
#     floor(E*N/100) of its E two-way roads are one-way, and the header's count
#     is the total; when fewer than asked for, the header says so and every
#     road left two-way truly cannot be turned (dropping either direction
#     would leave some place unable to reach another);
#   - every place reaches every other in its network, following directions.
# It refuses to pass vacuously: with N > 0 some road must have been turned.
cat > "$TMP/ow_check.py" <<'EOF'
import sys,re
ow,base,n=open(sys.argv[1]).read(),open(sys.argv[2]).read(),int(sys.argv[3])
def roads(t): return set(re.findall(r'^\s+\(road ([\w-]+) ([\w-]+)\)$',t,re.M))
def body(t): return [l for l in t.splitlines()
                     if not l.startswith(';;') and not re.match(r'^\s+\(road ',l)]
R,B=roads(ow),roads(base)
assert R<=B, R-B
assert all((a,b) in R or (b,a) in R for a,b in B), 'a road vanished in both directions'
assert body(ow)==body(base), 'something besides the roads changed'
def comps(E):
    adj={}
    for a,b in E: adj.setdefault(a,set()).add(b); adj.setdefault(b,set()).add(a)
    seen,out=set(),[]
    for s in adj:
        if s in seen: continue
        c,st={s},[s]
        while st:
            for y in adj[st.pop()]:
                if y not in c: c.add(y); st.append(y)
        seen|=c; out.append(c)
    return out
def strongly_connected(E,net):
    fw,bw={},{}
    for a,b in E:
        if a in net: fw.setdefault(a,[]).append(b); bw.setdefault(b,[]).append(a)
    def reach(adj):
        s=min(net); r,st={s},[s]
        while st:
            for y in adj.get(st.pop(),[]):
                if y not in r: r.add(y); st.append(y)
        return r
    return reach(fw)==net and reach(bw)==net
total=0; short=False
for net in comps(B):
    two=[(a,b) for a,b in B if a<b and a in net and (b,a) in B]
    one=[(a,b) for a,b in two if ((a,b) in R)!=((b,a) in R)]
    want=len(two)*n//100
    assert len(one)<=want, (min(net),len(one),want)
    assert strongly_connected(R,net), ('not strongly connected',min(net))
    if len(one)<want:
        short=True
        for a,b in two:
            if (a,b) in R and (b,a) in R:
                for d in ((a,b),(b,a)):
                    assert not strongly_connected(R-{d},net), ('could have turned',d)
    total+=len(one)
m=re.search(r'^;; One-way (\d+)%: (\d+) of (\d+) two-way roads made one-way(.*)$',ow,re.M)
assert m and int(m.group(1))==n and int(m.group(2))==total, (m and m.groups(),total)
assert short==('all that could be' in m.group(4)), 'header and shortfall disagree'
assert n==0 or total>0, 'vacuous: nothing was turned'
EOF
ow_check() { python3 "$TMP/ow_check.py" "$@"; }

name "--oneway (grid): count, every place reaches every other, over seeds"
OW_BAD=""
for n in 10 30 60; do for k in 0 20; do for s in 1 2 3 4; do
  gen --style grid --dimensions 5 5 --seed "$s" --knockout "$k" > "$TMP/of.pddl"
  gen --style grid --dimensions 5 5 --seed "$s" --knockout "$k" --oneway "$n" > "$TMP/ow.pddl"
  ow_check "$TMP/ow.pddl" "$TMP/of.pddl" "$n" 2>"$TMP/ow.err" || { OW_BAD="N=$n knockout=$k seed=$s: $(tail -1 "$TMP/ow.err")"; break 3; }
done; done; done
[ -z "$OW_BAD" ] && pass || fail "$OW_BAD"

name "--oneway (clique): per clique, still strongly connected"
OW_BAD=""
for n in 25 50; do for s in 1 2 3; do
  gen --style clique --clique-size 5 --number-cliques 3 --seed "$s" > "$TMP/of.pddl"
  gen --style clique --clique-size 5 --number-cliques 3 --seed "$s" --oneway "$n" > "$TMP/ow.pddl"
  ow_check "$TMP/ow.pddl" "$TMP/of.pddl" "$n" 2>"$TMP/ow.err" || { OW_BAD="N=$n seed=$s: $(tail -1 "$TMP/ow.err")"; break 2; }
done; done
[ -z "$OW_BAD" ] && pass || fail "$OW_BAD"

# 100% cannot be met on a knocked-out grid (its bridges must stay two-way):
# every road that can be turned is, the rest provably cannot, and both the
# header and stderr say so.
name "--oneway 100: as many as possible, the rest provably bridges, warned"
gen --style grid --dimensions 5 5 --seed 2 --knockout 30 > "$TMP/of.pddl"
WARN="$(bash "$PPGEN" --style grid --dimensions 5 5 --seed 2 --knockout 30 --oneway 100 -o "$TMP/ow.pddl" 2>&1 >/dev/null)"
if ow_check "$TMP/ow.pddl" "$TMP/of.pddl" 100 2>"$TMP/ow.err" \
   && grep -q 'all that could be' "$TMP/ow.pddl" && grep -q 'without cutting a place off' <<<"$WARN"; then pass
else fail "$(tail -1 "$TMP/ow.err") | header: $(grep '^;; One-way' "$TMP/ow.pddl") | stderr: $WARN"; fi

name "--oneway 0 is byte-identical to omitting it"
gen --style grid --dimensions 4 4 --seed 11 --knockout 20 > "$TMP/o0a.pddl"
gen --style grid --dimensions 4 4 --seed 11 --knockout 20 --oneway 0 > "$TMP/o0b.pddl"
cmp -s "$TMP/o0a.pddl" "$TMP/o0b.pddl" && pass || fail "--oneway 0 changed the file"

name "--oneway is recorded when set, and replays"
gen --style grid --dimensions 5 5 --seed 7 --oneway 40 > "$TMP/ow.pddl"
ARGS_OW=$(sed -n 's/^;;   \(--.*\)$/\1/p' "$TMP/ow.pddl" | tr '\n' ' ')
# shellcheck disable=SC2086
gen $ARGS_OW > "$TMP/ow2.pddl"
grep -qx ';;   --oneway 40' "$TMP/ow.pddl" && cmp -s "$TMP/ow.pddl" "$TMP/ow2.pddl" && pass \
  || fail "not recorded, or the recorded settings do not replay"

# --------------------------------------------------------- mindist, maxdist ---
#
# md_check <file> <LO> <HI> <kind> [roads] : the oracle is its own BFS over the
# file's roads -- plus its routes when the goal objects are packages, since a
# truck cannot fly, unless "roads" says no airplane can fly them either.  Every goal object starts at p1-1; each destination is from LO to
# HI steps away (HI 0: no upper bound); an object's destinations are distinct.
# It refuses to pass vacuously: some place other than the origin must lie
# outside the range, so the filter actually excluded something.
cat > "$TMP/md_check.py" <<'EOF'
import sys,re,collections
t=open(sys.argv[1]).read(); lo=int(sys.argv[2]); hi=int(sys.argv[3]) or 10**9; kind=sys.argv[4]
init,goal=t.split('(:goal')
E=re.findall(r'^\s+\(road ([\w-]+) ([\w-]+)\)$',init,re.M)
if kind=='pkg' and sys.argv[5:]!=['roads']: E+=re.findall(r'^\s+\(route ([\w-]+) ([\w-]+)\)$',init,re.M)
adj=collections.defaultdict(list)
for a,b in E: adj[a].append(b)
d={'p1-1':0}; q=collections.deque(['p1-1'])
while q:
    x=q.popleft()
    for y in adj[x]:
        if y not in d: d[y]=d[x]+1; q.append(y)
starts=re.findall(rf'\(at ({kind}\d+) ([\w-]+)\)',init)
assert starts and all(p=='p1-1' for _,p in starts), starts
dest=collections.defaultdict(list)
for o,p in re.findall(rf'\(at ({kind}\d+) ([\w-]+)\)',goal): dest[o].append(p)
assert set(dest)=={o for o,_ in starts}, (dest,starts)
for o,ps in dest.items():
    for p in ps: assert lo<=d[p]<=hi, (o,p,d[p])
# with preferences each destination appears in the disjunction AND a preference:
# count distinct ones via the preference lines when present
pref=collections.defaultdict(list)
for o,p in re.findall(rf'\(preference [\w-]+ \(at ({kind}\d+) ([\w-]+)\)',goal): pref[o].append(p)
for o,ps in (pref or dest).items(): assert len(ps)==len(set(ps)), (o,ps)
assert any(0<v<lo or v>hi for v in d.values()), 'vacuous: nothing outside the range'
EOF
md_check() { python3 "$TMP/md_check.py" "$@"; }

name "--mindist: packages at p1-1, destinations >= N by road or flight"
MD_BAD=""
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 2 --packages 4 --require some --preferences 1 5 \
      --destinations 3 --mindist 4 --seed "$s" > "$TMP/md.pddl"
  md_check "$TMP/md.pddl" 4 0 pkg 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

name "--maxdist: packages at p1-1, destinations <= M by road or flight"
MD_BAD=""
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 2 --packages 4 --destinations 2 \
      --maxdist 3 --seed "$s" > "$TMP/md.pddl"
  md_check "$TMP/md.pddl" 1 3 pkg 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

name "--mindist N --maxdist M: every destination in the range"
MD_BAD=""
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 7 7 --airports 1 --packages 3 --destinations 2 \
      --mindist 3 --maxdist 5 --seed "$s" > "$TMP/md.pddl"
  md_check "$TMP/md.pddl" 3 5 pkg 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

name "--mindist N --maxdist N: every destination exactly N steps away"
MD_BAD=""
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 3 --packages 3 --preferences 1 5 \
      --destinations 2 --mindist 3 --maxdist 3 --seed "$s" > "$TMP/md.pddl"
  md_check "$TMP/md.pddl" 3 3 pkg 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

# Each bound alone leaves the other side open: over seeds some destination
# lies beyond it, or a lone bound would act as an exact distance.
name "a lone --mindist or --maxdist leaves the other side open"
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 1 --packages 3 --mindist 4 --seed "$s"
done > "$TMP/md.lo"
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 1 --packages 3 --maxdist 4 --seed "$s"
done > "$TMP/md.hi"
if pycheck "$TMP/md.lo" "$TMP/md.hi" <<'EOF'
import sys,re
def ds(f):
    g=' '.join(re.findall(r'\(:goal[^:]*',open(f).read()))
    # one airport, so road distance from p1-1 is Manhattan
    return {int(r)+int(c)-2 for r,c in re.findall(r'\(at pkg\d+ p(\d+)-(\d+)\)',g)}
lo,hi=ds(sys.argv[1]),ds(sys.argv[2])
assert min(lo)>=4 and max(lo)>4, lo
assert max(hi)<=4 and min(hi)<4, hi
EOF
then pass; else fail "a lone bound put every destination at exactly N"; fi

# A truck cannot fly: with an airport at the origin, a route makes a far
# corner one step away for a package -- a truck must still drive there.
name "--mindist --maxdist --packages 0: distance by road alone"
MD_BAD="" MD_AIR=0
for s in 1 2 3 4 5 6 7 8; do
  gen --style grid --dimensions 5 5 --airports 2 --trucks 3 --packages 0 \
      --mindist 6 --maxdist 6 --seed "$s" > "$TMP/md.pddl"
  if grep -q '(route p1-1 ' "$TMP/md.pddl"; then MD_AIR=$((MD_AIR+1)); fi
  md_check "$TMP/md.pddl" 6 6 truck 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
# vacuous unless some seed put an airport at the origin
[ "$MD_AIR" -eq 0 ] && MD_BAD="${MD_BAD:-no seed put an airport at p1-1}"
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

# Routes are flown by airplanes: with none, a package too goes by road alone.
name "--mindist --maxdist --airplanes 0: package distance by road alone"
MD_BAD="" MD_AIR=0
for s in 1 2 3 4 5 6 7 8; do
  gen --style grid --dimensions 5 5 --airports 2 --packages 3 --airplanes 0 \
      --mindist 6 --maxdist 6 --seed "$s" > "$TMP/md.pddl"
  if grep -q '(route p1-1 ' "$TMP/md.pddl"; then MD_AIR=$((MD_AIR+1)); fi
  md_check "$TMP/md.pddl" 6 6 pkg roads 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ "$MD_AIR" -eq 0 ] && MD_BAD="${MD_BAD:-no seed put an airport at p1-1}"
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

# One airport has no routes, so the distance is by road even with airplanes,
# and the header must not claim flights were counted.
name "one airport: the distance header says by road"
if gen --style grid --dimensions 5 5 --airports 1 --packages 2 --mindist 3 --seed 1 \
   | grep -qx ';; Every destination is at least 3 steps from the origin by road ([0-9]* places qualify).'
then pass; else fail "header claims flights with no routes"; fi

name "--mindist measures over the roads left by --knockout"
MD_BAD=""
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 1 --packages 3 --knockout 30 \
      --mindist 7 --maxdist 7 --seed "$s" > "$TMP/md.pddl"
  md_check "$TMP/md.pddl" 7 7 pkg 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

# md_check's BFS follows each (road a b) from a to b only, so it measures
# one-way roads in their direction.  --airports 1: no routes, roads alone.
name "--mindist measures over one-way roads in their direction"
MD_BAD=""
for s in 1 2 3 4 5 6; do
  gen --style grid --dimensions 6 6 --airports 1 --packages 3 --oneway 50 \
      --mindist 7 --maxdist 7 --seed "$s" > "$TMP/md.pddl"
  grep -q '^;; One-way 50%' "$TMP/md.pddl" || { MD_BAD="seed $s: no one-way roads made"; break; }
  md_check "$TMP/md.pddl" 7 7 pkg 2>"$TMP/md.err" || { MD_BAD="seed $s: $(tail -1 "$TMP/md.err")"; break; }
done
[ -z "$MD_BAD" ] && pass || fail "$MD_BAD"

# Only the goal objects' starts, the goals and the comments change: trucks,
# airports, airplanes and roads are those of the same seed without the option.
name "--mindist / --maxdist change only the starts and goals"
gen --style grid --dimensions 5 5 --packages 3 --seed 4 > "$TMP/mdf.pddl"
gen --style grid --dimensions 5 5 --packages 3 --mindist 3 --seed 4 > "$TMP/md.pddl"
gen --style grid --dimensions 5 5 --packages 3 --maxdist 3 --seed 4 > "$TMP/mdh.pddl"
if pycheck "$TMP/md.pddl" "$TMP/mdh.pddl" "$TMP/mdf.pddl" <<'EOF'
import sys,re
def body(t): return [l for l in t.split('(:goal')[0].splitlines()
                     if not l.startswith(';;') and not re.match(r'^\s+\(at pkg',l)]
a,h,b=(open(f).read() for f in sys.argv[1:])
assert body(a)==body(b) and body(h)==body(b)
EOF
then pass; else fail "something besides starts and goals changed"; fi

name "--mindist / --maxdist are recorded only when set"
grep -qx ';;   --mindist 3' "$TMP/md.pddl" && ! grep -q -- '--maxdist' "$TMP/md.pddl" \
  && grep -qx ';;   --maxdist 3' "$TMP/mdh.pddl" && ! grep -q -- '--mindist' "$TMP/mdh.pddl" \
  && ! grep -q -- '--mindist\|--maxdist' "$TMP/mdf.pddl" && pass \
  || fail "$(grep -- '--mindist\|--maxdist' "$TMP/md.pddl" "$TMP/mdh.pddl" "$TMP/mdf.pddl")"

# ------------------------------------------------- recorded settings / seed ---

name "the file records every setting, defaults included"
if pycheck "$TMP/c.pddl" <<'EOF'
import sys,re
t=open(sys.argv[1]).read()
p=dict(re.findall(r'^;;   (--[\w-]+) (.+)$',t,re.M))
for f in ('--style','--clique-size','--number-cliques','--trucks','--airplanes',
          '--packages','--drive-cost','--fly-cost','--preferences',
          '--destinations','--require','--seed'):
    assert f in p, (f,p)
assert p['--style']=='clique' and p['--drive-cost']=='1' and p['--fly-cost']=='3'
assert p['--preferences']=='none' and p['--destinations']=='1' and p['--require']=='all'
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

name "the recorded settings block replays byte for byte"
RT_BAD=""
for spec in "--style clique --clique-size 4 --number-cliques 3 --seed 1" \
            "--style grid --dimensions 5 5 --airports 3 --packages 4 --preferences 1 7 --require some --seed 42" \
            "--style clique --clique-size 4 --number-cliques 2 --packages 3 --preferences 1 9 --destinations 3 --seed 5" \
            "--style clique --clique-size 4 --number-cliques 2 --trucks 3 --packages 0 --preferences 1 5 --destinations 2 --seed 6" \
            "--style grid --dimensions 4 4 --trucks 4 --packages 0 --airplanes 1 --preferences 1 5 --require some --seed 7" \
            "--style grid --dimensions 4 4 --packages 3 --destinations 2 --require some --seed 12" \
            "--style clique --clique-size 5 --number-cliques 2 --knockout 40 --seed 8" \
            "--style grid --dimensions 5 5 --knockout 25 --seed 9" \
            "--style grid --dimensions 6 6 --packages 3 --require some --preferences 1 5 --destinations 2 --mindist 3 --maxdist 3 --seed 10" \
            "--style grid --dimensions 5 5 --trucks 2 --packages 0 --knockout 20 --mindist 4 --seed 11" \
            "--style grid --dimensions 6 6 --packages 3 --maxdist 4 --seed 14"
do
  gen $spec > "$TMP/rt1.pddl"
  # feed the file's own settings block back in as the command line
  gen $(sed -n 's/^;;   //p' "$TMP/rt1.pddl" | tr '\n' ' ') > "$TMP/rt2.pddl"
  diff -q "$TMP/rt1.pddl" "$TMP/rt2.pddl" >/dev/null || { RT_BAD="$spec"; break; }
done
if [ -z "$RT_BAD" ]; then pass; else fail "settings block did not replay: $RT_BAD"; fi

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
err "airplanes with no airports are rejected" "over 0 groups"     --style grid --dimensions 3 3 --airports 0 --airplanes 2
err "a non-numeric count is rejected"      "expects a non-negative" --style grid --dimensions 3 x
err "an unknown flag is rejected"          "unknown option"       --style grid --dimensions 3 3 --bogus 1
err "--preferences with one bound is rejected" "two numbers"       --style grid --dimensions 3 3 --preferences 5
err "--preferences with a non-number is rejected" "expects a number" --style grid --dimensions 3 3 --preferences lo hi
err "a numeric --require is rejected"     "all or some"          --style grid --dimensions 4 4 --require 2
err "--require none is rejected"           "all or some"          --style grid --dimensions 4 4 --require none
err "weights on goals all forced are rejected" "cannot change the plan" --style grid --dimensions 4 4 --packages 3 --preferences 1 5
err "weights on one forced goal (some, one object) are rejected" "with a single package makes every goal" --style grid --dimensions 4 4 --packages 1 --require some --preferences 1 5
err "--destinations 0 is rejected"         "at least 1"           --style grid --dimensions 4 4 --destinations 0
err "more destinations than places is rejected" "distinct destination" --style grid --dimensions 1 3 --packages 2 --destinations 3
err "--packages 0 with no trucks is rejected" "at least one truck" --style grid --dimensions 3 3 --packages 0 --trucks 0
err "more truck destinations than its clique holds is rejected" "per truck" --style clique --clique-size 3 --number-cliques 2 --packages 0 --destinations 3
# The exact wording asked for, with M = spanning-tree size / roads as a percent:
# a 4x4 grid has 24 roads and a 15-road tree (62.5%); a clique of 4 has 6 and 3.
err "--knockout above the tree bound (grid) names M" "Knockout value set too high, 62.5% required to maintain connectivity" --style grid --dimensions 4 4 --knockout 50
err "--knockout above the tree bound (clique) names M" "Knockout value set too high, 50% required to maintain connectivity" --style clique --clique-size 4 --number-cliques 2 --knockout 51
err "--knockout above 100 is rejected"     "0 to 100"             --style grid --dimensions 4 4 --knockout 101
err "a negative --knockout is rejected"    "non-negative"         --style grid --dimensions 4 4 --knockout -5
err "--oneway above 100 is rejected"       "0 to 100"             --style grid --dimensions 4 4 --oneway 101
err "a negative --oneway is rejected"      "non-negative"         --style grid --dimensions 4 4 --oneway -5
# 3x3 with one airport: road distances 0..4, and one place at 4
err "--mindist beyond the farthest place is rejected" "only 0 places are at least 5 steps from the origin p1-1 by road (the farthest is 4)" --style grid --dimensions 3 3 --airports 1 --mindist 5
err "--maxdist too near for the destinations is rejected" "only 2 places are at most 1 step from" --style grid --dimensions 3 3 --airports 1 --destinations 3 --maxdist 1
err "a range with too few places is rejected" "only 5 places are 2 to 3 steps from" --style grid --dimensions 3 3 --airports 1 --destinations 6 --mindist 2 --maxdist 3
err "an exact distance with too few places is rejected" "only 1 place is exactly 4 steps" --style grid --dimensions 3 3 --airports 1 --destinations 2 --mindist 4 --maxdist 4
err "--mindist names the truck's road-only distance" "by road (the farthest" --style grid --dimensions 3 3 --airports 1 --packages 0 --mindist 9
err "--maxdist below --mindist is rejected" "is below --mindist" --style grid --dimensions 4 4 --mindist 3 --maxdist 2
err "--mindist 0 is rejected"              "at least 1"           --style grid --dimensions 4 4 --mindist 0
err "--maxdist 0 is rejected"              "at least 1"           --style grid --dimensions 4 4 --maxdist 0
err "--mindist is rejected for clique"     "grid style only"      --style clique --clique-size 3 --number-cliques 2 --mindist 2
err "--maxdist is rejected for clique"     "grid style only"      --style clique --clique-size 3 --number-cliques 2 --maxdist 2

# ------------------------------------------------------------ solvability ---

SOLVER="${WEIGHTED_SOLVER:-EvalMaxSAT_bin}"
if command -v "$SOLVER" >/dev/null 2>&1; then
  name "a preference problem translates and solves"
  gen --style clique --clique-size 3 --number-cliques 2 --packages 3 \
      --require some --preferences 1 5 --seed 8 > "$TMP/pr.pddl"
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

  # Solving is the real test of the own-clique rule: a destination in another
  # clique would make the problem UNSAT at every horizon.
  name "clique --packages 0 solves, every truck at its destination"
  gen --style clique --clique-size 3 --number-cliques 2 --trucks 3 --packages 0 --seed 9 > "$TMP/ts.pddl"
  if WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" "$TMP/ts.pddl" \
       --domain "$DOMAIN" --maxslices 6 >"$TMP/ts.log" 2>&1 &&
     pycheck "$TMP/ts.pddl" "$TMP/ts.answer" <<'EOF'
import sys,re
prob=open(sys.argv[1]).read(); ans=open(sys.argv[2]).read()
goal=re.findall(r'\(at (truck\d+) ([\w-]+)\)',prob.split('(:goal')[1])
last=max(int(m) for m in re.findall(r'\(HOLDS \(AT \w+ [\w-]+\) (\d+)\)',ans))
for tr,dest in goal:
    assert f'(HOLDS (AT {tr.upper()} {dest.upper()}) {last})' in ans, (tr,dest)
EOF
  then pass; else fail "truck-goal problem did not solve; see $TMP/ts.log"; fi

  name "grid --packages 0 --destinations 2: each truck reaches one of its own"
  gen --style grid --dimensions 3 3 --trucks 3 --packages 0 --preferences 1 5 \
      --destinations 2 --seed 10 > "$TMP/tsg.pddl"
  if WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" "$TMP/tsg.pddl" \
       --domain "$DOMAIN" --maxslices 8 >"$TMP/tsg.log" 2>&1 &&
     pycheck "$TMP/tsg.pddl" "$TMP/tsg.answer" <<'EOF'
import sys,re,collections
prob=open(sys.argv[1]).read(); ans=open(sys.argv[2]).read()
want=collections.defaultdict(set)
for tr,place in re.findall(r'\(preference [\w-]+ \(at (truck\d+) ([\w-]+)\)',prob.split('(:goal')[1]):
    want[tr].add(place)
last=max(int(m) for m in re.findall(r'\(HOLDS \(AT \w+ [\w-]+\) (\d+)\)',ans))
held={(t.lower(),l.lower()) for t,l in re.findall(rf'\(HOLDS \(AT (\w+) ([\w-]+)\) {last}\)',ans)}
for tr,places in want.items():
    assert any((tr,p) in held for p in places), (tr,places)
EOF
  then pass; else fail "a truck missed all its destinations; see $TMP/tsg.log"; fi

  # Connectivity is what keeps a knocked-out problem solvable: with roads gone
  # the routes get longer, but every delivery is still reachable.
  name "grid --knockout: a generated problem still solves"
  gen --style grid --dimensions 4 4 --airports 2 --packages 2 --knockout 30 --seed 12 > "$TMP/ks.pddl"
  if WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" "$TMP/ks.pddl" \
       --domain "$DOMAIN" --maxslices 16 >"$TMP/ks.log" 2>&1 &&
     grep -q 'SOLVED' "$TMP/ks.log"
  then pass; else fail "knocked-out problem did not solve; see $TMP/ks.log"; fi

  # every drive in the plan follows a road as written: (drive t a b) needs
  # (road a b), so a one-way road is never driven against its direction
  name "grid --oneway: solves, and no drive goes against a one-way road"
  gen --style grid --dimensions 4 4 --airports 0 --trucks 1 --packages 2 --oneway 60 --seed 12 > "$TMP/os.pddl"
  if (cd "$TMP" && WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" os.pddl \
        --domain "$DOMAIN" --maxslices 24 >"$TMP/os.log" 2>&1) && grep -q 'SOLVED' "$TMP/os.log" &&
     python3 - "$TMP/os.pddl" "$TMP/os.answer" <<'EOF'
import sys,re
p,a=open(sys.argv[1]).read().lower(),open(sys.argv[2]).read().lower()
roads=set(re.findall(r'\(road ([\w-]+) ([\w-]+)\)',p))
one=[r for r in roads if (r[1],r[0]) not in roads]
drives=re.findall(r'\(occurs \(drive [\w-]+ ([\w-]+) ([\w-]+)\) \d+\)',a)
assert one and drives, ('vacuous', len(one), len(drives))
assert all(d in roads for d in drives), [d for d in drives if d not in roads]
EOF
  then pass; else fail "see $TMP/os.log"; fi

  name "grid --mindist N --maxdist N: a generated problem still solves"
  gen --style grid --dimensions 3 3 --airports 1 --packages 2 --mindist 3 --maxdist 3 --seed 13 > "$TMP/mds.pddl"
  if WEIGHTED_SOLVER="$SOLVER" bash "$REPO/bin/planner.sh" "$TMP/mds.pddl" \
       --domain "$DOMAIN" --maxslices 16 >"$TMP/mds.log" 2>&1 &&
     grep -q 'SOLVED' "$TMP/mds.log"
  then pass; else fail "maxdist problem did not solve; see $TMP/mds.log"; fi
else
  echo "  (skipping solvability: no MaxSAT solver '$SOLVER' on PATH)"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
