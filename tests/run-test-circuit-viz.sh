#!/bin/bash
#
# run-test-circuit-viz.sh -- the circuit visualizer (SatPlan/Visualizer:
# circuit.html, server/circuit_server.py, server/circuit-server.lisp).
#
#   1. circuit.js is what build.sh makes from src/ (skipped under another tsc).
#   2. The server's parsing: the goal's hypotheses and evidence files, and
#      which evidence files it offers (none that are ordering-only, none that
#      a longer file extends).
#   3. The numbers, against an INDEPENDENT oracle: the bundled example's theory
#      is regenerated from its .wff and counted by SharpSAT-TD (wmc.sh, Z with the
#      evidence and hypothesis added as unit clauses), a counter independent of the circuit.  For each
#      evidence set the server's P(h|E) must equal the oracle's marginal of the
#      hypothesis atom, Z(E,h)/Z(E), and its likelihood posterior must equal
#      P(h|E)/P(h) normalized over the hypotheses (P(E) cancels), to 1e-9.
#      Refuses to pass vacuously: the evidence must move some hypothesis.  The
#      prior P(h) must equal the oracle's evidence-free marginal.  Compound
#      hypotheses likewise (grid3x3-1-pairs: four (and ...)s, scored through
#      recognize.sh's (rechyp<i>) atoms), the oracle counting each
#      conjunction's own literals, so the hypothesis-to-atom map is checked.
#   4. Contradictory evidence is reported unsat; ordering forms, compound
#      formulas and unknown atoms are refused with reasons, and the Lisp
#      process keeps answering.  A goal recognize.sh refuses (two (or ...)
#      sets, a plain conjunction) is shown literal by literal, the uniform-prior
#      column normalized within each goal line.
#   5. HTTP: the server starts on a free port, serves the page, its script and
#      every API route, and recovers when its Lisp process is killed.
#
# Needs python3 and sbcl; the oracle needs SharpSAT-TD (case 3 skips without it);
# case 1 needs tsc.  Run from anywhere:  bash tests/run-test-circuit-viz.sh

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # no __pycache__ beside the server
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
VIZ="$REPO/SatPlan/Visualizer"
EX="$VIZ/circuit-examples"
SERVER="$VIZ/server/circuit_server.py"
TMP="$(mktemp -d /tmp/fifo-cviz-XXXXXX)"; TMP="$(cd "$TMP" && pwd -P)"
SPID=""
cleanup() { [ -n "$SPID" ] && { pkill -P "$SPID" 2>/dev/null; kill "$SPID" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT

for t in python3 sbcl; do
  command -v "$t" >/dev/null 2>&1 || { echo "=== circuit visualizer: $t not found: skipped ==="; exit 0; }
done

PASS=0; FAIL=0; SKIP=0
name() { printf '  %-68s ... ' "$1"; }
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP ($1)"; SKIP=$((SKIP+1)); }

echo "=== circuit visualizer ==="

# ------------------------------------------------------------------- build
name "circuit.js is up to date (build.sh)"
if ! command -v tsc >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  skip "no tsc/node"
else
  built_with=$(head -1 "$VIZ/circuit.js" | sed -n 's/.* with tsc \([^ ]*\) .*/\1/p')
  if [ "$built_with" != "$(tsc --version | awk '{print $2}')" ]; then
    skip "built with tsc $built_with"
  elif mkdir -p "$TMP/build" && bash "$VIZ/build.sh" --outdir "$TMP/build" >/dev/null 2>&1 \
       && cmp -s "$TMP/build/circuit.js" "$VIZ/circuit.js"; then pass
  else fail "rebuild: bash SatPlan/Visualizer/build.sh"; fi
fi

# ----------------------------------------------------------------- parsing
cat > "$TMP/parse.py" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import circuit_server as S
ex = sys.argv[2]
items, un = S.parse_evidence(open(ex + "/grid3x3-1-pkg1-p1-3-obs5.txt").read())
assert [i["slice"] for i in items] == [1, 2, 3, 4, 5] and not un, (items, un)
assert items[1]["literal"] == "(occurs (load pkg1 truck1 p3-3) 2)", items[1]
items, un = S.parse_evidence("(and (occurs (b) 3) (not (occurs (a) 1)) (occurs (c) 3))")
assert [(i["slice"], i["positive"]) for i in items] == [(1, False), (3, True), (3, True)], items
assert items[1]["literal"] == "(occurs (b) 3)", "file order within a slice"
items, un = S.parse_evidence(open(ex + "/grid3x3-1-pkg1-p1-3-ord1.txt").read())
assert not items and un == ["(occur-in-order (drive truck1 p2-3 p3-3))"], (items, un)
items, un = S.parse_evidence("(or (occurs (a) 1) (occurs (b) 1))")
assert not items and len(un) == 1, (items, un)
for bad, why in (("(and (occurs (a) 1)", "an unclosed list"),
                 ("(occurs (a) 1)\n(occurs (b) 2)", "a multi-form file (FiFO reads only the first)")):
    try:
        S.parse_evidence(bad)
        raise SystemExit(why + " was accepted")
    except ValueError:
        pass
# (not A B) reads as (not A) elsewhere in FiFO: here it is refused, not half-used
items, un = S.parse_evidence("(and (not (occurs (a) 1) (occurs (b) 2)) (occurs (c) 3))")
assert [i["slice"] for i in items] == [3] and len(un) == 1 and "one argument" in un[0], (items, un)
assert S.lisp_string('a"b\\c') == '"a\\"b\\\\c"'
# the files offered: not the ordering-only one, not pkg1-p1-3-obs1 (obs5 of the
# same solution extends it); the other solutions' obs1 files are kept though
# they start like obs5; an obs3 that diverges from obs5 is kept; an unparseable
# file is kept
import glob, os, shutil, tempfile
d = tempfile.mkdtemp()
for f in glob.glob(ex + "/grid3x3-1-*.txt"):
    shutil.copy(f, d)
open(d + "/grid3x3-1-pkg1-p1-3-obs3.txt", "w").write(
    "(and (occurs (drive truck1 p2-3 p3-3) 1) (occurs (drive truck1 p3-3 p2-3) 2))")
open(d + "/grid3x3-1-bad.txt", "w").write("(and (occurs (a) 1)")
kept, hidden = S.useful_evidence(sorted(glob.glob(d + "/*.txt")))
names = [os.path.basename(k) for k in kept]
assert names == ["grid3x3-1-bad.txt", "grid3x3-1-pkg1-p1-3-obs3.txt", "grid3x3-1-pkg1-p1-3-obs5.txt",
                 "grid3x3-1-pkg1-p2-1-obs1.txt", "grid3x3-1-pkg2-p1-1-obs1.txt",
                 "grid3x3-1-pkg2-p2-1-obs1.txt"] and hidden == 2, (names, hidden)
shutil.rmtree(d)
# a session filters its directories' files, but files named one by one are
# always offered (here obs1, though obs5 extends it, and the ordering file)
s = S.make_session("0", ex + "/grid3x3-1.pddl", ex + "/grid3x3-1.dnnf",
                   [ex + "/grid3x3-1-pkg1-p1-3-obs1.txt", ex + "/grid3x3-1-pkg1-p1-3-ord1.txt", ex])
menu, hidden = S.menu_files(s)
assert ex + "/grid3x3-1-pkg1-p1-3-obs1.txt" in menu and ex + "/grid3x3-1-pkg1-p1-3-ord1.txt" in menu, menu
assert len(menu) == len(set(menu)) == 6 and hidden == 0, (menu, hidden)   # each once, though named and in ex
EOF
name "evidence files parse as specified; multi-form and (not A B) refused; useless files hidden"
if out=$(python3 "$TMP/parse.py" "$VIZ/server" "$EX" 2>&1); then pass; else fail "$(tail -2 <<<"$out")"; fi

# ------------------------------------------------------------- the numbers
cat > "$TMP/numbers.py" <<'EOF'
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import circuit_server as S
ex, tmp, fifo_lisp = sys.argv[2], sys.argv[3], sys.argv[4]
oracle = sys.argv[5] == "1"
lisp = S.Lisp(fifo_lisp, heap_mb=2048)
lisp.start()
circuit = os.path.join(ex, "grid3x3-1.dnnf")
info = lisp.load(circuit, os.path.join(ex, "grid3x3-1.pddl"))
H = info["horizon"]
goals = [h["goal"] for h in info["hypotheses"]]
assert goals == ["(at pkg1 p1-3)", "(at pkg1 p2-1)", "(at pkg2 p2-1)", "(at pkg2 p1-1)"], goals
assert H == 7 and all(h["present"] for h in info["hypotheses"]), info
atoms = [f"(holds {g} {H})" for g in goals]
obs5 = [i["literal"] for i in S.parse_evidence(open(ex + "/grid3x3-1-pkg1-p1-3-obs5.txt").read())[0]]
sets = {"none": [], "one": obs5[:1], "three": obs5[:3],
        "negated": ["(not (occurs (drive truck1 p2-3 p3-3) 1))"],
        "mixed": [obs5[0], "(not (occurs (load pkg1 truck1 p3-3) 2))"]}

theory = open(os.path.join(tmp, "grid3x3-1.scnf")).read()
WMC = os.path.join(os.path.dirname(fifo_lisp), "bin", "wmc.sh")
counted = [0]

def Z(units):
    """The weighted model count of the theory with UNITS (literal texts) added
    as unit clauses, by SharpSAT-TD (wmc.sh) -- not the circuit."""
    path = os.path.join(tmp, f"z{counted[0]}.scnf")
    counted[0] += 1
    with open(path, "w") as f:
        f.write(theory + "\n" + "\n".join(f"(OR {u.upper()})" for u in units) + "\n")
    out = subprocess.run(["bash", WMC, path, "--counter", "sharpsat-td"],
                         capture_output=True, text=True, cwd=tmp).stdout
    m = [l for l in out.splitlines() if l.startswith("(WMC ")]
    assert m, ("no count", out[-400:])
    return float(m[0][5:].rstrip(")"))

def oracle_marginals(evidence):
    """{atom: P(atom | evidence)} = Z(E, atom) / Z(E)."""
    ze = Z(evidence)
    return {a: Z(evidence + [a]) / ze for a in atoms}

results = {}
for name, ev in sets.items():
    r = lisp.call(S.query_command(ev))
    assert r["ok"] and not r["unsat"], (name, r)
    results[name] = r
moved = max(abs(a - b) for a, b in zip(results["none"]["marginal"], results["three"]["marginal"]))
assert moved > 0.2, ("vacuous: three observations hardly moved any hypothesis", moved)
report = {"moved": round(moved, 3)}
want_of = {}                      # evidence-set name -> the oracle's marginals
if oracle:
    z0 = Z([])
    assert abs(results["none"]["z"] - z0) <= 1e-9 * z0, ("Z", results["none"]["z"], z0)
    prior = oracle_marginals([])
    for name, ev in sets.items():
        want = want_of[name] = oracle_marginals(ev)
        got = results[name]
        for i, a in enumerate(atoms):
            assert abs(got["marginal"][i] - want[a]) < 1e-9, (name, a, got["marginal"][i], want[a])
            assert abs(got["prior"][i] - prior[a]) < 1e-9, (name, a, got["prior"][i], prior[a])
        ratio = [want[a] / prior[a] if prior[a] > 0 else 0.0 for a in atoms]
        post = [x / sum(ratio) for x in ratio]
        for i in range(len(atoms)):
            assert abs(got["posterior"][i] - post[i]) < 1e-9, (name, i, got["posterior"][i], post[i])
    report["checked"] = len(sets)
# contradiction and refusals
r = lisp.call(S.query_command([obs5[0], "(not " + obs5[0] + ")"]))
assert r["ok"] and r["unsat"], r
r = lisp.call(S.query_command(["(occurs (drive truck1 p3-3 p3-3) 1)"]))      # no such road
assert r["ok"] and r["unsat"] or (not r["ok"] and r["unknown"]), r
r = lisp.call(S.query_command(["(occur-in-order (drive truck1 p2-3 p3-3))",
                               "(or (occurs (drive truck1 p2-3 p3-3) 1) (occurs (drive truck1 p2-3 p2-2) 1))",
                               "(occurs (fly plane9 x y) 1)"]))
assert not r["ok"] and len(r["refused"]) == 2 and r["unknown"] == ["(occurs (fly plane9 x y) 1)"], r
assert "recompil" in r["refused"][0]["reason"], r
r = lisp.call(S.query_command(obs5[:1]))
assert r["ok"] and abs(r["marginal"][0] - results["one"]["marginal"][0]) < 1e-12, "the process stopped answering"

# hypotheses by recognize.sh's rule (recognition-goal.lisp), on the same circuit
base = open(os.path.join(ex, "grid3x3-1.pddl")).read()
def problem_with(goal, name):
    i = base.index("(:goal")
    j = base.index("(:metric")
    path = os.path.join(tmp, name + ".pddl")
    open(path, "w").write(base[:i] + "(:goal " + goal + ")\n\n  " + base[j:])
    return path
# exclusivity clauses are dropped, not taken for hypotheses
r = lisp.load(circuit, problem_with("(and (or (at pkg1 p1-3) (at pkg1 p2-1)) "
                                    "(or (not (at pkg1 p1-3)) (not (at pkg1 p2-1))))", "excl"))
assert [h["goal"] for h in r["hypotheses"]] == ["(at pkg1 p1-3)", "(at pkg1 p2-1)"], r["hypotheses"]
# a FIRST hypothesis with no atom in the circuit: its marginal is null, the
# reply still valid JSON with one entry per hypothesis
r = lisp.load(circuit, problem_with("(or (at pkg9 p1-1) (at pkg1 p1-3))", "missing"))
assert [h["present"] for h in r["hypotheses"]] == [False, True], r["hypotheses"]
q = lisp.call(S.query_command(obs5[:1]))
assert q["marginal"][0] is None and q["posterior"][0] is None and q["marginal"][1] > 0.5, q
# a failed load (no such circuit) leaves the loaded circuit and hypotheses whole
try:
    lisp.load(os.path.join(tmp, "no-such.dnnf"), problem_with("(or (at pkg1 p1-3))", "one"))
    raise SystemExit("a missing circuit loaded")
except S.LispError:
    pass
q2 = lisp.call(S.query_command(obs5[:1]))
assert q2["marginal"] == q["marginal"], ("a failed load disturbed the loaded circuit", q2, q)
# recognize.sh's single set: one group, and a note only when it refuses
r = lisp.load(circuit, os.path.join(ex, "grid3x3-1.pddl"))
assert r["note"] is None and {h["group"] for h in r["hypotheses"]} == {0}, r
# a conjunction of two (or ...) sets, which recognize.sh refuses: shown literal
# by literal, one group per line, the note saying why; the uniform-prior column
# is the likelihood normalized WITHIN each line, not across both
r = lisp.load(circuit, problem_with("(and (or (at pkg1 p1-3) (at pkg1 p2-1)) "
                                    "(or (at pkg2 p2-1) (at pkg2 p1-1)))", "two"))
assert [h["group"] for h in r["hypotheses"]] == [0, 0, 1, 1] and "hypothesis sets" in r["note"], r
q = lisp.call(S.query_command(obs5[:1]))
assert abs(sum(q["posterior"]) - 2) < 1e-12 and abs(q["posterior"][0] - results["one"]["posterior"][0]) > 1e-3, \
    ("vacuous: per-line normalization made no difference", q, results["one"])
# ... against the oracle: P(h|E)/P(h) normalized within each line (the same
# four atoms as the oracle's, in the same order)
def per_line(want, lines, neg=(False,) * 4):
    m = [1 - want[a] if n else want[a] for a, n in zip(atoms, neg)]
    p = [1 - prior[a] if n else prior[a] for a, n in zip(atoms, neg)]
    ratio = [x / y if y > 0 else 0.0 for x, y in zip(m, p)]
    tot = {g: sum(r for r, h in zip(ratio, lines) if h == g) for g in set(lines)}
    return m, p, [r / tot[g] for r, g in zip(ratio, lines)]
if oracle:
    m, p, post = per_line(want_of["one"], [0, 0, 1, 1])
    for i in range(4):
        assert abs(q["marginal"][i] - m[i]) < 1e-9 and abs(q["prior"][i] - p[i]) < 1e-9 \
            and abs(q["posterior"][i] - post[i]) < 1e-9, (i, q, m, p, post)
# a nested (and ...) is flattened, as the page does: the same two lines
r = lisp.load(circuit, problem_with("(and (and (or (at pkg1 p1-3) (at pkg1 p2-1))) "
                                    "(or (at pkg2 p2-1) (at pkg2 p1-1)))", "nested"))
assert [h["group"] for h in r["hypotheses"]] == [0, 0, 1, 1] and all(h["present"] for h in r["hypotheses"]), r
# lines of negations only, with no other (or ...) for them to accompany, are
# hypotheses, not dropped; (not A) is scored as A's complement
r = lisp.load(circuit, problem_with("(and (or (not (at pkg1 p1-3)) (not (at pkg1 p2-1))) "
                                    "(or (not (at pkg2 p2-1)) (not (at pkg2 p1-1))))", "negs"))
assert [h["group"] for h in r["hypotheses"]] == [0, 0, 1, 1] and all(h["present"] for h in r["hypotheses"]) \
    and r["hypotheses"][0]["atom"] == "(not (holds (at pkg1 p1-3) 7))", r
q = lisp.call(S.query_command(obs5[:1]))
if oracle:
    m, p, post = per_line(want_of["one"], [0, 0, 1, 1], (True,) * 4)
    for i in range(4):
        assert abs(q["marginal"][i] - m[i]) < 1e-9 and abs(q["prior"][i] - p[i]) < 1e-9 \
            and abs(q["posterior"][i] - post[i]) < 1e-9, (i, q, m, p, post)
# a plain conjunction: each conjunct its own line (a single hypothesis, 1.0)
r = lisp.load(circuit, problem_with("(and (at pkg1 p1-3) (at pkg2 p2-1))", "conj"))
assert [h["group"] for h in r["hypotheses"]] == [0, 1] and "conjunction" in r["note"], r
q = lisp.call(S.query_command(obs5[:1]))
assert q["posterior"] == [1.0, 1.0], q
lisp.stop()
print(json.dumps(report))
EOF

# the oracle's theory: the example's .wff instantiated (with its own axioms copy)
cp "$EX/grid3x3-1.wff" "$EX/satplan.wff" "$TMP/"
ORACLE=0
if command -v sharpSAT >/dev/null 2>&1; then
  if (cd "$TMP" && sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
        --eval "(instantiate \"grid3x3-1.wff\" :scnfile \"grid3x3-1.scnf\")" >/dev/null 2>&1) \
     && [ -s "$TMP/grid3x3-1.scnf" ]; then ORACLE=1; fi
fi
name "P(h|E) and the likelihood posterior equal SharpSAT-TD's, 5 evidence sets"
if out=$(python3 "$TMP/numbers.py" "$VIZ/server" "$EX" "$TMP" "$FIFO_LISP" "$ORACLE" 2>&1); then
  if [ "$ORACLE" = 1 ]; then pass; else skip "no sharpSAT, or the theory did not instantiate; numbers not checked"; fi
  name "unsat, refusals; hypotheses by FiFO rule; failed load leaves circuit whole"
  pass
else
  fail "$(tail -3 <<<"$out")"
  name "unsat, refusals; hypotheses by FiFO rule; failed load leaves circuit whole"
  fail "see above"
fi

# ------------------------------------------------- compound hypotheses
# grid3x3-1-pairs: the same world, its goal ONE disjunction of four
# conjunctions (both packages' destinations).  recognize.sh scores each through
# a derived atom it creates, (rechyp<i>), and the circuit (d4, projected onto
# the actions and those four atoms) keeps no (holds (at ..) 8) atom at all -- so
# the server can only get a conjunction right through cv--derived-atom's
# mapping.  The oracle never uses the rechyp atoms: it counts the full theory
# with the conjunction's OWN literals added, Z(E, a, b) / Z(E), so the
# hypothesis-to-atom mapping is checked independently of it.
cat > "$TMP/compound.py" <<'EOF'
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import circuit_server as S
ex, tmp, fifo_lisp = sys.argv[2], sys.argv[3], sys.argv[4]
lisp = S.Lisp(fifo_lisp, heap_mb=2048)
lisp.start()
info = lisp.load(os.path.join(ex, "grid3x3-1-pairs.dnnf"), os.path.join(ex, "grid3x3-1-pairs.pddl"))
H = info["horizon"]
conj = [("(at pkg1 p2-3)", "(at pkg2 p3-3)"), ("(at pkg1 p2-2)", "(at pkg2 p3-3)"),
        ("(at pkg1 p2-3)", "(at pkg2 p2-2)"), ("(at pkg1 p3-2)", "(at pkg2 p2-2)")]
hyps = info["hypotheses"]
assert H == 8 and info["note"] is None, info
assert [h["goal"] for h in hyps] == [f"(and {a} {b})" for a, b in conj], hyps
assert [h["atom"] for h in hyps] == [f"(holds (rechyp{i}) 8)" for i in range(4)], hyps
assert all(h["present"] for h in hyps) and {h["group"] for h in hyps} == {0}, hyps
sets = {"none": [],
        "load pkg2 first": ["(occurs (load pkg2 truck1 p2-3) 1)"],
        "drive first": ["(occurs (drive truck1 p2-3 p3-3) 1)"],
        "pkg1 dropped at p2-2": ["(occurs (unload pkg1 truck1 p2-2) 7)"],
        "negated": ["(not (occurs (load pkg2 truck1 p2-3) 1))"],
        "two": ["(occurs (drive truck1 p2-3 p3-3) 2)", "(occurs (unload pkg2 truck1 p3-3) 3)"]}
results = {}
for name, ev in sets.items():
    r = lisp.call(S.query_command(ev))
    assert r["ok"] and not r["unsat"], (name, r)
    results[name] = r
lisp.stop()
moved = max(abs(a - b) for a, b in zip(results["none"]["marginal"], results["pkg1 dropped at p2-2"]["marginal"]))
assert moved > 0.5, ("vacuous: the evidence hardly moved any conjunction", moved)
theory = open(os.path.join(tmp, "grid3x3-1-pairs.scnf")).read()
WMC = os.path.join(os.path.dirname(fifo_lisp), "bin", "wmc.sh")
counted = [0]
def Z(units):
    """Z of the full theory with UNITS added as unit clauses, by SharpSAT-TD."""
    path = os.path.join(tmp, f"pz{counted[0]}.scnf")
    counted[0] += 1
    with open(path, "w") as f:
        f.write(theory + "\n" + "\n".join(f"(OR {u.upper()})" for u in units) + "\n")
    out = subprocess.run(["bash", WMC, path, "--counter", "sharpsat-td"],
                         capture_output=True, text=True, cwd=tmp).stdout
    m = [l for l in out.splitlines() if l.startswith("(WMC ")]
    assert m, ("no count", out[-400:])
    return float(m[0][5:].rstrip(")"))
lits = [[f"(holds {a} {H})", f"(holds {b} {H})"] for a, b in conj]
z0 = Z([])
assert abs(results["none"]["z"] - z0) <= 1e-9 * z0, ("Z", results["none"]["z"], z0)
prior = [Z(l) / z0 for l in lits]
for name, ev in sets.items():
    ze = Z(ev)
    want = [Z(ev + l) / ze for l in lits]
    got = results[name]
    for i in range(4):
        assert abs(got["marginal"][i] - want[i]) < 1e-9, (name, i, got["marginal"][i], want[i])
        assert abs(got["prior"][i] - prior[i]) < 1e-9, (name, i, got["prior"][i], prior[i])
    ratio = [w / p if p > 0 else 0.0 for w, p in zip(want, prior)]
    post = [x / sum(ratio) for x in ratio]
    for i in range(4):
        assert abs(got["posterior"][i] - post[i]) < 1e-9, (name, i, got["posterior"][i], post[i])
print(json.dumps({"sets": len(sets), "moved": round(moved, 3), "counts": counted[0]}))
EOF
name "compound hypotheses: (and ...) scored via rechyp<i>, = SharpSAT-TD on its conjuncts"
if [ "$ORACLE" != 1 ]; then
  skip "no sharpSAT, or the theory did not instantiate"
else
  cp "$EX/grid3x3-1-pairs.wff" "$TMP/"
  if ! (cd "$TMP" && sbcl --noinform --non-interactive --eval "(load \"$FIFO_LISP/FiFO.lisp\")" \
          --eval "(instantiate \"grid3x3-1-pairs.wff\" :scnfile \"grid3x3-1-pairs.scnf\")" >/dev/null 2>&1) \
     || [ ! -s "$TMP/grid3x3-1-pairs.scnf" ]; then
    fail "grid3x3-1-pairs.wff did not instantiate"
  elif out=$(python3 "$TMP/compound.py" "$VIZ/server" "$EX" "$TMP" "$FIFO_LISP" 2>&1); then pass
  else fail "$(tail -3 <<<"$out")"; fi
fi

# -------------------------------------------------------------------- HTTP
name "a session naming a missing file is refused at startup"
if out=$(python3 "$SERVER" --port 0 --session "$TMP/no-such.pddl" "$EX/grid3x3-1.dnnf" 2>&1); then
  fail "the server started"
elif grep -q "does not exist" <<<"$out"; then pass; else fail "$(tail -1 <<<"$out")"; fi

name "--clara: every problem listed; failed/uncompiled ones not openable; pieces joined; evidence"
# a CLARA tree made here: grid3x3-1 compiled (whole circuit), grid3x3-2 compiled
# but committed in pieces, grid3x3-3 timed out, grid4x4-1 never compiled,
# grid3x3-4 recorded ok but its file is gone, grid3x3-5's circuit is on disk
# though a LATER attempt timed out; the record file ends in a half-written
# line; evidence named as CLARA's are
cat > "$TMP/clara.py" <<'EOF'
import json, os, re, shutil, subprocess, sys, time, urllib.request
sys.path.insert(0, sys.argv[1])
import circuit_server as S
ex, root, server = sys.argv[2], sys.argv[3], sys.argv[4]
fam = os.path.join(root, "TwoPackage")
for d in ("circuits", "evidence", "results"):
    os.makedirs(os.path.join(fam, d))
for p in ("grid3x3-1", "grid3x3-2", "grid3x3-3", "grid3x3-4", "grid3x3-5", "grid4x4-1"):
    shutil.copy(ex + "/grid3x3-1.pddl", os.path.join(fam, p + ".pddl"))
for p in ("grid3x3-1", "grid3x3-5"):
    shutil.copy(ex + "/grid3x3-1.dnnf", os.path.join(fam, "circuits", p + ".dnnf"))
data = open(ex + "/grid3x3-1.dnnf", "rb").read()
third = len(data) // 3 + 1
def split(content, when):
    for k, suf in enumerate(("aa", "ab", "ac")):
        f = os.path.join(fam, "circuits", f"grid3x3-2.dnnf.part-{suf}")
        open(f, "wb").write(content[k * third:(k + 1) * third])
        os.utime(f, (when, when))
split(data, time.time() - 100)
recs = [{"instance": "grid3x3-1", "status": "ok"}, {"instance": "grid3x3-2", "status": "ok"},
        {"instance": "grid3x3-3", "status": "failed"}, {"instance": "grid3x3-3", "status": "timeout", "limit_s": 7200},
        {"instance": "grid3x3-4", "status": "ok"},
        {"instance": "grid3x3-5", "status": "ok"}, {"instance": "grid3x3-5", "status": "timeout", "limit_s": 3600}]
open(os.path.join(fam, "results", "compile-d4.jsonl"), "w").write(
    "".join(json.dumps(r) + "\n" for r in recs) + '{"instance": "grid4x4-1", "sta')   # a sweep mid-write
obs5 = open(ex + "/grid3x3-1-pkg1-p1-3-obs5.txt").read()
first = "(and " + re.findall(r"\(occurs .*?\) \d+\)", obs5)[0] + ")"
for p in ("grid3x3-1", "grid3x3-2"):
    open(os.path.join(fam, "evidence", f"{p}-none.txt"), "w").write("(and)\n")
    open(os.path.join(fam, "evidence", f"{p}-pkg1-p1-3-obs100.txt"), "w").write(obs5)
    open(os.path.join(fam, "evidence", f"{p}-pkg1-p1-3-obs25.txt"), "w").write(first)   # CLARA's other condition
# goals that sort differently as text and as numbers (p10 vs p5), and an
# ordering file, which is not a condition the browser offers
for g in ("pkg1-p10-3", "pkg1-p5-3"):
    open(os.path.join(fam, "evidence", f"grid3x3-1-{g}-obs100.txt"), "w").write(obs5)
open(os.path.join(fam, "evidence", "grid3x3-1-pkg1-p1-3-ord1.txt"), "w").write("(occur-in-order (a))")
sessions, cat = S.clara_sessions(root, 0)
by = {e["name"].split("/")[1]: e for e in cat}
assert sorted(by) == ["grid3x3-1", "grid3x3-2", "grid3x3-3", "grid3x3-4", "grid3x3-5", "grid4x4-1"], sorted(by)
assert [by[p]["session"] is not None for p in sorted(by)] == [True, True, False, False, True, False], cat
assert "2 h limit" in by["grid3x3-3"]["reason"], by["grid3x3-3"]   # the LAST record counts
assert "never compiled" in by["grid4x4-1"]["reason"] and "missing" in by["grid3x3-4"]["reason"], cat
assert by["grid3x3-2"]["bytes"] == len(data) == by["grid3x3-1"]["bytes"], (by["grid3x3-2"]["bytes"], len(data))
assert (by["grid4x4-1"]["size"], by["grid4x4-1"]["instance"], by["grid4x4-1"]["sizeKey"]) == ("4×4", "1", [4, 4])
assert all(s["clara"] for s in sessions) and [bool(s["pieces"]) for s in sessions] == [False, True, False], sessions
# one row per goal, its 100% file (the page steps through it; the 25% file,
# its start, has no row), labelled with the goal alone, p5 before p10
rows = S.clara_evidence(sessions[0])
assert [(r["label"], r["file"]) for r in rows] == [
    ("no evidence", None),
    ("pkg1 at p1-3", "grid3x3-1-pkg1-p1-3-obs100.txt"),
    ("pkg1 at p5-3", "grid3x3-1-pkg1-p5-3-obs100.txt"),
    ("pkg1 at p10-3", "grid3x3-1-pkg1-p10-3-obs100.txt")], rows
assert S.clara_goal_label("pkg1-p2-4-pkg2-p3-4") == "pkg1 at p2-4, pkg2 at p3-4"
assert S.clara_goal_label("truck1-p8-4") == "truck1 at p8-4" and S.clara_goal_label("odd-name") == "odd-name"
# reassemble: joins exactly; again is a no-op; a whole file changed here is refused
whole = os.path.join(fam, "circuits", "grid3x3-2.dnnf")
pieces = sessions[1]["pieces"]
assert S.reassemble(whole, pieces) and open(whole, "rb").read() == data
assert not S.reassemble(whole, pieces)
open(whole, "ab").write(b" ")
try:
    S.reassemble(whole, pieces)
    raise SystemExit("a whole file changed since it was split was overwritten")
except ValueError:
    pass
os.remove(whole)
# a joined file is not trusted once pieces are newer (a pull brought a
# recompiled circuit): the session keeps its pieces, and the load rejoins
assert S.reassemble(whole, pieces)
s2 = next(s for s in S.clara_sessions(root, 0)[0] if s["name"].endswith("grid3x3-2"))
assert s2["pieces"] and s2["circuit"] == whole, s2
newer = data.replace(b"(:L", b"(:L ", 1)   # different bytes, as a recompiled circuit's would be
split(newer, time.time() + 100)
assert S.reassemble(whole, s2["pieces"]) and open(whole, "rb").read() == newer, "a stale join was served"
split(data, time.time() + 200)
assert S.reassemble(whole, s2["pieces"]) and open(whole, "rb").read() == data
os.remove(whole)
# --clara with no compiled circuit at all: the server still starts, with the
# catalogue and no sessions (not the bundled example)
bare = os.path.join(root + "-bare", "FourPackage")
os.makedirs(bare)
shutil.copy(ex + "/grid3x3-1.pddl", os.path.join(bare, "grid6x6-1.pddl"))
def serve(where):
    proc = subprocess.Popen([sys.executable, server, "--port", "0", "--clara", where],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        m = re.match(r"circuit visualizer: (http\S+)", line)
        if m:
            return proc, m.group(1)
    proc.wait()
    raise SystemExit("the server did not start")
def stop(proc):
    subprocess.run(["pkill", "-KILL", "-P", str(proc.pid)], check=False)   # its SBCL child first
    proc.kill()
    proc.wait()
proc, url = serve(root + "-bare")
try:
    get = lambda p: json.loads(urllib.request.urlopen(url + p, timeout=120).read())
    assert get("api/sessions") == [], "the bundled example was served under --clara"
    assert [(e["name"], e["session"]) for e in get("api/clara")] == [("FourPackage/grid6x6-1", None)]
finally:
    stop(proc)
# end to end: the server's /api/clara, and loading the pieces-only circuit joins it
proc, url = serve(root)
try:
    get = lambda p: json.loads(urllib.request.urlopen(url + p, timeout=120).read())
    api = get("api/clara")
    assert [(e["name"], e["session"] is not None, len(e["evidence"])) for e in api] == \
        [("TwoPackage/grid3x3-1", True, 4), ("TwoPackage/grid3x3-2", True, 2), ("TwoPackage/grid3x3-3", False, 0),
         ("TwoPackage/grid3x3-4", False, 0), ("TwoPackage/grid3x3-5", True, 1), ("TwoPackage/grid4x4-1", False, 0)], api
    assert all(s["clara"] for s in get("api/sessions"))
    sid = next(e["session"] for e in api if e["name"].endswith("grid3x3-2"))
    req = urllib.request.Request(url + "api/load", json.dumps({"id": sid}).encode(), {"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=300).read())
    assert r["session"]["bytes"] == len(data) and r["circuit"]["horizon"] == 7, r.get("error", r["session"])
    assert open(whole, "rb").read() == data, "the joined file"
finally:
    stop(proc)
print("ok")
EOF
mkdir -p "$TMP/clara"
if out=$(python3 "$TMP/clara.py" "$VIZ/server" "$EX" "$TMP/clara" "$SERVER" 2>&1); then pass
else fail "$(tail -3 <<<"$out")"; fi

name "HTTP: page, script, every API route; per-session queries; recovers from a killed Lisp"
# two sessions on one circuit with DIFFERENT hypothesis sets (4 and 2), so the
# reply shows which one a query ran on: one naming the session not loaded must
# reload it first
mkdir -p "$TMP/two"
python3 - "$EX/grid3x3-1.pddl" "$TMP/two/grid3x3-1.pddl" <<'EOF'
import sys
s = open(sys.argv[1]).read(); i, j = s.index("(:goal"), s.index("(:metric")
open(sys.argv[2], "w").write(s[:i] + "(:goal (or (at pkg1 p1-3) (at pkg1 p2-1)))\n\n  " + s[j:])
EOF
python3 "$SERVER" --port 0 --session "$EX/grid3x3-1.pddl" "$EX/grid3x3-1.dnnf" "$EX" \
        --session "$TMP/two/grid3x3-1.pddl" "$EX/grid3x3-1.dnnf" "$EX" > "$TMP/server.log" 2>&1 &
SPID=$!
URL=""
for _ in $(seq 1 60); do
  URL=$(sed -n 's/^circuit visualizer: \(http[^ ]*\).*/\1/p' "$TMP/server.log")
  [ -n "$URL" ] && break
  sleep 0.5
done
cat > "$TMP/http_check.py" <<'EOF'
import json, os, subprocess, sys, urllib.request, urllib.error
url, server_pid = sys.argv[1], sys.argv[2]
def get(path):
    with urllib.request.urlopen(url + path, timeout=120) as r:
        return r.read().decode(), r.headers.get("Content-Type", "")
def post(path, body):
    req = urllib.request.Request(url + path, json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())
page, ct = get("")
assert "Circuit Visualizer" in page and "circuit.js" in page and ct.startswith("text/html"), ct
js, ct = get("circuit.js")
assert "renderMap" in js and "loadSession" in js, "circuit.js"
css, _ = get("visualizer.css")
assert ".hyp" in css
try:
    get("../../lisp/FiFO.lisp")
    raise SystemExit("a file outside the page was served")
except urllib.error.HTTPError:
    pass
sessions = json.loads(get("api/sessions")[0])
assert len(sessions) == 2 and sessions[0]["name"] == "grid3x3-1" and not any(s["clara"] for s in sessions), sessions
assert json.loads(get("api/clara")[0]) == [], "no --clara: an empty CLARA catalogue (the page hides its button)"
sid, other = sessions[0]["id"], sessions[1]["id"]
r = post("api/load", {"id": sid})
assert r["circuit"]["horizon"] == 7 and "(:goal" in r["problem"], list(r)
# the circuit's size on disk, for the page's size line
assert r["session"]["bytes"] == os.path.getsize(os.path.join(os.environ["EXDIR"], "grid3x3-1.dnnf")), r["session"]
assert len(r["session"]["evidence"]) == 4 and r["session"]["hidden"] == 2 and \
    not any(f.endswith(("-ord1.txt", "-p1-3-obs1.txt")) for f in r["session"]["evidence"]), r["session"]
acts = json.loads(get(f"api/actions?id={sid}")[0])["actions"]
assert "(occurs (drive truck1 p2-3 p3-3) 1)" in acts, len(acts)
ev = json.loads(get(f"api/evidence?id={sid}&file=grid3x3-1-pkg1-p1-3-obs5.txt")[0])
assert len(ev["items"]) == 5, ev
# a file left out of the menu still opens by name (?evidence=FILE)
ev1 = json.loads(get(f"api/evidence?id={sid}&file=grid3x3-1-pkg1-p1-3-obs1.txt")[0])
assert len(ev1["items"]) == 1, ev1
lit = ev["items"][0]["literal"]
q1 = post("api/query", {"id": sid, "literals": [lit]})
assert q1["ok"] and q1["marginal"][0] > 0.5, q1
for bad in ({"id": sid, "literals": "not a list"}, {"literals": [lit]}, {"id": "99", "literals": [lit]}):
    assert "error" in post("api/query", bad), bad
# a query for the session not loaded loads it first (another tab's view), and
# back again: each answers with its own hypotheses
qo = post("api/query", {"id": other, "literals": [lit]})
assert qo["ok"] and len(qo["marginal"]) == 2 and abs(qo["marginal"][0] - q1["marginal"][0]) < 1e-12, qo
qb = post("api/query", {"id": sid, "literals": [lit]})
assert qb["ok"] and len(qb["marginal"]) == 4, qb
# kill THIS server's Lisp child (not any other's): the next query restarts it,
# reloads the circuit, and answers the same
subprocess.run(["pkill", "-KILL", "-P", server_pid], check=False)
for attempt in range(2):
    q2 = post("api/query", {"id": sid, "literals": [lit]})
    if q2.get("ok"):
        break
assert q2.get("ok") and abs(q2["marginal"][0] - q1["marginal"][0]) < 1e-12, q2
print("ok")
EOF
if [ -z "$URL" ]; then
  fail "the server did not start: $(tail -3 "$TMP/server.log")"
elif out=$(EXDIR="$EX" python3 "$TMP/http_check.py" "$URL" "$SPID" 2>&1); then pass
else fail "$(tail -3 <<<"$out") | server: $(tail -2 "$TMP/server.log")"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
