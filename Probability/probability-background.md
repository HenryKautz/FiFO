# Probabilistic FiFO: Theory and Background

## Documentation

- [README.md](../README.md) — the FiFO language reference and user guide.
- [software-components.md](../software-components.md) - summary of FiFO scripts and all the systems for logical and probabilistic reasoning and scripts that FiFO uses.
- [SatPlan/satplan.md](../SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](probability.md) — the probabilistic layer in practice: MAP inference, computing marginals under a weighted theory, and learning weights from target probabilities.
- $\color{red}{\textbf{Probability/probability-background.md}}$ — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [benchmarks.md](../benchmarks.md) — measured results: horizons, CNF sizes, and compilation costs.
- [discussion.md](../discussion.md) — discussion and open issues.

## Table of Contents

- [1. Setup and notation](#1-setup-and-notation)
- [2. Parameter tying and the feature space](#2-parameter-tying-and-the-feature-space)
- [3. The unifying view](#3-the-unifying-view)
- [4. Case 1 — Complete, optimal data](#4-case-1--complete-optimal-data)
- [5. Why an oracle is needed even with complete data](#5-why-an-oracle-is-needed-even-with-complete-data)
- [6. Case 2 — Complete but merely-good data](#6-case-2--complete-but-merely-good-data)
- [7. Case 3 — Partial data](#7-case-3--partial-data)
- [8. Case 4 — Beliefs about marginals, little or no data](#8-case-4--beliefs-about-marginals-little-or-no-data)
- [9. Case 5 — Combining beliefs and data](#9-case-5--combining-beliefs-and-data)
- [10. Domain-size dependence (a real caveat)](#10-domain-size-dependence-a-real-caveat)
- [11. Practical recipe for the FiFO / MaxSAT stack](#11-practical-recipe-for-the-fifo--maxsat-stack)
- [12. Sampling-based marginal inference: MC-SAT](#12-sampling-based-marginal-inference-mc-sat)
- [13. Projected inference over action variables](#13-projected-inference-over-action-variables)
- [14. Maximum-term approximation of the partition function](#14-maximum-term-approximation-of-the-partition-function)
- [15. MAP inference: the mode of the distribution](#15-map-inference-the-mode-of-the-distribution)
- [16. Provenance / related work](#16-provenance--related-work)
- [17. Summary table](#17-summary-table)
- [References](#references)

A working summary of how to learn the weights in a FiFO weighted-MaxSAT theory —
i.e. the costs attached to weighted literals — across the full range of data
regimes, from complete optimal demonstrations down to nothing but prior beliefs
about marginal probabilities. Sections 12–13 cover the sampling end of the
marginal-*inference* design space: section 12's MC-SAT is implemented
(`--solver mc-sat`) and this is the theory behind it, while section 13's
projected inference is not; section 14 covers the maximum-term approximation,
which the plan-recognition pipeline (`recognize.sh`) *does* implement; section 15
covers MAP — the other query on the same distribution, the one every MaxSAT call
in the stack is actually making. The implemented back ends of all of it are
documented in [probability.md](probability.md).

---

## 1. Setup and notation

FiFO compiles a finite-domain FOL theory into hard CNF clauses plus a set of
**weighted literals**. A weighted MaxSAT / PBO solver finds the minimum-cost
feasible assignment. *Learning the weights* is the inverse problem: given
assignments believed to be (near-)optimal, recover weights that make them so.

(A weight or target marginal on a compound *formula* φ — a Markov-logic feature —
is handled by reifying φ into a fresh determined atom `A ⇔ φ` and weighting `A`,
which is count-neutral and gives `P(A) = P(φ)`; the schema $a$ below is then that
atom, so all of the following applies with no change. See
[probability.md](probability.md).)

| Symbol | Meaning |
|---|---|
| $x \in \{0,1\}^n$ | full assignment to all variables |
| $\mathcal{F}_d$ | feasible set — assignments satisfying the hard clauses for instance $d$ |
| $a = 1,\dots,A$ | weighted-literal **schemas** (a few dozen, e.g. `load`, `drive`) |
| $\theta \in \mathbb{R}^A$ | the weights to learn (one per schema) |
| $N_a(x)$ | number of true ground instances of schema $a$ in $x$ |
| $\Phi(x) = (N_1,\dots,N_A)$ | feature / sufficient-statistic vector (schema counts) |

The objective the solver minimizes is **linear in the weights**:

$$C_\theta(x) = \sum_a \theta_a N_a(x) = \theta^\top \Phi(x).$$

In planning terms $\Phi(x)$ is the histogram of action types in a plan (summed over
groundings and time steps), and $`C_\theta`$ is the total plan cost.

---

## 2. Parameter tying and the feature space

There is heavy tying: hundreds of ground weighted literals collapse to a few dozen
schema weights, because all ground instances of a schema share one weight
(`(Cost act c)` is the same for every grounding). This makes the parameter vector
small and the problem well-conditioned.

**Fixed domains** (all training instances share the same element counts; they may
still differ in initial/goal state or static facts): every instance maps into the
same $A$-dimensional count space, so all examples share one $\theta$. Tying is
optional here but better-conditioned.

**Varying domains** (different numbers of packages, trucks, places, time horizon):
the CNF, variables, and feasible set all change — but the schemas don't, and
$`\Phi_d : \mathcal{F}_d \to \mathbb{Z}_{\ge0}^A`$ always lands in the *same* space.
Here tying is **mandatory**: there is no correspondence between a ground literal in
a small instance and one in a large instance except through the schema. The payoff
is transfer — a $\theta$ fit on small instances predicts optimal plans for unseen
sizes, and expensive inference can be done on small instances only.

---

## 3. The unifying view

Two equivalent lenses organize everything below.

**Regret (discriminative).** The optimality gap of demonstration $k$ under $\theta$,

$$g_k(\theta) = \underbrace{\theta^\top\Phi(x^{(k)})}_{\text{counting}}
\;-\; \underbrace{\min_{x\in\mathcal{F}_d}\theta^\top\Phi(x)}_{\text{oracle}},$$

is a linear term minus a concave term, hence **convex** in $\theta$. The first term
is free (counting); the second is a MaxSAT solve.

**Moment matching (probabilistic).** Adopt the Gibbs model
$`P_\theta(x) \propto \exp(-\theta^\top\Phi(x))`$ on $\mathcal{F}$. Then learning is
matching the model's expected features $`\mathbb{E}_\theta[\Phi]`$ to a target. Every
regime below differs only in **where the target moments come from**:

- complete data → empirical counts $\bar\Phi$
- partial data → clamped (conditional) expectations $`\mathbb{E}_\theta[\Phi \mid o]`$
- prior beliefs → believed marginals $\tau$

The two lenses are the high- and low-temperature ends of one spectrum (max replaces
log-sum-exp).

---

## 4. Case 1 — Complete, optimal data

Each example is a full assignment assumed feasible and cost-optimal. Feasibility is
free; the content is optimality:

$$\theta^\top \Phi(x^{(k)}) \le \theta^\top \Phi(x)\quad \forall x \in \mathcal{F}.$$

This is an (exponential) polyhedral cone in $\theta$, handled by **constraint
generation / cutting planes** with the MaxSAT solver as the separation oracle, or by
the **averaged structured perceptron** (update $\theta \mathrel{+}= \eta(\Phi(\hat x) - \Phi(x^{(k)}))$).
The oracle is unchanged by tying: broadcast each schema weight onto its ground
literals and solve.

Two things to fix:

- **Gauge.** Optimality identifies $\theta$ only up to positive scaling — fix one
  reference cost to 1, or normalize.
- **Sign.** For action costs, impose $\theta \ge 0$ (correct and regularizing).

---

## 5. Why an oracle is needed even with complete data

> *"For Bayesian networks with complete data you just count — why not here?"*

Complete data removes only the **latent-variable** inference (reconstructing
unobserved parts of an example). It does **not** remove the inference needed to
*evaluate* the model over the feasible set.

A Bayes net is closed-form because it is *directed and locally normalized*: the
partition function is identically 1 and the likelihood decomposes, so normalized
counts **are** the parameters. This FiFO model is **undirected and constrained** —
the clauses couple the variables — so:

- *Probabilistic view:* the gradient is $`\bar\Phi - \mathbb{E}_\theta[\Phi]`$. Counting
  gives the empirical half; the model expectation needs $Z(\theta)$, a global
  $\theta$-dependent sum over $\mathcal{F}$ (weighted model counting, #P-hard).
- *Discriminative view:* "good weights" are *operationally defined* by what the
  solver does — evaluating a candidate $\theta$ requires $`\min_{x\in\mathcal F}\theta^\top\Phi(x)`$,
  one MaxSAT call. The weights are energies, not frequencies; the map from energies
  to behavior runs through the constrained argmin, which counting cannot invert.

The same lesson holds in the closest relative — generative MLN learning with complete
data is still not closed-form (hence pseudo-likelihood), and discriminative MLN
learning puts MAP inference in the loop.

---

## 6. Case 2 — Complete but merely-good data

When demonstrations are near-optimal but not optimal, the consistency cone is empty;
the problem shifts from feasibility to **minimizing total regret**, which stays
convex. The canonical objective is **Maximum Margin Planning** / structured SVM:

$$\min_{\theta\ge0}\ \tfrac{\lambda}{2}\|\theta\|^2 + \sum_k \Big[\theta^\top\Phi_k(x^{(k)}) - \min_{x\in\mathcal{F}_k}\big(\theta^\top\Phi_k(x) - \Delta_k(x)\big)\Big]_+ .$$

A subgradient is $`\Phi_k(x^{(k)}) - \Phi_k(\hat x_k)`$ with $`\hat x_k`$ the
loss-augmented MaxSAT optimum — the perceptron update, now not driven to zero.

Practical points:

- **Hinge / L1 slack**, not squared — robust to the occasional badly suboptimal demo.
- **Regularization does real work**: the regret surface is flat in directions, so
  $R(\theta)$ and the gauge pick among near-equivalent fits (L2 for stability, L1 for
  sparsity).
- **Validate by regret, not reproduction** — demos are suboptimal, so you *shouldn't*
  reproduce them. Watch the distribution of residual gaps $`g_k(\theta^*)`$; gaps that
  grow with instance size signal misspecification (see §10), not noise.
- **Solve the oracle to optimality** — an anytime/suboptimal solution under-estimates
  the min and gives a biased subgradient (relevant for anytime solvers like
  TT-Open-WBO-Inc).

The probabilistic alternative *models* the suboptimality via a Boltzmann demonstrator
$`P_\theta(x)\propto\exp(-\beta\,\theta^\top\Phi)`$ (temperature $1/\beta$ = rationality;
$\beta$ shares the gauge with the cost scale). Principled but pays the
partition-function cost — do the counting on small instances.

---

## 7. Case 3 — Partial data

Classify the **hidden** variables first; the regime depends entirely on whether they
are weighted or unweighted (features depend only on the *weighted* variables).

**Hidden = unweighted** (observe the actions, not all states). $\Phi(x^{(k)})$ is fully
determined; the hidden states matter only for feasibility. This stays essentially the
**convex complete-data** problem, plus a one-time SAT feasibility check per example.
(In SatPlan, states are largely forced by actions + axioms anyway.)

**Hidden = weighted** (observe states/goals, not the plan). The features themselves are
latent — **non-convex**. Two approaches:

1. **Latent structured SVM via CCCP** (fits the MaxSAT stack). Alternate:
   - *Impute*: clamped MaxSAT — fix observed variables (hard units, or soft if noisy),
     minimize $\theta^\top\Phi$ over the rest → best completion $\hat x^{(k)}$.
   - *Update*: a complete-data margin step using the free, loss-augmented MaxSAT.

   The data term becomes $`\min_{x\in\mathcal{F}_d(o^{(k)})}\theta^\top\Phi(x)`$; CCCP
   linearizes it via the imputation. Reuses one oracle twice — clamped, then free.

2. **EM on the marginal likelihood**, with gradient
   $`\mathbb{E}_\theta[\Phi \mid o^{(k)}] - \mathbb{E}_\theta[\Phi]`$ (clamped minus free
   expectation). CCCP is the "hard EM" version with a MAP completion in place of the
   expectation.

Cautions: non-convexity → warm-start (e.g. from fully-observed examples) and restarts;
identifiability degrades with the hidden fraction; the imputation can **self-reinforce**
(it fills in plans that look good under the current $\theta$). Observing only outcomes is
the classic ill-posed IRL case — the cure is observing part of the plan itself.

---

## 8. Case 4 — Beliefs about marginals, little or no data

This is the **maximum-entropy** problem: the weights are the **Lagrange multipliers**
enforcing your believed marginals. Convert beliefs to target expected counts
$`\tau_a = \sum_{j\in a} p_j`$, and solve the moment-matching condition

$$\mathbb{E}_\theta[\Phi] = \tau,$$

a low-dimensional convex program ($`\min_\theta \log Z(\theta) + \theta^\top\tau`$),
solvable by iterative scaling or gradient descent. Each step needs $`\mathbb{E}_\theta[\Phi]`$
(weighted model counting / sampling over $\mathcal{F}$) — do it on small instances.

- **Scale is now identified.** Unlike optimal-plan data (ratios only), marginals depend
  on the absolute scale of $\theta$ (the temperature), so they pin $\theta$ down fully.
- **Warm-start.** Ignoring clauses, each literal is logistic, giving
  $`\theta_a^{(0)} = \log\frac{1-p_a}{p_a}`$ (log-odds of the belief); the iterative
  inference corrects for the coupling the clauses introduce.
- **Soft matching.** Beliefs may be jointly infeasible under the clauses; penalize
  $`\|\mathbb{E}_\theta[\Phi]-\tau\|`$ with per-constraint confidence weights. Schemas with
  no belief get a prior/regularizer.

With no data there is nothing to validate against — $\theta$ is only as good as the
beliefs plus the MaxEnt assumption, which is the honest least-committal completion.

---

## 9. Case 5 — Combining beliefs and data

Both enter through the **same channel**: constraints on $`\mathbb{E}_\theta[\Phi]`$. Combining
them is combining target moments, weighted by confidence — beliefs act as **pseudo-data
with an effective sample size** (Bayesian shrinkage / conjugate prior). No data → match
the beliefs; abundant data → empirical moments dominate; in between, a blend.

**Recommended arrangement for the MaxSAT stack** (decouples expensive from cheap):

1. Solve the marginal MaxEnt **once**, offline, on small instances → prior center $`\theta_0`$.
2. Run the discriminative min-regret fit on the data with regularizer
   $`\tfrac{\lambda}{2}\|\theta - \theta_0\|^2`$ instead of $\tfrac{\lambda}{2}\|\theta\|^2$.

The costly probabilistic inference happens once (to set the prior); the cheap MaxSAT
oracle does the data fitting. With no data this returns $`\theta_0`$; with data it moves
off as far as the evidence warrants. The beliefs also **supply the scale** that
optimal-plan data leaves undetermined — the two sources are complementary.

---

## 10. Domain-size dependence (a real caveat)

Schema tying assumes $`\theta_a`$ is constant across instance sizes. If the true cost has
size-dependent structure (congestion, economies of scale, fixed overheads), pure tying
is misspecified — diagnosable as residual regret that **grows systematically with size**.
The fix stays linear: let $`\theta_a(d) = \alpha_a + \beta_a\,g(d)`$ for a size function
$g(d)$, adding size-modulated features.

For the max-margin route, also **normalize the per-instance loss** (by plan length or
variable count) so large instances don't dominate; regularization, living in the fixed
$A$-dimensional space, needs no rescaling. Ensure instances are large enough to exercise
every schema (coverage).

This connects to the **domain-size dependence / projectivity** literature in SRL — the
one corner here that touches a genuinely open question rather than settled technique.

---

## 11. Practical recipe for the FiFO / MaxSAT stack

- **Oracle**: weighted MaxSAT (RC2 / CP-SAT). Used free (competitor) and clamped
  (imputation); clamping = fixing literals as units.
- **Master problem**: a few dozen dimensions — averaged perceptron or a small QP; the
  **1-slack cutting-plane** SVM converges in few oracle calls (each call is a full solve).
- **Regimes**: convex and oracle-light when features are observed (complete, or
  hidden-unweighted); add CCCP/EM only when the *weighted* variables are hidden;
  fold prior beliefs in as the regularization center $`\theta_0`$.
- **Scale**: fit on small instances, transfer to large; do any counting/sampling small.

---

## 12. Sampling-based marginal inference: MC-SAT

Four of the marginal-inference back ends ([probability.md](probability.md)) are
*exact*: enumeration, ADDMC, and the two d-DNNF circuit compilers. Past their
scale limits, the canonical MLN approach is **MC-SAT** (Poon & Domingos 2006),
which fits FiFO's architecture particularly well because its inner loop is a SAT
solve. It **is now implemented** as `bin/marginals.sh --solver mc-sat`
(`lisp/mcsat.lisp`, driving WalkSAT v58's `-mcsat` mode); see
[probability.md § Approximate marginals by MC-SAT sampling](probability.md#approximate-marginals-by-mc-sat-sampling)
for how to run it. This section records the theory and the design space behind
that choice.

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
- **CMSGen** (Golia, Soos, Chakraborty & Meel 2021): the disciplined version of that last idea — a CryptoMiniSat variant that samples by randomising the polarity decisions a CDCL solver makes during search. It offers no uniformity guarantee at all; instead it was *tested* into shape, tuned against **Barbarik** (Chakraborty & Meel 2019), a grey-box tester that decides whether a sampler's distribution is close to uniform, until it passed — and it reports a 420× geometric speed-up over the samplers that do carry guarantees. The reason it is not a FiFO back end is the weights: CMSGen samples *uniformly over models*, so recovering $`P_\theta`$ means importance-reweighting each sample by $`e^{-\mathrm{cost}(x)}`$, and that estimator's variance blows up precisely when the weights are large enough to be worth having. MC-SAT instead folds the weights into the sampling process itself, via the slice step.

**What was implemented.** The random-phase option was rejected on cost grounds: a
per-sample process spawn plus a re-parse of the CNF dominates the inner search
when there are tens of thousands of samples. Instead the *whole* loop — outer
slice sampling and inner sampler — lives in C, in WalkSAT v58's `-mcsat` mode, so
FiFO writes one weighted CNF and shells out once. The inner sampler is **SampleSAT**
proper (Wei, Erenrich & Selman 2004): with probability `p` a greedy WalkSAT move,
otherwise a simulated-annealing (Metropolis) move whose energy is the number of
unsatisfied active clauses. The annealing move is what supplies the near-uniformity
WalkSAT alone lacks, and the weights never reach it — they are consumed entirely
by the slice step, so the inner loop is unweighted.

Two properties fell out of the construction and are worth recording. First, the
constraint set `M` **can never be unsatisfiable**: only *satisfied* soft clauses
are eligible for inclusion and the current assignment satisfies every hard clause,
so the current assignment is always a witness. The only from-scratch solve is the
initial one. Second, the failure mode is not sampling noise but **freezing**: on
strongly coupled models (many large weights) `1 − e^{−w} → 1`, nearly every clause
enters `M`, and the chain stops moving. That is invisible in the marginals
themselves, so the implementation reports an effective-sample-size diagnostic
alongside them; on the UAI-2014 MAR *Grids* benchmarks it correctly flagged badly
wrong marginals (efficiency ≈ 0.02) before any ground truth was available.

---

## 13. Projected inference over action variables

For SatPlan encodings there is important additional leverage. The variables partition into:

- **Action variables**: `(Occurs a s)` — carry weights, are the decisions
- **State variables**: `(Holds f s)` — unweighted, largely determined by the hard clauses given the action assignment

The frame axioms, precondition/effect axioms, and initial/goal constraints are tight: given a complete action assignment, the state variables are almost entirely forced by unit propagation. The effective sampling space is over action sequences, not full assignments.

This suggests a **projected inference** approach: sample over action variable assignments (using MC-SAT or random restarts), and derive state variable values deterministically via unit propagation after each action sample. Marginals of state variables are then computed as a function of action marginals rather than being sampled directly. This drastically reduces the effective dimension of the sampling problem.

---

## 14. Maximum-term approximation of the partition function

The inference back ends above compute a partition function
$`Z_S = \sum_{x \in S} e^{-\beta\, \mathrm{cost}(x)}`$ — a weighted sum over a
(possibly exponentially large) set $S$ of feasible models, with
$`\beta = 1/\text{scale}`$. Exact evaluation is #P-hard (weighted model
counting). The **maximum-term approximation** — also called the *Viterbi*,
*zero-temperature*, or *ground-state* approximation — replaces the sum by its
single largest term, i.e. the cheapest model in $S$:

$`Z_S \;=\; e^{-\beta\, c_{\min}(S)} \cdot \Omega_S(\beta), \qquad
   \Omega_S(\beta) = \sum_{x\in S} e^{-\beta\,(\mathrm{cost}(x) - c_{\min}(S))} \;\ge\; 1,
   \qquad c_{\min}(S) = \min_{x\in S}\mathrm{cost}(x),`$

and drops the **degeneracy factor** $`\Omega_S`$ (the entropy of near-optimal
models), keeping only $`Z_S \approx e^{-\beta\, c_{\min}(S)}`$, i.e.
$`\log Z_S \approx -\beta\, c_{\min}(S)`$ — the free energy approximated by the
ground-state energy. The point of the swap is computational: $`c_{\min}(S)`$ is
a **MaxSAT** optimization (tractable with core-guided solvers), where $`Z_S`$ is
counting. It is the same move MAP makes for a whole distribution — the single
most-probable assignment — applied here to a restricted set $S$.

**Accuracy.** The approximation is exact when $`\Omega_S = 1`$ (a unique optimum,
everything else far costlier) and sharpens as $`\beta \to \infty`$ (low
temperature: the dominant term swamps the rest). Its error in any *ratio* of
partition functions is the log-ratio of the dropped degeneracies. Concretely,
for the conditional $`P(A\mid B) = Z_{A\cap B}/Z_B`$ with $`Z_B = Z_{A\cap B} + Z_{\lnot A\cap B}`$,

$`P(A\mid B) \;=\; \sigma\!\big(\beta\,\Delta + \log(\Omega_{A\cap B}/\Omega_{\lnot A\cap B})\big),
   \qquad \Delta = c_{\min}(\lnot A\cap B) - c_{\min}(A\cap B),`$

and the max-term approximation keeps only $`\sigma(\beta\,\Delta)`$, dropping the
degeneracy log-ratio. So a conditional is well approximated by two MaxSAT costs
*differenced*, and the two goals' baselines (and much of their degeneracy)
cancel — only the *asymmetry* in near-optimal multiplicity between the two sides
is lost.

**Plan recognition is the application FiFO implements.** For a hypothesis $G$
and observations $O$, the likelihood is
$`P(O\mid G) = Z_{G,O}/Z_G = Z_{G,O}/(Z_{G,O}+Z_{G,\lnot O})`$; the max-term
approximation gives Ramírez & Geffner's recognizer,
$`P(O\mid G) \approx \sigma\big(\beta\,(c(G,\lnot O) - c(G,O))\big)`$, where
$`c(G,O)`$ / $`c(G,\lnot O)`$ are the cheapest plans for $G$ that do / do not
comply with the observations. This is exactly the `Z_G`-normalized recognition
posterior (§ [Case 4](#8-case-4--beliefs-about-marginals-little-or-no-data)-style
normalization applied to goals) with **counting replaced by optimization** — the
tractable stand-in for the exact weighted model count, which is intractable at
useful planning horizons. It is realized by `bin/recognize.sh`
([probability.md](probability.md#plan-recognition-posteriors-recognizesh)); the
worked results are in
[benchmarks.md](../benchmarks.md#ramírez-and-geffner-recognition-on-the-plan-recognition-benchmarks).

---

## 15. MAP inference: the mode of the distribution

Sections 12–14 are all concerned, one way or another, with the *sum*
$`Z = \sum_{x\in\mathcal F} e^{-\beta\,\mathrm{cost}(x)}`$ — exactly, approximately,
or by sampling. The complementary query asks for the **mode**: the single most
probable feasible assignment,

$`x^\star \;=\; \arg\max_{x\in\mathcal{F}} P_\theta(x)
   \;=\; \arg\min_{x\in\mathcal{F}} \sum_a \theta_a N_a(x),`$

the equality holding because $`t \mapsto e^{-t}`$ is strictly decreasing, so the
normalizer $`Z`$ — the hard part of every other query in this document — plays no
role at all. In FiFO's encoding this is literally weighted MaxSAT over the hard
clauses and the `(WEIGHT ...)` costs; see
[probability.md](probability.md#map-inference-the-most-probable-model) for how to run
it. Every MaxSAT call in the stack — the planner's cost-minimization step, each of
`recognize.sh`'s $`2n`$ solves, the oracle inside the learning loops of §§4–7 — is a
MAP query.

**Terminology.** The graphical-models literature reserves **MPE** (most probable
explanation) for the maximization over *all* variables, and uses **MAP** (or
*marginal MAP*) for the mixed query

$`\arg\max_{y}\sum_{z} P_\theta(y,z),`$

which maximizes over a subset $`Y`$ and *sums out* the rest. The two are genuinely
different: the most probable joint assignment need not contain the most probable
setting of any sub-block. FiFO implements only the full-assignment query; nothing
in the pipeline sums out a block before maximizing. The projected-inference sketch
of §13 splits the variables the same way (weighted action atoms vs. determined
state atoms), but it is a *summing* method with a deterministic completion, not a
marginal MAP.

**Why the stack leans on it.** The complexity separation is the whole practical
story. The decision version of MPE — "is there a feasible model of cost at most
$`k`$?" — is NP-complete, and the optimization is a short sequence of such
queries ($`\mathrm{FP}^{\mathrm{NP}}`$), which is exactly the regime core-guided
MaxSAT solvers are engineered for. Computing
$`Z`$ or a marginal is `#P`-hard, and marginal MAP is harder still, NP<sup>PP</sup>-complete
(Park & Darwiche 2004): it embeds a counting problem inside a search. That ordering
is visible in FiFO's own measurements — on the plan-recognition benchmarks the
exact weighted model counts time out at a 240 s cap while the corresponding MAP
solves finish in seconds, which is precisely why §14's substitution of optimization
for counting is worth making
([benchmarks.md](../benchmarks.md#ramírez-and-geffner-recognition-on-the-plan-recognition-benchmarks)).

**MAP is the zero-temperature limit.** Introduce the inverse temperature explicitly,
$`P_\beta(x)\propto e^{-\beta\,\mathrm{cost}(x)}`$. As $`\beta\to\infty`$ the
distribution concentrates on the minimum-cost models, converging to the uniform
distribution over the argmin set; as $`\beta\to 0`$ it flattens to the uniform
distribution over $`\mathcal{F}`$, and marginal inference at $`\beta=0`$ is plain
model counting. MAP is the $`\beta\to\infty`$ end of that family, which yields two
invariances worth stating because they explain an asymmetry in the implementation:

- **Scaling.** $`\arg\min`$ is unchanged by multiplying every cost by a positive
  constant. So the `scale: N` header the learning pipeline writes (100 by default,
  to make weights integral for MaxSAT) is *irrelevant* to MAP but is a temperature
  for everything else — which is why every counting and sampling back end divides
  it out before exponentiating (see *Weight scale* in
  [probability.md](probability.md)) and MaxSAT never has to.
- **Shifting.** $`\arg\min`$ is likewise unchanged by adding a constant, and by the
  per-atom re-basing that turns a reward for `L` true into a cost for `L` false.
  That is what licenses the wcnf encoding's shift transformation: it moves the
  reported objective by a known offset while leaving the optimal model fixed.

Under the same limit, MAP is the leading term of the partition function:
$`\log Z = -\beta\,c_{\min} + \log\Omega(\beta)`$ with $`\Omega \ge 1`$ the
degeneracy factor of §14. So a MAP cost is always a bound, $`Z \ge e^{-\beta c_{\min}}`$,
and §14's recognizer is nothing but this bound applied twice and differenced.

**Conditioning.** Evidence has probability 1, so conditioning is the same operation
for MAP as for counting: the evidence joins the hard clauses and MaxSAT runs on the
augmented theory, giving the conditional mode $`\arg\max_x P_\theta(x\mid E)`$. The
non-obvious part is that the mode does not behave like a marginal under
conditioning. $`x^\star_{\mid E}`$ need not agree with $`x^\star`$ on any variable,
and evidence that raises an atom's marginal can flip it off in the mode; there is no
monotonicity to exploit and no way to update a stored MAP model incrementally. Each
piece of evidence needs its own solve — the reason `recognize.sh` pays for $`2n`$
independent runs rather than reusing one.

**What the mode does not tell you.** It is tempting to read $`x^\star`$ as a summary
of $`P_\theta`$; it generally is not, and the failure is not subtle:

- *The mode is not the marginals.* Take $`n`$ unconstrained atoms each with cost
  $`\theta`$ when true, so $`P(a) = \sigma(-\theta)`$. At $`\theta = \log(3/2)`$
  every atom has marginal 0.4, yet the MAP model sets **all** of them false, and
  its probability, $`0.6^n`$, is exponentially small. The mode of a cost
  distribution turns off everything it is not forced to turn on; expectations do
  not.
- *Degeneracy is invisible.* MaxSAT returns one minimum-cost model and says nothing
  about how many others tie it. That count is exactly the $`\Omega`$ dropped by the
  max-term approximation, so the error §14 incurs is precisely the quantity a MAP
  solve cannot report.
- *The consequences are measurable.* On the recognition benchmarks the single
  cheapest plan identifies the hypothesis that is cheapest to *reach*, not the one
  best supported by the observations — a bias that is not fixed by better search,
  because it is a property of the query. The repair is to take a *ratio* of two MAP
  costs within each hypothesis so the baseline cancels (§14), not to solve the
  single MAP more accurately.

**MAP as the learning oracle.** The learning cases of §§4–7 call MAP rather than a
counter, and the substitution is the same zero-temperature approximation seen in
§14. The maximum-likelihood gradient is the moment-matching residual
$`\Phi(x_{\text{data}}) - \mathbb{E}_\theta[\Phi]`$; replacing the expectation by
the features of the current best model gives the (voted) perceptron update
$`\theta \leftarrow \theta + \eta\,(\Phi(x_{\text{data}}) - \Phi(x^\star_\theta))`$,
which is Viterbi training / hard EM — exact when the distribution is peaked on
$`x^\star`$, biased by exactly the near-optimal mass it ignores when it is not. Max-margin
training (§6) goes further and makes the oracle *loss-augmented* MAP, so the
approximation is built into the objective rather than into the gradient. This also
draws the line the other way: the belief-driven MaxEnt fit of §8 constrains
$`\mathbb{E}_\theta[\Phi]`$ itself, which no MAP call can supply — that regime needs
the counting or sampling back ends, and is why FiFO carries both kinds of machinery.

---

## 16. Provenance / related work

Essentially all of the above is established, mostly within Markov Logic or its direct
foundations:

- **Tied weights, counts as sufficient statistics, complete-data gradient,
  pseudo-likelihood** — generative MLN learning (Richardson & Domingos 2006).
- **Discriminative / max-margin with MAP in the loop** — Singla & Domingos 2005 (voted
  perceptron); Huynh & Mooney 2009 (1-slack structural SVM); MaxSAT/ILP MAP oracles
  (Riedel 2008; RockIt, Noessner et al. 2013).
- **Regret / inverse-optimization framing, merely-good data** — same math as Maximum
  Margin Planning (Ratliff et al. 2006) and MaxEnt IRL (Ziebart 2008); ill-posedness
  from Ng & Russell 2000.
- **Partial data / latent variables** — standard hidden-variable CRF/MLN training; EM
  for MLNs with missing data; latent structured SVM via CCCP (Yu & Joachims 2009).
- **Marginal beliefs / no data** — maximum entropy (Della Pietra, Della Pietra & Lafferty
  1997); as belief-driven training, Generalized Expectation criteria (Mann & McCallum;
  Druck et al. 2008), learning from measurements (Liang, Jordan & Klein 2009), posterior
  regularization (Ganchev et al. 2010). Adjacent to MLN, same exponential-family core.
- **Beliefs + data, priors on weights** — semi-supervised GE/measurements; Gaussian-prior
  MAP weight learning is standard MLN.
- **Domain-size dependence** — projectivity for SRL (Jaeger & Schulte; Poole and
  colleagues on population size; Kuželka et al. on weighted first-order model counting).

What is at most *new* is the **instantiation**: learning FiFO/SatPlan action costs through
the WCNF→MaxSAT pipeline with modern core-guided solvers at scale — inverse optimal
planning in this encoding, an application/engineering choice rather than a new learning
principle. A defensible contribution would more likely be empirical, or in the
domain-size corner, than in the methods. (Claim is about the components; not an
exhaustive literature search of the exact combination.)

---

## 17. Summary table

| Data regime | Hidden vars | Objective | Convex? | Oracle / inference |
|---|---|---|---|---|
| Complete, optimal | none | feasibility in cost cone | yes | free MaxSAT |
| Complete, merely good | none | min total regret (max-margin) | yes | free (loss-aug.) MaxSAT |
| Partial | unweighted only | as complete-data + SAT check | yes | free MaxSAT + feasibility |
| Partial | weighted | latent SSVM / EM | no | clamped + free MaxSAT (or WMC) |
| Beliefs only | n/a | MaxEnt moment matching | yes | $\mathbb{E}_\theta[\Phi]$ via WMC/sampling |
| Beliefs + data | varies | data fit + prior $\theta_0$ | per data term | offline WMC once + MaxSAT loop |

**Throughline:** every case is a constraint on $`\mathbb{E}_\theta[\Phi]`$ (empirical,
clamped, or believed). Counting supplies the free half; the constrained
argmin/partition function — the MaxSAT oracle or its counting analogue — supplies the
half that defines the problem.

------

## References

For §12 (sampling-based inference):

- H. Poon & P. Domingos (2006). Sound and efficient inference with probabilistic and deterministic dependencies. *AAAI-06*, pp. 458–463. (MC-SAT.)
- W. Wei, J. Erenrich & B. Selman (2004). Towards efficient sampling: Exploiting random walk strategies. *AAAI-04*, pp. 670–676. (SampleSAT.)
- S. Chakraborty, K. S. Meel & M. Y. Vardi (2013). A scalable approximate model counter. *CP 2013*, LNCS 8124, pp. 200–216. (ApproxMC — the universal-hashing counter the UniGen samplers are built on.)
- S. Chakraborty, D. J. Fremont, K. S. Meel, S. A. Seshia & M. Y. Vardi (2015). On parallel scalable uniform SAT witness generation. *TACAS 2015*, LNCS 9035, pp. 304–319. (UniGen.)
- S. Chakraborty & K. S. Meel (2019). On testing of uniform samplers. *AAAI-19*, 33:7777–7784. (Barbarik — a grey-box tester that decides whether a sampler's distribution is close to uniform, which is what made the next entry possible.)
- P. Golia, M. Soos, S. Chakraborty & K. S. Meel (2021). Designing samplers is easy: The boon of testers. *FMCAD 2021*. (CMSGen — near-uniform sampling by randomising a CDCL solver's polarity choices; see §12.)

For §14 (maximum-term approximation):

- M. Ramírez & H. Geffner (2010). Probabilistic plan recognition using off-the-shelf classical planners. *AAAI-10*, pp. 1121–1126. (The `σ(β·(c(G,¬O) − c(G,O)))` recognizer — the max-term approximation to `Z_{G,O}/Z_G`.)

For §15 (MAP inference):

- J. D. Park & A. Darwiche (2004). Complexity results and approximation strategies for MAP explanations. *Journal of Artificial Intelligence Research* 21:101–133. (MPE vs. marginal MAP; NP<sup>PP</sup>-completeness of the latter.)
- D. Koller & N. Friedman (2009). *Probabilistic Graphical Models: Principles and Techniques*. MIT Press, ch. 13. (MAP inference and the mode-vs-marginals distinction.)
- M. Collins (2002). Discriminative training methods for hidden Markov models: theory and experiments with perceptron algorithms. *EMNLP 2002*, pp. 1–8. (The perceptron update as a MAP-for-expectation substitution.)
- M. J. Wainwright & M. I. Jordan (2008). Graphical models, exponential families, and variational inference. *Foundations and Trends in Machine Learning* 1(1–2):1–305. (The zero-temperature limit of an exponential family.)

Full citations for the works named in §16 (Provenance / related work):

- M. Richardson & P. Domingos (2006). Markov logic networks. *Machine Learning* 62(1–2):107–136.
- J. Besag (1975). Statistical analysis of non-lattice data. *The Statistician* 24(3):179–195. (Pseudo-likelihood.)
- P. Singla & P. Domingos (2005). Discriminative training of Markov logic networks. *AAAI-05*, pp. 868–873.
- T. Huynh & R. Mooney (2009). Max-margin weight learning for Markov logic networks. *ECML PKDD 2009*, LNCS 5781, pp. 564–579.
- S. Riedel (2008). Improving the accuracy and efficiency of MAP inference for Markov logic. *UAI 2008*, pp. 468–475.
- J. Noessner, M. Niepert & H. Stuckenschmidt (2013). RockIt: Exploiting parallelism and symmetry for MAP inference in statistical relational models. *AAAI-13*.
- N. Ratliff, J. A. Bagnell & M. Zinkevich (2006). Maximum margin planning. *ICML 2006*, pp. 729–736.
- B. D. Ziebart, A. Maas, J. A. Bagnell & A. K. Dey (2008). Maximum entropy inverse reinforcement learning. *AAAI-08*, pp. 1433–1438.
- A. Y. Ng & S. Russell (2000). Algorithms for inverse reinforcement learning. *ICML 2000*, pp. 663–670.
- C.-N. J. Yu & T. Joachims (2009). Learning structural SVMs with latent variables. *ICML 2009*.
- S. Della Pietra, V. Della Pietra & J. Lafferty (1997). Inducing features of random fields. *IEEE Transactions on Pattern Analysis and Machine Intelligence* 19(4):380–393.
- G. Druck, G. Mann & A. McCallum (2008). Learning from labeled features using generalized expectation criteria. *SIGIR 2008*, pp. 595–602.
- G. Mann & A. McCallum (2010). Generalized expectation criteria for semi-supervised learning with weakly labeled data. *Journal of Machine Learning Research* 11:955–984.
- P. Liang, M. I. Jordan & D. Klein (2009). Learning from measurements in exponential families. *ICML 2009*.
- K. Ganchev, J. Graça, J. Gillenwater & B. Taskar (2010). Posterior regularization for structured latent variable models. *Journal of Machine Learning Research* 11:2001–2049.
- M. Jaeger & O. Schulte (2018). Inference, learning, and population size: Projectivity for SRL models. *Eighth International Workshop on Statistical Relational AI (StarAI)*, arXiv:1807.00564.
- D. Poole, D. Buchman, S. M. Kazemi, K. Kersting & S. Natarajan (2014). Population size extrapolation in relational probabilistic modelling. *SUM 2014*, LNCS 8720, pp. 292–305.
- O. Kuželka (2021). Weighted first-order model counting in the two-variable fragment with counting quantifiers. *Journal of Artificial Intelligence Research* 70:1281–1307.
