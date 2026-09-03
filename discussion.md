# FiFO Discussion and Open Issues

## Documentation

- [README.md](README.md) — the FiFO language reference and user guide.
- [software-components.md](software-components.md) - summary of FiFO scripts and all the systems for logical and probabilistic reasoning and scripts that FiFO uses.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: MAP inference, computing marginals under a weighted theory, and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [benchmarks.md](benchmarks.md) — measured results: horizons, CNF sizes, and compilation costs.
- $\color{red}{\textbf{discussion.md}}$ — discussion and open issues.

## Table of Contents

- [Mixing Probabilities and Utilities](#mixing-probabilities-and-utilities)
- [Handling Sequential Action Evidence](#handling-sequential-action-evidence)
- [Goal Posteriors and the Per-Goal Normalization (Z_G) Issue](#goal-posteriors-and-the-per-goal-normalization-z_g-issue)
- [Max-Term versus Counting](#max-term-versus-counting)
- [Projected Inference over Action Variables](#projected-inference-over-action-variables)

## Mixing Probabilities and Utilities

**Question.** For plan recognition instances it is natural to assign probabilities
to the disjuncts of a disjunctive goal and costs (negative utilities) to the
actions. Won't using both in one model give unexpected results, since the
probabilities are scaled independently of the costs? Should the model instead be
all utilities, or all probabilities?

**Answer.** The instinct is right, but costs and probabilities are not really two
different currencies — they are interconvertible via `cost = −log(probability)`.
The real danger in mixing them is not incoherence but that mixing them *without
choosing the exchange rate* means the exchange rate gets set by an accident of
the units the costs were written in.

Concretely, in FiFO's model every soft assertion becomes a weight inside
`exp(−total_weight / scale)`. A goal disjunct given probability 0.8 is converted
by the pipeline to a log-odds weight of `log(0.2/0.8) ≈ −1.39` (in nats, before
integer scaling). An action given cost 5 contributes 5 raw. Both suppress a
trajectory, but which suppresses it more depends entirely on whether the costs
happen to be written in units comparable to nats.

There are three coherent ways to set up such a model:

1. **All probabilities.** Give each action an occurrence probability and each
   goal disjunct a prior probability, condition on the evidence, and read off
   marginals. This is the right choice when the point of the exercise is a
   *posterior* over the goal disjuncts — plan recognition asking "P(Boston |
   evidence) = ?" — because posteriors only come from the weighted-model-counting
   path, which forces the probabilistic reading anyway. Everything is calibrated
   in one space by construction.

2. **All utilities, solved as MaxSAT.** Coherent, but it buys something
   different: the single most likely explanation (the MAP assignment), with no
   calibrated posterior. Fine if "the best explanation is Boston" suffices;
   useless if a posterior probability is wanted.

3. **Costs with an explicit temperature.** Keep the action costs as costs, but
   deliberately pick a temperature β and set each action's weight to β·cost.
   This says "each extra unit of cost makes a trajectory e^(−β) times less
   likely" — a Boltzmann likelihood over plans, combined with probabilistic goal
   priors. This is mixing, but principled: β is a single global modeling choice
   that can be defended, rather than a units accident repeated over every cost.
   It is exactly the model of Ramírez and Geffner's probabilistic plan
   recognition, and in FiFO β is realized through the weight scale. If costs are
   the natural way to think about the actions, this is the most comfortable
   path.

One FiFO-specific caveat when encoding goal priors as weighted preferences: the
preference reification is one-directional — the encoding forces `pref-violated`
when the preference body fails, but does not force it *false* when the body
holds. That is harmless for MaxSAT, but under weighted model counting it admits
spurious models in which a satisfied preference still pays the violation weight.
For recognition instances, encode disjunct priors with weights directly on
goal-selection literals rather than through the preference machinery.

### References

- Ramírez, M., & Geffner, H. (2010). Probabilistic plan recognition using
  off-the-shelf classical planners. *Proceedings of the 24th AAAI Conference on
  Artificial Intelligence (AAAI-10)*, 1121–1126. (The Boltzmann plan likelihood
  P(plan | goal) ∝ exp(−β·cost) combined with goal priors.)

## Handling Sequential Action Evidence

**Question.** Under partial observability I know the *order* of the observed
actions but not *when* they happened. How does FiFO's `occur-in-order` evidence
encode that, and why does it add new variables to the theory?

**Answer.** `(occur-in-order a₁ … aₖ)` asserts an order-preserving embedding of
the observation list into the action trace: there exist slices t₁ < t₂ < … < tₖ,
strictly increasing, with each `aᵢ` occurring at `tᵢ`. The actions must be
ground.

**Why the direct encoding does not work.** The obvious translation — nested
existentials over slice variables `t₁ … tₖ` with ordering guards `tᵢ < tᵢ₊₁` —
does not fit: FiFO's quantifier domains are fixed, so a later quantifier's range
cannot depend on an earlier quantifier's variable ("slices after `t₁`"). And a
scheme built from pairwise "`aᵢ` occurs before `aⱼ`" constraints breaks on
repeated actions — a blocks-world trace picks up and puts down the same block
several times, and a pairwise ordering cannot say *which* occurrence matches
*which* observation. Ordered-subsequence matching is simply not a local
constraint on the action atoms.

**The monitor-fluent construction.** Instead the modal compiles to fresh atoms
`ObsDone(c, i, s)` — "the first *i* observations of chain *c* have been explained
by slice *s*" — with a biconditional progression axiom

  ObsDone(i, s+1) ⟺ ObsDone(i, s) ∨ ( ObsDone(i−1, s) ∧ Occurs(aᵢ, s) ),

seeded by ObsDone(0, ·) ≡ true and ObsDone(i, 1) ≡ false, and the single evidence
unit ObsDone(k, numslices). That is O(k · numslices) clauses — linear in both the
trace length and the horizon.

**Why new variables are unavoidable.** "Some strictly increasing subsequence of
slices matches the observations" is a property of the *whole trajectory*, not of
any fixed set of action atoms. Deciding it requires carrying a running state —
*how far along the sequence we have gotten so far* — from one slice to the next,
and that running state is exactly what the `ObsDone` atoms hold. It is the same
reason matching a pattern against a string compiles to an automaton *with state*
rather than a fixed formula over the input characters: the `ObsDone` atoms are
that automaton's state, materialized as propositional variables. The index `i`
gives each observation its own occurrence, so repeated actions are handled
correctly; the one-slice step in the progression axiom is what forces the matched
slices to be *strictly* increasing; and the per-chain index `c` keeps several
`occur-in-order` forms' monitors separate.

**Why the biconditional matters.** Because the progression is an `⟺`, every
`ObsDone` atom is *fully determined* by the action trace — given the `Occurs`
values, each monitor value is forced. Determined variables are **count-neutral**
under weighted model counting: they add no free choices, so they do not distort
`Z`. A one-directional `⟹` would be sound for SAT feasibility but would double
the model count for every underdetermined monitor atom, corrupting marginals.
The biconditional is what lets the *same* `occur-in-order` form serve planning,
conditioning, and `--marginals` alike.

**Validation.** Each observed action is checked at translation time — known
action schema, correct arity, arguments of the right types, and satisfiable
static-precondition guards. An observation of an action the theory can never
execute would otherwise leave its `Occurs` atom unconstrained and let the monitor
fire vacuously — a soundness hole, so it is rejected.

One connection worth noting for the next entry: the whole observation sequence is
reified into the *single* atom `ObsDone(k, numslices)` ("all k observations
happened"). That is what makes it possible to read the recognition likelihood
P(O | G) as one atom's marginal rather than as a ratio of two counts (see the
[Z_G](#goal-posteriors-and-the-per-goal-normalization-z_g-issue) entry).

### References

- Ramírez, M., & Geffner, H. (2010). Probabilistic plan recognition using
  off-the-shelf classical planners. *Proceedings of the 24th AAAI Conference on
  Artificial Intelligence (AAAI-10)*, 1121–1126. (Compiling an observation
  sequence into the planning problem itself.)
- Gerevini, A., Haslum, P., Long, D., Saetti, A., & Dimopoulos, Y. (2009).
  Deterministic planning in the fifth international planning competition: PDDL3
  and experimental evaluation of the planners. *Artificial Intelligence*,
  173(5–6), 619–668. (Compiling trajectory/temporal constraints to automaton
  state — the same monitor-variable idea.)

## Goal Posteriors and the Per-Goal Normalization (Z_G) Issue

**Question.** For plan recognition I put all the candidate goals into one
disjunctive goal, condition on the observations, and read the posterior over the
goals off the marginals of a single weighted model count (as generated by
`SatPlan/Examples/Plan_Recognition/make-recognition-instance.lisp` for the
`BlocksWorldCosts` and `IntrusionDetectionCosts` examples). Is that the true
recognition posterior?

**Answer.** Not exactly. It is a coherent probability, but it silently builds in
a prior over the goals that you did not choose — one proportional to how many
ways, weighted by efficiency, each goal can be achieved.

**How the current examples are built.** `make-recognition-instance.lisp` takes a
dataset problem (domain, `template.pddl` with a `<HYPOTHESIS>` placeholder, the
`hyps.dat` candidate list, and an `occur-in-order` evidence file) and produces:
a domain with uniform action costs (`(increase (total-cost) 1)` on every action,
so plan cost = plan length and the trajectory distribution is the Boltzmann
model exp(−β·length), β = cost/scale); a single problem whose goal is the `or`
of *all* the `hyps.dat` candidates; and incremental evidence files. Running
`--marginals` on that one theory does a single weighted model count, and the
goal fluents' marginals are read as the posterior over the hypotheses. This is
cheap — one count gives every goal's number at once — and it is what
`BlocksWorldCosts` and `IntrusionDetectionCosts` currently do.

**The limitation.** Write `Z_{G,O}` for the weighted count of
evidence-consistent trajectories that achieve goal G, and `Z_G` for the weighted
count of *all* trajectories that achieve G (no evidence). The single disjunctive
count gives

  P_single(G | O) ∝ Z_{G,O}

whereas the Bayesian recognition posterior with a uniform prior is

  P(G | O) ∝ P(O | G) = Z_{G,O} / Z_G.

The single count is missing the `1/Z_G` normalization, so it implicitly assumes
the prior **P(G) ∝ Z_G**: goals that are intrinsically cheaper to reach, or
reachable by more distinct plans, get a head start regardless of whether the
observations support them. This is exactly the baseline that Ramírez & Geffner
remove by computing a cost *difference* (`c(G, O) − c(G, ¬O)`) rather than a
single cost — their second planner call subtracts off "how easy is G anyway."
The single-count marginal keeps it in. Concretely: two destinations equidistant
from the start, one reachable by a single route and the other by three routes of
the same length, receive posterior mass 1 : 3 *before any observation arrives*,
purely because the map offers more ways to reach the second — not because it is
the more likely intent.

Two smaller caveats compound this. The distribution is over *fixed-horizon*
trajectories, so the marginals shift with `numslices` (a longer horizon admits
more padded/detour trajectories); the posterior is conditional on the horizon.
And reading a hypothesis's probability off the goal *fluents* is indirect when
hypotheses share fluents.

**For preliminary data, this is livable.** If you just want first numbers on
these benchmarks, the single-count posterior is usable as long as you read it
knowing that a high-scoring goal may be scoring high because it is
reachable-many-ways, not because the evidence favors it.

**Would a fixed goal utility fix it? No.** Attaching a fixed weight/utility to
each goal contributes the same factor `exp(u_G)` to every trajectory achieving
G, so it factors out as a constant per goal:

  P(G | O) ∝ exp(u_G) · Z_{G,O},   effective prior  P(G) ∝ exp(u_G) · Z_G.

That is a genuine, useful knob — an explicit prior you control — and worth
setting when you have real prior beliefs (e.g. "espionage is a priori likelier
than vandalism"). But it multiplies *on top of* `Z_G`; it does not remove it.
The only fixed weight that would cancel the bias is `u_G = −log Z_G`, which
requires knowing each goal's `Z_G` — the very per-goal quantity the single count
avoids computing. A number chosen a priori cannot do it, because `Z_G` depends
on the goal's reachability structure and the horizon.

**The two ways to fix it.** To divide by `Z_G` you need the per-goal partition
functions, which the single disjunctive count does not expose. There are two
routes, one still open and one now implemented:

- *Exact normalization by weighted model counting.* Count `Z_{G,O}` and `Z_G`
  per goal and form the ratio — or, with one **goal-selection variable** `sel_i`
  per hypothesis (an exactly-one constraint over the hypotheses), read all of
  them from two counts and put explicit priors on `sel_i` rather than through the
  one-directional preference reification (see the [Mixing Probabilities and
  Utilities](#mixing-probabilities-and-utilities) entry). The selection variable
  is the per-hypothesis handle the raw disjunctive goal lacks — several
  hypotheses can share final-state fluents, so no single fluent marginal is "the
  probability of hypothesis i." **This route is not implemented, and at useful
  horizons the counts are intractable** (the `--marginals` runs time out).

- *Maximum-term approximation (Ramírez & Geffner).* Replace each partition
  function by its cheapest-plan term — so counting becomes MaxSAT — giving the
  recognizer `P(O | G) ≈ σ(β·(c(G,¬O) − c(G,O)))`. **This route is implemented**,
  in `bin/recognize.sh`, and is the practical way to get the calibrated posterior
  on these benchmarks. The theory is in
  [probability-background.md §3.2](Probability/probability-background.md#32-maximum-term-approximation-of-the-partition-function),
  the tool in
  [probability.md](Probability/probability.md#plan-recognition-posteriors-recognizesh),
  and the results in
  [benchmarks.md](benchmarks.md#ramírez-and-geffner-recognition-on-the-plan-recognition-benchmarks).

So the single-count marginal on the disjunctive instances stays as the cheap,
biased "preliminary numbers" option; `recognize.sh` is the calibrated
counterpart; and the exact-WMC normalization remains an open item.

### References

- Ramírez, M., & Geffner, H. (2010). Probabilistic plan recognition using
  off-the-shelf classical planners. *Proceedings of the 24th AAAI Conference on
  Artificial Intelligence (AAAI-10)*, 1121–1126. (The `c(G, O) − c(G, ¬O)`
  baseline that removes each goal's intrinsic reachability.)

------

## Max-Term versus Counting

FiFO now has two ways to answer "what is the probability of this atom", and they
are not two approximations of one quantity. They approximate **different halves**
of it, which is worth stating plainly because the numbers look alike.

The exact identity behind both is

$$
P(a) = \sigma\negthinspace\big(\beta\thinspace(c_{\min}(\lnot a) - c_{\min}(a)) + \log(\Omega_a / \Omega_{\lnot a})\big)
$$

with $`c_{\min}`$ the cheapest model of each polarity and $`\Omega`$ the
degeneracy — the number of near-optimal models, weighted by how near-optimal they
are. The counting back ends (`maxent`, `addmc`, `ddnnf`, `d4`) evaluate the whole
thing. `max-term` keeps the first term and drops the second.

**So the split is cost versus count.** The first term is what the *weights* say;
the second is what the *counting* says. A theory whose content is mostly weights
is one where `max-term` does well; a theory whose content is mostly combinatorial
structure is one where it says nothing at all. The degenerate case is sharp: on an
unweighted theory every difference is zero and every atom comes back 0.5, while
the true marginals are pure counts.

### Why this matters for SatPlan specifically

At a fixed horizon, a planning encoding is *full* of degeneracy: parallel actions
permute, irrelevant fluents float, and enormous numbers of plans share a cost.
That is exactly the $`\Omega`$ term, and it is exactly what `max-term` discards.
So the approximation is weakest on the instances FiFO most often produces. And
the premise that would justify accepting that — "counting will not finish here" —
has to be checked instance by instance, because it does not follow from problem
size. Measured ([benchmarks.md](benchmarks.md#max-term-marginals-versus-exact-counting)):

| | pb1 (logistics) | IntrusionDetection H=6 |
|---|---|---|
| clauses | 17 606 | 2 223 |
| exact counting (`d4`) | 5.2 s, all 1344 marginals | **never finishes** — 8.5 min in the compile, killed |
| `max-term` | dominated: slower, 0.145 mean error | 38.4 s for all 450, every optimum proved |

The *smaller* instance is the one that defeats the compiler, because
compilability tracks treewidth rather than clause count. So `max-term` is not
"for planning problems": on a planning problem that compiles it is strictly
worse, and on one that does not it is the only thing that returns an answer.

The sharper statement is that it suits **queries in which the degeneracy
cancels**. A bare marginal over a planning atom keeps the full
$`\Omega_a/\Omega_{\lnot a}`$ and is badly conditioned; `recognize.sh`'s
difference *within* a hypothesis puts both sides over the same goal's plan space,
so the shared degeneracy cancels and only the asymmetry survives. That is why the
differenced form was the right first application and the bare marginal is the
harder sell.

The compensating strength is that `max-term` is exact where the theory is
*determined*. A backbone atom, one whose opposite polarity is unsatisfiable, comes
back as 0 or 1 with a proof rather than an estimate. Compare MC-SAT's frozen-chain
failure on the same encodings, which reports every atom as 0 or 1 *wrongly*: both
produce a column of zeros and ones, and only one of them is entitled to.

### The three approximations are not interchangeable

FiFO now offers three ways to avoid exact counting, and they fail in different
regimes — which is more useful than it sounds, because it means a disagreement
between them is informative.

| | approximates | fails when |
|---|---|---|
| `mc-sat` | the whole distribution, by sampling | weights are **large** — the chain freezes and stops moving |
| `max-term` | the weight contribution only | weights are **small** relative to the entropy — returns 0.5 |
| `recognize.sh` | a ratio of two max-terms | the two sides have asymmetric degeneracy |

The third row is the reason `recognize.sh` works better than its ingredients
suggest: differencing two max-term estimates *within* a hypothesis cancels the
shared degeneracy, leaving only the asymmetry. A bare `max-term` marginal has no
such cancellation, so it is the more exposed of the two.

### Exclusivity is information, not a query parameter

One design point worth recording, because the alternative is tempting. When a
group of atoms is mutually exclusive, renormalising `max-term`'s estimates over
the group recovers exactly what independence gets wrong — on an unweighted
exactly-one-of-three theory, `0.5, 0.5, 0.5` becomes the exact `1/3, 1/3, 1/3`.

That information belongs to the **theory**, not to the query. The exact back ends
need no declaration of exclusivity because they see the constraints directly; only
the approximation does. Requiring the query to declare it would duplicate what the
theory already states and create a second place for it to be wrong. So FiFO
detects the group from the clauses — an at-least-one clause plus the pairwise
at-most-one clauses — and `--verify-groups` proves it by SAT entailment rather
than pattern-matching. The query set supplies only the *candidates*.

### Open issues

- **The degeneracy term is not estimated, only dropped.** `K`-best enumeration
  would interpolate: take the top `K` models per polarity with blocking clauses
  and use $`Z_S \approx \sum_{i \le K} e^{-\beta c_i}`$. Since $`\Omega_S \ge 1`$,
  every `K` gives a *lower bound* on $`Z_S`$, so this converts a biased point
  estimate into anytime bracketing. `K = 1` is what is implemented today.
- **Cost is `1 + n` MaxSAT solves**, so a query over thousands of atoms is hours.
  `--weighted-only` helps; IPAMIR, the incremental MaxSAT interface, is the real
  answer, since the `n` instances differ by a single unit clause.
- **Nothing checks the two families against each other** on an instance where both
  finish. A harness that runs `max-term` and `d4` on the same file and reports the
  error distribution would turn "approximates the weight half" from an argument
  into a measurement.
- **The estimator has a resolution ceiling.** Since `logit P(a) = β·Δ_a`, it can
  take only as many distinct values as there are distinct cost gaps. On pb1, 15
  atoms produced 7 distinct estimates, and five atoms with true marginals from
  `0.0176` to `0.2024` all came back as `σ(−2) = 0.1192`
  ([benchmarks.md](benchmarks.md#max-term-marginals-versus-exact-counting)). This
  is a property of the encoding's cost structure, so no solver improves it.

### Open problem: characterising when the degeneracy cancels

The error is `log(Ω_a / Ω_{¬a})`, where
`Ω_S(β) = Σ_{x∈S} e^{−β(cost(x) − c_min(S))}` is the near-optimal mass measured
relative to *that side's own* minimum. So the question "when is max-term
trustworthy?" is the question "when do the two polarities have the same shifted
cost spectrum?" — the same number of solutions at each increment above their
respective minima. Equivalently: equal excess free energy above the ground state.
**The atom must shift the cost landscape without reshaping it.**

Four partial answers, in decreasing order of confidence.

**1. Conditional independence is sufficient, and exact.** If fixing the atom
changes only the cost and not what the rest of the theory can do, the residual
contributes the same `Ω` to both sides. This is the same factoring identity that
makes post-hoc priors free: a unit cost is constant across the models where its
atom is true, so it leaves `c_min` shifted but the spectrum unchanged.

**2. At low temperature the error is a ratio of optimum multiplicities.** As
`β → ∞`, each `Ω` tends to the number of optimal solutions on its side, so the
error tends to `log(#optima with a / #optima without a)`. That is *testable*: solve,
add a blocking clause, re-solve. If the second-best cost is strictly higher on
both sides, the optimum is unique both ways and the estimate is well conditioned.
Two extra solves per atom — expensive, but it yields a per-atom confidence flag
rather than a global guess, and it composes with the `K`-best refinement above,
which computes the same gap profile for its own purposes.

**3. Symmetry looks like the structural story — conjecture, untested.** Write
`Ω ≈ N · μ`, distinct solutions times the nuisance multiplicity contributed by
symmetry (permuting parallel actions, padding, floating fluents). When
`μ_a = μ_{¬a}` the nuisance cancels and only `N_a/N_{¬a}` survives. That predicts
what is observed: an atom lying in a **nontrivial orbit of the CNF's automorphism
group** — "does this load happen at slice 2 or slice 3?" — has its symmetry broken
on one side only, so `μ` differs and nothing cancels; an atom **fixed by every
automorphism**, such as a nullary goal predicate `hypI`, has the same `μ` either
way. This is mechanically checkable with a symmetry tool (BreakID, saucy), and
would explain the gap between a pb1 action atom and a recognition hypothesis in
structural terms rather than by appeal to the domain.

**4. Why differencing helps, in the same language.** `recognize.sh` compares
`c(G,O)` against `c(G,¬O)` at **fixed G**. The nuisance factor `μ` is a property of
`G`'s plan space, identical on both sides, so it divides out and only the
observation asymmetry survives. A bare marginal compares two polarity-restricted
ensembles with no such shared factor, which is why it is the worse-conditioned
question.

None of this is settled. The exact criterion is solid, the symmetry account is a
conjecture, and every diagnostic above costs more per atom than the estimate it
would qualify. The cheapest useful one is the uniqueness probe of (2).

### References

- See [Probability/probability-background.md §3.2](Probability/probability-background.md#32-maximum-term-approximation-of-the-partition-function)
  for the derivation of the maximum-term approximation and its error, and
  [§3.3](Probability/probability-background.md#33-map-inference-the-mode-of-the-distribution)
  for the mode-versus-marginals distinction it rests on.
- [notes-from-claude-code.md §5](notes-from-claude-code.md) records the working
  discussion this section summarises, including the measurements.

------

## Projected Inference over Action Variables

For SatPlan encodings there is important additional leverage. The variables partition into:

- **Action variables**: `(Occurs a s)` — carry weights, are the decisions
- **State variables**: `(Holds f s)` — unweighted, largely determined by the hard clauses given the action assignment

The frame axioms, precondition/effect axioms, and initial/goal constraints are tight: given a complete action assignment, the state variables are almost entirely forced by unit propagation. The effective sampling space is over action sequences, not full assignments.

This suggests a **projected inference** approach: sample over action variable assignments (using MC-SAT or random restarts), and derive state variable values deterministically via unit propagation after each action sample. Marginals of state variables are then computed as a function of action marginals rather than being sampled directly. This drastically reduces the effective dimension of the sampling problem.

**Status: not implemented.** Nothing in the pipeline projects onto the action
variables; every back end samples or counts over the full assignment. The idea is
recorded here rather than in
[probability-background.md](Probability/probability-background.md) because that
document covers the machinery FiFO has, and this is a proposal.

Two things make it more than a speculation. `--unitprop` already measures the
effect the projection would exploit: on SatPlan encodings it reports 85–90% of
variables fixed by propagation, which is the same observation that the action
atoms carry the free dimensions. And the max-term back end already restricts
attention to a queried subset of atoms, so a *counting* method that did the same
would slot into the same interface.

The open question is the completion step. Unit propagation determines the state
atoms only when the action assignment leaves nothing free; where it does not, the
residual has to be counted rather than propagated, and it is not obvious that the
residuals are small enough — or independent enough across samples — for the
projected marginals to be cheaper than the direct ones.

### References

- [Probability/probability-background.md §3.1](Probability/probability-background.md#31-sampling-based-marginal-inference-mc-sat)
  for MC-SAT, the sampler this would sit on top of, and
  [§3.3](Probability/probability-background.md#33-map-inference-the-mode-of-the-distribution)
  for why this is a summing method rather than a marginal MAP.
