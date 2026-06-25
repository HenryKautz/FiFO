# FiFO TO-DO

Open work items. See [Learning/learning.md](Learning/learning.md) for the
weight-learning pipeline as it stands and
[Learning/fifo-weight-learning.md](Learning/fifo-weight-learning.md) for the theory.

## 1. End-to-end weight learning from an uninstantiated `.wff` — DONE

Implemented. `(PROBABILITY <literal> <p> [<tie-label>])` is now a core FiFO form
(parsed/placed like `weight`); `instantiate` passes it through to the `.scnf` as
`(PROBABILITY <literal> <p> <gid>)` with a tie-group id shared by all groundings
of one source form (auto integer, or an explicit label). The learning pipeline
(`reweight.lisp`, `maxent.lisp`) groups by `gid`, fits **one** weight per group
(log-odds is tied automatically; MaxEnt uses a tied estimator whose sufficient
statistic is the group's true-count), and with `:wff "source.wff"` writes a copy
of the source `.wff` with each `(probability ...)` replaced by its tied
`(weight ...)` cost — re-instantiable at a new domain size. `propositionalize`
rejects an `.scnf` that still contains `PROBABILITY` forms. Overlapping forms
(one literal under two groups) and non-constant `p` within a group are errors.
See [Learning/learning.md](Learning/learning.md).

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
- Connect to Learning/fifo-weight-learning.md §10 (domain-size dependence) — plan cost may
  not be size-invariant; may need size-modulated features.

## Note: validating the small-domain → full-size transfer

Both items hinge on **schema tying** — the assumption that weights learned on
small domains transfer unchanged to larger ones. Learning/fifo-weight-learning.md §10 warns
this can be **misspecified** when the true cost has size-dependent structure
(congestion, economies of scale, fixed overheads). When we build and validate the
transfer, keep the §10 diagnostic in mind: residual regret that **grows
systematically with instance size** signals misspecification (not noise), and the
fix stays linear — `θ_a(d) = α_a + β_a·g(d)` for a size function `g(d)`, adding
size-modulated features.
