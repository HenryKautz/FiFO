# Notes from a Claude Code session

A record of the working session that added MAP-inference documentation, the
solver installer, NuWLS-c, MaxPre 2 preprocessing, the solver time limit, and
the `solve.sh` / `map.sh` drivers — followed by a discussion of whether any of
the CDCL-based sampling work could serve FiFO.

Companion to [notes-from-claude-cloud.md](notes-from-claude-cloud.md), which
records the earlier conversation about MaxSAT solvers that prompted much of this.

Commits, in order:

```
23cb1b3  Document MAP inference, add a component guide and a solver installer
2523ee8  Add NuWLS-c, MaxPre 2 preprocessing, and a solver time limit
1ae1b47  Add solve.sh and map.sh: one driver per question, with solver checking
d49543c  solve.sh/map.sh: print the whole answer, and fix the verdict scan
2e5836f  gitignore: stop SatPlan/**/.DS_Store from showing up
ec687b2  probability-background: cite ApproxMC, Barbarik, and CMSGen
cd878c7  probability-background: cite CMSGen in section 12, not only the references
97c26fe  probability-background: why the hashing sampler family does not fit FiFO
```

------

## 1. What does `solve` use for MaxSAT, and how does it decide?

The starting question. The answer turned out to be worth writing down because
it is *not* what one might assume.

**`solve` decides nothing.** There is no SAT-vs-MaxSAT detection. Two
independent settings, with nothing cross-checking them:

- the **solver** is whatever `*solver*` names — no inspection of the problem;
- the **format** depends on `*cnf-format*` **and** whether the theory has
  weights. In `propositionalize`:

  ```lisp
  (cond ((or (null weightdata) (eql wformat 'CNF))
          ;; plain "p cnf", weights appended as `cw` comment lines
        ...)
  ```

| weights? | `*cnf-format*` | file written |
|---|---|---|
| no | anything | `p cnf` — the format setting is ignored entirely |
| yes | `CNF` (default) | `p cnf` + `cw` comment lines |
| yes | `WCNF` / `WCNF-OLD` | weighted CNF |

The first row matters: with no weights, `*cnf-format*` has no effect at all.

**The default is a trap.** A theory full of `(weight …)` forms, left at the
default `CNF`, writes its weights as `cw` lines. Those start with `c`, so a SAT
solver treats them as comments and returns a valid, arbitrary, **non-optimal**
model with no complaint and no `o` line.

The planner is the exception — it *does* switch, by grepping the generated scnf
(`planner.lisp`): `(setq has-costs (file-contains-string-p "(WEIGHT" scnf))`,
then flipping `*cnf-format*` and `*solver*` together.

This is what motivated `solve.sh` / `map.sh`: put the policy in the drivers, one
per question, each fixing the format that defines it.

------

## 2. Things that were built

Covered properly in [software-components.md](software-components.md); only the
non-obvious decisions are recorded here.

### The solver time limit is enforced by FiFO, with SIGTERM

Neither anytime MaxSAT solver takes a time limit on the command line. They are
meant to be *stopped*, and they print their best solution so far when they are.
NuWLS-c's own MaxSAT Evaluation wrapper is literally:

```bash
timeout -s 15 $wl ./nuwls-c_static $1
```

So FiFO does the same thing — but in process, via `sb-ext:run-program :wait nil`
plus `process-kill`, because **macOS ships neither `timeout` nor `gtimeout`**.
SIGKILL follows only if the solver ignores SIGTERM.

Measured on pb5 (109 887 lines), confirming the limit governs the budget rather
than merely capping the clock:

| `--timeout` | wall | best objective |
|---|---|---|
| 2 s | 2.74 s | `o 198` |
| 10 s | 5.18 s | `o 122` — solver finished on its own |

The same check on tt-open-wbo-inc (`Main.cc:450` installs the SIGTERM handler):
3 s → `o 147`, 15 s → `o 122`.

A timed-out MAP run gives the best model *found*, not a proven optimum, so
`(*OBJECTIVE* N)` becomes an upper bound. The verdict distinguishes them:
`s OPTIMUM FOUND` is proved, `s SATISFIABLE` is best-so-far.

### MaxPre 2 reconstruction is load-bearing, and MAP-only

The pipeline is `preprocess → solve → reconstruct`. Skipping the last step does
not fail — it produces a **plausible wrong answer**. On the small grocery
example MaxPre collapses three variables to one; the solver returns `v 1`, and
interpreting that single bit against the three-variable `.map` reports
`BUY STEAK`, cost 310, instead of `BUY MILK`, cost 3.10.

Two MaxPre quirks had to be papered over, both found by experiment:

- `reconstruct` parses **only** `s OPTIMUM FOUND`. Given the `s SATISFIABLE`
  that an anytime solver prints when it has not proved optimality, it answers
  `Failed to parse solution`.
- Without an `o` line it emits an uninitialised objective
  (`o 8458720177635290220`).

So FiFO normalises the solver's output to `o`/`s`/`v` before the call and
restores the real status afterwards.

**MaxPre must never touch the marginal pipeline.** It preserves the optimum cost
and an optimal model; it does *not* preserve the model count, so it would
silently corrupt `Z` and every marginal. Structurally it cannot: no marginal
back end calls `satisfy`. Requesting a preprocessor with `*cnf-format*` `CNF` is
now an explicit error.

### SPB-MaxSAT was investigated and dropped

The public [JHL-HUST/SPB-MaxSAT](https://github.com/JHL-HUST/SPB-MaxSAT) is the
bare SLS algorithm from the IJCAI-24 paper, **not** the `SPB-MaxSAT-c` hybrid
that won MSE 2024 — which is not on GitHub at all. Reading the source:

1. **No tt-open-wbo-inc inside it**, so the "falls back on tt-open-wbo-inc"
   premise does not hold. Seven source files, pure local search.
2. **Pre-2022 format only.** `build_instance` needs `p wcnf <v> <c> <top>` and
   calls `exit(-1)` if `sscanf` reads fewer than 5 fields.
3. **Prints a model only on SIGTERM.** Normal termination runs `simple_print`,
   which emits `<cost>\t<time>` and nothing else; the `v` bit-string comes from
   `print_best_solution`, called only from the `interrupt` handler.
4. **Never emits an `s` or `o` line.**
5. **Cutoff hardcoded** — `cutoff_time = 300` in `build.h:102`, no CLI flag.

Points 3 and 5 interact badly: at a 300 s timeout its internal cutoff races our
SIGTERM, and if its own cutoff wins you get a cost with no assignment.

------

## 3. Bugs found while testing

Recorded because several were silent rather than loud.

### `satisfy` read solver banners as verdicts

The worst one. `satisfy` decided SAT vs UNSAT by scanning the whole output file
for the substring `"SAT"`. **Every MaxSAT solver's banner contains it** —
tt-open-wbo-inc prints `MaxSAT Evaluation 2024` and `SAT-based solver` before
doing any work. So a run that printed a banner and *no verdict* was read as SAT.

That is exactly what happens when a MaxSAT solver is handed a plain `p cnf`
file, which is what FiFO writes for an unweighted theory whatever format is
requested. On a `prove` form the result was a **wrong logical answer**: an
entailment reported as `COUNTEREXAMPLE`.

Now `solver-verdict` reads the DIMACS `s` line first and falls back to
`verdict-by-scan` — whole words `SATISFIABLE` / `UNSATISFIABLE`, or a line that
is exactly `SAT` / `UNSAT`.

*The first fix was insufficient:* adding the `s`-line check while leaving the
substring fallback in place left the bug fully intact.

### `set -o pipefail` + `grep -q` reports success as failure

Hit **three times** in this session, in three different files. `grep -q` exits on
its first match, closing the pipe; the writer gets SIGPIPE; `pipefail` turns the
whole pipeline non-zero. So

```bash
if "$bin" -help 2>&1 | grep -q -- "-mcsat"; then     # WRONG under pipefail
```

reports "no `-mcsat`" for a binary that has it. It only *looked* correct while
the installed walksat was v57 and genuinely lacked the flag — the wrong
mechanism giving the right answer. Capture first:

```bash
help="$("$bin" -help </dev/null 2>&1 || true)"
case "$help" in *-mcsat*) return 0 ;; esac
```

### Other

- **ADDMC will not configure under CMake 4** — it asks for
  `cmake_minimum_required(VERSION 2.8.9)`, and CMake 4 dropped compatibility
  below 3.5. Fixed with `CMAKE_POLICY_VERSION_MINIMUM=3.5`.
- **A leading dot in a scratch root breaks FiFO.** `satisfy` derives the
  `.satout` name by replacing from the **first** dot in the path, so a root of
  `.map-123` sends the solver's output where the reader does not look. (The same
  fragility applies to any directory with a dot in its name.)
- **`merge-pathnames` inherits `:type`** — `*d4*` had been resolving to
  `compiler.lisp`, meaning `--solver d4` had only ever worked with `D4` set.
- **NuWLS-c and MaxPre need Homebrew's include/lib paths**, which Apple clang
  does not search. `CPATH` / `LIBRARY_PATH` add them without clobbering the
  Makefiles' own flags, which a command-line `CFLAGS=` would.

------

## 4. Could a CDCL solver do the sampling?

The most interesting thread, and the one with no code attached.

### The literature: none of it takes weighted clauses

Weighted model counting and weighted sampling use **literal weights** — a
model's weight is the product over its literals. Weighted *clauses* are the
MaxSAT convention. FiFO straddles both: a cost `θ` on `L` is a soft unit clause
for MaxSAT and `W(L true) = exp(−θ)`, `W(L false) = 1` for counting, which is
what `wmc.lisp` already emits for ADDMC. **The encoding is never the obstacle.**

|  | unweighted | literal-weighted |
|---|---|---|
| counting | ApproxMC | WeightMC / ApproxWeightMC |
| sampling | UniGen, CMSGen | WeightGen, then WAPS |

FiFO supports **none** of these. Its back ends are `maxent`, `ddnnf` (both
built-in), `addmc`, `d4`, and `mc-sat`.

### Tilt is what rules the hashing family out

WeightGen's own definition: `wmax = max w(σ)`, `wmin = min w(σ)`, and
"the tilt ρ = wmax/wmin. Our algorithms require an upper bound on the tilt,
denoted r, which is provided by the user."

Theorem 4: WeightGen "runs in time polynomial in `r`, `|F|` and `1/ε`", and §4.3
observes "The theoretical **linear** dependence on the tilt … can be seen to
roughly occur in practice." Its guarantee (Theorem 3) needs `ε > 6.84` — within
roughly a factor of 8 — succeeding with probability ≥ 0.52.

For a Boltzmann distribution, **tilt is `e^(cost range)`**. At FiFO's default
scale of 100, a real cost of 0.69 is stored as 69, so `ρ ≈ e^69`. `--scale 1`
does not save it: a plan cost spread of 100 still gives `e^100`.

The same quantity wrecks importance-reweighting on top of CMSGen. Both routes
fail for one reason.

**The deeper mismatch.** WeightGen's justification for assuming small tilt is
that, for PGM inference, large tilt "would … mean existence of two assignments
that are consistent with the evidence, but one of which is overwhelmingly more
likely than the other" — which they call unlikely for human-elicited
probabilities. But in a cost-based planning model that dominance *is the model*.
FiFO's semantics is the thing their assumption excludes.

Their large-tilt variant needs a pseudo-Boolean solver rather than a SAT solver,
giving back what made the approach attractive. WAPS, the modern replacement,
compiles to d-DNNF — which is exactly what fails on the big instances.

The one transferable idea: WeightGen takes an **independent support** `S`,
because it "significantly reduce[s] the size of XOR constraints". That is §13 of
`probability-background.md` — in a SatPlan encoding the `Occurs` atoms determine
the `Holds` atoms by unit propagation, so the action variables are a natural,
much smaller support. Orthogonal to the tilt problem, and still unexploited.

### Why not just use kissat as MC-SAT's inner sampler?

Because the inner step is not "find a model of M" — it is "**sample
near-uniformly** from the models of M". MC-SAT is a slice sampler, and its
stationary distribution equals the target *only if* that step is uniform. A
biased sampler breaks detailed balance and leaves the chain converging to
something unknown.

Kissat is superb at the first job and offers no guarantee on the second.
Demonstrated on a CNF with **2²⁰ − 1 solutions**, where a uniform sampler gives
~10 of 20 variables true:

| kissat invocation | true vars |
|---|---|
| any `--seed`, default phase | 20/20 |
| `--phase=false` | 1/20 |
| `--randec` cranked up, `--seed=7` | 20/20 |

It lands on a **corner** and stays there. The seed changes nothing — with no
conflicts there are no random decisions to make. For a SatPlan encoding "all
false" means minimal-action plans, so the marginals would be pulled to a corner,
confidently and wrongly.

There is direct evidence in this codebase already: the CDCL seed *is* a kissat
model, and on pb1 the chain froze exactly there — `mixing: mean Hamming distance
= 0.00` while `-unitprop` reported **211.7 variables free to move** each step.

**But the instinct is right.** Free variables > 0 with Hamming distance 0 means
the chain *could* have moved and did not: on pb1 the inner sampler is the
bottleneck, not a genuinely determined distribution. Improving it is the correct
lever.

And the developed form of the idea exists. **CMSGen is a CDCL solver used as a
sampler** — CryptoMiniSat with randomised polarity — and its paper exists
precisely because naive randomisation does *not* give near-uniformity; they
tuned it against the Barbarik tester until it passed.

The key realisation: **the objection to CMSGen does not apply inside MC-SAT.**
CMSGen is unsuitable as a standalone marginal sampler because it ignores
weights — but MC-SAT's inner problem is *unweighted by construction*. The slice
step consumes the weights first, leaving hard clauses plus "stay satisfied" unit
constraints. Uniform sampling of exactly that is what CMSGen does.

So CMSGen is a poor *replacement* for MC-SAT and a natural *component* of it.

The cost is engineering: a per-sample process spawn is what drove the whole loop
into C, so this means linking CryptoMiniSat as a library inside the WalkSAT v58
binary. Worth measuring against simply raising `--samplesat-cutoff` before
building anything.

------

## 5. Max-term marginals: generalising `recognize.sh` beyond planning

`recognize.sh` computes a posterior using cheapest-plan (MaxSAT) calls only —
the maximum-term approximation of §14, applied to a restricted set. The question
was whether the same move gives **marginals for FiFO generally**, not just goal
posteriors for planning.

It does, with a clean derivation and two sharp limits.

### The formula

A marginal is a ratio of partition functions over the two polarities of an atom,
so substituting the §14 decomposition `log Z_S = −β·c_min(S) + log Ω_S`:

```
P(a) = σ( β·(c_min(¬a) − c_min(a))  +  log(Ω_a / Ω_¬a) )
```

Dropping the degeneracy ratio leaves the max-term marginal

```
P(a) ≈ σ( β · (c_min(¬a) − c_min(a)) )
```

which is literally the Ramírez–Geffner formula with the hypothesis replaced by an
atom, `c_min(a)` and `c_min(¬a)` being MaxSAT solves with a unit clause clamping
the atom true or false. In graphical-model terms these are **max-marginals**,
with MaxSAT playing the role max-product belief propagation plays there.

### Cost: `1 + n` solves

Not `2n`. Solve the unconstrained MaxSAT once for `x*` and `c_min`; for each atom
whichever polarity `x*` already has *is* `c_min`, so only the opposite clamp needs
a solve. That is exactly the shape of `marginals-addmc` (one run for `Z`, one per
clamped atom).

The scaling caveat is real: `recognize.sh` does `2n` calls for `n` = 10–21
hypotheses, whereas marginals over all atoms means `n` in the thousands. Two
mitigations already exist — `--weighted-only`, and **IPAMIR**, the incremental
MaxSAT interface flagged in `notes-from-claude-cloud.md` for exactly this shape of
problem (many instances differing by one unit clause).

### No hypothesis set, and no disjointness

Unlike `recognize.sh`, nothing needs declaring. `{a, ¬a}` is automatically an
exhaustive, mutually exclusive partition, so `Z = Z_a + Z_¬a` holds for every atom
and each marginal **self-normalises**. `recognize.sh` needs disjointness only
because it builds one *categorical* distribution with a shared denominator — and
even there disjointness is an assumption about the domain ("exactly one goal is
the agent's"), not something the encoding enforces.

Consequence: which atoms you query is a reporting choice, not a modelling one.
Max-term marginals are local; R&G posteriors are global, since dropping a
hypothesis changes every other one.

**What is lost** is coherence. The estimates are pseudo-marginals, not guaranteed
consistent with any joint. Measured on an unweighted exactly-one-of-three theory:

| | A | B | C | sum |
|---|---|---|---|---|
| exact (enumeration) | 0.333 | 0.333 | 0.333 | **1.0** |
| max-term | 0.5 | 0.5 | 0.5 | **1.5** |

Both clamps of every atom are satisfiable at cost 0, so `Δ = 0` and `σ(0) = 0.5`
three times over. So disjointness is not a *requirement* inherited from
`recognize.sh` — it is **information that would otherwise be discarded**.
Renormalising a known-exclusive group recovers `1/3` each, exactly. That argues
for optional exclusive groups rather than a required hypothesis set; FiFO's
existing `gid` tie-group field on `(PROBABILITY …)` lines is a natural hook,
though it currently means shared *weight* rather than mutual exclusion.

### The degeneracy blindness, stated sharply

The dropped `log(Ω_a/Ω_¬a)` is the *asymmetry* in near-optimal multiplicity
between the polarities, so symmetric atoms come out well — that is why the
differencing in R&G works. But on an **unweighted** theory every `Δ_a` is 0 and
the method returns 0.5 for everything, carrying literally no information.

It approximates the part of the distribution coming from **weights** and discards
the part coming from **counting**. Worth contrasting with MC-SAT, which degrades
when weights are *large* (the chain freezes); this degrades when weights are
*small* relative to the entropy. They fail in opposite regimes.

Backbone atoms are the compensating strength: if clamping `a` false is UNSAT then
`P(a) = 1` **exactly, with a proof** — unlike MC-SAT's frozen chain, which reports
0/1 wrongly.

### Priors are already weights — and post-hoc priors are exact

A unit cost `θ` on `a` is constant across `{a true}`, so it factors out of the
minimisation: `c_min(a) = θ + c⁰_min(a)`. Hence

```
logit P(a) ≈ β·(c⁰_min(¬a) − c⁰_min(a))  −  βθ
              ╰──────── evidence ────────╯   ╰prior╯
```

a log-odds sum of prior and evidence. So the `1 + n` MaxSAT calls can be run once
with priors zeroed and **any** prior applied afterwards as a log-odds shift,
exactly, with no re-solving. Prior sweeps are free.

The limit, measured on `(or a b)` with a cost of `log 3` on `A`:

| | P(A) | P(B) |
|---|---|---|
| prior **in the theory** | 0.2500 | **0.7500** |
| prior applied **post-hoc** | 0.2500 | **0.5000** |
| exact | 0.4000 | 0.8000 |

A prior on `A` shifts `P(A)` separably but its effect on *other* atoms is not
recoverable post-hoc, because `θ` is constant across `{A true}` and not across
`{B true}`. So: exact for the atom it is on, wrong for everything else.

### The circularity, which max-term does not fix

FiFO's `(probability a p)` is a target marginal **with respect to the whole
theory**, so converting it to a weight is itself the inverse problem — and needs
marginals. On `(or a b)` with a target `P(A) = 0.4`:

| estimator | learned weight | |
|---|---|---|
| log-odds (closed form) | 0.4055 | `log(1.5)` — the isolated-atom / empty-theory answer |
| maxent (enumerates) | 1.0986 | `log(3)` — the value that actually yields 0.4 |

A factor of 2.7 apart on a two-atom theory. This is pre-existing rather than
something the max-term idea introduces: it is exactly why FiFO ships two
estimators, and `propositionalize` already refuses a `.scnf` containing
`(PROBABILITY …)` forms, so the choice must be made upstream.

Inverting the log-odds identity, `θ_a = Δ⁰_a − logit(p)/β`, looks like a way out
— but here `Δ⁰ = 0`, so it returns `log(1.5)`, **identical to log-odds and wrong
in the same way**. The counting content that makes the true answer `log 3` is
invisible to it. Max-term would beat log-odds only where the theory already
carries weights enough that `Δ⁰ ≠ 0` says something.

What it does buy is **self-consistency**: learn with the max-term oracle, query
with max-term, and the round trip is exact by construction, because the biases are
the same bias. That is defensible provided "P" is understood to denote the
max-term pseudo-marginal rather than the Gibbs marginal. Three coherent stacks,
and the middle one does not exist yet:

- **exact everywhere** — maxent learning + addmc/d4/ddnnf querying;
- **cheap everywhere** — log-odds learning + max-term querying, self-consistent
  only if the inversion also uses max-term;
- **mixed** — what one would do by accident, with no guarantee at all.

### If it gets built

`marginals.sh --solver max-term`, reusing `rw--read-scnf`, the wcnf writer, the
scale/offset correction (`wcnf-scale-offset`), `*solver-timeout*`, and
`marginals-addmc`'s clamp-and-resolve loop; `β = 1/scale` with a `--beta`
override as `recognize.sh` has. A `K`-best refinement is the natural tunable
version — enumerate the top `K` models per side with blocking clauses and use
`Z_S ≈ Σ_{i≤K} e^{−β c_i}`. `K = 1` is max-term, `K → ∞` is exact, and since
`Ω_S ≥ 1` every `K` gives a **lower bound** on `Z_S`, turning a biased point
estimate into anytime bracketing.

It should be documented as answering a *different question* rather than as
approximating the same one — much as `recognize.sh` is presented as R&G's
recognizer rather than as approximate WMC.
