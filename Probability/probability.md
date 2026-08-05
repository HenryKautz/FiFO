# Probabilistic FiFO: Marginal Inference and Weight Learning

## Table of Contents

- [README.md](../README.md) — the FiFO language reference and user guide.
- [SatPlan/satplan.md](../SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- $\color{red}{\textbf{Probability/probability.md}}$ — the probabilistic layer in practice: computing marginals under a weighted theory and learning weights from target probabilities.
- [Probability/probability-background.md](probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [FAQ.md](../FAQ.md) — frequently asked questions about modeling with FiFO.
- [benchmarks.md](../benchmarks.md) — measured results: horizons, CNF sizes, and compilation costs.

A FiFO theory with weighted literals defines a probability distribution over the
models of its hard clauses. That single fact supports two directions of
computation, and this guide covers how to run both:

- **Marginal inference (weights → probabilities):** given the weights, compute
  the probability that each atom is true — and, with evidence, conditional
  probabilities. Four implemented back ends: exact enumeration, the ADDMC
  weighted model counter, FiFO's own d-DNNF compiler, and the external d4
  compiler.
- **Weight learning (probabilities → weights):** given target marginal
  probabilities for the weighted atoms, recover the integer literal weights
  that realize them. Two implemented estimators: independent log-odds and
  exact iterative MaxEnt.

The two directions are inverses, and the learner uses inference as its inner
loop: it adjusts the weights until the model's *actual* marginals match the
targets. For the theory — the full range of learning data regimes,
sampling-based inference methods not yet implemented, and provenance — see
[probability-background.md](probability-background.md).

For **PDDL planning** problems you usually drive both directions from the
planner instead of running these tools directly: write `:probability` specs on
actions / preferences / `:fluent-cost` forms and use `bin/learn-pddl.sh` for
learning, and `planner.sh --marginals [--pddl-evidence ...]` for conditioned
marginals at the working horizon. See
[../SatPlan/satplan.md](../SatPlan/satplan.md).

------

## The probability model

FiFO's WCNF encoding defines a Gibbs distribution over the feasible set:

$$P_\theta(x) = \frac{1}{Z(\theta)} \exp!\left(-\sum_a \theta_a N_a(x)\right) \cdot \mathbf{1}[x \in \mathcal{F}]$$

where $\mathcal{F}$ is the set of assignments satisfying all hard clauses, and $\theta_a$ are the weights (costs). The marginal probability of literal $L$ is:

$$P(L) = \sum_{x \in \mathcal{F}:, L(x)=1} P_\theta(x) = \frac{Z_L(\theta)}{Z(\theta)}$$

a ratio of two partition functions over $\mathcal{F}$, both restricted by the hard clauses. This is weighted model counting (#WMC), and it's #P-hard in general — so the practical question is which back end fits the instance.

In FiFO syntax, a `(WEIGHT L w)` line is the cost paid when literal `L` is true
(`W(L true) = exp(-w/scale)`, `W(L false) = 1`); a target marginal `p` for a
literal corresponds to the cost-when-true `θ = log((1-p)/p)`, whose sign decides
which polarity carries the (positive) weight.

------

## Marginal inference: weights → probabilities

### Exact enumeration (small instances)

The simplest back end enumerates the feasible set $\mathcal{F}$ and sums weights directly:

```
for each x in enumerate(F):
    w(x) = exp(-sum_a theta_a * N_a(x))
    for each literal L:
        if L(x) = 1: acc_L += w(x)
    Z += w(x)
P(L) = acc_L / Z
```

`lisp/maxent.lisp` provides

```lisp
(marginals "file.scnf" &key out-file weighted-only scale (node-limit 5000000) (verbose t))
```

which reads a weighted `.scnf` (hard `(OR ...)` clauses plus `(WEIGHT literal w)` costs), enumerates the feasible set, and computes the exact marginal `P(atom = true)` of **every** atom under the Gibbs distribution `P(x) ∝ exp(-Σ weights of true literals)` — weighted and unweighted atoms alike, so SatPlan `Holds` state atoms are reported alongside `Occurs` action atoms. It reuses the same feasible-set enumeration the MaxEnt fit uses, but tracks every variable rather than only the weighted ones. With no weights the distribution is uniform over the feasible set. It honors the same `scale` as the other back ends (auto-read from the `scale: N` header, `:scale 1` for raw weights — see "Weight scale" below), so all solvers report the same marginals on the same file. It prints one `(MARGINAL <atom> <probability>)` line per atom (sorted), and `:out-file` also writes them to a file. Being exact enumeration, it is for small instances (the `node-limit` caps the search) — the WMC and circuit back ends below are the path to scale, and the sampling methods described in [probability-background.md](probability-background.md) go beyond that.

Pass `:weighted-only t` to report only the atoms that carry a weight; this also restricts the enumeration to those variables (unweighted ones collapse into a multiplicity), the same cheaper enumeration the MaxEnt fit uses — useful when the state-atom marginals aren't needed.

The shell wrapper is `bin/marginals.sh`:

```sh
# every atom's marginal for a weighted scnf
bin/marginals.sh problem.scnf

# also save them; cap the enumeration
bin/marginals.sh problem.scnf --out problem.marginals --node-limit 1000000

# only the weighted (e.g. Occurs action) atoms
bin/marginals.sh problem.scnf --weighted-only
```

A handy way to produce the input is `bin/planner.sh <problem.pddl> --stop-after scnf`, which writes the instantiated `.scnf` without solving. The lisp is located via `FIFO_LISP` (see the README's Installation section).

------

### Weighted model counting via ADDMC

Where the enumeration above is exact but exponential, **ADDMC** (the algebraic-decision-diagram weighted model counter) compiles the same weighted `.scnf` to an algebraic decision diagram, so it scales to instances far beyond brute enumeration. `lisp/wmc.lisp` provides

```lisp
(wmc "file.scnf" &key wcnf-file keep-wcnf scale epsilon evidence evidence-file addmc verbose)             ; partition function Z
(marginals-addmc "file.scnf" &key out-file weighted-only scale epsilon evidence evidence-file addmc verbose)  ; per-atom marginals
```

`wmc` returns the partition function `Z = Σ_{x∈F} exp(-cost(x))` — itself a weighted model count. `marginals-addmc` computes `P(a) = Z[clauses ∧ a] / Z` by running ADDMC once for `Z` and once more per reported atom with a unit clause clamping that atom true; it accepts the same `:weighted-only` restriction as `marginals`.

**The encoding.** The bridge emits the **MCC-2020 weighted CNF** format (ADDMC's `--wf 4`). FiFO's model — `W(L true) = exp(-θ)`, `W(L false) = 1` for a literal `L` with cost-when-true `θ` — maps directly: each charged literal becomes a weight line `w <lit> exp(-θ)`, and the opposite literal keeps ADDMC's default weight `1.0`. (Tied/duplicate `(WEIGHT ...)` forms on the same literal sum their costs first.) MCC's independent per-literal weights are what make this work — the Cachet format, which forces `W(¬v) = 1 − W(v)`, cannot represent FiFO's `W(v=0) = 1`.

This was cross-checked against the enumeration back end: on the test instances the two agree to the last double-precision bit (max `|P_enum − P_addmc| = 0`).

**The ADDMC build.** ADDMC is a separate executable — a macOS fork at [github.com/HenryKautz/ADDMC](https://github.com/HenryKautz/ADDMC) (of [vardigroup/ADDMC](https://github.com/vardigroup/ADDMC)). Build it, then put `addmc` on `PATH`, set the `ADDMC` environment variable, or pass `--addmc-bin`. The fork also defaults CUDD's terminal-merging epsilon to `0` — exposed as ADDMC's `--ep` option, surfaced here as `--epsilon` / `:epsilon` — instead of CUDD's flooring default of `1e-12`. CUDD merges ADD terminal values within epsilon of each other, including merging tiny values into the `0` terminal. FiFO scales costs by an integer factor (100 by default) for MaxSAT, so a legitimate weighted count can be as small as `exp(-69) ≈ 1e-30`, which the `1e-12` default would round down to `0`. With epsilon `0` the count is exact down to ordinary double-precision underflow — the same limit the Lisp enumeration hits — and a user who wants to trade exactness for speed/memory can set a positive `--epsilon`.

The shell wrappers:

```sh
# partition function Z of a weighted scnf
bin/wmc.sh problem.scnf

# marginals: the back end is --solver maxent (Lisp enumeration, the default) or
# --solver addmc (the ADDMC counter, which scales further)
bin/marginals.sh problem.scnf                                 # default: maxent
bin/marginals.sh problem.scnf --solver addmc
bin/marginals.sh problem.scnf --solver addmc --weighted-only --out problem.marginals
bin/marginals.sh problem.scnf --solver addmc --epsilon 1e-9   # faster, approximate
bin/marginals.sh problem.scnf --addmc-bin /path/to/addmc      # implies --solver addmc
```

**Weight scale.** This matters more than it looks. The weight-learning pipeline writes *integer* weights, the real costs multiplied by a scale (default 100) so MaxSAT has integers to optimize, and records `scale: N` in the `.scnf` header. The absolute scale is irrelevant to MaxSAT — it only minimizes a sum — but it is *everything* to a probability: `P(x) ∝ exp(−cost(x))`, so weights of 69 versus 0.69 describe utterly different distributions. At the ×100 scale the distribution is essentially zero-temperature: it collapses onto the minimum-cost models, the partition function underflows toward `0`, and the marginals are pulled to the corners. On the 2-atom `(OR (P A) (P B))` example with learned weight 69, the marginals come out `0.50`; at the true weight `0.69` they are `0.60` — which is exactly the target the learner was fitting.

So all of `marginals` (enumeration), `marginals-addmc`, `wmc`, and the circuit back ends divide the integer weights by the scale before exponentiating. By default they read `scale: N` from the header (1.0 if absent, e.g. hand-written or raw-SatPlan-cost scnfs); pass `:scale 1` / `--scale 1` to count with the raw integer weights, or `:scale n` to force a value. The shell flag is `--scale n` on `wmc.sh` and on `marginals.sh` for **all** solvers — so every back end agrees on the same file.

Cost note: `marginals-addmc` does one ADDMC run for `Z` plus one per reported atom, so `--weighted-only` (or a small atom set) keeps the run count down on instances with many state atoms.

------

### d-DNNF compilation, FiFO's own (no external binary)

`lisp/ddnnf.lisp` is a **pure-Lisp d-DNNF compiler + circuit evaluator** — the third back end alongside `maxent` (enumeration) and `addmc` (the external counter). Its reason to exist is **compile-once / query-many**: where ADDMC's expensive contraction produces only a number and is re-run for every count, this compiles the hard theory once into a reusable circuit, then answers any number of queries — different weightings, different evidence — cheaply.

**What it builds.** A trace-based knowledge compiler grown from the exhaustive DPLL already in `maxent.lisp`: instead of summing counts, the search records itself as a DAG — each decision branch (`x` / `¬x`) → a deterministic **OR** node, each split into variable-disjoint clause components → an **AND** node, and a component cache (signature → node) turns the tree into a shared DAG. The result is a smooth, deterministic, decomposable NNF (a d-DNNF). Smoothness is *by construction*: a variable that drops out of a subproblem is reintroduced as `free(v) = OR(+v, −v) = (W(+v)+W(−v))`. Weights live **outside** the Boolean structure (`W(L)=exp(−cost/scale)`, exactly as in the ADDMC bridge), so one circuit serves any weighting.

**The three properties, and why smoothness matters.** Writing *scope(n)* for the set of variables appearing below a node, a d-DNNF guarantees: **decomposable** — each AND node's children have disjoint scopes; **deterministic** — each OR node's children are mutually exclusive (no assignment satisfies two at once); and **smooth** — each OR node's children all have the *same* scope. The counting/marginal arithmetic below relies on all three. Smoothness is the subtle one: if an OR branch omits a variable in the node's scope, that variable is *free* on the branch, so the branch stands for `2` models of the full space (or, weighted, a factor `W(+v)+W(−v)`), not one. For example `(x₁∧¬x₂) ∨ (x₂∧x₃)` over `{x₁,x₂,x₃}` is not smooth — the left branch drops `x₃`, the right drops `x₁` — and a naïve leaf count gives `2` instead of the correct `4`. Smoothing fixes this by conjoining the tautology `free(v)=(v∨¬v)` into any branch missing `v`, equalizing the scopes without changing the function; then **every model uses exactly one literal of every variable in scope**, which is exactly what the leaf-sum marginal pass assumes. (The home-grown compiler is smooth by construction; d4's decision-DNNF is decomposable and deterministic but *not* smooth, so its dump is smoothed on import — see `--solver d4` below.)

**How it queries.** Two passes over the DAG (Darwiche's value/derivative scheme): an up pass gives node values — the root value is `Z` — and a down pass gives node derivatives, from which, for every variable `v`, `Z[v=true] = Σ over the +v leaves of value·derivative` and `P(v=true) = Z[v=true] / Z`. **All** marginals come out of one up/down pass — `O(circuit)` — versus ADDMC's one full count per atom.

```lisp
(ddnnf-compile "file.scnf" &key scale verbose)            ; the expensive step: scnf -> circuit
(ddnnf-query   circuit &key clamp)                        ; (values Z ztrue-vector), reuses it
(ddnnf-marginals "file.scnf" &key circuit save-circuit out-file weighted-only scale
                                  evidence evidence-file verbose)
(ddnnf-marginals-sets "file.scnf" "sets.txt" &key ...)    ; compile once, one line of evidence per query
(ddnnf-save circuit "file.dnnf") (ddnnf-load "file.dnnf") ; persist / restore a compiled circuit
```

**Persistence.** The circuit is a flat, topologically-ordered array of nodes with integer-id children — plain readable data — so it serializes to a single s-expression (a `.dnnf` text file) that round-trips across SBCL sessions with no fasl or version coupling. Compile once, save, and reuse on later runs. Because weights are stored separately from the structure, a loaded circuit can be **re-weighted by `--scale` without recompiling**.

```sh
# compile once, save the artifact, and report the unconditioned marginals
bin/marginals.sh problem.scnf --solver ddnnf --save-circuit problem.dnnf

# later, separate runs: load the artifact and query WITHOUT recompiling
bin/marginals.sh --circuit problem.dnnf --evidence '(not (occurs (turn-on s1) 1))'
bin/marginals.sh --circuit problem.dnnf --evidence '(occurs (turn-off s1) 1)'
bin/marginals.sh --circuit problem.dnnf --scale 1            # re-weight, no recompile
```

**Evidence reuse — the one rule that matters.** Unit-literal evidence (ground facts) becomes a *clamp* on leaf weights and **reuses** the compiled circuit; only non-unit evidence (a disjunction, or an implication that doesn't reduce to units) is recompiled, from the circuit's stored clauses. So the compile is amortized across all the literal-evidence queries — exactly the case ADDMC and enumeration cannot amortize.

**Scope.** This is for **FiFO-scale** instances — the same envelope where `maxent` enumeration is viable, but conditionable and persistable. A node cap (`*ddnnf-node-limit*`, also `--node-limit`) makes it fail gracefully on a too-structured (high-treewidth) instance and point you at `--solver addmc`, which remains the tool for large single counts. The marginals were cross-checked against the enumeration back end on the test instances: exact agreement (max `|P_enum − P_ddnnf| = 0`), including under unit-clamp vs. recompiled-with-evidence and save→load.

**Outgrowing it.** The home-grown compiler is for FiFO-scale; when an instance is too structured for it, the *same* circuit machinery can be driven by the state-of-the-art external **d4** compiler instead — see [d-DNNF via the external d4 compiler](#d-dnnf-via-the-external-d4-compiler) below.

------

### d-DNNF via the external d4 compiler

The home-grown compiler above is deliberately FiFO-scale. **d4** ([d4v2](https://github.com/crillab/d4v2)) is the state-of-the-art decision-DNNF knowledge compiler — years of work on branching heuristics, hypergraph-partition decomposition, and component caching — and it can compile instances far too structured (high-treewidth) for the trace compiler. FiFO can use it as a drop-in *producer* for the very same circuit, via `ddnnf-compile-d4` / `--solver d4`.

**Producer behind the same struct.** The key design point is that d4 replaces only the *front end*. It compiles the **Boolean structure** — the hard clauses, which FiFO emits as plain DIMACS — and nothing else. FiFO keeps the weights on its own side and applies them at the leaves during evaluation, so d4 never sees a weight. Its dumped circuit is parsed into the identical node struct the home-grown compiler builds, and then **everything downstream is reused unchanged**: the two-pass value/derivative evaluator, all-marginals-at-once, unit-evidence clamping and reuse, non-unit recompilation, and `.dnnf` save/load. `--save-circuit` / `--circuit` and `--scale` re-weighting all work on a d4-produced circuit exactly as on a home-grown one.

**Smoothing on import.** d4 emits a decision-DNNF in its arc format that is decomposable and deterministic but **not smooth** (a branch may drop a variable that a sibling constrains). Since the leaf-sum marginal pass assumes smoothness (see [above](#d-dnnf-compilation-fifos-own-no-external-binary)), FiFO smooths the dump on import — conjoining `free(v)=OR(+v,−v)` into any branch missing `v`, and adding a `free(v)` at the root for variables that appear in no clause. The result is a smooth, deterministic, decomposable circuit indistinguishable (to the evaluator) from a home-grown one.

```sh
# compile the structure with d4, report all marginals (weights applied by FiFO)
bin/marginals.sh problem.scnf --solver d4
bin/marginals.sh problem.scnf --solver d4 --evidence '(occurs (turn-off s1) 1)'
bin/marginals.sh problem.scnf --solver d4 --save-circuit problem.dnnf   # persist, then reuse
bin/marginals.sh --circuit problem.dnnf --evidence '(not (occurs (turn-on s1) 1))'
```

**Interface & dependency.** `--solver d4` (and the Lisp `ddnnf-compile-d4`, or `ddnnf-marginals … :compiler :d4`) needs the d4 compiler binary — d4v2's `demo/compiler` executable — located via the `*d4*` Lisp variable, the `D4` environment variable, or `--d4-bin <path>`. Build it from a d4v2 checkout (a macOS fork is at [github.com/HenryKautz/d4v2](https://github.com/HenryKautz/d4v2)); it is entirely optional — only `--solver d4` uses it, and every other back end works without it.

Cross-checked against the enumeration back end: exact agreement (max `|P_enum − P_d4| = 0`) on the weighted test instances, including unit-evidence reuse and save→load of a d4-produced circuit.

The d4 compile times and d-DNNF circuit sizes on the LogisticsCosts benchmarks — at each problem's smallest feasible horizon and the way they explode a slice or two beyond it — are tabulated in [benchmarks.md](../benchmarks.md#d-dnnf-compilation-on-the-logisticscosts-benchmarks).

------

### Conditioning on evidence

`wmc`, `marginals-addmc`, and the `ddnnf`/`d4` solvers all take **evidence** to compute *conditional* quantities: `P(A | E) = WMC(theory ∧ E ∧ A) / WMC(theory ∧ E)`. Conditioning on `E` simply means adding `E` to the **hard** clauses (evidence has probability 1), so with `E` supplied every reported marginal becomes `P(atom | E)` and `wmc` returns the conditioned partition function `WMC(theory ∧ E)`. (The `--evidence` / `--evidence-file` flags below apply to `--solver addmc`, `--solver ddnnf`, and `--solver d4`; with the circuit solvers, unit-literal evidence reuses the compiled circuit while non-unit evidence recompiles.)

- `:evidence` (Lisp) / `--evidence '<form>'` (shell, repeatable) — a **ground** FiFO formula. It is clausified by FiFO's own parser (`(implies (P A) (P B))` → `(OR (NOT (P A)) (P B))`, etc.) and conjoined with the theory. Multiple forms are conjoined.
- `:evidence-file` / `--evidence-file <f>` — a file of ground FiFO formulas, conjoined with any `--evidence` forms.

```sh
# all marginals conditioned on an action not occurring
bin/marginals.sh problem.scnf --solver addmc --evidence '(not (occurs (turn-on s1) 1))'

# a non-literal ground condition, and the conditioned partition function
bin/marginals.sh problem.scnf --solver addmc --evidence '(implies (holds (on s1) 1) (p a))'
bin/wmc.sh       problem.scnf --evidence '(not (p a))'      # WMC(theory ^ ~A)
```

The evidence must be **ground** — propositional, over atoms already named in the `.scnf` — because the `.scnf` has discarded the domains and schemas needed to ground quantifiers or new terms. Two consequences: (1) atoms introduced only by the evidence (e.g. Tseitin auxiliaries from a complex formula) are not themselves reported as marginals; (2) **quantified or parametric** evidence belongs at the `.wff` level — add the assertion to the source and re-`instantiate`, which conditions the whole theory with the correct grounding. For the WMC to stay exact, FiFO's clausification of the evidence must be model-count-preserving (full Tseitin equivalences); the small ground formulas above clausify with no auxiliaries at all. The conditional was cross-checked against the enumeration solver run on a `.scnf` with the same evidence baked in as a hard clause: exact agreement.

If `E` contradicts the theory, `WMC(theory ∧ E) = 0` (the evidence is impossible) and `marginals-addmc` reports that no marginals exist.

For a SatPlan problem the planner lifts all of this to the PDDL level: `planner.sh … --marginals --counter addmc --pddl-evidence '<modal form>'` conditions on evidence that may be quantified over the time slices, instantiates the problem conjoined with it, and reports `P(atom | evidence)` at the working horizon. A complete end-to-end walkthrough on the Switch domain — plain plan, evidence reshaping the plan, the separate evidence scnf, and conditional marginals — is in [../SatPlan/satplan.md](../SatPlan/satplan.md#worked-example-the-switch-domain-end-to-end).

------

## From inference to learning

The two halves of this guide meet in a simple picture. Planning and learning
already give:

```
beliefs → weights (learning)     weights → plan (MaxSAT)
```

and marginal inference adds:

```
weights → marginals (inference)
```

which enables: (a) sanity-checking learned weights against intended beliefs; (b) computing posterior beliefs about which actions will be used given the cost structure; (c) the E-step in EM for the hidden-weighted-variables regime (Case 3 of [probability-background.md](probability-background.md)) — where you need $\mathbb{E}_\theta[\Phi \mid o]$, a clamped marginal inference call.

The key difference from the MaxSAT oracle used in planning: the MaxSAT oracle returns the single minimum-cost assignment, while marginal inference sums over all feasible assignments weighted by $e^{-\text{cost}}$. At zero temperature they agree; at finite temperature, marginals spread probability over suboptimal plans in proportion to how nearly-optimal they are.

------

## Weight learning: probabilities → weights

**Input:** an instantiated `.scnf` file (the output of FiFO's `instantiate`) whose
`(PROBABILITY <literal> p [gid])` lines carry a **target marginal probability**
`p ∈ [0.0, 1.0]` — the probability that `<literal>` should be true. The optional
`gid` is a **tie-group id**: every ground instance of one source-`.wff`
`(probability ...)` form shares a `gid`, and the pipeline fits **one** weight per
group (parameter tying — see [probability-background.md](probability-background.md)
§1–2). `instantiate` writes these forms automatically from a `.wff`; a hand-written
`.scnf` may omit `gid`, in which case each line is its own untied group.

`PROBABILITY` is a distinct keyword from FiFO's `(WEIGHT <literal> c)` cost form
on purpose: the pipeline's **input** speaks probabilities (`PROBABILITY`) and its
**output** speaks integer costs (`WEIGHT`). They never share syntax, so an output
file is not a valid input — re-running the pipeline on its own output is rejected
rather than silently misread.

**Output:** `<root>_reweighted.scnf`, identical to the input except that every
`PROBABILITY` line is replaced by a **positive-integer** `WEIGHT` on a single
polarity (the other polarity is implicitly zero), per the README shift+scale
convention. Degenerate certainties (`p = 0` / `p = 1`) become hard unit clauses
rather than infinite weights. The original `PROBABILITY` assertions are echoed
into the output as `;;` comment lines, recording the provenance of the weights.
The result feeds straight into FiFO's `propositionalize` → MaxSAT (the `;`/`;;`
comment lines are skipped by the reader).

For **PDDL planning** problems, you usually don't run this pipeline directly:
write `:probability` specs on actions / preferences / `:fluent-cost` forms and use
`bin/learn-pddl.sh`, which translates, learns with the estimators below, and writes
the learned costs back into copies of the PDDL files. See the README's
"Learning costs and weights from probabilities".

### Two estimators

| File | Function | Method | Use when |
|---|---|---|---|
| `reweight.lisp` | `reweight` | Independent log-odds (closed form) | Atoms are (near-)independent; fast, no solver |
| `maxent.lisp` | `maxent-reweight` | Exact iterative MaxEnt over the feasible set | Hard clauses couple the weighted atoms |

`reweight` ignores the clauses and sets `θ = log((1-p)/p)` per atom directly.
`maxent-reweight` corrects for clause coupling: it enumerates the feasible set
once and iterates `θ` until the model's marginals match the targets. When the
atoms happen to be independent, the two agree exactly.

### Running it

The shell wrapper `bin/learn.sh` is the easiest entry point — it selects the
estimator (`--method log-odds` (default) or `--maxent`), exposes every option
below as a flag, and prints them all with `learn.sh --help`:

```sh
bin/learn.sh myfile.scnf                 # log-odds -> myfile_reweighted.scnf
bin/learn.sh myfile.scnf --maxent --wff myfile.wff   # max-ent + .wff write-back
```

To call the estimators directly: SBCL is required (the same toolchain as FiFO).
The estimators live in `lisp/` (installed to `~/lib/fifo/lisp`); load them by
path. The example `.scnf` files referenced below are in this `Probability/`
directory.

#### Independent log-odds

```sh
sbcl --non-interactive \
     --eval '(load "lisp/reweight.lisp")' \
     --eval '(reweight "myfile.scnf")'
```

Writes `myfile_reweighted.scnf`. Options:

- `:out-file "path.scnf"` — override the output path.
- `:scale N` — integer resolution (default `100`); real weight of any emitted
  line is `integer / N`. Larger `N` = finer resolution (and a sharper / lower-
  temperature distribution).
- `:wff "source.wff"` — also write the learned weights **back into a copy of the
  source `.wff`** (see "Tie groups and `.wff` write-back" below).
- `:wff-out "path.wff"` — override the write-back path (default
  `<wff-root>_weighted.wff`).

#### Exact iterative MaxEnt

```sh
sbcl --non-interactive \
     --eval '(load "lisp/maxent.lisp")' \
     --eval '(maxent-reweight "myfile.scnf")'
```

(`maxent.lisp` loads `reweight.lisp` for the shared helpers.) It prints a
target-vs-achieved marginal report and writes the same report as comment lines in
the output. Options:

- `:out-file`, `:scale`, `:wff`, `:wff-out` — as above. With tie groups the fit
  uses one shared `θ` per group (sufficient statistic = the group's true-count),
  matching each group's **mean** marginal to its target; the report is per group.
- `:consider-weights` — whether explicit `(WEIGHT ...)` lines take part in the
  fit (default `t`); see "Mixing explicit weights and probabilities" below.
- `:eta` — step size for the damped diagonal-Newton update (default `1.0`).
- `:tol` — convergence tolerance on `max |achieved − target|` (default `1e-5`).
- `:max-iters` — iteration cap (default `5000`).
- `:verbose` — print the report to stdout (default `t`).

#### Mixing explicit weights and probabilities

A file may carry both explicit `(WEIGHT literal w)` costs and `(PROBABILITY ...)`
targets. **Only the probability-derived weights are adjusted** — the explicit
weights are always copied to the output unchanged (and left untouched in the
`.wff` write-back). An atom may not have both a weight and a probability target
(that is a contradictory double specification, and is an error).

For `maxent-reweight`, `:consider-weights` controls whether the explicit weights
take part in the fit:

- `t` (default): they are held **fixed** in the model energy, so the probability
  weights are learned *in their presence* — the realized marginals account for
  them. (Example: with a hard `(or A B)`, a large fixed cost on `A`, and a target
  `P(B)=0.6`, `B`'s learned cost comes out much higher than it would in
  isolation, because the model rarely picks `A`.)
- `nil`: the fit ignores them (faster), so the probability weights are fit as if
  the explicit weights were absent; they are still passed through to the output.

The independent log-odds estimator (`reweight`) ignores all coupling, so it has
no `:consider-weights` knob — it always passes explicit weights through without
letting them influence the conversion.

#### Tie groups and `.wff` write-back

The intended end-to-end flow starts and ends at the **`.wff`** level:

1. Write a `.wff` with `(probability <literal> <p> [<tie-label>])` forms and
   `instantiate` it on a **small** domain → a `.scnf` whose `PROBABILITY` lines
   carry tie-group ids.
2. Run `reweight` / `maxent-reweight` with `:wff "source.wff"`. Besides the
   reweighted `.scnf`, this writes `source_weighted.wff`: a copy of the source in
   which each `(probability ...)` form is replaced by **one** tied `(weight ...)`
   cost (or a hard clause for `p = 0`/`1`). Because the weight sits on the schema,
   re-instantiating gives every grounding the same (tied) cost.
3. Edit `source_weighted.wff` to enlarge the domains and re-instantiate at full
   size — schema tying carries the small-domain weights over (cf.
   [probability-background.md](probability-background.md) §2, §10).

Two well-formedness checks are enforced when grouping: a literal targeted by two
different tie groups (**overlapping** forms) is an error, and the target `p` must
be **constant** within a group.

#### Downstream

Either output is an ordinary `.scnf`. To compile and solve:

```sh
# from the FiFO project root, with lisp/FiFO.lisp loaded
(propositionalize "Probability/myfile_reweighted.scnf")   ; -> .cnf/.wcnf + .map
(satisfy ...)                                              ; or run a MaxSAT solver
```

Add `(OPTION WEIGHTS WCNF)` to the input (it is passed through) to get a `.wcnf`
for a MaxSAT solver; otherwise `propositionalize` emits plain `.cnf` with
`cw` comment lines.

### Input format example

```lisp
(OR (BUY BANANA) (BUY STEAK) (BUY MILK))   ; a hard clause
(PROBABILITY (BUY BANANA) 0.5)             ; target marginal probabilities
(PROBABILITY (BUY STEAK) 0.25)
(PROBABILITY (BUY MILK) 0.9)
(PROBABILITY (NOT (BUY EGGS)) 0.2)         ; target on a negated literal: P(EGGS)=0.8
(PROBABILITY (BUY SPAM) 0.0)               ; certainty -> hard clause
(PROBABILITY (BUY BREAD) 1.0)              ; certainty -> hard clause
(OPTION WEIGHTS WCNF)                      ; passed through
```

A target on `(NOT L)` is normalized to the positive atom (`p` on `(NOT L)` means
`P(L)=1-p`). Specifying the same atom twice is an error.

The corresponding `<root>_reweighted.scnf` echoes each of these as a `;;` comment
and emits the learned `(WEIGHT ... <integer>)` lines below them.

### Worked examples in this directory

- `test_marginals.scnf` → `test_marginals_reweighted.scnf` — the example above;
  the `OR` couples BANANA/STEAK/MILK, so the MaxEnt weights differ from the
  independent ones, while the uncoupled EGGS is identical under both.
- `test_coupled.scnf` → `test_coupled_reweighted.scnf` — `(OR A B)` with both
  targets `0.6`; MaxEnt converges to the analytic `θ = ln 2` (integer weight 69),
  achieving exactly 0.6, where the independent estimator would get it wrong.

### Limitations (current)

- **Exact MaxEnt is small-instance only.** `maxent-reweight` enumerates the
  feasible set (node cap ~5M, then it errors). This is the "do the counting on
  small instances" regime; a sampler / weighted model counter would replace the
  enumeration for scale.
- **Inconsistent targets.** If the hard clauses are themselves unsatisfiable,
  `maxent-reweight` errors (no feasible set). If they are satisfiable but the
  targets are jointly unachievable over the feasible set (e.g. a unit clause
  forces an atom against its target, or two targets exceed what a mutex allows),
  the fit cannot converge: it runs to `:max-iters`, the affected `θ`s clamp, and
  it prints a prominent **"did NOT converge — targets may be inconsistent with the
  hard clauses"** warning plus the per-group target-vs-achieved gap, rather than
  silently misreporting. (The independent `reweight` never inspects the clauses,
  so it cannot detect inconsistency at all.)

------

## References

- **The MLN probability model** (hard clauses + weighted atoms as a log-linear distribution; tied weights over ground instances of a first-order source) — M. Richardson & P. Domingos (2006). Markov logic networks. *Machine Learning* 62(1–2):107–136.
- **Probabilistic inference by weighted model counting** — T. Sang, P. Beame & H. Kautz (2005). Performing Bayesian inference by weighted model counting. *AAAI-05*, pp. 475–482; M. Chavira & A. Darwiche (2008). On probabilistic inference by weighted model counting. *Artificial Intelligence* 172(6–7):772–799.
- **ADDMC** — J. M. Dudek, V. H. N. Phan & M. Y. Vardi (2020). ADDMC: Weighted model counting with algebraic decision diagrams. *AAAI-20*, pp. 1468–1476. ADDs themselves: R. I. Bahar, E. A. Frohm, C. M. Gaona, G. D. Hachtel, E. Macii, A. Pardo & F. Somenzi (1997). Algebraic decision diagrams and their applications. *Formal Methods in System Design* 10(2–3):171–206.
- **d-DNNF and the knowledge compilation map** — A. Darwiche (2001). Decomposable negation normal form. *Journal of the ACM* 48(4):608–647; A. Darwiche & P. Marquis (2002). A knowledge compilation map. *Journal of Artificial Intelligence Research* 17:229–264.
- **Two-pass circuit evaluation for all marginals** (the `ddnnf-marginals` scheme) — A. Darwiche (2003). A differential approach to inference in Bayesian networks. *Journal of the ACM* 50(3):280–305.
- **Compiling by tracing an exhaustive DPLL search** (the design of FiFO's own compiler: decisions → OR, disjoint components → AND, component cache → DAG) — J. Huang & A. Darwiche (2005). DPLL with a trace: From SAT to knowledge compilation. *IJCAI-05*, pp. 156–162.
- **Component caching for model counting** — T. Sang, F. Bacchus, P. Beame, H. Kautz & T. Pitassi (2004). Combining component caching and clause learning for effective model counting. *SAT 2004*; M. Thurley (2006). sharpSAT — counting models with advanced component caching and implicit BCP. *SAT 2006*, LNCS 4121, pp. 424–429.
- **The d4 compiler** (`--solver d4`) — J.-M. Lagniez & P. Marquis (2017). An improved decision-DNNF compiler. *IJCAI-17*, pp. 667–673.
- **The MCC weighted-CNF format** — J. K. Fichte, M. Hecher & F. Hamiti (2021). The model counting competition 2020. *ACM Journal of Experimental Algorithmics* 26:1–26.
- **Maximum-entropy fitting of log-linear models** (the `--maxent` estimator: convex log Z + θ·τ objective, moment matching at the optimum) — S. Della Pietra, V. Della Pietra & J. Lafferty (1997). Inducing features of random fields. *IEEE Transactions on Pattern Analysis and Machine Intelligence* 19(4):380–393.
- **Numerical optimization for MaxEnt** (why gradient/Newton updates, as in the damped diagonal-Newton fit, beat iterative scaling) — R. Malouf (2002). A comparison of algorithms for maximum entropy parameter estimation. *CoNLL-2002*, pp. 49–55.
- **Weighted partial MaxSAT / WCNF** (the downstream solver format the learned integer weights feed) — F. Bacchus, M. Järvisalo & R. Martins (2021). Maximum satisfiability. In *Handbook of Satisfiability*, 2nd ed., IOS Press, ch. 24, pp. 929–991.
