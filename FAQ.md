# FiFO FAQ

## Table of Contents

- [README.md](README.md) — the FiFO language reference and user guide.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: computing marginals under a weighted theory and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- $\color{red}{\textbf{FAQ.md}}$ — frequently asked questions about modeling with FiFO.

## FAQ Topics

- [Mixing Probabilities and Utilities](#mixing-probabilities-and-utilities)
- [Handling Sequential Action Evidence](#handling-sequential-action-evidence)
- [Goal Posteriors and the Per-Goal Normalization (Z_G) Issue](#goal-posteriors-and-the-per-goal-normalization-z_g-issue)

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

**The real fix, and why a selection variable is needed.** To divide by `Z_G` you
need the per-goal partition functions, which the single disjunctive count does
not expose. Two routes:

- *Per-goal counts.* For each hypothesis, count `Z_{G,O}` (with evidence) and
  `Z_G` (without) and form the ratio — the calibrated likelihood P(O | G). This
  mirrors R&G's two-calls-per-goal structure. (`occur-in-order` already reifies
  "the observations happened" into a single atom `ObsDone(k, numslices)`, so
  P(O | G) can be had as *one* count per goal — the marginal of that atom in G's
  unconditioned theory — instead of two.)

- *Selection variables.* Introduce one **goal-selection variable** `sel_i` per
  hypothesis, each implying its goal conjunction (with an exactly-one
  constraint), and read `Z_{G_i}` and `Z_{G_i,O}` from the selectors' marginals
  in two counts total (one with evidence, one without) rather than 2n. This is
  also where an explicit prior belongs — put the goal weight on `sel_i`, not
  through the one-directional preference reification (see the previous FAQ
  entry). A selection variable is *needed* because the raw disjunctive goal
  gives no per-hypothesis handle: several hypotheses may share final-state
  fluents, so no single fluent marginal is "the probability of hypothesis i,"
  and there is nothing to attach a prior weight to. `sel_i` is that handle — it
  makes each hypothesis a single atom whose marginal is its posterior and whose
  weight is its prior. (One subtlety: when hypotheses overlap in their final
  states, the exactly-one selector attributes each trajectory to a single
  hypothesis, which differs slightly from the per-goal counts that would count a
  shared trajectory under each goal it satisfies.)

None of this is implemented yet — the current examples use the simple
single-count approach deliberately, to get preliminary data first.

### References

- Ramírez, M., & Geffner, H. (2010). Probabilistic plan recognition using
  off-the-shelf classical planners. *Proceedings of the 24th AAAI Conference on
  Artificial Intelligence (AAAI-10)*, 1121–1126. (The `c(G, O) − c(G, ¬O)`
  baseline that removes each goal's intrinsic reachability.)
