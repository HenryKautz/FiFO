# FiFO Benchmarks

## Table of Contents

- [README.md](README.md) — the FiFO language reference and user guide.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: computing marginals under a weighted theory and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- $\color{red}{\textbf{benchmarks.md}}$ — measured results: horizons, CNF sizes, and compilation costs.
- [discussion.md](discussion.md) — discussion and open issues.

This file collects the measured results referenced throughout the documentation:
planning horizons and CNF sizes for the example problems, the cost of compiling
them to d-DNNF circuits for exact inference, and MAP inference on the plan-
recognition benchmarks.

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

## MAP inference on the plan-recognition benchmarks

### Provenance and adaptation

Two problems from the Ramírez & Geffner plan-recognition benchmarks (AAAI-10), via the PUCRS goal-plan-recognition dataset (see [`SatPlan/Examples/Plan_Recognition/`](SatPlan/Examples/Plan_Recognition/)):

- **BlockWords** (`block-words-aaai_p01`) — eight letter-labeled blocks; 21 candidate goals, each a tower spelling an English word. The hidden goal spells **CORE** (`hyp16` in generation order; `hyp0` is a different word, DRAW).
- **IntrusionDetection** (`intrusion-detection-aaai_p10`) — an attacker over ten hosts; 10 candidate goals naming attacker objectives over subsets of hosts. The hidden goal is *information-gathered on all ten hosts* (`hyp0`).

Each is adapted to a FiFO/SatPlan recognition instance by `make-recognition-instance.lisp`:

- **Costs.** Every action gets a uniform `(increase (total-cost) 1)`, so plan cost = plan length and the distribution over trajectories is the Boltzmann model `exp(−β · length)`, `β = cost / scale` — the model Ramírez & Geffner assume. (BlockWords additionally has the original `(not (= ?x ?y))` guards dropped, since FiFO has no `=`; harmless in the 4-operator blocks world.)
- **Disjunctive goal over derived predicates.** Each hypothesis becomes a nullary derived predicate `hypI` equal to the conjunction of its goal literals, so the goal is `(or (hyp0) … (hypN))` and each hypothesis is a single atom `(HOLDS (hypI) numslices)` — one readable handle per hypothesis.
- **Ordered evidence.** The dataset's `obs.dat` (the true agent's plan) is turned into `occur-in-order` forms; `evidence-K.txt` is the first *K* observations — partial observability, order known, times unknown.
- **Horizon.** So the horizon never eliminates a hypothesis, the *minimum feasible horizon of each single-hypothesis goal* is found with the non-probabilistic planner, and the shared horizon `H` is the **maximum** over hypotheses: **Intrusion H = 6**, **BlockWords H = 15** (one word, `hyp15`, needs 15 slices).

### MAP results

For three evidence prefixes per domain, the **MAP / max-optimal plan** — the single lowest-cost plan that embeds the observations (in order) and satisfies some hypothesis, found by weighted MaxSAT at the fixed horizon `H`. *Recognized* is the hypothesis that holds at the final slice of that plan; *cost* is the number of actions.

| Domain | Observations | Horizon | Vars | Clauses | Time | MAP cost | Recognized | True |
|---|--:|--:|--:|--:|--:|--:|:--:|:--:|
| IntrusionDetection | 1 | 6  | 1 056 | 2 240   | 3.3 s | 14 | hyp3  | hyp0  |
| IntrusionDetection | 3 | 6  | 1 068 | 2 282   | 3.9 s | 16 | hyp3  | hyp0  |
| IntrusionDetection | 5 | 6  | 1 080 | 2 324   | 2.2 s | 18 | hyp2  | hyp0  |
| BlockWords         | 1 | 15 | 3 681 | 240 552 | 8.4 s | 4  | hyp5  | hyp16 |
| BlockWords         | 3 | 15 | 3 711 | 240 666 | 9.1 s | 7  | hyp5  | hyp16 |
| BlockWords         | 5 | 15 | 3 741 | 240 780 | 9.7 s | 10 | **hyp16** | hyp16 |

(Intermediate results are kept under each instance's `runs/` subdirectory — `runs/horizons/` for the per-hypothesis horizon sweep, `runs/map/` for these runs.)

### Reading the results: MAP is the cheapest explanation, not the most likely one

The recognized hypothesis is *wrong* (≠ the true hidden goal) in five of the six rows, and that is expected — it is the cost bias of MAP, not a defect of the encoding (the machinery is provably sound: BlockWords recovers the true `hyp16` once the evidence is rich enough). MAP returns the single **cheapest** plan consistent with the observations, so it recognizes the hypothesis that is cheapest to reach, regardless of whether the observations actually single it out:

- **BlockWords** flips to the true `hyp16` at 5 observations. With 1–3 observations the prefix (`unstack R P`, …) lies on the optimal path of many words, so it fails to discriminate and the cheaper decoy `hyp5` (the word CROW, cost 4) wins over the pricier true CORE (cost 10). By 5 observations the prefix contains `stack R E` — putting R on E, a CORE move but not a CROW move — so the evidence finally discriminates and the cheap decoy is ruled out.
- **IntrusionDetection** never recovers the true `hyp0`, because the observed recons are the common first step of *every* attack (non-discriminative) and the true goal — reconnaissance on all ten hosts — is the *most expensive* hypothesis in the set. The cheapest plan embedding the recons always lands on a smaller, cheaper targeted attack.

Two points worth drawing out. First, **switching to marginals would not fix this and would make it worse**: at a fixed horizon the cheap goal has *more* compatible trajectories (more slack to pad) *and* cheaper ones (weighted up by `exp(−cost)`), so the raw marginal `P(hyp | O) ∝ Z_{hyp,O}` favors the cheap decoy even more strongly — the Z_G bias of [discussion.md](discussion.md#goal-posteriors-and-the-per-goal-normalization-z_g-issue). Calibrated recognition needs the normalized likelihood `Z_{hyp,O} / Z_hyp`, which divides out each goal's intrinsic cheapness, *plus* discriminating evidence. Second, **exact marginals were intractable here anyway**: at these horizons (H = 6 and 15) every weighted-model-counting run timed out (ADDMC, 240 s cap), while MAP finished in seconds — the same tractability gap between optimization (MaxSAT) and counting (WMC) seen in the cost-of-slack table above. MAP is the tractable-but-biased option; the exact posterior is the calibrated-but-expensive one.

### References

- M. Ramírez & H. Geffner (2010). Probabilistic plan recognition using off-the-shelf classical planners. *AAAI-10*, 1121–1126. (The Boltzmann plan model and the `c(G,O) − c(G,¬O)` baseline that removes each goal's intrinsic reachability.)
- R. F. Pereira, N. Oren & F. Meneguzzi (2017). Landmark-based heuristics for goal recognition. *AAAI-17*. (The curated dataset these instances come from.)

## Ramírez and Geffner recognition on the plan-recognition benchmarks

The MAP table above shows the cost bias: the single cheapest plan recognizes the cheapest-to-reach hypothesis, not the most likely one. The calibrated fix is the posterior `P(G | O) ∝ π_G · Z_{G,O}/Z_G`, but exact `Z` (weighted model counting) is intractable at these horizons. **Ramírez & Geffner's `c(G,O) − c(G,¬O)` method is the tractable approximation** — it replaces each partition function by its dominant (min-cost) term, so counting becomes MaxSAT optimization. `bin/recognize.sh` implements it: for each hypothesis `hypI` it runs `planner.sh` twice at the fixed horizon `H` (same `H` as the MAP table), computing the cheapest plan that **complies** with the observations (`--pddl-evidence '(occur-in-order …)'`) and the cheapest that **does not** (`--pddl-evidence '(not (occur-in-order …))'`), then

`Δ_I = c(¬O) − c(O)`, `P(O | hypI) = σ(β·Δ_I)`, `P(hypI | O) = π_I·P(O|hypI) / Σ_J π_J·P(O|hypJ)`

with uniform priors `π` and `β = 1` here. It costs `2n` MaxSAT runs per evidence set (≈ 1 m 53 s for Intrusion's 10 hypotheses at H=6, ≈ 6.7 min for BlockWords' 21 at H=15; see the Wall-clock column). For each evidence prefix, the recognized (argmax) hypothesis and the posterior mass on the **true** hidden goal (Intrusion `hyp0`, BlockWords `hyp16`):

| Domain | Observations | Horizon | 2n MaxSAT runs | Wall-clock | Recognized (posterior) | True-goal posterior |
|---|--:|--:|--:|--:|:--|--:|
| IntrusionDetection | 1 | 6  | 20 | ≈ 1 m 53 s | hyp0 — 5-way tie (0.16) | 0.16 (tied 1st) |
| IntrusionDetection | 3 | 6  | 20 | 1 m 53 s     | **hyp0** (0.37) | 0.37 (1st) |
| IntrusionDetection | 5 | 6  | 20 | ≈ 1 m 53 s | **hyp0** (0.67) | 0.67 (1st) |
| BlockWords | 1 | 15 | 42 | ≈ 6.7 min | (large tie, 0.05) | 0.05 (tied) |
| BlockWords | 3 | 15 | 42 | ≈ 6.7 min | hyp10 (0.21) | 0.12 (2nd) |
| BlockWords | 5 | 15 | 42 | ≈ 6.7 min | **hyp16** — tie w/ hyp15 (0.31) | 0.31 (tied 1st) |

The wall-clock is the `2n` MaxSAT runs for that evidence set. It is essentially constant across the observation prefixes within a domain — the horizon and CNF size are fixed and the evidence adds only a few clauses — so it is measured/estimated once per domain rather than per row: IntrusionDetection evidence-3 timed directly at 1 m 53 s (20 runs at H = 6, ≈ 5.7 s/run); BlockWords from its ≈ 19 s per-hypothesis pair at H = 15 (≈ 9.5 s/run × 42). MaxSAT is what makes this affordable at all — the exact weighted model counting these approximate timed out at a 240 s-per-call cap.

The normalization does exactly what it should. On **IntrusionDetection**, where raw MAP never recovered the true broad-espionage goal, R&G puts `hyp0` at or above every rival and sharpens it from a 5-way tie (0.16) to a decisive 0.67 as observations accrue — because reconning taurus/leo/… is *on the optimal path* for the all-hosts goal (`Δ = 0`, complying is free) but *wasteful* for a targeted attack (`Δ < 0`). The evidence-1 structure is itself informative: the five hypotheses that require reconning taurus get `c(¬O) = ∞` (that observation is *necessary*, likelihood 1) and tie at the top, while the five that don't are ranked down. On **BlockWords** the true `hyp16` climbs from a large tie (1 obs) to 2nd (3 obs, behind `hyp10`, whose plan the observed prefix makes strictly cheaper, `Δ = +2`) to tied-first with `hyp15` (5 obs) — the two words that share the observed prefix.

The one-line takeaway: the same `2n` cheapest-plan computations that MAP already does per hypothesis, differenced against a *not-complying* baseline, recover the calibrated recognition posterior that exact model counting could not afford — the practical realization of the `Z_G` normalization discussed in [discussion.md](discussion.md#goal-posteriors-and-the-per-goal-normalization-z_g-issue). Per-hypothesis costs and posteriors for each evidence set are under each instance's `runs/recognize/`.
