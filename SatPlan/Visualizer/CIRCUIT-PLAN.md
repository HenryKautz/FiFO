# Circuit visualizer — plan

An interactive page for **plan recognition over a compiled circuit**: load a
grid planning problem together with a d-DNNF circuit compiled from its
recognition theory, add observations (from an evidence file, stepping through
it, or entered by hand), and see the probability of every goal atom — every
hypothesis — given the evidence so far.

It reuses the plan visualizer's page design and TypeScript (map, panels,
styles), adds a Python server that holds the circuit, and talks to FiFO's Lisp
for the actual evaluation.

## 1. What is computed

A FiFO circuit (`marginals.sh --solver ddnnf|d4 --save-circuit`, or the ones in
CLARA's `*/circuits/`) represents the weighted model set of a SatPlan
recognition theory: each model is a plan of the horizon's length, weighted by
exp(−cost) (action costs, preference penalties).  For pinned evidence E — a set
of literals such as `(occurs (drive truck1 p2-3 p3-3) 1)` or its negation — FiFO
evaluates the SAME circuit with those literals clamped (`ddnnf-query :clamp`):
one upward and one downward pass, no recompilation, giving Z(E) and, for every
atom, the weight of the models where it is true.

For each hypothesis h — a disjunct of the problem's goal, read at the final
slice, `(holds (at pkg1 p1-3) H)` — the page shows

- **P(h | E)** = Z(E ∧ h) / Z(E), the marginal (the number recognize.sh's
  `--method marginals` reports per hypothesis), and
- the **likelihood posterior** P(E | h) / Σ P(E | h') — Ramírez and Geffner's
  posterior with a uniform prior (recognize.sh's `--baseline per-hypothesis`).
  It is free: P(E | h) = Z(E ∧ h) / Z(h), and Z(h) comes from the one
  evidence-free pass made when the circuit loads.  It removes the model's
  implicit prior P(h) — how many cheap plans each goal has — which the
  marginal keeps.

The marginals need not sum to 1 (two packages can both be delivered); the
posterior column does.

Also shown: Z(E) / Z(∅), the probability of the evidence under the model; and
"inconsistent" when Z(E) = 0 (the evidence contradicts every plan).

**Supported evidence (v1):** unit literals over atoms the circuit KEEPS — for a
projected circuit, the actions and the goal atoms.  Each is a clamp, so a query
costs two passes over the circuit (milliseconds for TwoPackage's 3x3, about a
second for a million-node circuit).  NOT supported in v1, refused with an
explanation: ordering evidence `(occur-in-order ...)` (CLARA's `-ordK.txt`),
any non-unit formula, and literals of projected-away atoms — FiFO would have to
recompile the circuit for each (d4: minutes), which is not interactive.

## 2. Architecture

    browser (circuit.html + circuit.js)
        |  HTTP, JSON
    Python server (circuit_server.py, standard library only)
        |  pipes: one s-expression command per line in, one JSON line out
    SBCL (FiFO.lisp + wmc.lisp + ddnnf.lisp + circuit-server.lisp), kept running,
        holding the loaded circuit

- **Python** owns HTTP, static files, the list of sessions, file reading,
  evidence-file parsing, and the life of the SBCL child (start, restart on
  crash, one request at a time under a lock).
- **Lisp** owns everything about the circuit: loading it (`ddnnf-load`, text or
  binary), mapping atom text to variables, finding the hypothesis atoms,
  clamping, evaluating (`ddnnf-query`).  A small new file,
  `SatPlan/Visualizer/server/circuit-server.lisp`, wraps those calls in a
  read–eval–reply loop; it changes nothing in FiFO.
- **The page** owns the map, panels and interaction, reusing the plan
  visualizer's modules (`sexpr.ts`, `problem.ts`, `domain.ts`, `plan.ts`,
  `render.ts`) and stylesheet; only the application file is new
  (`circuit-app.ts`, compiled to `circuit.js`).

### Lisp protocol

Python writes one command per line; Lisp answers with any number of log lines
(FiFO's `;` chatter) followed by exactly one line `@@REPLY <json>`.

| Command | Reply |
|---|---|
| `(cv-load "<circuit path>" ("(at pkg1 p1-3)" ...))` | `{nvars, nodes, projected: n or null, horizon, z0, hypotheses: [{goal, atom, present}], actions: n}` — the hypothesis atoms are `(HOLDS <goal> H)`, H the highest slice of any HOLDS atom in the circuit |
| `(cv-actions)` | `{actions: ["(occurs (drive ...) 1)", ...]}` — the kept OCCURS atoms, for manual entry |
| `(cv-query ("(occurs ...)" "(not (occurs ...))" ...))` | `{ok, z, z0, pe, unsat, probs: [p per hypothesis], unknown: [...], refused: [...], ms}` |
| `(cv-quit)` | — |

Errors come back as `@@REPLY {"error": "..."}`; the loop never exits on a bad
command.  Atom text is read with the standard reader (upcased), the same atoms
the circuit's map holds.

### HTTP API

| Request | Body / reply |
|---|---|
| `GET /` , `/circuit.html`, static files | the page, its scripts, the stylesheet |
| `GET /api/sessions` | the sessions the server was started with: `[{id, name, problem, circuit, evidence: [file names]}]` |
| `POST /api/load {id}` | loads that session's circuit; replies with the problem text (for the map), the Lisp `cv-load` reply, and the session's evidence file list |
| `GET /api/evidence?id=&file=` | `{items: [{literal, slice, positive}], unsupported: [...], text}` — the file parsed into pinned literals in slice order |
| `POST /api/parse-evidence {text}` | the same, for a file the user chose in the browser |
| `GET /api/actions` | the kept action atoms |
| `POST /api/query {literals: [...]}` | the Lisp `cv-query` reply |

### Sessions

The server is started with the problem/circuit pairs it serves:

    circuit_server.py --session PROBLEM.pddl CIRCUIT.dnnf[b] [EVIDENCE-DIR-or-files...]
                      [--session ...] [--clara DIR] [--port 8765]

`--clara ~/Programming/CLARA` adds every TwoPackage (and SimpleGrid,
ThreePackage) problem that has a circuit, with its evidence files
(`evidence/NAME-*-obsK.txt`).  A self-contained small example ships in
`SatPlan/Visualizer/circuit-examples/` so the page and the tests work without
CLARA.

## 3. The page

Same layout and style as the plan visualizer:

- **Header**: a Session menu (from `/api/sessions`), the evidence-file menu of
  that session plus a file chooser for a local evidence file, and a summary
  line (problem, circuit size, horizon, projected or not).
- **Map** (left): the plan visualizer's map of the problem's initial state.
  The observed actions so far are drawn as moves in their vehicle's color (the
  renderer's `next` highlight, extended to carry slice labels); each goal
  destination is shaded by its probability (a new `goalProb` render option:
  fill opacity = P(h|E), label "G3 0.42").
- **Hypotheses** (right, top — where the Goal panel was): one row per
  hypothesis: its label and literal in its package's color, a bar and the
  number P(h|E), and the normalized share; sorted by probability, with the
  most probable highlighted.  P(E) and the query time underneath.
- **Evidence** (right, bottom — where the Solution panel was): the list of
  observations with ◀ ▶ ⏮ ⏭ to step through them (step k applies the first k),
  click a row to jump, ✕ to remove one; an "Add observation" form with an
  action box (autocompleted from the kept actions), a slice number and a
  negate checkbox; "Clear".  Each change re-queries.

Errors from the server (unsupported evidence, an unknown atom, a lost Lisp
process) show in the page's message strip, as in the plan visualizer.

## 4. Files

    SatPlan/Visualizer/
      circuit.html             the page
      circuit.js               built from src/circuit-app.ts + the shared modules
      src/circuit-app.ts       the page's application code (new)
      src/render.ts            + goalProb and labelled moves (backward compatible)
      tsconfig.circuit.json    builds circuit.js
      build.sh                 also builds circuit.js
      server/circuit_server.py the HTTP server (stdlib), SBCL child, sessions
      server/circuit-server.lisp  the Lisp side: load, hypotheses, query
      circuit-examples/        a small problem, its circuit, evidence files
      CIRCUIT-PLAN.md          this file
    tests/run-test-circuit-viz.sh   the suite (below)

## 5. Tests

`tests/run-test-circuit-viz.sh` (skips without python3/sbcl):

1. **Oracle agreement.** For the bundled example and several evidence sets
   (none, one action, several, a negated action, a mix), the server's P(h | E)
   must equal Z(E, h) / Z(E) counted by SharpSAT-TD (`wmc.sh`, an exact counter
   independent of the circuit) on the theory regenerated from the example's
   `.wff`, with the evidence and h as unit clauses; and its posterior must equal
   P(h|E)/P(h) normalized, to 1e-9.  (ADDMC, the first choice, did not finish
   this theory in 10 minutes.)
2. **Unsat**: contradictory evidence reports `unsat`, not a division by zero.
3. **Refusals**: an ordering form, a non-unit formula, an atom not in the
   circuit — each refused with its reason, and the session still answers.
4. **Evidence files**: an `-obsK.txt` parses to K pinned literals in slice
   order; an `-ordK.txt` is reported unsupported.
5. **HTTP**: the server starts on a free port, serves the page and every API
   route, and survives a killed Lisp child (restarts it and reloads).
6. **Build**: circuit.js is current (as for visualizer.js), and the plan
   visualizer's suite still passes (render.ts changes are backward compatible).

## 6. Later (not v1)

- Ordering evidence and non-unit formulas by recompiling in the background
  with a progress indicator (or a cache per evidence set).
- Compiling a circuit from a problem in the page (recognize.sh + marginals.sh
  `--save-circuit`), for problems that have none yet.
- Non-uniform priors for the likelihood posterior (a prior per hypothesis,
  entered in the page).
- Showing the most probable plan given E (needs a max-product pass).
