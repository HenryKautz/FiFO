## Marginal Inference in FiFO: Following the MLN Approach

This is a natural next step — the weight-learning pipeline already computes marginals (as a subroutine inside `maxent-reweight`), but it does so only to *verify* learned weights. Exposing marginal inference as a first-class operation is what makes FiFO a full probabilistic reasoning system rather than just a planner.

------

### The Probability Model

FiFO's WCNF encoding defines a Gibbs distribution over the feasible set:

$$P_\theta(x) = \frac{1}{Z(\theta)} \exp!\left(-\sum_a \theta_a N_a(x)\right) \cdot \mathbf{1}[x \in \mathcal{F}]$$

where $\mathcal{F}$ is the set of assignments satisfying all hard clauses, and $\theta_a$ are the weights (costs). The marginal probability of literal $L$ is:

$$P(L) = \sum_{x \in \mathcal{F}:, L(x)=1} P_\theta(x) = \frac{Z_L(\theta)}{Z(\theta)}$$

a ratio of two partition functions over $\mathcal{F}$, both restricted by the hard clauses. This is weighted model counting (#WMC), and it's #P-hard in general — so the question is which tractable approximation is right for FiFO's structure.

------

### Method 1 — Exact Enumeration (Small Instances)

`maxent.lisp` already does this. It enumerates $\mathcal{F}$ and computes model expectations during the iterative fit. The extension to standalone marginal inference is minimal: instead of iterating $\theta$ until the model matches targets, just take a given $\theta$ and make one pass:

```
for each x in enumerate(F):
    w(x) = exp(-sum_a theta_a * N_a(x))
    for each literal L:
        if L(x) = 1: acc_L += w(x)
    Z += w(x)
P(L) = acc_L / Z
```

This is already essentially inside `maxent-reweight` and could be factored out as `(marginals "file.scnf")`. The node cap (~5M in the current implementation) is the only constraint. For small SatPlan instances (the ones used for weight learning), this is the right answer and costs almost nothing beyond what you're already computing.

------

### Method 2 — MC-SAT (The MLN Standard)

For larger instances, **MC-SAT** (Poon & Domingos 2006) is the canonical MLN approach, and it fits FiFO's architecture particularly well because its inner loop is a SAT solve.

**The algorithm.** Given a current satisfying assignment $x$:

1. For each soft clause $c_i$ (in FiFO, unit clauses $\neg L_i$ with weight $w_i$):
   - If $c_i$ is *violated* by $x$ (i.e. $L_i$ is true): add $c_i$ to $M$ with probability 1
   - If $c_i$ is *satisfied* by $x$ (i.e. $L_i$ is false): add $c_i$ to $M$ with probability $1 - e^{-w_i}$
2. Sample a new $x$ **uniformly** from ${x' \in \mathcal{F} : x' \models M}$ using **SampleSAT** (WalkSAT + random restarts)
3. Accumulate $x$ into marginal counters; go to 1

**Why it works.** The slice sampling construction makes the stationary distribution exactly $P_\theta$. Crucially, step 2 finds any *satisfying* assignment — not the optimal one — so the inner loop is a SAT call, not a MaxSAT call.

**FiFO-specific simplification.** FiFO's soft clauses are all unit clauses. The slice selection in step 1 becomes: for each action literal $L_i$ that is *false* in $x$, add the unit constraint $\neg L_i$ (force it to stay false) with probability $1 - e^{-w_i}$. The resulting constrained formula is the hard clauses plus a subset of "stay false" unit constraints. SampleSAT then finds a satisfying assignment that respects both the planning axioms and the sampled constraints. Each selected unit constraint is a free reduction (unit propagation), so the effective problem is smaller than the original.

**The SampleSAT problem.** This is the gap between MLN theory and FiFO practice. SampleSAT needs a *near-uniform* satisfying assignment — not just any satisfying assignment. Kissat returns the first solution it finds, which is not uniform. Options:

- **WalkSAT with random restart**: run WalkSAT (stochastic local search) from a random initial assignment. This is what the original Alchemy MLN system does, and it's approximately uniform in practice for sparse problems. For planning formulas, mixing is harder because of the tight constraint structure.
- **UniGen / ApproxMC**: near-uniform samplers based on universal hashing. They give provably near-uniform samples but are slower than WalkSAT. UniGen3 is the current state of the art.
- **Random-phase SAT**: run kissat many times with different random seeds and random variable-phase initialization. Not provably uniform but often adequate in practice and completely free to implement (just loop over `solve`).

For a first implementation, random-phase SAT calls are the lowest-friction path, and the approximation quality improves with sample count.

------

### Method 3 — Weighted Model Counting Tools

There's a clean alternative that avoids MCMC entirely: compile the WCNF to a **weighted model counter** and compute all marginals exactly (or with guarantees). The WMC formulation maps directly from FiFO's encoding:

- Each variable $v$ with a weight $w_v$ (for $v=1$) gets weight function $W(v=1) = e^{-w_v}$, $W(v=0) = 1$
- Variables without weights get $W = 1$ on both assignments
- Hard clauses are encoded as zero-weight factors on forbidden assignments

Tools that accept this formulation and return marginals:

- **GPMC** (Projected Model Counter): extends model counting with variable projection; can return conditional marginals efficiently
- **SharpSAT-TD** (tree decomposition–based): exact, works well when the primal graph has small treewidth — which SatPlan formulas don't generally have, but the time-sliced structure helps
- **ADDMC** (algebraic decision diagrams): algebraic WMC; excellent on structured problems, handles the weighted case natively

The WMC approach gives exact marginals with no sampling noise, and the tools are mature. The friction is in the conversion: you'd need to emit a `.wmc` or weighted `.cnf` format that these tools accept. Given that FiFO already targets multiple DIMACS formats, adding a WMC output mode is straightforward.

------

### FiFO-Specific Structure: Projecting Onto Action Variables

For SatPlan encodings there's important additional leverage. The variables partition into:

- **Action variables**: `(Occurs a s)` — carry weights, are the decisions
- **State variables**: `(Holds f s)` — unweighted, largely determined by the hard clauses given the action assignment

The frame axioms, precondition/effect axioms, and initial/goal constraints are tight: given a complete action assignment, the state variables are almost entirely forced by unit propagation. The effective sampling space is over action sequences, not full assignments.

This suggests a **projected inference** approach: sample over action variable assignments (using MC-SAT or random restarts), and derive state variable values deterministically via unit propagation after each action sample. Marginals of state variables are then computed as a function of action marginals rather than being sampled directly. This drastically reduces the effective dimension of the sampling problem.

------

### Practical Implementation Roadmap for FiFO

**Immediate (reuse existing code):** Factor out the enumeration + weighted marginal computation from `maxent-reweight` into a standalone `(marginals "file.scnf")` function. This gives exact inference for small instances and integrates naturally with the existing SCNF format.

**Near-term (random-phase MC-SAT):** Implement MC-SAT using random-phase kissat calls as the inner sampler. Each "sample" is: (1) randomly activate soft clause constraints per the MC-SAT rule, (2) run kissat with a random seed, (3) if SAT, accumulate. This is a straightforward loop in Python or Lisp over existing FiFO infrastructure. Approximate but immediately usable.

**Medium-term (proper SampleSAT):** Replace the inner sampler with WalkSAT-based SampleSAT or UniGen. The Python `pysat` library (already in the weight-learning stack) provides WalkSAT access; UniGen has Python bindings via `pyunigen`.

**Alternative path (WMC tools):** Emit a weighted CNF file accepted by GPMC or ADDMC, then shell out to the tool and parse its count back. Cleanest conceptually, avoids implementing sampling at all, limited to instances where the WMC solver terminates. **(Implemented via ADDMC — see "Implemented: weighted model counting via ADDMC" below.)**

------

### The Connection to Weight Learning

This closes the loop on the existing pipeline in a satisfying way. The current flow is:

```
beliefs → weights (learning)     weights → plan (MaxSAT)
```

Marginal inference adds:

```
weights → marginals (inference)
```

which enables: (a) sanity-checking learned weights against intended beliefs; (b) computing posterior beliefs about which actions will be used given the cost structure; (c) the E-step in EM for the hidden-weighted-variables regime (Case 3 in the weight-learning document) — where you need $\mathbb{E}_\theta[\Phi \mid o]$, a clamped marginal inference call.

The key difference from the MaxSAT oracle used in weight learning: the MaxSAT oracle returns the single minimum-cost assignment, while marginal inference sums over all feasible assignments weighted by $e^{-\text{cost}}$. At zero temperature they agree; at finite temperature, marginals spread probability over suboptimal plans in proportion to how nearly-optimal they are.

------

### Implemented: exact marginals (Method 1)

The "Immediate" step above is implemented. `lisp/maxent.lisp` provides

```lisp
(marginals "file.scnf" &key out-file weighted-only scale (node-limit 5000000) (verbose t))
```

which reads a weighted `.scnf` (hard `(OR ...)` clauses plus `(WEIGHT literal w)` costs), enumerates the feasible set, and computes the exact marginal `P(atom = true)` of **every** atom under the Gibbs distribution `P(x) ∝ exp(-Σ weights of true literals)` — weighted and unweighted atoms alike, so SatPlan `Holds` state atoms are reported alongside `Occurs` action atoms. It reuses the same feasible-set enumeration the MaxEnt fit uses, but tracks every variable rather than only the weighted ones. With no weights the distribution is uniform over the feasible set. It honors the same `scale` as the ADDMC path (auto-read from the `scale: N` header, `:scale 1` for raw weights — see "Weight scale" below), so the two solvers report the same marginals on the same file. It prints one `(MARGINAL <atom> <probability>)` line per atom (sorted), and `:out-file` also writes them to a file. Being exact enumeration, it is for small instances (the `node-limit` caps the search) — Methods 2 and 3 above remain the path to scale.

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

### Implemented: weighted model counting via ADDMC (Method 3)

The WMC-tools path is implemented against **ADDMC** (the algebraic-decision-diagram weighted model counter). Where the enumeration above is exact but exponential, ADDMC compiles the same weighted `.scnf` to an algebraic decision diagram, so it scales to instances far beyond brute enumeration. `lisp/wmc.lisp` provides

```lisp
(wmc "file.scnf" &key wcnf-file keep-wcnf scale epsilon evidence evidence-file addmc verbose)             ; partition function Z
(marginals-addmc "file.scnf" &key out-file weighted-only scale epsilon evidence evidence-file addmc verbose)  ; per-atom marginals
```

`wmc` returns the partition function `Z = Σ_{x∈F} exp(-cost(x))` — itself a weighted model count. `marginals-addmc` computes `P(a) = Z[clauses ∧ a] / Z` by running ADDMC once for `Z` and once more per reported atom with a unit clause clamping that atom true; it accepts the same `:weighted-only` restriction as `marginals`.

**The encoding.** The bridge emits the **MCC-2020 weighted CNF** format (ADDMC's `--wf 4`). FiFO's model — `W(L true) = exp(-θ)`, `W(L false) = 1` for a literal `L` with cost-when-true `θ` — maps directly: each charged literal becomes a weight line `w <lit> exp(-θ)`, and the opposite literal keeps ADDMC's default weight `1.0`. (Tied/duplicate `(WEIGHT ...)` forms on the same literal sum their costs first.) MCC's independent per-literal weights are what make this work — the Cachet format, which forces `W(¬v) = 1 − W(v)`, cannot represent FiFO's `W(v=0) = 1`.

This was cross-checked against the Method-1 enumeration: on the test instances the two agree to the last double-precision bit (max `|P_enum − P_addmc| = 0`).

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

So all three of `marginals` (enumeration), `marginals-addmc`, and `wmc` divide the integer weights by the scale before exponentiating. By default they read `scale: N` from the header (1.0 if absent, e.g. hand-written or raw-SatPlan-cost scnfs); pass `:scale 1` / `--scale 1` to count with the raw integer weights, or `:scale n` to force a value. The shell flag is `--scale n` on `wmc.sh` and on `marginals.sh` for **both** solvers — so `--solver maxent` and `--solver addmc` agree on the same file.

Cost note: `marginals-addmc` does one ADDMC run for `Z` plus one per reported atom, so `--weighted-only` (or a small atom set) keeps the run count down on instances with many state atoms.

------

### Conditioning on evidence

`wmc` and `marginals-addmc` take **evidence** to compute *conditional* quantities: `P(A | E) = WMC(theory ∧ E ∧ A) / WMC(theory ∧ E)`. Conditioning on `E` simply means adding `E` to the **hard** clauses (evidence has probability 1), so with `E` supplied every reported marginal becomes `P(atom | E)` and `wmc` returns the conditioned partition function `WMC(theory ∧ E)`.

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

For a SatPlan problem the planner lifts all of this to the PDDL level: `planner.sh … --marginals --counter addmc --pddl-evidence '<modal form>'` conditions on evidence that may be quantified over the time slices, instantiates the problem conjoined with it, and reports `P(atom | evidence)` at the working horizon. A complete end-to-end walkthrough on the Switch domain — plain plan, evidence reshaping the plan, the separate evidence scnf, and conditional marginals — is in [../SatPlan/SatPlan.md](../SatPlan/SatPlan.md#worked-example-the-switch-domain-end-to-end).

------

### Related Documents

- [../README.md](../README.md) — the FiFO language reference and user guide.
- [../Learning/learning.md](../Learning/learning.md) — the weight-learning pipeline: target marginal probabilities → integer literal weights (the inverse direction of inference).
- [../SatPlan/SatPlan.md](../SatPlan/SatPlan.md) — the SatPlan planner, which lifts conditioning and marginal inference to PDDL (`--evidence`/`--pddl-evidence`, `--marginals`), with an end-to-end worked example.