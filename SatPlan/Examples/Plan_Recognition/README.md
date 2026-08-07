# Plan-Recognition Benchmarks

Two problem sets from the classic Ramírez & Geffner plan-recognition
benchmarks (AAAI-10), taken from the PUCRS goal-plan-recognition dataset
(https://github.com/pucrs-automated-planning/goal-plan-recognition-dataset),
which preserves the original six R&G domains (the `*-aaai` problems) alongside
nine newer ones.

## Contents

- `BlockWords/` — from `blocks-world/block-words-aaai_p01`. Eight
  letter-labeled blocks; the 21 candidate goals each stack a tower spelling an
  English word (the hidden goal spells C-O-R-E). The domain is the standard
  4-operator blocks world, with the original `(not (= ?x ?y))` stack/unstack
  guards dropped (FiFO has no `=`; the guards are redundant in this domain —
  see the comment in `block-words.pddl`).
- `IntrusionDetection/` — from
  `intrusion-detection/intrusion-detection-aaai_p10`, unmodified. An attacker
  performs recon on ten hosts and then gathers information, vandalizes, or
  steals data; the ten candidate goals name attacker objectives over subsets
  of the hosts.
- `BlocksWorldCosts/`, `IntrusionDetectionCosts/` — full recognition instances
  (uniform action costs, a disjunctive goal over all hypotheses, incremental
  evidence files) generated from the two above by
  `make-recognition-instance.lisp`. See "Recognition instances" below.

Each directory carries the recognition instance in the dataset's own format
plus a concrete planning problem derived from it:

| File | Contents |
|---|---|
| `template.pddl` | initial state, with the goal left as a `<HYPOTHESIS>` placeholder |
| `hyps.dat` | the candidate goals, one comma-separated conjunction per line |
| `real_hyp.dat` | the hidden true goal (one line of `hyps.dat`) |
| `obs.dat` | the observed action sequence, in order (here 100% observability) |
| `evidence-partial.txt` | a 50%-observability slice of `obs.dat` as one `occur-in-order` form |
| `pb1.pddl` | `template.pddl` with the hidden goal substituted in |
| `pb1.answer` | the plan found by `planner.sh` |
| `intermediates/pb1.wff` | the pddl2fifo translation (regression-checked by `tests/run-test-pddl.sh`) |

## Running

```sh
# BlockWords is inherently sequential (one hand): the plan takes 10 actions,
# so the horizon must be raised past the default reachability bound.
bin/planner.sh SatPlan/Examples/Plan_Recognition/BlockWords/pb1.pddl \
    --domain SatPlan/Examples/Plan_Recognition/BlockWords/block-words.pddl \
    --maxslices 12

# IntrusionDetection parallelizes (independent hosts) and solves at 3 slices.
bin/planner.sh SatPlan/Examples/Plan_Recognition/IntrusionDetection/pb1.pddl \
    --domain SatPlan/Examples/Plan_Recognition/IntrusionDetection/intrusion-detection.pddl
```

Neither domain has action costs, so the SAT solver is free to include
superfluous actions (visible in `IntrusionDetection/pb1.answer`); only
feasibility is being solved.

## Recognition instances: disjunctive goal + costs + evidence

The `pb1` problems above pin down a *single* hypothesis and solve for
feasibility. A genuine recognition instance instead keeps *all* the
hypotheses and asks, given the observations, for the posterior over them. That
needs three changes to the raw dataset problem, all produced by
`make-recognition-instance.lisp`:

1. **Uniform action costs** (`(increase (total-cost) 1)` on every action).
   Without costs, every trajectory consistent with the evidence has equal
   weight and the posterior is a mere volume count; with a uniform cost the
   distribution over plans becomes the Boltzmann model `P(plan) ∝ exp(−β·length)`
   that Ramírez & Geffner assume — the recognizer then favors goals for which
   the observed behavior is *efficient*, not merely *possible*. The temperature
   is `β = cost / scale` (the scnf weight scale, default 1). See FAQ.md
   ("Mixing Probabilities and Utilities").
2. **A disjunctive goal** — the `or` of all the `hyps.dat` candidates — so a
   single theory ranges over every hypothesis at once.
3. **Incremental evidence files** `evidence-1.txt … evidence-k.txt`, the first
   *i* observations of `evidence-partial.txt` as an `occur-in-order` form, for
   watching the posterior sharpen as observations accrue.

### Generating an instance

```sh
cd SatPlan/Examples/Plan_Recognition
sbcl --script make-recognition-instance.lisp \
     BlockWords/block-words.pddl BlockWords/template.pddl \
     BlockWords/hyps.dat BlockWords/evidence-partial.txt \
     BlocksWorldCosts            # optional 6th arg: the uniform cost (default 1)
```

The checked-in `BlocksWorldCosts/` and `IntrusionDetectionCosts/` were produced
exactly this way. Each holds `<domain>-costs.pddl`, `problem.pddl` (the
disjunctive goal), and `evidence-1.txt … evidence-5.txt`.

### Running the pipeline

**Most likely explanation** (MAP) — weighted MaxSAT picks the cheapest plan,
over all hypotheses, that embeds the observed subsequence in order:

```sh
bin/planner.sh SatPlan/Examples/Plan_Recognition/BlocksWorldCosts/problem.pddl \
    --domain SatPlan/Examples/Plan_Recognition/BlocksWorldCosts/block-words-costs.pddl \
    --minslices 9 --maxslices 12 \
    --pddl-evidence-file SatPlan/Examples/Plan_Recognition/BlocksWorldCosts/evidence-5.txt
```

**Posterior over the goals** (marginal inference) — `--marginals` reports
`P(atom | evidence)`; the goal atoms' marginals are the posterior over the
hypotheses. Exact enumeration (`--counter maxent`, the default) is only
tractable on tiny instances, so use an ADDMC binary here:

```sh
bin/planner.sh SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts/problem.pddl \
    --domain SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts/intrusion-detection-costs.pddl \
    --numslices 4 --marginals --counter ../ADDMC/addmc \
    --pddl-evidence-file SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts/evidence-3.txt
```

At horizon 4 after three observed recons, the `(information-gathered …)` atoms
carry the posterior mass (the recons are efficient only under the
espionage hypothesis) while `(data-stolen-from …)` and `(vandalized …)` are 0 —
no break-in was observed and four slices are too few to recon, break in, and
steal. Feeding `evidence-1.txt` through `evidence-5.txt` in turn shows the
distribution concentrate as observations accumulate.

Note the horizon caveat: a k-observation sequence needs at least k+1 slices, and
a disjunctive goal does not raise the reachability lower bound, so set
`--numslices`/`--minslices` high enough to fit the observations.

**Calibrated posterior via Ramírez & Geffner** (`bin/recognize.sh`) — when exact
marginals are intractable (they time out at these horizons), the R&G
`c(G,O) − c(G,¬O)` method gives the calibrated posterior using only MaxSAT.
For each hypothesis it runs the planner twice — cheapest plan that complies with
the observations vs. cheapest that does not — and forms
`P(hypI | O) = σ(β·Δ_I)·π_I / Σ …`:

```sh
bin/recognize.sh \
    SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts/intrusion-detection-costs.pddl \
    SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts/problem.pddl \
    SatPlan/Examples/Plan_Recognition/IntrusionDetectionCosts/evidence-3.txt --horizon 6
```

Unlike the MAP plan (which recognizes the *cheapest* hypothesis), this recovers
the true broad-espionage `hyp0` and sharpens it as observations accrue. Omit
`--horizon` to have it compute the max per-hypothesis feasible horizon; `--beta`
sets the temperature (default 1), `--priors FILE` the priors (default uniform).
Results and the comparison to MAP are tabulated in
[benchmarks.md](../../../benchmarks.md#ramírez-and-geffner-recognition-on-the-plan-recognition-benchmarks).

## References

- M. Ramírez & H. Geffner (2010). Probabilistic plan recognition using
  off-the-shelf classical planners. *AAAI-10*. (The `*-aaai` problems.)
- R. F. Pereira, N. Oren & F. Meneguzzi (2017). Landmark-based heuristics for
  goal recognition. *AAAI-17*. (The curated dataset.)
