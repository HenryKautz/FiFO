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

For each hypothesis h — a disjunct of the goal's ONE `(or ...)`, by
recognize.sh's own rule (`lisp/recognition-goal.lisp`, `rg--classify`:
exclusivity clauses dropped, preferences ignored, a plain conjunction or a
second hypothesis set refused), read at the final slice,
`(holds (at pkg1 p1-3) H)` — the page shows

- **P(h)** = Z(h) / Z(∅), the prior the model itself implies (a goal with more
  and cheaper plans gets more),
- **P(h | E)** = Z(E ∧ h) / Z(E), the marginal (the number recognize.sh's
  `--method marginals` reports per hypothesis), and
- **uniform prior**: P(E | h) / Σ P(E | h') — Ramírez and Geffner's
  posterior with a uniform prior (recognize.sh's `--baseline per-hypothesis`),
  equal to P(h | E) / P(h) normalized.  It is free: P(E | h) = Z(E ∧ h) / Z(h),
  and Z(h) comes from the one evidence-free pass made when the circuit loads.
  It removes the model's implicit prior P(h), which the marginal keeps; with
  no evidence it is uniform by construction.  Caution, shown on the page:
  with slice-pinned evidence and a fixed horizon it favours the goal whose
  plans have the least slack (an on-time action is nearly certain under it),
  and a short horizon overemphasizes this.  On TwoPackage/grid6x6-4, whose
  recognition horizon 14 is exactly G2's shortest plan, P(E | G2) = 1 for
  the first four drives toward pkg1, and the column ranks G2 above the
  cheaper G1 though both are on an optimal path.

The marginals need not sum to 1 (two packages can both be delivered); the
uniform-prior column does, within each goal line.

**Goals recognize.sh refuses** (a conjunction of several `(or ...)` sets, a
plain conjunction, a hard goal beside the set) are shown literal by literal
instead: every goal literal is a hypothesis atom, numbered by its conjunct
(`group`), and the uniform-prior column is normalized within each conjunct.
The goal is split as the page splits it (nested ANDs flattened); an `(or ...)`
of negations only is dropped as an exclusivity clause only when another
`(or ...)` is there for it to accompany; a `(not A)` hypothesis is scored as
A's complement.  The load reply's `note` says why, and the page shows it
(kept while the evidence changes).  The page highlights the most probable
hypothesis of each line.

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
| `(cv-load "<circuit path>" "<problem.pddl>")` | `{nvars, nodes, projected: n or null, horizon, z0, note, hypotheses: [{goal, atom, present, group}], actions: n}` — the hypotheses by `rg--classify` (else literal by literal, `note` saying why), their atoms `(HOLDS <goal> H)`, H the highest slice of any HOLDS atom in the circuit.  Atomic: computed in full before the loaded circuit is replaced, so a failed load leaves the previous one whole |
| `(cv-actions)` | `{actions: ["(occurs (drive ...) 1)", ...]}` — the kept OCCURS atoms, for manual entry |
| `(cv-query ("(occurs ...)" "(not (occurs ...))" ...))` | `{ok, z, z0, pe, unsat, prior, marginal, likelihood, posterior: [one per hypothesis], unknown: [...], refused: [...], ms}` |
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
| `GET /api/actions?id=` | the kept action atoms |
| `POST /api/query {id, literals: [...]}` | the Lisp `cv-query` reply.  It names its session: if another tab has loaded a different one meanwhile, that session is reloaded first, so a page never gets another circuit's numbers |

### Sessions

The server is started with the problem/circuit pairs it serves:

    circuit_server.py --session PROBLEM.pddl CIRCUIT.dnnf[b] [EVIDENCE-DIR-or-files...]
                      [--session ...] [--clara DIR] [--port 8765]

`--clara ~/Programming/CLARA` adds every TwoPackage (and SimpleGrid,
ThreePackage) problem that has a circuit, with its evidence files
(`evidence/NAME-*-obsK.txt`).  Only useful files are offered
(`useful_evidence`): none with no literal the page can clamp (the `-ordK.txt`
files are one ordering form each), and none whose literals a longer file for
the same solution extends (`-obs1`, `-obs2` beside `-obs3`: the page steps
through `-obs3`).  Files for different solutions are all kept, even when one
starts like another, and so is every file named one by one.  The menu is
worked out when a session is first loaded, not at startup; a file left out of
it still opens by name (`?evidence=FILE`).  A self-contained small example ships in
`SatPlan/Visualizer/circuit-examples/` so the page and the tests work without
CLARA.

## 3. The page

Same layout and style as the plan visualizer:

- **Header**: a Session menu (from `/api/sessions`), the evidence-file menu of
  that session plus a file chooser for a local evidence file, and a summary
  line (problem, circuit size, horizon, projected or not).
- **Map** (left): the plan visualizer's map of the state the applied
  observations lead to — the initial state with each observed action applied
  in slice order (`applyActions`), so vehicles drive and packages ride, are
  loaded and unloaded; unobserved slices are skipped over.  The observed
  actions so far are drawn as moves in their vehicle's color with slice
  labels; each goal destination is shaded by its probability (the `goalProb`
  render option: fill opacity = P(h|E), label "G3 0.42").  Goals sharing a
  place are tiled, shrunk to fit, never overlapping (both visualizers).
- **Goal** (right, top): the goal formula as in the plan visualizer (shared
  `goalHtml`), one line per conjunct; a literal achieved in the displayed
  state is highlighted, with each literal's P(h|E) beside it.
- **Hypotheses**: one row per hypothesis, in label order (G1, G2, …): its
  label and literal in its package's color, P(h), a bar and the number
  P(h|E), and the uniform-prior share; the most probable highlighted.
  Underneath, what the columns mean, P(E) and the query time.
- **Evidence** (right, bottom — where the Solution panel was): the list of
  observations with ◀ ▶ ⏮ ⏭ to step through them (step k applies the first k;
  a chosen file starts at step 0, before any observation),
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
