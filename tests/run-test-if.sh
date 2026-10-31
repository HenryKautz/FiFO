#!/bin/bash
#
# run-test-if.sh -- (if <test> <body>) under negation.
#
# (if test body) means test -> body: with the test false it asserts nothing
# (TRUE), so its negation is FALSE.  parse-not once returned no clauses (TRUE)
# there, so a false-test if under not, implies, equiv or a negated quantifier
# silently dropped a constraint: (implies (if <false> a) b) did not assert b,
# and (not (all x D true (if (< x 3) (p x)))) asserted nothing at all.
#
# The oracle is independent of FiFO's answers: each case's wff is instantiated,
# and a Python evaluator checks, for EVERY assignment of the case's atoms, that
# the clauses are satisfiable (existentially over any auxiliary TSEITIN atom of
# the compact encoding) exactly when the case's intended meaning -- written
# directly in Python -- is true.  Every case runs with the compact encoding on
# (the default) and off.  Mutation-checked: restoring the old (t nil) in
# parse-not fails the false-test cases.
#
# Run from anywhere:  bash tests/run-test-if.sh
# Tests the working copy's lisp/ by default; set FIFO_LISP to override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export FIFO_LISP="${FIFO_LISP:-$REPO/lisp}"
FIFO="$FIFO_LISP/FiFO.lisp"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2

command -v sbcl >/dev/null 2>&1 || { echo "sbcl not found on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH" >&2; exit 2; }

PASS=0; FAIL=0
name() { printf '  %-66s ... ' "$1"; }
pass() { echo "PASS"; PASS=$((PASS+1)); }
fail() { echo "FAIL ($1)"; FAIL=$((FAIL+1)); }

# The cases: name | atoms (space separated, as the .scnf writes them) | intended
# meaning (a Python expression over the dict v) | the wff body.  T and F are
# guards that are true and false.
cat > cases.txt <<'EOF'
not of a true-test if is not body|A|not v['A']|(not (if (< 1 2) a))
not of a false-test if is FALSE|A|False|(not (if (< 2 1) a))
implies with a false-test if antecedent is the consequent|A B|v['B']|(implies (if (< 2 1) a) b)
implies with a true-test if antecedent|A B|(not v['A']) or v['B']|(implies (if (< 1 2) a) b)
equiv with a false-test if side is the other side|A B|v['B']|(equiv (if (< 2 1) a) b)
equiv with a true-test if side|A B|v['A'] == v['B']|(equiv (if (< 1 2) a) b)
not of an and with a false-test if conjunct|A C|not v['C']|(not (and (if (< 2 1) a) c))
negated guarded all: some guarded x lacks p|(P 1) (P 2) (P 3) (P 4)|not (v['(P 1)'] and v['(P 2)'])|(domain d (set 1 2 3 4))\n(not (all x d true (if (< x 3) (p x))))
negated guarded exists is FALSE (x=3 makes the body TRUE)|(P 1) (P 2) (P 3) (P 4)|False|(domain d (set 1 2 3 4))\n(not (exists x d true (if (< x 3) (p x))))
a false-test if in an or is TRUE (unaffected)|A B|True|(or (if (< 2 1) a) b)
double negation of a false-test if is TRUE|A|True|(not (not (if (< 2 1) a)))
a bare false-test if is TRUE, a true-test one its body|A B|v['B']|(if (< 2 1) a)\n(if (< 1 2) b)
EOF

cat > check.py <<'EOF'
import sys, itertools, re
scnf, atoms_s, meaning = sys.argv[1], sys.argv[2], sys.argv[3]
atoms = re.findall(r'\([^()]*\)|[^\s()]+', atoms_s)

def read(text):                       # s-expressions -> nested lists of strings
    toks = re.findall(r'\(|\)|[^\s()]+', text)
    out, stack = [], [[]]
    for t in toks:
        if t == '(':
            stack.append([])
        elif t == ')':
            x = stack.pop(); stack[-1].append(x)
        else:
            stack[-1].append(t)
    return stack[0]

def show(x):
    return x if isinstance(x, str) else '(' + ' '.join(map(show, x)) + ')'

def lit(x):                           # -> (atom, polarity)
    if isinstance(x, list) and x and x[0] == 'NOT':
        return (show(x[1]), False)
    return (show(x), True)

text = '\n'.join(l for l in open(scnf) if not l.startswith(';'))
clauses = []
for form in read(text):
    if isinstance(form, list) and form and form[0] == 'OR':
        clauses.append([lit(x) for x in form[1:]])
    elif form == 'NIL' or form == []:          # the empty clause
        clauses.append([])
    else:
        clauses.append([lit(form)])
used = {a for c in clauses for a, _ in c}
aux = sorted(u for u in used if u not in atoms)
assert all(a.startswith('(TSEITIN') for a in aux), ('unexpected atoms', aux)
assert len(aux) <= 12, ('too many auxiliary atoms to enumerate', len(aux))

def sat(v):
    for bits in itertools.product([False, True], repeat=len(aux)):
        w = dict(v); w.update(zip(aux, bits))
        if all(any(w[a] == p for a, p in c) for c in clauses):
            return True
    return False

bad = []
for bits in itertools.product([False, True], repeat=len(atoms)):
    v = dict(zip(atoms, bits))
    want = eval(meaning, {}, {'v': v})
    if sat(v) != want:
        bad.append((v, 'FiFO says', sat(v), 'want', want))
if bad:
    print(bad[0]); sys.exit(1)
EOF

echo "=== (if ...) under negation, against a truth-table oracle ==="
while IFS='|' read -r label atoms meaning body; do
  [ -z "$label" ] && continue
  for mode in on off; do
    if [ "$mode" = off ]; then pre='(option *compact-encoding* nil)\n'; else pre=''; fi
    printf "$pre$body\n" > case.wff
    name "$label (compact $mode)"
    if ! out=$(sbcl --noinform --non-interactive --eval "(load \"$FIFO\")" \
                 --eval "(instantiate \"$TMP/case.wff\" :scnfile \"$TMP/case.scnf\")" 2>&1) \
       || [ ! -f case.scnf ]; then
      fail "instantiate failed: $(tail -2 <<<"$out" | tr '\n' ' ')"; continue
    fi
    if res=$(python3 check.py case.scnf "$atoms" "$meaning" 2>&1); then pass; else fail "$res"; fi
    rm -f case.scnf
  done
done < cases.txt

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
