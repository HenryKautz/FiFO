# FiFO TO-DO

Open work items. See [Learning/learning.md](Learning/learning.md) for the
weight-learning pipeline as it stands and
[fifo-weight-learning.md](fifo-weight-learning.md) for the theory.

## 1. End-to-end weight learning from an uninstantiated `.wff`

Today the learning pipeline starts from an already-instantiated `.scnf` whose
`(PROBABILITY <literal> p)` lines give target marginals. We want to start one step
earlier, at the source `.wff`, and end one step later, with an editable weighted
`.wff`.

Goal: take an **uninstantiated** FiFO `.wff` that contains `(PROBABILITY ...)`
forms, and:

1. Instantiate it on **small** domains (where exact MaxEnt enumeration is
   tractable).
2. Learn the weights on that small instance (independent log-odds or exact
   iterative MaxEnt, as now).
3. Emit a FiFO **`.wff`** (not just an `.scnf`) carrying the learned integer
   `(WEIGHT ...)` costs, which the user can then **edit to change the domains**
   and re-instantiate at full size — relying on schema tying so the small-domain
   weights transfer (cf. fifo-weight-learning.md §2, §10 on domain-size
   dependence).

Open questions / subtasks:
- Teach the parser/instantiator to accept `(PROBABILITY ...)` in `.wff` files
  (placement rules analogous to `weight`: in `and`/`all`/`exists`/`if`, not in
  `or`/`not`/etc.).
- Decide how learned ground weights map back to a **schema-level** weight in the
  emitted `.wff` (parameter tying: many ground `PROBABILITY` instances of one
  schema → one learned `WEIGHT`). Handle conflicts/averaging if ground targets
  for the same schema disagree.
- Round-trip: emitted `.wff` should re-instantiate cleanly at a new domain size.

## 2. Probabilities instead of costs in the SatPlan compiler

The SatPlan path (`SatPlan/`, `pddl2fifo`, `planner.lisp`) currently expresses
action costs / preference weights as `(weight ...)` costs. We want to let the
user specify **probabilities** for the relevant choices instead, and **learn the
costs** on small domains — the same small-domain-learn-then-scale idea as item 1,
applied to planning.

Goal: allow a probability specification (e.g. on action occurrences, preferences,
or fluent costs) to flow through the SatPlan compiler, learn the corresponding
weights on small planning instances, and reuse them at larger horizons / domain
sizes.

Open questions / subtasks:
- Where probabilities attach in the PDDL→FiFO translation (action `:cost`,
  `(preference ...)`, `:fluent-cost`) and how that surfaces as `(PROBABILITY ...)`.
- What the marginal *means* for a planning fluent/action (per time slice? over the
  whole plan?), and whether the feasible set for MaxEnt is the set of valid plans.
- Tie into the planner's horizon search: learn on a small horizon, transfer.
- Connect to fifo-weight-learning.md §10 (domain-size dependence) — plan cost may
  not be size-invariant; may need size-modulated features.

## Note: validating the small-domain → full-size transfer

Both items hinge on **schema tying** — the assumption that weights learned on
small domains transfer unchanged to larger ones. fifo-weight-learning.md §10 warns
this can be **misspecified** when the true cost has size-dependent structure
(congestion, economies of scale, fixed overheads). When we build and validate the
transfer, keep the §10 diagnostic in mind: residual regret that **grows
systematically with instance size** signals misspecification (not noise), and the
fix stays linear — `θ_a(d) = α_a + β_a·g(d)` for a size function `g(d)`, adding
size-modulated features.
