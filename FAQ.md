# FiFO FAQ

## Table of Contents

- [README.md](README.md) — the FiFO language reference and user guide.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: computing marginals under a weighted theory and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- $\color{red}{\textbf{FAQ.md}}$ — frequently asked questions about modeling with FiFO.

## FAQ Topics

- [Mixing Probabilities and Utilities](#mixing-probabilities-and-utilities)

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
