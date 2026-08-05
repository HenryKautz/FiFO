# FiFO Benchmarks

## Table of Contents

- [README.md](README.md) — the FiFO language reference and user guide.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: computing marginals under a weighted theory and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [FAQ.md](FAQ.md) — frequently asked questions about modeling with FiFO.
- $\color{red}{\textbf{benchmarks.md}}$ — measured results: horizons, CNF sizes, and compilation costs.

This file collects the measured results referenced throughout the documentation:
planning horizons and CNF sizes for the example problems, and the cost of
compiling them to d-DNNF circuits for exact inference.

## SatPlan: smallest horizons for the LogisticsCosts problems

The `SatPlan/Examples/LogisticsCosts` set (the `logistics-costs` domain — action costs load/unload = 1, drive = 4, fly = 15) collects seven problems: `pb1`–`pb5` are the PDDL4J logistics/rocket instances and `pb6`/`pb7` are small hand-written trucks+airplanes problems. Running each through `bin/planner.sh` (which tests feasibility with `kissat` at each horizon from the reachability lower bound upward, then minimizes cost with the MaxSAT solver at the smallest feasible horizon) gives the smallest horizon at which a plan exists, and its optimal cost:

| Problem | PDDL4J origin | Reachability LB | Smallest feasible horizon | CNF at that horizon (vars / clauses) | Optimal cost |
|---|---|--:|--:|--:|--:|
| `pb1` | `rocket_ext.a`  | 3 | 8  | 1 888 / 17 606  | 99  |
| `pb2` | `logistics.a`   | 5 | 12 | 7 518 / 90 356  | 126 |
| `pb3` | `logistics.easy`| 5 | 10 | 3 423 / 39 417  | 68  |
| `pb4` | `rocket_ext.b`  | 3 | 8  | 1 888 / 17 606  | 110 |
| `pb5` | `logistics.b`   | 5 | 14 | 7 988 / 103 439 | 122 |
| `pb6` | hand-written    | 3 | 6  | 528 / 3 710     | 44  |
| `pb7` | hand-written    | 3 | 6  | 1 503 / 14 961  | 66  |

The reachability lower bound (from `pddl2fifo`'s relaxed planning-graph analysis) is a loose floor; the true smallest horizon is one to nine slices higher because delete effects and resource contention (only so many trucks/airplanes act in parallel) force extra steps. All finished in well under a minute here — the SAT feasibility search dominates, and the MaxSAT cost step converged at the first feasible horizon for every instance. The intermediate `.wff`, `.scnf`, and `.wcnf` files for each problem (generated at its smallest feasible horizon) are kept under `SatPlan/Examples/LogisticsCosts/intermediates/`.

## d-DNNF compilation on the LogisticsCosts benchmarks

Compiling each SatPlan LogisticsCosts problem (see [the horizon table above](#satplan-smallest-horizons-for-the-logisticscosts-problems)) with d4 at its *smallest feasible horizon* — the hard clauses only, plain DIMACS — with a 10-minute cap:

| Problem | Horizon | Variables | Clauses | d4 compile time | d-DNNF size (nodes + arcs) |
|---|--:|--:|--:|--:|--:|
| `pb6` | 6  | 528   | 3 710  | < 1 s | 128   |
| `pb7` | 6  | 1 503 | 14 961 | 4 s   | 540   |
| `pb1` | 8  | 1 888 | 17 606 | 3 s   | 2 857 |
| `pb4` | 8  | 1 888 | 17 606 | 3 s   | 1 589 |
| `pb3` | 10 | 3 423 | 39 417 | 3 s   | 4 428 |

None came close to the cap — every instance compiled in seconds to a circuit of a few hundred to a few thousand nodes-plus-arcs. The reason is that the *smallest feasible* horizon is the most tightly constrained one: there is little slack, so few plans (and few partial assignments) survive, and the d-DNNF stays small. Note also that `pb1` and `pb4` have identical CNF dimensions yet different circuit sizes: same encoding, different goals.

**The cost of slack.** Pushing each problem *one* and *two* slices past its minimum — the same instances, just more room to maneuver — makes the compiled circuit explode, even though the CNF barely grows (a slice adds only a few hundred variables). Circuit size (nodes + arcs) and d4 compile time at horizon +0 / +1 / +2:

| Problem | d-DNNF size (+0 / +1 / +2) | d4 time (+0 / +1 / +2) |
|---|--:|--:|
| `pb6` | 128 / 1 162 / 8 300               | < 1 s / 1 s / 1 s |
| `pb7` | 540 / 6 524 / 1 948 897           | 4 s / 1 s / 15 s |
| `pb1` | 2 857 / 406 757 / 23 574 047      | 3 s / 6 s / 271 s |
| `pb4` | 1 589 / 192 335 / 10 926 204      | 3 s / 4 s / 150 s |
| `pb3` | 4 428 / 976 103 / — (timeout)     | 3 s / 13 s / **> 600 s** |

One extra slice already grows the d-DNNF by one to three orders of magnitude (pb3: 4 428 → 976 103 nodes-plus-arcs); a second slice reaches tens of millions (pb1 at +2: 23.5 M) and, for `pb3` at horizon 12, blows past the 10-minute cap. Compile time follows the same curve — seconds at the minimum, but 271 s for `pb1` at +2 and a timeout for `pb3`. This is the concrete reason to plan at the smallest feasible horizon (and why the home-grown compiler carries a node cap): the slack slices multiply logically-equivalent plans, and the circuit — which must represent *all* of them — grows accordingly.
