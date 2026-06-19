# Learning Weights for FiFO / SatPlan Encodings

A working summary of how to learn the weights in a FiFO weighted-MaxSAT theory —
i.e. the costs attached to weighted literals — across the full range of data
regimes, from complete optimal demonstrations down to nothing but prior beliefs
about marginal probabilities.

---

## 1. Setup and notation

FiFO compiles a finite-domain FOL theory into hard CNF clauses plus a set of
**weighted literals**. A weighted MaxSAT / PBO solver finds the minimum-cost
feasible assignment. *Learning the weights* is the inverse problem: given
assignments believed to be (near-)optimal, recover weights that make them so.

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
groundings and time steps), and $C_\theta$ is the total plan cost.

---

## 2. Parameter tying and the feature space

There is heavy tying: hundreds of ground weighted literals collapse to a few dozen
schema weights, because all ground instances of a schema share one weight
(`(Cost act c)` is the same for every grounding). This makes the parameter vector
small and the problem well-conditioned.

**Fixed domains** (all training instances share the same element counts; they may
still differ in initial/goal state or observed facts): every instance maps into the
same $A$-dimensional count space, so all examples share one $\theta$. Tying is
optional here but better-conditioned.

**Varying domains** (different numbers of packages, trucks, places, time horizon):
the CNF, variables, and feasible set all change — but the schemas don't, and
$\Phi_d : \mathcal{F}_d \to \mathbb{Z}_{\ge0}^A$ always lands in the *same* space.
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
$P_\theta(x) \propto \exp(-\theta^\top\Phi(x))$ on $\mathcal{F}$. Then learning is
matching the model's expected features $\mathbb{E}_\theta[\Phi]$ to a target. Every
regime below differs only in **where the target moments come from**:

- complete data → empirical counts $\bar\Phi$
- partial data → clamped (conditional) expectations $\mathbb{E}_\theta[\Phi \mid o]$
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

- *Probabilistic view:* the gradient is $\bar\Phi - \mathbb{E}_\theta[\Phi]$. Counting
  gives the empirical half; the model expectation needs $Z(\theta)$, a global
  $\theta$-dependent sum over $\mathcal{F}$ (weighted model counting, #P-hard).
- *Discriminative view:* "good weights" are *operationally defined* by what the
  solver does — evaluating a candidate $\theta$ requires $\min_{x\in\mathcal F}\theta^\top\Phi(x)$,
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

$$\min_{\theta\ge0}\ \tfrac{\lambda}{2}\|\theta\|^2
+ \sum_k \Big[\theta^\top\Phi_k(x^{(k)})
- \min_{x\in\mathcal{F}_k}\big(\theta^\top\Phi_k(x) - \Delta_k(x)\big)\Big]_+ .$$

A subgradient is $\Phi_k(x^{(k)}) - \Phi_k(\hat x_k)$ with $\hat x_k$ the
loss-augmented MaxSAT optimum — the perceptron update, now not driven to zero.

Practical points:

- **Hinge / L1 slack**, not squared — robust to the occasional badly suboptimal demo.
- **Regularization does real work**: the regret surface is flat in directions, so
  $R(\theta)$ and the gauge pick among near-equivalent fits (L2 for stability, L1 for
  sparsity).
- **Validate by regret, not reproduction** — demos are suboptimal, so you *shouldn't*
  reproduce them. Watch the distribution of residual gaps $g_k(\theta^*)$; gaps that
  grow with instance size signal misspecification (see §10), not noise.
- **Solve the oracle to optimality** — an anytime/suboptimal solution under-estimates
  the min and gives a biased subgradient (relevant for anytime solvers like
  TT-Open-WBO-Inc).

The probabilistic alternative *models* the suboptimality via a Boltzmann demonstrator
$P_\theta(x)\propto\exp(-\beta\,\theta^\top\Phi)$ (temperature $1/\beta$ = rationality;
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

   The data term becomes $\min_{x\in\mathcal{F}_d(o^{(k)})}\theta^\top\Phi(x)$; CCCP
   linearizes it via the imputation. Reuses one oracle twice — clamped, then free.

2. **EM on the marginal likelihood**, with gradient
   $\mathbb{E}_\theta[\Phi \mid o^{(k)}] - \mathbb{E}_\theta[\Phi]$ (clamped minus free
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
$\tau_a = \sum_{j\in a} p_j$, and solve the moment-matching condition

$$\mathbb{E}_\theta[\Phi] = \tau,$$

a low-dimensional convex program ($\min_\theta \log Z(\theta) + \theta^\top\tau$),
solvable by iterative scaling or gradient descent. Each step needs $\mathbb{E}_\theta[\Phi]$
(weighted model counting / sampling over $\mathcal{F}$) — do it on small instances.

- **Scale is now identified.** Unlike optimal-plan data (ratios only), marginals depend
  on the absolute scale of $\theta$ (the temperature), so they pin $\theta$ down fully.
- **Warm-start.** Ignoring clauses, each literal is logistic, giving
  $\theta_a^{(0)} = \log\frac{1-p_a}{p_a}$ (log-odds of the belief); the iterative
  inference corrects for the coupling the clauses introduce.
- **Soft matching.** Beliefs may be jointly infeasible under the clauses; penalize
  $\|\mathbb{E}_\theta[\Phi]-\tau\|$ with per-constraint confidence weights. Schemas with
  no belief get a prior/regularizer.

With no data there is nothing to validate against — $\theta$ is only as good as the
beliefs plus the MaxEnt assumption, which is the honest least-committal completion.

---

## 9. Case 5 — Combining beliefs and data

Both enter through the **same channel**: constraints on $\mathbb{E}_\theta[\Phi]$. Combining
them is combining target moments, weighted by confidence — beliefs act as **pseudo-data
with an effective sample size** (Bayesian shrinkage / conjugate prior). No data → match
the beliefs; abundant data → empirical moments dominate; in between, a blend.

**Recommended arrangement for the MaxSAT stack** (decouples expensive from cheap):

1. Solve the marginal MaxEnt **once**, offline, on small instances → prior center $\theta_0$.
2. Run the discriminative min-regret fit on the data with regularizer
   $\tfrac{\lambda}{2}\|\theta - \theta_0\|^2$ instead of $\tfrac{\lambda}{2}\|\theta\|^2$.

The costly probabilistic inference happens once (to set the prior); the cheap MaxSAT
oracle does the data fitting. With no data this returns $\theta_0$; with data it moves
off as far as the evidence warrants. The beliefs also **supply the scale** that
optimal-plan data leaves undetermined — the two sources are complementary.

---

## 10. Domain-size dependence (a real caveat)

Schema tying assumes $\theta_a$ is constant across instance sizes. If the true cost has
size-dependent structure (congestion, economies of scale, fixed overheads), pure tying
is misspecified — diagnosable as residual regret that **grows systematically with size**.
The fix stays linear: let $\theta_a(d) = \alpha_a + \beta_a\,g(d)$ for a size function
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
  fold prior beliefs in as the regularization center $\theta_0$.
- **Scale**: fit on small instances, transfer to large; do any counting/sampling small.

---

## 12. Provenance / related work

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

## 13. Summary table

| Data regime | Hidden vars | Objective | Convex? | Oracle / inference |
|---|---|---|---|---|
| Complete, optimal | none | feasibility in cost cone | yes | free MaxSAT |
| Complete, merely good | none | min total regret (max-margin) | yes | free (loss-aug.) MaxSAT |
| Partial | unweighted only | as complete-data + SAT check | yes | free MaxSAT + feasibility |
| Partial | weighted | latent SSVM / EM | no | clamped + free MaxSAT (or WMC) |
| Beliefs only | n/a | MaxEnt moment matching | yes | $\mathbb{E}_\theta[\Phi]$ via WMC/sampling |
| Beliefs + data | varies | data fit + prior $\theta_0$ | per data term | offline WMC once + MaxSAT loop |

**Throughline:** every case is a constraint on $\mathbb{E}_\theta[\Phi]$ (empirical,
clamped, or believed). Counting supplies the free half; the constrained
argmin/partition function — the MaxSAT oracle or its counting analogue — supplies the
half that defines the problem.
