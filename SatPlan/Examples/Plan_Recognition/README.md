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

Each directory carries the recognition instance in the dataset's own format
plus a concrete planning problem derived from it:

| File | Contents |
|---|---|
| `template.pddl` | initial state, with the goal left as a `<HYPOTHESIS>` placeholder |
| `hyps.dat` | the candidate goals, one comma-separated conjunction per line |
| `real_hyp.dat` | the hidden true goal (one line of `hyps.dat`) |
| `obs.dat` | the observed action sequence, in order (here 100% observability) |
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

## Toward recognition instances

These directories carry everything a FiFO plan-recognition instance needs:
the lines of `hyps.dat` become a disjunctive goal whose disjuncts carry prior
probabilities, `obs.dat` becomes evidence (`--pddl-evidence` `at` forms pin
each observation to its slice under full observability), and the posterior
over the candidate goals is read off with `--marginals`. See FAQ.md
("Mixing Probabilities and Utilities") for how to keep goal priors and action
weights in one coherent probability model.

## References

- M. Ramírez & H. Geffner (2010). Probabilistic plan recognition using
  off-the-shelf classical planners. *AAAI-10*. (The `*-aaai` problems.)
- R. F. Pereira, N. Oren & F. Meneguzzi (2017). Landmark-based heuristics for
  goal recognition. *AAAI-17*. (The curated dataset.)
