#!/bin/bash
#
# run-test-circuit-viz.sh -- the circuit visualizer (SatPlan/Visualizer:
# circuit.html, server/circuit_server.py, server/circuit-server.lisp).
#
#   1. circuit.js is what build.sh makes from src/ (skipped under another tsc).
#   2. The server's parsing: the goal's hypotheses and evidence files.
#   3. The numbers, against an INDEPENDENT oracle: the bundled example's theory
#      is regenerated from its .wff and counted by SharpSAT-TD (wmc.sh, Z with the
#      evidence and hypothesis added as unit clauses), a counter independent of the circuit.  For each
#      evidence set the server's P(h|E) must equal the oracle's marginal of the
#      hypothesis atom, Z(E,h)/Z(E), and its likelihood posterior must equal
#      P(h|E)/P(h) normalized over the hypotheses (P(E) cancels), to 1e-9.
#      Refuses to pass vacuously: the evidence must move some hypothesis.
#   4. Contradictory evidence is reported unsat; ordering forms, compound
#      formulas and unknown atoms are refused with reasons, and the Lisp
#      process keeps answering.
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
cleanup() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"; }
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
g = S.goal_literals(open(ex + "/grid3x3-1.pddl").read())
assert g == ["(at pkg1 p1-3)", "(at pkg1 p2-1)", "(at pkg2 p2-1)", "(at pkg2 p1-1)"], g
g2 = S.goal_literals("(define (problem x) (:goal (and (or (at a p) (at b q)) (at c r) "
                     "(preference w (at d s)) (or (at a p) (at e t)))))")
assert g2 == ["(at a p)", "(at b q)", "(at c r)", "(at e t)"], g2
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
try:
    S.parse_evidence("(and (occurs (a) 1)")
    raise SystemExit("an unclosed list was accepted")
except ValueError:
    pass
assert S.lisp_string('a"b\\c') == '"a\\"b\\\\c"'
EOF
name "goal hypotheses and evidence files parse as specified"
if out=$(python3 "$TMP/parse.py" "$VIZ/server" "$EX" 2>&1); then pass; else fail "$(tail -2 <<<"$out")"; fi

# ------------------------------------------------------------- the numbers
cat > "$TMP/numbers.py" <<'EOF'
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import circuit_server as S
ex, tmp, fifo_lisp = sys.argv[2], sys.argv[3], sys.argv[4]
oracle = sys.argv[5] == "1"
goals = S.goal_literals(open(ex + "/grid3x3-1.pddl").read())
lisp = S.Lisp(fifo_lisp, heap_mb=2048)
lisp.start()
info = lisp.load(os.path.join(ex, "grid3x3-1.dnnf"), goals)
H = info["horizon"]
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
if oracle:
    z0 = Z([])
    assert abs(results["none"]["z"] - z0) <= 1e-9 * z0, ("Z", results["none"]["z"], z0)
    prior = oracle_marginals([])
    for name, ev in sets.items():
        want = oracle_marginals(ev)
        got = results[name]
        for i, a in enumerate(atoms):
            assert abs(got["marginal"][i] - want[a]) < 1e-9, (name, a, got["marginal"][i], want[a])
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
  name "contradiction unsat; ordering, compound, unknown refused; still answers"
  pass
else
  fail "$(tail -3 <<<"$out")"
  name "contradiction unsat; ordering, compound, unknown refused; still answers"
  fail "see above"
fi

# -------------------------------------------------------------------- HTTP
name "HTTP: page, script, every API route; recovers from a killed Lisp"
python3 "$SERVER" --port 0 > "$TMP/server.log" 2>&1 &
SPID=$!
URL=""
for _ in $(seq 1 60); do
  URL=$(sed -n 's/^circuit visualizer: \(http[^ ]*\).*/\1/p' "$TMP/server.log")
  [ -n "$URL" ] && break
  sleep 0.5
done
cat > "$TMP/http_check.py" <<'EOF'
import json, os, subprocess, sys, urllib.request, urllib.error
url = sys.argv[1]
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
assert sessions and sessions[0]["name"] == "grid3x3-1", sessions
sid = sessions[0]["id"]
r = post("api/load", {"id": sid})
assert r["circuit"]["horizon"] == 7 and "(:goal" in r["problem"], list(r)
acts = json.loads(get("api/actions")[0])["actions"]
assert "(occurs (drive truck1 p2-3 p3-3) 1)" in acts, len(acts)
ev = json.loads(get(f"api/evidence?id={sid}&file=grid3x3-1-pkg1-p1-3-obs5.txt")[0])
assert len(ev["items"]) == 5, ev
q1 = post("api/query", {"literals": [ev["items"][0]["literal"]]})
assert q1["ok"] and q1["marginal"][0] > 0.5, q1
bad = post("api/query", {"literals": "not a list"})
assert "error" in bad, bad
# kill the Lisp child: the next query restarts it, reloads the circuit, answers
subprocess.run(["pkill", "-f", "cv-serve"], check=False)
for attempt in range(2):
    q2 = post("api/query", {"literals": [ev["items"][0]["literal"]]})
    if q2.get("ok"):
        break
assert q2.get("ok") and abs(q2["marginal"][0] - q1["marginal"][0]) < 1e-12, q2
print("ok")
EOF
if [ -z "$URL" ]; then
  fail "the server did not start: $(tail -3 "$TMP/server.log")"
elif out=$(python3 "$TMP/http_check.py" "$URL" 2>&1); then pass
else fail "$(tail -3 <<<"$out") | server: $(tail -2 "$TMP/server.log")"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
