# FiFO Software Components

## Documentation

- [README.md](README.md) — the FiFO language reference and user guide.
- $\color{red}{\textbf{software-components.md}}$ — summary of FiFO scripts and all the systems for logical and probabilistic reasoning and scripts that FiFO uses.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: MAP inference, computing marginals under a weighted theory, and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [benchmarks.md](benchmarks.md) — measured results: horizons, CNF sizes, and compilation costs.
- [discussion.md](discussion.md) — discussion and open issues.

## Table of Contents

- [What the pieces are](#what-the-pieces-are)
  - [The files](#the-files) · [Which script runs which part](#which-script-runs-which-part)
- [Conventions shared by every script](#conventions-shared-by-every-script)
- [The scripts](#the-scripts)
  - [install-solvers.sh](#install-solverssh) · [solve.sh](#solvesh) · [map.sh](#mapsh) · [planner.sh](#plannersh) · [recognize.sh](#recognizesh) · [marginals.sh](#marginalssh) · [wmc.sh](#wmcsh) · [learn.sh](#learnsh) · [learn-pddl.sh](#learn-pddlsh) · [cleanupfifo.sh](#cleanupfifosh) · [run_regression_tests.sh](#run_regression_testssh) · [fifo-options.sh](#fifo-optionssh) · [fifo-solvers.sh](#fifo-solverssh) · [fifo-answer.sh](#fifo-answersh) · [test runners](#the-test-runners-under-tests) · [make-recognition-instance.lisp](#make-recognition-instancelisp)
- [The Lisp modules](#the-lisp-modules)
- [Solvers and external tools](#solvers-and-external-tools)
  - [How FiFO finds a solver](#how-fifo-finds-a-solver)
  - [Runtime](#runtime)
  - [SAT solvers](#sat-solvers)
  - [Weighted MaxSAT solvers](#weighted-maxsat-solvers)
  - [Preprocessors](#preprocessors)
  - [Weighted model counters and knowledge compilers](#weighted-model-counters-and-knowledge-compilers)
  - [Samplers](#samplers)
  - [Which component uses which solver](#which-component-uses-which-solver)

------

## What the pieces are

FiFO is a finite-domain first-order language that compiles to propositional CNF.
Everything in the system is a stage of one pipeline. The front half is shared;
after the `.scnf` it forks three ways, according to which of three questions is
being asked of the theory.

```
  .pddl ──pddl2fifo──▶ .wff ──instantiate──▶ .scnf
                                             │
    ┌────────────────────────┬───────────────┴───────────────┐
    │ SATISFIABILITY         │ MAP / minimum cost            │ PROBABILITIES
    │ is there a model?      │ which model is best?          │ how likely is an atom?
    ▼                        ▼                               ▼
    propositionalize         propositionalize                the back ends read the .scnf
    *cnf-format* CNF         *cnf-format* WCNF               directly -- no DIMACS stage,
    │                        │                               no propositionalize
    ▼                        ▼                               │
    .cnf + .map              .wcnf + .map                    ├─ maxent    exact, in Lisp
    │                        │    ▲                          ├─ ddnnf     exact, in Lisp
    │                        │    └─ MaxPre 2 (optional)     ├─ addmc     exact, external
    │                        │       preprocess/reconstruct  ├─ d4        exact, external
    ▼                        ▼                               ├─ mc-sat    sampling
    SAT solver               MaxSAT solver                   └─ max-term  1+n MaxSAT runs
    kissat                   anytime  tt-open-wbo-inc,       │
    │                                 nuwls-c                │
    │                        exact    wmaxcdcl, rc2          ▼
    │                        │                               (MARGINAL <atom> <p>)  or
    └───▶ .satout ◀──────────┘                               (MAXTERM-MARGINAL <atom> <p>)
               │
           interpret
               │
               ▼
       .soln / .answer
```

The middle lane is the one that is easy to get wrong, because the fork is not
automatic: `solve` chooses the format from `*cnf-format*` and the solver from
`*solver*`, with nothing cross-checking them, so a weighted theory left at the
default `CNF` writes its weights as `cw` comment lines that a SAT solver ignores
— and returns a valid but **non-optimal** model. That is what `solve.sh` and
`map.sh` exist to prevent: one driver per question, each fixing the format that
defines it.

(The solver names in the diagram are the common choices, not the whole list —
[Solvers and external tools](#solvers-and-external-tools) has them all.)

### The files

- **`.wff`** — FiFO source: options, domain declarations, formulas, `weight` /
  `probability` forms.
- **`.scnf`** — *symbolic* CNF: ground `(OR ...)` clauses plus `(WEIGHT literal w)`
  and `(PROBABILITY literal p gid)` lines. The interchange format the
  probabilistic tools read, and the last stage that still names atoms.
- **`.cnf` / `.wcnf`** — DIMACS for an external solver, plus a `.map` file giving
  the integer ↔ symbolic-atom correspondence. The weighted forms also carry
  `c weights scaled by S` / `c weight shift offset M` comments, since DIMACS
  requires positive integer weights and the true cost is `objective / S + M`.
- **`.satout` → `.soln` / `.answer`** — raw solver output, then its translation
  back into symbolic literals.

### Which script runs which part

| Script | Stages it runs | Produces |
|---|---|---|
| [`solve.sh`](#solvesh) | instantiate → propositionalize (**CNF**) → SAT solver → interpret | `.answer`: `SAT` + true atoms, `UNSAT`, or for a `prove` form `PROVEN` + bindings / `NOANSWER` / `COUNTEREXAMPLE`. Printed with `;` commentary; strip those and it is the file verbatim |
| [`map.sh`](#mapsh) | instantiate → propositionalize (**WCNF**) → *[MaxPre preprocess]* → MaxSAT solver → *[reconstruct]* → interpret | `.answer` with `(*OBJECTIVE* N)` and the minimum-cost model; also prints the **true cost** `N / scale + offset` |
| [`planner.sh`](#plannersh) | pddl2fifo → *(per horizon)* instantiate → propositionalize → SAT; then re-solve the smallest feasible horizon in WCNF if the domain has costs | the plan and its cost, plus `.wff`, `.scnf`, `.cnf`/`.wcnf`, `.map`, `.satout`, `.answer` beside the problem. With `--marginals`, marginals at the working horizon instead of a plan |
| [`recognize.sh`](#recognizesh) | drives `planner.sh` `2n` times (comply / not-comply per hypothesis) | `summary.tsv` — costs, likelihood, prior, posterior per hypothesis — and the argmax on stdout |
| [`marginals.sh`](#marginalssh) | reads the `.scnf` **directly**; no DIMACS stage except inside `max-term`, which writes its own wcnf | `(MARGINAL <atom> <p>)` lines, or `(MAXTERM-MARGINAL ...)` for `--solver max-term`; `--out` also writes them to a file |
| [`wmc.sh`](#wmcsh) | reads the `.scnf` → MCC weighted CNF → ADDMC | `(WMC <Z>)`, the partition function |
| [`learn.sh`](#learnsh) | reads a `.scnf` carrying `(PROBABILITY ...)` targets → fits weights | a reweighted `.scnf` with integer `(WEIGHT ...)` costs; with `--wff`, also a weighted copy of the source `.wff` |
| [`learn-pddl.sh`](#learn-pddlsh) | pddl2fifo → instantiate → learn → rewrite the domain | a `.pddl` domain with each `:probability` replaced by the learned `:cost` (and a problem file when preferences or fluent costs carry targets) |
| [`install-solvers.sh`](#install-solverssh) | none — bootstrap | solver binaries in `~/bin`; checkouts under `Solvers/` |
| [`cleanupfifo.sh`](#cleanupfifosh) | none — housekeeping | deletes `.scnf .cnf .wcnf .map .satout .soln .answer` |

Three questions, three solver families: **satisfiability** (SAT), **the most
probable model** (MaxSAT — see
[MAP inference](Probability/probability.md#map-inference-the-most-probable-model)),
and **probabilities** (weighted model counting, sampling, or the max-term
approximation). The [Solvers](#solvers-and-external-tools) section catalogs all of
them.

------

## Conventions shared by every script

**Locating the Lisp.** Every script finds `FiFO.lisp` and its siblings through the
`FIFO_LISP` environment variable, which defaults to `~/lib/fifo/lisp` — the
install location. `make install` copies `bin/` → `~/bin` and `lisp/` →
`~/lib/fifo/lisp` (override with `make install BINDIR=... LISPDIR=...`). To run
from a source checkout without installing:

```sh
export FIFO_LISP=/path/to/FiFO/lisp
```

The test runners under `tests/` default `FIFO_LISP` to the *checkout's* `lisp/`
instead, so they always exercise the working copy.

**`--options <file>`.** `planner.sh`, `marginals.sh`, `wmc.sh`, `learn.sh`,
`learn-pddl.sh`, and `recognize.sh` all accept `--options FILE`, which splices the
options in `FILE` into the command line at that point. `FILE` holds one logical
line, wrappable across physical lines with a trailing backslash, parsed with shell
quoting — so an argument containing spaces survives:

```
--domain d.pddl --pddl-evidence '(occur-in-order (move a b) (move b c))'
```

Expansion is not recursive, and if the file holds more than one logical line a
warning is printed and only the first is used. See
[fifo-options.sh](#fifo-optionssh).

**Exit status and errors.** Bad usage exits 2 with the full usage text on stderr.
A Lisp-level failure is reported as `<script>: <condition>` and exits 1. Optional
solver binaries are probed *before* the run, so a missing or wrong-version binary
produces a clear message rather than a confusing failure downstream.

**Intermediate files** are written next to the input and left in place;
[`cleanupfifo.sh`](#cleanupfifosh) removes them.

------

## The scripts

### `install-solvers.sh`

Bootstrap: clone, build, and install the external solvers of the
[Solvers](#solvers-and-external-tools) section. Repositories are cloned into
`<FiFO>/Solvers/`, binaries are installed into `~/bin`, and build output goes to
`<FiFO>/Solvers/logs/<solver>.log`.

```sh
bin/install-solvers.sh [--all] [--only <solver>]... [--bindir <dir>] [--dry-run] [--list]
```

A solver that is already usable is skipped. **Usable** is checked per solver
rather than by mere presence on `PATH`: a `walksat` without `-mcsat` (v57 or
earlier) counts as missing and gets replaced, and `d4` is looked for at `$D4` or
in the install directory, since FiFO does not search `PATH` for it.

| Option | Meaning |
|---|---|
| `--all` | (Re)install every solver even if one is already available. |
| `--only <solver>` | Install just this one. Repeatable. Names: `kissat`, `tt-open-wbo-inc`, `nuwls-c`, `evalmaxsat`, `wmaxcdcl`, `rc2`, `addmc`, `d4`, `walksat`, `maxpre`. |
| `--bindir <dir>` | Install binaries here instead of `~/bin`. |
| `--dry-run` | Print what would be cloned and built, without doing it. |
| `--list` | List the solvers, their repositories, and whether each is already present. |
| `-h`, `--help` | Usage. |

Each solver is pinned to the branch it should be built from, and an existing
checkout sitting on a different branch is re-pointed before the pull, so a
repository that later moves its work to another branch does not leave stale
checkouts building the wrong source.

Set `FIFO_SOLVERS` to clone somewhere other than `<FiFO>/Solvers` — worth doing
when the FiFO directory sits inside a synced folder, since these build trees run
to hundreds of megabytes and are entirely regenerable. (`Solvers/` is in
`.gitignore`.)

**A failed build never stops the run.** Each solver is attempted in turn; a
failure prints the last lines of its log and is recorded, and the script moves on.
The closing summary lists every solver as *installed*, *already present*, or
*failed* with the reason, followed by any post-install notes (`~/bin` not on
`PATH`; the `export D4=…` that d4 needs). Exit status is 0 only if nothing
failed.

Prerequisites are checked *before* cloning, so a missing tool is reported as a
one-line "missing build prerequisites: cmake" rather than a wall of compiler
errors. All of them need `git`, `make`, and a C/C++ compiler, except `rc2`, which needs `python3` and `pip`; `addmc` and `d4`
also need `cmake`; `nuwls-c` needs GMP and `maxpre` needs Boost (both found via
the Homebrew prefix, which the script puts on `CPATH`/`LIBRARY_PATH`); on macOS `d4` additionally needs Homebrew with
`brew install gcc gmp boost cmake`, because its build uses the GNU toolchain
rather than Apple clang.

Not covered: the alternative solvers FiFO does not drive directly (Mallob,
Painless, MaxHS) and the two that install through a package manager (RC2 via
`pip install python-sat`, CP-SAT via `pip install ortools`).

------

### `solve.sh`

Solve a problem for **satisfiability**: plain DIMACS CNF, a pure SAT solver, and
the model translated back into symbolic literals.

```sh
solve.sh <problem.wff> [options]
```

| Option | Meaning |
|---|---|
| `--solver <name>` | SAT solver (default `kissat`). A MaxSAT solver is refused with an explanation pointing at `map.sh`. |
| `--timeout <secs>` | Stop the solver after this many seconds. `0`, `-1` or `none` mean no limit. Default is FiFO's `*solver-timeout*`, 600 s. |
| `--out <file>` | Answer file (default `<problem>.answer`). |
| `--staticfile <file>` | Static ground facts to instantiate against. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

The CNF format is **not** an option here — fixing it is what makes this the
satisfiability driver. `--cnf-format` and the MaxSAT-only `--preprocessor` are
both rejected with a pointer to `map.sh`.

**Output.** Both drivers print the answer in a form that serves two readers at
once. Everything that is not a `;` comment is the `.answer` file verbatim — a
verdict on the first line, then s-expressions — so anything already parsing
`.answer` files works on this stdout unchanged. The `;` lines say what the
verdict means and what the payload is, which the payload alone cannot: after
`PROVEN`, `(X ALICE)` is a variable binding; after `SAT`, an identically shaped
line is a true atom of a model.

```
; PROVEN -- the theory entails the goal; the 1 line(s) below are variable
;           bindings, each (<variable> <value>), witnessing it
PROVEN
(X ALICE)
```

The five verdicts are `SAT` / `UNSAT` (no `prove` form) and `PROVEN` /
`NOANSWER` / `COUNTEREXAMPLE` (with one). Rendering lives in
[`fifo-answer.sh`](#fifo-answersh).

Exit status is 0 when the problem got a verdict, 1 when the solver failed to
produce one, 2 on bad usage.

------

### `map.sh`

**MAP inference**: the most probable model, i.e. the one of minimum total
weight. Weighted CNF, a MaxSAT solver, the same symbolic answer.

```sh
map.sh <problem.wff> [options]
```

| Option | Meaning |
|---|---|
| `--solver <name>` | MaxSAT solver (default `tt-open-wbo-inc-Glucose4_1`). Abbreviations `tt-glucose`, `tt-intelsat`, `nuwls` are resolved. A plain SAT solver is refused with a pointer to `solve.sh`. |
| `--old-format` | Emit the classic `p wcnf <v> <c> <top>` format instead of the 2022 `h`-line format, for solvers that predate it. |
| `--timeout <secs>` | As above. An anytime MaxSAT solver stopped this way prints its best solution so far, so a timeout still yields a usable — if not provably optimal — answer. |
| `--preprocessor <p>` | Preprocess with a MaxPre 2 binary and reconstruct the model afterwards (usually `--preprocessor maxpre`). |
| `--preprocessor-techniques <s>` | MaxPre's `-techniques=` string. |
| `--out <file>`, `--staticfile <file>`, `--options <file>`, `-h` | As for `solve.sh`. |
| `--keep` | Keep the intermediate `.cnf`/`.map`/`.satout` files. |

Besides the answer file's raw `(*OBJECTIVE* N)`, `map.sh` prints the **true
cost**, correcting `N` by the scale and shift the weighted formats require:

```
true cost: 3.1   (raw objective 62 / scale 20 + offset 0)
```

------

### `planner.sh`

The SatPlan driver: translate PDDL, search for the smallest workable horizon, and
solve there. Optionally do conditioned marginal inference instead of planning.

```sh
planner.sh <problem.pddl|problem.wff> [options]
```

A `.pddl` problem is translated with `pddl2fifo`; a `.wff` is used as-is. At each
horizon the problem is instantiated and tested for feasibility with a plain SAT
solver; if the domain has action costs, preferences, or fluent costs, the smallest
feasible horizon is re-solved as weighted MaxSAT to minimize total cost.

| Option | Meaning |
|---|---|
| `--domain <file>` | Domain file. Default: the `(:domain <name>)` named by the problem, `<name>.pddl` next to it. |
| `--minslices <int>` | First horizon tried. Default: `pddl2fifo`'s relaxed-planning-graph reachability lower bound (2 for a `.wff`). |
| `--maxslices <int>` | Last horizon tried. Default: `2 × minslices`. |
| `--numslices <int>` | Shorthand setting both bounds — solve at exactly this horizon. |
| `--solver <name>` | The **pure SAT** (feasibility) solver. Default `kissat`. Does *not* change the MaxSAT solver — see the next row. |
| `--weighted-solver <name>` | The MaxSAT solver for the cost-minimization step. Default `tt-open-wbo-inc-Glucose4_1`, which is **anytime**: it returns the best plan found, not a proven optimum. `wmaxcdcl`, `EvalMaxSAT_bin` and `rc2-maxsat.py` are exact and prove there is no cheaper plan. Also settable from the environment as `WEIGHTED_SOLVER`. |
| `--stop-after wff` | Stop after writing the `.wff` (translation only). |
| `--stop-after scnf` | Stop after instantiating the `.scnf` at the smallest horizon (or `--numslices`), without solving. With evidence, also leaves `<root>-evidence.scnf`. |
| `--longer <K>` | For a costed domain, also minimize cost at up to `K` horizons beyond the smallest feasible one and return the cheapest plan found (default 0). A longer horizon can admit a cheaper plan. |
| `--evidence <formula>` | Condition on a FiFO formula (ground, or quantified over the problem's domains). Instantiated in the same environment as the problem into a separate `<root>-evidence.scnf` and conjoined. Repeatable. |
| `--evidence-file <f>` | A file of such formulas, conjoined with any `--evidence`. |
| `--pddl-evidence <form>` | Evidence in the PDDL modal language — `always`, `at-end`, `hold-during`, `occur-sometime`, `never`, `at`, `occur-in-order` — over PDDL predicate/action names, translated by `pddl2fifo`. Repeatable. PDDL input only. |
| `--pddl-evidence-file <f>` | A file of such PDDL modal forms. |
| `--marginals` | Run weighted model counting instead of planning: print `P(atom \| evidence)` at the working horizon, with no plan search. |
| `--counter <name>` | With `--marginals`: the same back ends `marginals.sh --solver` offers — `maxent` (default, exact enumeration), `addmc`, `ddnnf`, `d4` (the other exact counters), `mc-sat` (approximate sampling). Binaries are located exactly as in `marginals.sh`: `$ADDMC` / `$D4` else `PATH`. An unrecognised name is an error; a path is still accepted as an ADDMC binary, deprecated in favour of `--addmc-bin`. |
| `--addmc-bin <path>` | The ADDMC binary; implies `--counter addmc`. |
| `--d4-bin <path>` | The d4 compiler binary; implies `--counter d4`. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

**Solvers.** `SAT_SOLVER="kissat"` for feasibility and
`WEIGHTED_SOLVER="tt-open-wbo-inc-Glucose4_1"` for the cost step. Both now have
command-line overrides (`--solver` and `--weighted-solver`), and the weighted one
also reads the `WEIGHTED_SOLVER` environment variable.

**Output.** The plan (or the marginals) on stdout; all intermediates and the
`.answer` file next to the problem file.

------

### `recognize.sh`

Ramírez & Geffner plan recognition over a costed SatPlan instance, using
cheapest-plan (MaxSAT) computations only — the tractable approximation to the
intractable `Z_G`-normalized posterior.

```sh
recognize.sh <costs-domain.pddl> <problem.pddl> <evidence-file> [options]
```

For each hypothesis `hypI` (nullary derived predicates `hyp0 … hyp(n-1)`, as
produced by [`make-recognition-instance.lisp`](#make-recognition-instancelisp)) it
calls `planner.sh` twice at a fixed horizon — the cheapest plan that **complies**
with the observations and the cheapest that **does not** — and forms
`P(hypI | O) ∝ πᵢ · σ(β · (c(¬O) − c(O)))`, normalized over the disjoint
hypotheses.

| Option | Meaning |
|---|---|
| `--horizon <H>` | Fixed horizon. Default: the maximum over hypotheses of their smallest feasible horizon, and at least *observations + 1*, so no hypothesis is excluded. |
| `--beta <B>` | Inverse temperature in the sigmoid (default 1.0). Larger `β` sharpens the likelihood. |
| `--priors <file>` | `n` prior weights, one per line, `hyp0` first; renormalized. Default: uniform. |
| `--out <dir>` | Output directory. Default `<problem-dir>/runs/recognize`. |
| `--solver <name>` | Override the SAT feasibility solver passed through to `planner.sh`. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

**Cost.** `2n` MaxSAT runs per evidence set (each capped at a 900 s internal
timeout). **Output.** A table on stdout, the argmax hypothesis, and
`<out>/summary.tsv` with columns `hyp, c_O, c_notO, delta, likelihood, prior,
posterior`. Per-hypothesis intermediates are deleted as their costs are read.

------

### `marginals.sh`

Marginal inference on an instantiated `.scnf`: the probability `P(atom = true)` of
**every** atom — weighted or not — under the Gibbs distribution
`P(x) ∝ exp(−Σ weights of true literals)` over the feasible set. Five back ends,
four exact and one approximate.

```sh
marginals.sh <file.scnf> [options]
```

| Option | Meaning |
|---|---|
| `--solver <name>` | Back end: `maxent` (default; exact Lisp enumeration — small instances), `addmc` (exact; ADDMC weighted model counter), `ddnnf` (exact; FiFO's own d-DNNF compiler, pure Lisp), `d4` (exact; same circuit machinery, structure compiled by the external d4), `mc-sat` (**approximate**; MC-SAT sampling via WalkSAT v58), `max-term` (**approximate, and a different quantity** — see below). |
| `--weighted-only` | Report (and enumerate) only the weighted atoms. Much cheaper when there are many state atoms. Also reveals the internal `(WEIGHTED-FORMULA n)` atoms carrying formula weights. |
| `--out <file>` | Also write the `(MARGINAL ...)` lines to a file. |
| `--node-limit <int>` | Search-effort cap: enumeration nodes for `maxent` (default 5 000 000), circuit nodes for `ddnnf` (default 2 000 000). Not accepted by `addmc`/`d4`/`mc-sat`. |
| `--scale <n>` | Divide integer weights by `n` before exponentiating. Default: the `scale: N` header the learning pipeline records (1 if absent). `--scale 1` uses the raw weights. Applies to every back end. |
| `--evidence <form>` | Condition on a **ground** FiFO formula, conjoined as a hard constraint, so the results become `P(atom \| form)`. Repeatable. `addmc`/`ddnnf`/`d4`/`mc-sat` only. |
| `--evidence-file <f>` | A file of ground FiFO formulas, conjoined with any `--evidence`. |
| `--addmc-bin <path>` | ADDMC binary (else `$ADDMC`, else `addmc` on `PATH`). Implies `--solver addmc`. |
| `--d4-bin <path>` | d4 (d4v2) compiler binary (else `$D4`, else a sibling `d4v2` checkout). Implies `--solver d4`. |
| `--walksat-bin <path>` | WalkSAT v58 binary (else `$WALKSAT`, else a sibling `Walksat_v58_MC-SAT` checkout, else `walksat` on `PATH`). Implies `--solver mc-sat`. |
| `--epsilon <e>` | *(addmc)* ADDMC's CUDD terminal-merging tolerance (`--ep`); default 0 = exact. A positive value trades exactness for speed/memory. |
| `--save-circuit <f>` | *(ddnnf/d4)* After compiling, persist the circuit to `<f>`; this run still reports marginals. |
| `--circuit <f>` | *(ddnnf/d4)* Load a saved circuit and query it **without** recompiling — give this instead of a `.scnf`. Unit-literal `--evidence` reuses it; non-unit evidence recompiles from the stored clauses. `--scale` re-weights it for free. |
| `--samples <n>` | *(mc-sat)* Retained samples (default 10 000). Monte-Carlo error falls as `1/√n`. |
| `--burnin <n>` | *(mc-sat)* Discarded warm-up samples (default 100). |
| `--seed <n>` | *(mc-sat)* Sampler seed; the same seed reproduces the marginals exactly. Default: time-based. |
| `--unitprop` | *(mc-sat)* Unit-propagate before each sample. Distribution-preserving; a large speedup on SatPlan encodings, and it makes the frozen-chain diagnostic decisive. |
| `--walk-prob <r>` | *(mc-sat)* SampleSAT's probability of a WalkSAT (rather than annealing) move; default 0.5. |
| `--temp <r>` | *(mc-sat)* SampleSAT's annealing temperature; default 0.25. |
| `--samplesat-cutoff <n>` | *(mc-sat)* Flips of the SampleSAT walk per sample; default `100 + 10 × #atoms`. |
| `--init-cutoff <n>` | *(mc-sat)* Flips per try for the initial solve of the hard clauses (default `100 × #atoms`), and the budget to repair a SampleSAT endpoint back onto a solution. |
| `--init-tries <n>` | *(mc-sat)* Random restarts for that initial solve (default 100). |
| `--no-sat-seed` | *(mc-sat)* Do **not** seed the initial assignment from the CDCL solver. On by default because local search alone cannot reach a model of a structured SatPlan encoding — and a CDCL UNSAT verdict is then a proof, reported at once. |
| `--query <atom>` | *(max-term)* Atom to report; repeatable, or `all`. **Required** — each atom costs one MaxSAT solve. |
| `--query-file <f>` | *(max-term)* A file of atoms, one per line. |
| `--beta <r>` | *(max-term)* Inverse temperature; default `1/scale`. |
| `--prior <atom>=<p>` | *(max-term)* Log-odds prior. **Replaces** that atom's own weight rather than stacking on it, and costs no re-solving. Repeatable. |
| `--priors <file>` | *(max-term)* A file of `atom = p` lines. |
| `--groups auto\|none` | *(max-term)* Detect groups of queried atoms the **theory** makes mutually exclusive and renormalise over each. Default `auto`. |
| `--maxsat-bin <path>` | *(max-term)* The MaxSAT solver. Default `bin/rc2-maxsat.py`, which is **exact** and terminates with a proof. An anytime solver may be given instead, but offers no optimality guarantee — and since max-term is a *difference* of two minima, two unproven bounds do not cancel. Unproven solves are counted and warned about. |
| `--verify-groups` | *(max-term)* Additionally *prove* each group by SAT entailment, catching encodings the syntactic scan misses. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

**Output.** One `(MARGINAL <atom> <probability>)` line per atom. With
`--solver mc-sat` the run also prints the sampler's diagnostics as `;` comments —
read the **efficiency** and **mixing** lines before the numbers; see
[Probability/probability.md](Probability/probability.md#approximate-marginals-by-mc-sat-sampling).

**`--solver max-term` answers a different question.** It applies the maximum-term
approximation ([probability-background.md §14](Probability/probability-background.md#14-maximum-term-approximation-of-the-partition-function))
per atom:

```
logit P(a) = beta * ( c_min(not a) - c_min(a) )
```

with each `c_min` a MaxSAT solve, so `1 + n` solves cover `n` atoms (the
unconstrained optimum already supplies one polarity each). It scales where
counting cannot — the same trade `recognize.sh` makes — but it approximates what
the **weights** contribute and discards what the **counting** contributes. On an
unweighted theory every difference is zero and it returns 0.5 for everything.
Output is labelled `(MAXTERM-MARGINAL …)` rather than `(MARGINAL …)` so that it
cannot be mistaken for a Gibbs marginal by eye or by `grep`.

Two things it gets exactly right. A **backbone** atom — one whose opposite
polarity is UNSAT — is reported as 0 or 1 and flagged `[proved]`. And a group of
atoms the theory makes **mutually exclusive** is renormalised over, which recovers
the exact answer where per-atom independence would not: on an unweighted
exactly-one-of-three theory the ungrouped estimates are `0.5` three times, summing
to 1.5, while the grouped ones are `1/3` each, matching the exact enumerator.
Exclusivity is a property of the theory, so it is **detected** from the clauses
(an at-least-one clause plus the pairwise at-most-one clauses) rather than
declared in the query — the exact back ends need no such declaration because they
see the constraints directly. An at-most-one group that is not exhaustive gets a
virtual "none of them" outcome, so its probabilities sum to less than 1 rather
than being inflated.

A convenient way to produce the input: `planner.sh <problem.pddl> --stop-after scnf`.

------

### `wmc.sh`

The exact weighted model count — the partition function `Z = Σ_{x∈F} exp(−cost(x))`
— of a weighted `.scnf`, via ADDMC.

```sh
wmc.sh <file.scnf> [options]
```

| Option | Meaning |
|---|---|
| `--addmc-bin <path>` | ADDMC binary (else `$ADDMC`, else `addmc` on `PATH`), spelled as in `marginals.sh` and `planner.sh`. `--addmc` is accepted as a deprecated alias. |
| `--scale <n>` | Divide integer weights by `n` before exponentiating. Default: the `scale: N` header (1 if absent). |
| `--epsilon <e>` | ADDMC's CUDD terminal-merging tolerance (`--ep`); default 0 = exact. |
| `--evidence <form>` | Condition on a ground FiFO formula, so `Z` becomes the conditioned count. Repeatable. |
| `--evidence-file <f>` | A file of ground FiFO formulas. |
| `--wcnf <file>` | Write (and keep) the intermediate MCC weighted CNF here. |
| `--keep-wcnf` | Keep the intermediate `.wcnf` scratch file instead of deleting it. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

**Output.** One line, `(WMC <Z>)`.

------

### `learn.sh`

The weight-learning pipeline on an `.scnf`: turn `(PROBABILITY literal p [gid])`
target marginals into integer `(WEIGHT literal w)` costs.

```sh
learn.sh <input.scnf> [options]
```

| Option | Meaning |
|---|---|
| `--method log-odds\|maxent` | Estimator. Default `log-odds`. |
| `--maxent` | Shorthand for `--method maxent`. |
| `--out <file>` | Output `.scnf`. Default `<root>_reweighted.scnf`. |
| `--scale <int>` | Integer weight resolution; the real weight is `w/scale` (default 100). Recorded in the output header. |
| `--wff <file>` | Also write the learned weights back into a copy of this source `.wff` (the one that produced the `.scnf`), replacing each `probability` form with the tied `weight`. |
| `--wff-out <file>` | Write-back path. Default `<wff-root>_weighted.wff`. |
| `--eta <float>` | *(maxent)* Damped-Newton step size (default 1.0). |
| `--tol <float>` | *(maxent)* Convergence tolerance (default 1e-5). |
| `--max-iters <int>` | *(maxent)* Iteration cap (default 5000). |
| `--no-consider-weights` | *(maxent)* Ignore existing explicit `(WEIGHT ...)` lines while fitting (they are still passed through). By default they are held fixed so the fit accounts for them. |
| `--quiet` | *(maxent)* Suppress the per-group target-vs-achieved report. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

The maxent-only options are rejected under `--method log-odds` rather than
silently ignored.

**The two estimators.** `log-odds` is the closed form `θ = log((1−p)/p)` per atom
and ignores clause coupling; `maxent` is an exact fit over the feasible set that
matches each tie group's mean marginal to its target (it enumerates, so small
instances only). See
[Probability/probability.md](Probability/probability.md#two-estimators).

------

### `learn-pddl.sh`

End-to-end PDDL weight learning: translate, instantiate at a small horizon, learn
weights for the `(:probability ...)` action specs, and write a copy of the domain
with each `:probability` replaced by the learned `:cost`.

```sh
learn-pddl.sh <problem.pddl> [--domain <domain.pddl>] [options]
```

| Option | Meaning |
|---|---|
| `--domain <file>` | Domain file. Default: `<name>.pddl` from the problem's `(:domain <name>)`, next to the problem. |
| `--method log-odds\|maxent` | Estimator (default `log-odds`). |
| `--maxent` | Shorthand for `--method maxent`. |
| `--scale <int>` | Integer weight resolution; real weight = `w/scale` (default 100). |
| `--numslices <int>` | Instantiation horizon used for learning (default 3). For `--maxent` the problem must be feasible at this horizon; `log-odds` is horizon-independent. |
| `--domain-out <file>` | Learned domain path. Default `<domain-root>_learned.pddl`. |
| `--problem-out <file>` | Learned problem path. Default `<problem-root>_learned.pddl`; written only if the instance has preference or `:fluent-cost` probabilities. |
| `--options <file>` | Splice in the options from `<file>`. |
| `-h`, `--help` | Usage. |

All ground instances of one action schema share a single learned weight
(parameter tying). The result is written as `:cost <w>`, which may be **negative**
when the action is favored (`p > 0.5`).

------

### `cleanupfifo.sh`

Delete the regenerable byproducts of the pipeline — `.scnf .cnf .wcnf .map
.satout .soln .answer` — from a directory. Source files (`.wff`, `.pddl`,
`.lisp`, …) are never touched.

```sh
cleanupfifo.sh [<dir>|<file>] [-r|--recursive] [-n|--dry-run]
```

With no argument it cleans the current directory; given a file, it cleans the
directory containing it.

| Option | Meaning |
|---|---|
| `-r`, `--recursive` | Also clean every subdirectory. Use with care — this reaches committed test fixtures such as `*_gold.scnf`. |
| `-n`, `--dry-run` | List what would be deleted, without deleting. |
| `-h`, `--help` | Usage. |

------

### `run_regression_tests.sh`

The full regression suite, run from the repo root:

```sh
bash bin/run_regression_tests.sh
```

For every gold file under `tests/gold_instantiate/` and `tests/gold_solve/`, the
corresponding `.wff` source (looked up in `passed_*/`, then `tests_*/`) is run
through `instantiate` or `solve` and diffed against the gold file. Each test runs
in its own SBCL process with a 180 s timeout, so a crash or hang in one cannot
affect the others; gensym symbols (`#:XXnnnn`) are renumbered by order of first
appearance before comparison, since their absolute numbers differ between SBCL
sessions. No options. Exit status is 0 only if every test passes. It tests
`lisp/` by default; set `FIFO_LISP` to test an installed copy.

------

### `fifo-answer.sh`

Not a command — a helper `solve.sh` and `map.sh` **source**. `_fifo_print_answer`
renders a `.answer` file: the file itself verbatim, preceded by `;` comment lines
explaining the verdict and labelling the payload.

The split matters because `solve` returns only the verdict symbol — the model and
the extracted variable bindings live in the answer file, so a driver that prints
the return value alone silently discards the answer to a `prove` query. `;` is
the comment character in both Lisp and DIMACS and is what the rest of FiFO
already uses for commentary, so `grep -v '^;'` recovers the machine-readable form
exactly.

------

### `fifo-solvers.sh`

Not a command — a helper the task drivers **source**. It classifies a solver name
as `sat`, `maxsat`, or `unknown` (`_fifo_solver_kind`), and refuses a mismatch
with an explanation (`_fifo_require_solver_kind`). Matching is on the basename,
case-insensitively, and checks the MaxSAT patterns first, so
`tt-open-wbo-inc-Glucose4_1` classifies as MaxSAT rather than being caught by
"glucose". An unrecognised name is `unknown` and allowed through — a locally
built binary is the user's business.

It also mirrors FiFO's `*solver-abbreviations*` (`_fifo_resolve_solver`), so the
shell can check that `nuwls` really means `nuwls-c` before reporting it missing.
Keep that table in step with `lisp/FiFO.lisp`.

The check matters because the failure it prevents is silent rather than loud:
weights written into a plain `.cnf` become `cw` comment lines, which a SAT
solver ignores while cheerfully returning a **non-optimal** model.

------

### `fifo-options.sh`

Not a command — a helper that the other scripts **source**. It provides
`_fifo_expand_options "$@"`, which scans an argument list for `--options FILE`,
reads the single logical line in `FILE` (backslash-continued lines are joined,
shell quoting honored), and leaves the expanded arguments in the global array
`FIFO_EXPANDED_ARGS`. Expansion is not recursive. On a bad argument it calls
`_fifo_options_die`, which each script predefines so the message carries its own
name and usage.

------

### The test runners under `tests/`

All are behavioral or gold-diff suites, runnable from anywhere unless noted, and
all default `FIFO_LISP` to the checkout's `lisp/`.

| Script | What it covers |
|---|---|
| `tests/run-test-instantiate.sh <name>` | Runs `instantiate` on `tests_instantiate/<name>.wff` and cats the resulting `.scnf`. **Run from inside `tests/`.** |
| `tests/run-test-solve.sh <name>` | Runs `solve` on `tests_solve/<name>.wff` and cats the `.answer`. **Run from inside `tests/`.** |
| `tests/run-test-pddl.sh` | PDDL-translator regression: for every example with a checked-in translation under `SatPlan/Examples/`, runs `pddl2fifo` on a temp copy and diffs the `.wff` byte-for-byte (the `(include ...)` satplan path is normalized). |
| `tests/run-test-evidence.sh` | `--pddl-evidence`, chiefly `occur-in-order`: behavioral checks (the plan embeds the observed sequence at strictly increasing slices; bad evidence raises its contextual error), not gold diffs — evidence clauses can contain session-varying gensyms. |
| `tests/run-test-mcsat.sh` | The MC-SAT back end: each case fixes `--seed` and asserts the sampled marginals match the exact `maxent` ones to a tolerance. Skips cleanly (exit 0) when no WalkSAT v58 binary is found. |
| `tests/run-test-cli.sh` | The `solve.sh` / `map.sh` output contract: all five verdicts reach stdout, extracted bindings are printed and labelled, and stripping `;` lines reproduces the `.answer` file byte for byte. Also pins the verdict-detection fix — a solver banner containing "MaxSAT" must not read as a SAT verdict. |
| `tests/run-test-maxterm.sh` | The max-term back end: the hand-computable weighted case, the deliberately-pinned unweighted blind spot (0.5 everywhere), exclusive groups detected from the theory recovering the exact 1/3, backbone atoms flagged `[proved]`, and that a post-hoc prior equals the same weight compiled into the theory for its own atom but not for others. Skips without a MaxSAT solver. |
| `tests/run-test-maxsat.sh` | The MaxSAT side of `solve`: the solver keywords, `*solver-timeout*` (including that 0/-1/nil mean no limit), and MaxPre preprocessing. The key case asserts that preprocessing reproduces the un-preprocessed answer exactly, and a companion case checks MaxPre really did renumber (1-variable model expanded back to 3) so the first case is actually testing reconstruction. Skips cleanly when no MaxSAT solver is installed. |
| `tests/run-test-weight-formula.sh` | Formula-valued `weight`/`probability`: the reified biconditional appears, illegal nesting errors, and maxent learns a formula's weight so `P(φ)` hits its target. |

------

### `make-recognition-instance.lisp`

Lives in `SatPlan/Examples/Plan_Recognition/`. Turns a goal-plan-recognition
dataset problem into a runnable FiFO recognition instance.

```sh
sbcl --script make-recognition-instance.lisp \
     <domain.pddl> <template.pddl> <hyps.dat> <evidence-file> <out-dir> [<uniform-cost>]
```

From a dataset domain, a `template.pddl` (initial state with a `<HYPOTHESIS>`
goal placeholder), the `hyps.dat` candidate-goal list, and an evidence file
holding one `(occur-in-order <action>+)` sequence, it writes into `<out-dir>`:

- `<domain-root>-costs.pddl` — the domain with **uniform** action costs, so plan
  cost is `cost × plan length` and the distribution over trajectories is the
  Boltzmann model;
- `problem.pddl` — the template with its goal replaced by the **disjunction** of
  all candidate goals;
- `evidence-<i>.txt` for `i = 1..k` — the first `i` observations, for
  `--pddl-evidence-file`, so the explanation can be watched shifting as evidence
  accrues.

`<uniform-cost>` defaults to 1. With scnf weight scale `s`, each action multiplies
a trajectory's probability by `exp(−cost/s)`, so the Boltzmann temperature is
`β = cost/s`.

------

## The Lisp modules

Everything in `lisp/` is installed as a unit; the scripts load only what they
need. The interpreter's own API (`parse`, `instantiate`, `propositionalize`,
`satisfy`, `interpret`, `solve`) is documented in the [README](README.md).

| File | Role |
|---|---|
| `FiFO.lisp` | The interpreter: parser, CNF generation, SAT/MaxSAT invocation, answer extraction. Holds `*solver*`, `*cnf-format*`, and the solver-abbreviation table. |
| `pddl2fifo.lisp` | PDDL → FiFO translator: actions, costs, preferences, derived predicates, PDDL 3.0 `:constraints`, and the modal evidence language. |
| `planner.lisp` | The planning driver: horizon search, cost minimization, evidence conditioning, and the `--marginals` dispatch. |
| `reweight.lisp` | The independent log-odds weight estimator, and the shared `.scnf` reader/writer. |
| `maxent.lisp` | The exact iterative MaxEnt estimator, and `(marginals ...)` — exact marginal inference by enumeration. |
| `plearn.lisp` | The PDDL weight-learning orchestrator behind `learn-pddl.sh`. |
| `wmc.lisp` | The ADDMC bridge: `(wmc ...)` and `(marginals-addmc ...)`, plus the MCC weighted-CNF writer and the evidence clausifier the other back ends reuse. |
| `ddnnf.lisp` | FiFO's own d-DNNF compiler and circuit evaluator, the d4 importer, and circuit persistence. |
| `maxterm.lisp` | The max-term bridge: `(marginals-maxterm ...)` — `1+n` MaxSAT solves per query, exclusive-group detection from the theory, and post-hoc log-odds priors. Answers a different question from the counting back ends, and labels its output `(MAXTERM-MARGINAL ...)` to say so. |
| `mcsat.lisp` | The MC-SAT bridge: `(marginals-mcsat ...)`, the WCNF writer in MLN sign convention, CDCL seeding, and the diagnostics. |
| `satplan.wff` | The domain-independent SatPlan axioms — a *runtime* dependency of every generated planning `.wff`. |

------

## Solvers and external tools

Only SBCL and one SAT solver are required. Everything else is optional and needed
only by the feature that uses it; each is probed before use, and a missing binary
produces a specific message.

**To install them all, run [`bin/install-solvers.sh`](#install-solverssh)**, which
clones, builds, and installs everything below (except the alternatives noted as
out of scope there). The rest of this section is the reference: what each solver
is, where it comes from, and what its build needs.

### How FiFO finds a solver

| Solver | Lisp variable | Environment variable | Command-line flag | Fallback |
|---|---|---|---|---|
| SAT (feasibility) | `*solver*` | — | `planner.sh --solver`, or `(option *solver* ...)` in a `.wff` | `kissat` on `PATH` |
| MaxSAT (costs) | `*solver*` (rebound) | — | `WEIGHTED_SOLVER` at the top of `planner.sh`; `(option *solver* tt-glucose)` in a `.wff` | `tt-open-wbo-inc-Glucose4_1` on `PATH` |
| ADDMC | `*addmc*` | `ADDMC` | `--addmc-bin` (marginals.sh, wmc.sh, planner.sh) | `addmc` on `PATH` |
| d4 | `*d4*` | `D4` | `marginals.sh --d4-bin` | a `d4v2` checkout beside the FiFO repo: `d4v2/demo/compiler/build/compiler` |
| WalkSAT (MC-SAT) | `*walksat*` | `WALKSAT` | `marginals.sh --walksat-bin` | a `Walksat` checkout beside the FiFO repo: `Walksat/Walksat_v58_MC-SAT/walksat`; else `walksat` on `PATH` |

Two solver-name abbreviations are built in and resolved by `(option *solver* ...)`:
`tt-glucose` → `tt-open-wbo-inc-Glucose4_1` and `tt-intelsat` →
`tt-open-wbo-inc-IntelSATSolver`. Note that they are resolved **only** by the
`option` form — a bare `(setq *solver* ...)` needs the full binary name. Add your
own with `(option *solver-abbreviations* (("ms" "minisat-2.2")))`.

------

### Runtime

**SBCL + Quicklisp** — the interpreter is Common Lisp and is developed against
[SBCL](https://www.sbcl.org/). Quicklisp supplies `cl-ppcre`, the one library
dependency. On this system SBCL requires the long form `--eval`; the short `-e`
is not recognized and silently drops the forms.

------

### SAT solvers

The `solve` pipeline and the planner's feasibility phase use a plain
(non-weighted) SAT solver that reads DIMACS CNF. The default is `kissat`, but any
solver with the same command-line behavior can be selected (via the `*solver*`
variable, or the planner's `SAT_SOLVER` / `--solver` setting). Some options:

**Kissat**

- Source: https://github.com/arminbiere/kissat

A fast, self-contained sequential SAT solver in C by Armin Biere (a "keep it
simple and clean" reimplementation of the CaDiCaL ideas). Standard
`./configure && make` build, no dependencies; the default solver here. It is also
what seeds the MC-SAT sampler's initial assignment.

**MallobSat (Mallob)**

- Source: https://github.com/domschrei/mallob

A distributed, malleable SAT solver by Dominik Schreiber that scales across many
cores and machines via MPI, and has won the International SAT Competition's Cloud
Track repeatedly. Useful when a single machine is not enough.

**Painless**

- Source: https://github.com/lip6/painless

A framework for parallel (and, via D-Painless, distributed) SAT solving that
composes existing sequential solvers with configurable clause-sharing strategies;
a key contributor is Mazigh Saoudi (see also https://github.com/S-Mazigh).
Painless-based solvers have placed first in recent SAT Competition parallel
tracks.

------

### Weighted MaxSAT solvers

These minimize the total weight of the true weighted literals subject to the hard
clauses — i.e. they compute the **most probable model**. They read one of the two
weighted DIMACS formats FiFO emits (`(option *cnf-format* WCNF)` for the 2022
format with `h` lines, `WCNF-OLD` for the classic `p wcnf` header). See
[MAP inference](Probability/probability.md#map-inference-the-most-probable-model)
for how to drive one end to end.

**TT-Open-WBO-Inc** — *the default*

- Source: https://github.com/alexander-nadel-academic/tt-open-wbo-inc (the GitHub
  version corresponds to the MaxSAT Evaluation 2023 submission)
- Fork updated to compile cleanly on macOS:
  https://github.com/HenryKautz/tt-open-wbo-inc — upstream does **not** build on
  macOS as-is. The fork adds GCC warning fixes, Homebrew GCC auto-detection, a
  `bin/` output layout, a `make install` target, and the `<functional>` include
  `MaxSAT.h` needs for `std::function` (missing upstream; the IntelSAT build gets
  away with it because topor's headers pull it in transitively, the Glucose4_1
  build does not).

Standard C++ build (`make`), no commercial dependencies; reads WCNF and prints
improving solutions as it finds them (`o` lines), with the best model on the `v`
line. Because it is an **anytime** solver, an interrupted run yields its best
model so far rather than a proven optimum — `interpret` takes the last `o` line.
The planner uses the Glucose 4.1 build, `tt-open-wbo-inc-Glucose4_1`; the
IntelSAT build is the other option.

**NuWLS-c**

- Source: https://github.com/shaowei-cai-group/NuWLS-c
- Paper: Chu, Cai & Luo, *NuWLS: Improving Local Search for (Weighted) Partial MaxSAT*, AAAI 2023.

The winner of all four incomplete categories at MaxSAT Evaluation 2022, and the
lineage that has topped the anytime tracks since. It is an Open-WBO derivative —
the same family as TT-Open-WBO-Inc — with NuWLS as its stochastic-local-search
component, so it reads the same WCNF and prints the same `s`/`o`/`v` output.
Select it with `(option *solver* nuwls)` or `:solver "nuwls"`.

*Installation note:* `cd code && make`; the Makefile already writes the binary to
`bin/nuwls-c`. It needs `gmpxx.h` and `libgmpxx`, which on macOS live under the
Homebrew prefix that Apple clang does not search — `install-solvers.sh` puts them
on `CPATH`/`LIBRARY_PATH` for the build.

*Time limits:* like TT-Open-WBO-Inc it has no time-limit flag; it is an anytime
solver meant to be stopped with `SIGTERM`, on which it prints its best solution.
See `*solver-timeout*` in the [README](README.md#solver-time-limits).

**rc2-maxsat.py** — *FiFO's exact MaxSAT wrapper, and the default for `max-term`*

A thirty-line wrapper in `bin/` around PySAT's RC2, giving it the plain
command-line interface the rest of FiFO expects: one wcnf path in, `o` / `s` / `v`
lines out. RC2 is **core-guided and complete**, so it prints `s OPTIMUM FOUND` —
which the anytime solvers never do.

That guarantee is not decoration for `--solver max-term`: the estimator is a
*difference* of two minimum costs, so two unproven upper bounds do not cancel and
their difference is meaningless. `marginals.sh` counts unproven solves and warns.
On LogisticsCosts pb1 it is also *faster* than the anytime solver (12.4 s against
33.8 s for the same 15 atoms), since it stops once it has a proof.

*Installation:* `install-solvers.sh --only rc2`, which runs `pip install
python-sat` — the one entry that is a package rather than a clone-and-build, since
the wrapper itself ships with FiFO and only the library it wraps can be missing.
It is in the installer precisely because it is max-term's default: a run that
installed everything else and skipped this one would leave that back end broken.

**WMaxCDCL** — *native, exact, and the fastest of the exact options here*

- Source: https://github.com/jordicollcaballero/WMaxCDCL_Paper (the MaxSAT
  Evaluation 2023 submission, under `WMaxCDCL/code`)
- `install-solvers.sh --only wmaxcdcl`, installed as `wmaxcdcl`

Branch-and-bound with clause learning, from Coll et al., *Solving Weighted
Maximum Satisfiability with Branch and Bound and Clause Learning*. Complete, so
it prints `s OPTIMUM FOUND` alongside `o` and a bit-string `v` line — exactly the
three lines FiFO parses.

*Measured against `rc2-maxsat.py`* on 450 max-term solves: identical marginals,
but **2.4× slower** (95.0 s against 39.2 s), so RC2 remains the default. The
likely cause is the workload — `1 + n` solves of one instance differing by a
single unit clause, where per-invocation startup dominates — rather than solver
quality; a single large hard instance could well reverse it. See
[benchmarks.md](benchmarks.md#exact-maxsat-back-ends-compared).

*Installation note, and it differs from the README:* the README says `make rs`,
which is the **static** target. macOS ships no static libc, so that cannot link
there; `install-solvers.sh` uses `make r` (dynamic release) instead and renames
the result. The repository also ships prebuilt binaries, but they are
`ELF x86-64 GNU/Linux` and unusable on macOS — the source build is the only route.
The `WMaxCDCL-flags/` tree in the same repository is the same solver with ablation
switches for the paper's experiments; the installer builds the plain submission.

**EvalMaxSAT**

- Source: https://github.com/FlorentAvellaneda/EvalMaxSAT
- `install-solvers.sh --only evalmaxsat`

Core-guided exact MaxSAT (OLL over CaDiCaL), top-three in the weighted exact
category of recent MaxSAT Evaluations. All dependencies are vendored, so it is a
plain out-of-source `cmake` build with nothing to fetch.

*Caveat, measured:* the resulting binary **segfaults on macOS** — on a
three-clause weighted instance, and on a real FiFO wcnf after printing several
improving `o` lines. The build reports no errors. It is kept in the installer
because it is likely fine on Linux, but `rc2-maxsat.py` is the exact solver FiFO
defaults to.

**RC2 via PySAT**

- Install: `pip install python-sat` (PyPI: https://pypi.org/project/python-sat/)
- Source: https://github.com/pysathq/pysat
- Docs: https://pysathq.github.io/

RC2 ships inside the package — `from pysat.examples.rc2 import RC2` plus
`from pysat.formula import WCNF` and you are solving in about five lines. There is
also a command-line entry point (`rc2.py`).

**MaxHS**

- Source: https://github.com/fbacchus/MaxHS

An implicit-hitting-set MaxSAT solver. One important caveat: MaxHS uses CPLEX from
IBM as its MIP solver, so you need the CPLEX static libraries to link against.
CPLEX is free to faculty and graduate students through the IBM Academic Initiative
(https://www.ibm.com/academic), and you set the CPLEX library/include paths in the
Makefile before building. If the CPLEX dependency is a blocker, precompiled MaxHS
binaries from past MaxSAT Evaluations are available on the evaluation sites (e.g.
https://maxsat-evaluations.github.io/ → pick a year → "Descriptions/Downloads").

**CP-SAT (Google OR-Tools)**

- Easiest: `pip install ortools` (PyPI: https://pypi.org/project/ortools/)
- Source and binaries: https://github.com/google/or-tools
- Docs: https://developers.google.com/optimization/cp/cp_solver

No license hassle, no compilation, and the Python API is pleasant. Note that
CP-SAT takes its own model format rather than WCNF, so the model is built
programmatically (clauses as `AddBoolOr`, objective as `Minimize`). Utilities for
converting wcnf files into CP-SAT Python code are in
[wcnfsolvers](https://github.com/HenryKautz/wcnfsolvers).

------

### Preprocessors

**MaxPre 2**

- Source: https://bitbucket.org/coreo-group/maxpre2/src/master/ (Hannes Ihalainen,
  Helsinki CoReO group). The original MaxPre (Korhonen et al., SAT 2017) is a
  different repository, https://github.com/Laakeri/maxpre — build guides for
  other solvers often point there, so check which one a guide assumes.
- Selected with `*preprocessor*` / `--preprocessor`; optional, and used only by
  the MaxSAT path.

A WCNF preprocessor that simplifies a weighted instance before it reaches the
solver — bounded variable elimination, blocked clause elimination, subsumption,
label matching and more. Cheap, and often decisive on instances with many hard
clauses. FiFO drives it in standalone mode: preprocess, solve, then reconstruct
the model back into the original variable numbering.

*Installation note:* plain `make`; `src/Makefile` moves the binary to `maxpre` at
the repository root. It needs Boost's iostreams headers (`main.cpp` includes
`boost/iostreams/filter/gzip.hpp`), which on macOS need the Homebrew prefix on
`CPATH`/`LIBRARY_PATH` — `install-solvers.sh` handles that.

*Reconstruction is mandatory.* MaxPre renumbers and eliminates variables, so a
model of the preprocessed instance is meaningless against FiFO's `.map` file.
Interpreted directly it names the wrong atoms rather than failing outright. See
[Preprocessing with MaxPre 2](README.md#preprocessing-with-maxpre-2) for the
details FiFO papers over, including the fact that MaxPre's `reconstruct` parses
only `s OPTIMUM FOUND`.

*Not for probabilities.* MaxPre preserves the optimum cost and an optimal model;
it does **not** preserve the model count, so it changes `Z` and every marginal.
It belongs to the MAP path only, and the marginal back ends never touch it.

------

### Weighted model counters and knowledge compilers

These compute probabilities rather than a best model: the partition function `Z`,
and marginals as ratios of partition functions. Two of the four exact back ends
are internal to FiFO and need no binary at all.

**Enumeration (`--solver maxent`)** — *built in, no dependency*

In `lisp/maxent.lisp`. Enumerates the feasible set and sums weights directly.
Exact and trivially correct, hence the reference the other back ends are checked
against; exponential, so it is for small instances. `--node-limit` caps it.

**FiFO's d-DNNF compiler (`--solver ddnnf`)** — *built in, no dependency*

In `lisp/ddnnf.lisp`. Trace-compiles the hard clauses from maxent's DPLL search
(decisions → OR, disjoint components → AND, component cache → DAG;
smooth-by-construction) into a circuit, then gets `Z` and **all** marginals in two
passes. Compile once, query many: unit-literal evidence reuses the compiled
circuit, and `--save-circuit` / `--circuit` persist it across runs. FiFO-scale
instances only.

**ADDMC**

- Source: https://github.com/HenryKautz/ADDMC — a macOS fork of
  [vardigroup/ADDMC](https://github.com/vardigroup/ADDMC)
- Located via `*addmc*` / `ADDMC` / `--addmc-bin` (`marginals.sh`) or `--addmc`
  (`wmc.sh`), else `addmc` on `PATH`.

An algebraic-decision-diagram weighted model counter. Exact, and it scales far
past enumeration. FiFO feeds it the MCC-2020 weighted CNF format, whose
independent per-literal weights are what make FiFO's `W(L true) = exp(−θ)`,
`W(L false) = 1` model representable at all.

*Installation note:* build with the usual `make`; the fork also defaults CUDD's
terminal-merging epsilon to `0` (exposed as `--ep`, surfaced here as `--epsilon`)
instead of CUDD's `1e-12`. That default matters: FiFO scales costs by 100, so a
legitimate count can be `exp(−69) ≈ 1e-30`, which the stock default would floor to
zero.

**d4 (d4v2)**

- Upstream: https://github.com/crillab/d4v2
- macOS fork: https://github.com/HenryKautz/d4v2
- Located via `*d4*` / `D4` / `--d4-bin`, else a sibling `d4v2` checkout.

The state-of-the-art decision-DNNF knowledge compiler — years of work on branching
heuristics, hypergraph-partition decomposition, and component caching — able to
compile instances far too structured (high-treewidth) for the home-grown
compiler. FiFO uses it as a drop-in *producer* for the same circuit: d4 compiles
only the Boolean structure, and FiFO smooths its arc-format dump and applies the
weights at the leaves, so evidence handling, persistence, and querying are shared
with `--solver ddnnf`.

*Installation note:* the binary wanted is d4v2's `demo/compiler` executable
(`demo/compiler/build/compiler` after a build).

------

### Samplers

**WalkSAT v58 (MC-SAT mode)**

- Source: https://gitlab.com/HenryKautz/Walksat — the `Walksat_v58_MC-SAT`
  directory
- Located via `*walksat*` / `WALKSAT` / `--walksat-bin`, else a sibling checkout,
  else `walksat` on `PATH`.

The one **approximate** marginal back end. `-mcsat` runs the whole MC-SAT
algorithm (Poon & Domingos 2006) in C — outer slice sampling plus the inner
SampleSAT walk — so a single process yields every marginal, and it returns in
seconds on instances the exact counters cannot finish. The chain's stationary
distribution is exactly FiFO's Gibbs distribution.

*Installation note:* plain `make` in that directory. **Version 58 or later is
required** — `-mcsat` does not exist in v57 and earlier, which print their help
and exit; both `marginals.sh` and the test suite probe `-help` for `-mcsat` and
refuse rather than silently running the wrong thing. If `~/bin/walksat` is an
older build, point `WALKSAT` at the v58 binary explicitly.

*Reading the output:* MC-SAT mixes poorly on strongly coupled models, so the run
prints an effective-sample-size **efficiency** line and a **mixing** (Hamming
distance) line; a low efficiency or a `FROZEN` verdict means the marginals are
wrong, not merely noisy. Details in
[Probability/probability.md](Probability/probability.md#approximate-marginals-by-mc-sat-sampling).

------

### Which component uses which solver

[Which script runs which part](#which-script-runs-which-part) gives the same
scripts by pipeline stage and output; this table gives them by solver.

| Component | Query | Solver |
|---|---|---|
| `solve.sh` | satisfiability | SAT — `kissat` |
| `map.sh` | MAP / most probable model | MaxSAT — `tt-open-wbo-inc-*`, `nuwls-c` (anytime); `wmaxcdcl`, `EvalMaxSAT_bin`, `rc2-maxsat.py` (exact) |
| `solve` (plain `.wff`) | satisfiability | SAT — `kissat` |
| `solve` with `(option *cnf-format* WCNF)` | MAP / most probable model | MaxSAT — `tt-open-wbo-inc-*` |
| `planner.sh` horizon search | satisfiability | SAT — `kissat` |
| `planner.sh` cost minimization | MAP | MaxSAT — `tt-open-wbo-inc-Glucose4_1` |
| `recognize.sh` | `2n` conditional MAP queries | MaxSAT (via `planner.sh`) |
| `solve` with `:solver "nuwls"` | MAP / most probable model | MaxSAT — `nuwls-c` |
| `solve` with `:preprocessor "maxpre"` | MAP, on a simplified instance | MaxPre 2 + any MaxSAT solver |
| `marginals.sh --solver maxent` | exact marginals | none — built-in enumeration |
| `marginals.sh --solver ddnnf` | exact marginals | none — built-in d-DNNF compiler |
| `marginals.sh --solver addmc` | exact marginals | ADDMC |
| `marginals.sh --solver d4` | exact marginals | d4 (structure) + FiFO circuit evaluation |
| `marginals.sh --solver mc-sat` | approximate marginals | WalkSAT v58 `-mcsat` (+ `kissat` to seed) |
| `marginals.sh --solver max-term` | max-term pseudo-marginals | **exact** MaxSAT — `rc2-maxsat.py` (default) or `wmaxcdcl`; an anytime solver is selectable but unproven |
| `wmc.sh` | partition function `Z` | ADDMC |
| `learn.sh --method log-odds` | closed-form fit | none |
| `learn.sh --method maxent` | exact iterative fit | none — built-in enumeration |
| `learn-pddl.sh` | either of the above | none |
