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
