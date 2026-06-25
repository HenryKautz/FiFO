# FiFO Weight Learning — Pipeline Guide

This directory implements weight learning for FiFO weighted-MaxSAT theories: given
**target marginal probabilities** for the weighted atoms, recover the integer
literal weights that realize them.

For the theory — the full range of data regimes, the regret / moment-matching
views, and the provenance — see [fifo-weight-learning.md](fifo-weight-learning.md).
This file covers only **how to run** the pipeline that is implemented so far,
which is Case 4 of that document (*beliefs about marginals*).

## What the pipeline does

**Input:** an instantiated `.scnf` file (the output of FiFO's `instantiate`) whose
`(PROBABILITY <literal> p [gid])` lines carry a **target marginal probability**
`p ∈ [0.0, 1.0]` — the probability that `<literal>` should be true. The optional
`gid` is a **tie-group id**: every ground instance of one source-`.wff`
`(probability ...)` form shares a `gid`, and the pipeline fits **one** weight per
group (parameter tying — see [fifo-weight-learning.md](fifo-weight-learning.md)
§1–2). `instantiate` writes these forms automatically from a `.wff`; a hand-written
`.scnf` may omit `gid`, in which case each line is its own untied group.

`PROBABILITY` is a distinct keyword from FiFO's `(WEIGHT <literal> c)` cost form
on purpose: the pipeline's **input** speaks probabilities (`PROBABILITY`) and its
**output** speaks integer costs (`WEIGHT`). They never share syntax, so an output
file is not a valid input — re-running the pipeline on its own output is rejected
rather than silently misread.

**Output:** `<root>_reweighted.scnf`, identical to the input except that every
`PROBABILITY` line is replaced by a **positive-integer** `WEIGHT` on a single
polarity (the other polarity is implicitly zero), per the README shift+scale
convention. Degenerate certainties (`p = 0` / `p = 1`) become hard unit clauses
rather than infinite weights. The original `PROBABILITY` assertions are echoed
into the output as `;;` comment lines, recording the provenance of the weights.
The result feeds straight into FiFO's `propositionalize` → MaxSAT (the `;`/`;;`
comment lines are skipped by the reader).

The model is the Gibbs distribution `P(x) ∝ exp(-Σ θ·Φ(x))` over the feasible set,
where a `WEIGHT w L` is the cost paid when literal `L` is true. A target marginal
`p` maps to the cost-when-true `θ = log((1-p)/p)`; the sign of `θ` decides which
polarity carries the (positive) weight.

## Two estimators

| File | Function | Method | Use when |
|---|---|---|---|
| `reweight.lisp` | `reweight` | Independent log-odds (closed form) | Atoms are (near-)independent; fast, no solver |
| `maxent.lisp` | `maxent-reweight` | Exact iterative MaxEnt over the feasible set | Hard clauses couple the weighted atoms |

`reweight` ignores the clauses and sets `θ = log((1-p)/p)` per atom directly.
`maxent-reweight` corrects for clause coupling: it enumerates the feasible set
once and iterates `θ` until the model's marginals match the targets. When the
atoms happen to be independent, the two agree exactly.

## Running it

Requires SBCL (the same toolchain as FiFO). Run from inside `Learning/`.

### Independent log-odds

```sh
sbcl --non-interactive \
     --eval '(load "reweight.lisp")' \
     --eval '(reweight "myfile.scnf")'
```

Writes `myfile_reweighted.scnf`. Options:

- `:out-file "path.scnf"` — override the output path.
- `:scale N` — integer resolution (default `100`); real weight of any emitted
  line is `integer / N`. Larger `N` = finer resolution (and a sharper / lower-
  temperature distribution).
- `:wff "source.wff"` — also write the learned weights **back into a copy of the
  source `.wff`** (see "Tie groups and `.wff` write-back" below).
- `:wff-out "path.wff"` — override the write-back path (default
  `<wff-root>_weighted.wff`).

### Exact iterative MaxEnt

```sh
sbcl --non-interactive \
     --eval '(load "maxent.lisp")' \
     --eval '(maxent-reweight "myfile.scnf")'
```

(`maxent.lisp` loads `reweight.lisp` for the shared helpers.) It prints a
target-vs-achieved marginal report and writes the same report as comment lines in
the output. Options:

- `:out-file`, `:scale`, `:wff`, `:wff-out` — as above. With tie groups the fit
  uses one shared `θ` per group (sufficient statistic = the group's true-count),
  matching each group's **mean** marginal to its target; the report is per group.
- `:consider-weights` — whether explicit `(WEIGHT ...)` lines take part in the
  fit (default `t`); see "Mixing explicit weights and probabilities" below.
- `:eta` — step size for the damped diagonal-Newton update (default `1.0`).
- `:tol` — convergence tolerance on `max |achieved − target|` (default `1e-5`).
- `:max-iters` — iteration cap (default `5000`).
- `:verbose` — print the report to stdout (default `t`).

### Mixing explicit weights and probabilities

A file may carry both explicit `(WEIGHT literal w)` costs and `(PROBABILITY ...)`
targets. **Only the probability-derived weights are adjusted** — the explicit
weights are always copied to the output unchanged (and left untouched in the
`.wff` write-back). An atom may not have both a weight and a probability target
(that is a contradictory double specification, and is an error).

For `maxent-reweight`, `:consider-weights` controls whether the explicit weights
take part in the fit:

- `t` (default): they are held **fixed** in the model energy, so the probability
  weights are learned *in their presence* — the realized marginals account for
  them. (Example: with a hard `(or A B)`, a large fixed cost on `A`, and a target
  `P(B)=0.6`, `B`'s learned cost comes out much higher than it would in
  isolation, because the model rarely picks `A`.)
- `nil`: the fit ignores them (faster), so the probability weights are fit as if
  the explicit weights were absent; they are still passed through to the output.

The independent log-odds estimator (`reweight`) ignores all coupling, so it has
no `:consider-weights` knob — it always passes explicit weights through without
letting them influence the conversion.

### Tie groups and `.wff` write-back

The intended end-to-end flow starts and ends at the **`.wff`** level:

1. Write a `.wff` with `(probability <literal> <p> [<tie-label>])` forms and
   `instantiate` it on a **small** domain → a `.scnf` whose `PROBABILITY` lines
   carry tie-group ids.
2. Run `reweight` / `maxent-reweight` with `:wff "source.wff"`. Besides the
   reweighted `.scnf`, this writes `source_weighted.wff`: a copy of the source in
   which each `(probability ...)` form is replaced by **one** tied `(weight ...)`
   cost (or a hard clause for `p = 0`/`1`). Because the weight sits on the schema,
   re-instantiating gives every grounding the same (tied) cost.
3. Edit `source_weighted.wff` to enlarge the domains and re-instantiate at full
   size — schema tying carries the small-domain weights over (cf.
   [fifo-weight-learning.md](fifo-weight-learning.md) §2, §10).

Two well-formedness checks are enforced when grouping: a literal targeted by two
different tie groups (**overlapping** forms) is an error, and the target `p` must
be **constant** within a group.

### Downstream

Either output is an ordinary `.scnf`. To compile and solve:

```sh
# from the FiFO project root, with FiFO.lisp loaded
(propositionalize "Learning/myfile_reweighted.scnf")   ; -> .cnf/.wcnf + .map
(satisfy ...)                                           ; or run a MaxSAT solver
```

Add `(OPTION WEIGHTS WCNF)` to the input (it is passed through) to get a `.wcnf`
for a MaxSAT solver; otherwise `propositionalize` emits plain `.cnf` with
`cw` comment lines.

## Input format example

```lisp
(OR (BUY BANANA) (BUY STEAK) (BUY MILK))   ; a hard clause
(PROBABILITY (BUY BANANA) 0.5)             ; target marginal probabilities
(PROBABILITY (BUY STEAK) 0.25)
(PROBABILITY (BUY MILK) 0.9)
(PROBABILITY (NOT (BUY EGGS)) 0.2)         ; target on a negated literal: P(EGGS)=0.8
(PROBABILITY (BUY SPAM) 0.0)               ; certainty -> hard clause
(PROBABILITY (BUY BREAD) 1.0)              ; certainty -> hard clause
(OPTION WEIGHTS WCNF)                      ; passed through
```

A target on `(NOT L)` is normalized to the positive atom (`p` on `(NOT L)` means
`P(L)=1-p`). Specifying the same atom twice is an error.

The corresponding `<root>_reweighted.scnf` echoes each of these as a `;;` comment
and emits the learned `(WEIGHT ... <integer>)` lines below them.

## Worked examples in this directory

- `test_marginals.scnf` → `test_marginals_reweighted.scnf` — the example above;
  the `OR` couples BANANA/STEAK/MILK, so the MaxEnt weights differ from the
  independent ones, while the uncoupled EGGS is identical under both.
- `test_coupled.scnf` → `test_coupled_reweighted.scnf` — `(OR A B)` with both
  targets `0.6`; MaxEnt converges to the analytic `θ = ln 2` (integer weight 69),
  achieving exactly 0.6, where the independent estimator would get it wrong.

## Limitations (current)

- **Exact MaxEnt is small-instance only.** `maxent-reweight` enumerates the
  feasible set (node cap ~5M, then it errors). This is the "do the counting on
  small instances" regime; a sampler / weighted model counter would replace the
  enumeration for scale.
- **Inconsistent targets.** If the hard clauses are themselves unsatisfiable,
  `maxent-reweight` errors (no feasible set). If they are satisfiable but the
  targets are jointly unachievable over the feasible set (e.g. a unit clause
  forces an atom against its target, or two targets exceed what a mutex allows),
  the fit cannot converge: it runs to `:max-iters`, the affected `θ`s clamp, and
  it prints a prominent **"did NOT converge — targets may be inconsistent with the
  hard clauses"** warning plus the per-group target-vs-achieved gap, rather than
  silently misreporting. (The independent `reweight` never inspects the clauses,
  so it cannot detect inconsistency at all.)

## See also

- [fifo-weight-learning.md](fifo-weight-learning.md) — the theory: all data
  regimes (complete/optimal, merely-good, partial, beliefs, beliefs+data),
  convexity, the oracle's role, domain-size dependence, and related work.
- `../README.md` — FiFO language reference, the `WEIGHT` form, and the weighted
  CNF output formats (`cnf` / `wcnf-old` / `wcnf`).
