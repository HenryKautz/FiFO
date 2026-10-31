# FiFO TO-DO

Open work items. See [Probability/probability.md](Probability/probability.md) for the
weight-learning pipeline as it stands and
[Probability/probability-background.md](Probability/probability-background.md) for the theory.

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
See [Probability/probability.md](Probability/probability.md).

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
- Connect to Probability/probability-background.md §2.9 (domain-size dependence) — plan cost may
  not be size-invariant; may need size-modulated features.

## Note: validating the small-domain → full-size transfer

Both items hinge on **schema tying** — the assumption that weights learned on
small domains transfer unchanged to larger ones. Probability/probability-background.md §2.9 warns
this can be **misspecified** when the true cost has size-dependent structure
(congestion, economies of scale, fixed overheads). When we build and validate the
transfer, keep the §2.9 diagnostic in mind: residual regret that **grows
systematically with instance size** signals misspecification (not noise), and the
fix stays linear — `θ_a(d) = α_a + β_a·g(d)` for a size function `g(d)`, adding
size-modulated features.

## 3. Regression tests to update for the new clara-logistics (2026-10-30) — DONE

Done 2026-10-30 by way (a): `clara-logistics-old.pddl` declares `(handle-cost)`
(never charged) so it accepts ppgen's current output, and both suites now plan
against it (evgen 110/110, evidence 42/42).  `SatPlan/pb1.pddl` has its
`handle-cost` line and the new proved optimum (10 slices, cost 20).  The
visualizer example and CLARA SimpleGrid/TwoPackage items below remain.

The original note:

`pddl/clara-logistics.pddl` changed: `load` and `unload` now cost `(handle-cost)`
each (ppgen `--handle-cost`, default 1) and `transfer` is gone (a package changes
vehicles by unload + load).  The old domain is kept as
`pddl/clara-logistics-old.pddl` (domain name `clara-logistics-old`).  Every other
suite and the gold tests pass; these fail (full run on the visualizer branch):

- **`tests/run-test-evgen.sh`** — 6 of 110 fail:
  - `--observe mixes a fluent name and an action name` (the spec's `fly,in` case, ~line 117)
  - `the evidence binds: a shifted observation costs more` (~line 287; gave no cost)
  - `recognize.sh's negation of it is a valid formula` (~line 384)
  - `and the not-comply case is the more expensive one` (~line 389)
  - `and it BINDS: a window excluding an observation breaks it` (~line 837)
  - `and the order matters: the reversed sequence costs more or is impossible` (~line 1004)
- **`tests/run-test-evidence.sh`** — 9 of 42 fail, all in "occur-in-order as a
  windowed trajectory constraint" (~line 404 on):  the three arities agree; a
  window containing the plan; negation with a window; the same as
  `--pddl-evidence`; strict ordering serializes; non-strict stays in the same
  slice; one observation; non-strict window and negation; non-strict as
  `--pddl-evidence`.

**Why:** each builds a fixed-seed ppgen problem and hard-codes actions observed in
*that* problem's optimal plan and its cost (e.g. "the plan puts A at slice 1, B
at 2, C at 4; unconstrained cost 16").  With paid handling and no transfer the
optimal plans change, so the chosen observations no longer bind as asserted.

**Two ways to fix:** (a) point these fixtures at `clara-logistics-old.pddl` —
they test the evidence machinery, not the domain — which needs the generated
problems' `(:domain clara-logistics)` rewritten too, since ppgen names the new
domain; or (b) re-derive each case's observed actions, slices and costs from a
fresh optimal plan under the new domain.

**Not tests, but also affected:**
- `SatPlan/pb1.pddl`: no `(= (handle-cost) 1)` (planning it now errors) and its
  documented optimal plan uses `transfer`; needs the line, a re-planned optimum,
  and a new comment.
- `SatPlan/Visualizer/examples/`: `clara-logistics.pddl` there is a copy of the
  OLD domain, matching the bundled `grid5x5-air` solution (cost 17, free loads).
  Re-plan with the new domain to update it.
- CLARA `SimpleGrid/` and `TwoPackage/` (~300 problems) name `clara-logistics`
  with no `handle-cost`: re-planning them errors.  Their results were made with
  the old domain; switch them to `(:domain clara-logistics-old)` to reproduce.
