# FiFO: Future Directions

*A speculative, expansive discussion of where FiFO could go next.*

## The through-line: FiFO has been walking up the inference hierarchy

Look at the arc of what has been built. It started as finite-domain FOL → CNF →
**SAT** (does a model exist?). Then SatPlan added a *purpose* for the models.
Then MaxSAT added **optimization** (best model). Then maxent/reweight added
**weights**. Then ADDMC, the home-grown d-DNNF, and d4 added **weighted model
counting and marginals** (the whole distribution, not one model).

That's not a random walk. It's the exact path the field itself took:
**SAT → #SAT → WMC → probabilistic logic**. FiFO has, somewhat organically,
become a *knowledge-compilation-based probabilistic logic language* that happens
to also do planning. The finite-domain FOL front-end plus WMC back-end plus
maxent weight-learning is, computationally, almost precisely the **Markov Logic
Network** recipe — while the "compile once, query many" d-DNNF machinery is the
**probabilistic-circuits** recipe. FiFO is sitting on the seam between those two
worlds, and most systems live on only one side of it.

So the big speculative question isn't "what feature next" — it's **which of
these identities does FiFO lean into, and is there a synthesis nobody else has
cleanly done?** The bets below are ordered roughly by excitement.

## Bet 1 (favorite): lift the counting to first order — WFOMC

Right now FiFO *grounds* everything to propositional CNF and then compiles.
That's the treewidth wall we kept hitting (pb3@12 timing out). But FiFO is a
**finite-domain first-order** language — it knows the quantifier structure
*before* it grounds. The frontier of the field is exactly this: **Weighted
First-Order Model Counting** — count models at the lifted level, exploiting
exchangeability so you never pay for grounding symmetric structure.

The beautiful results here (Van den Broeck, Kuželka, Kazemi): the two-variable
fragment **FO²**, and even **C²** (with counting quantifiers "exactly k", "at
least k"), are *domain-liftable* — polynomial in the domain size instead of
exponential. For a language whose whole substrate is finite-domain FOL, this is
the most natural possible leap, and almost no practical system exposes it well.
You'd compile a *first-order* circuit once and then answer queries for *any*
domain size by plugging in n, without recompiling.

The catch, and it's real: liftability is fragile. Step outside FO²/C² (arbitrary
arity, certain transitive axioms) and you lose the polynomial guarantee. So this
becomes a language-design conversation: do you carve out a **liftable fragment**
of FiFO that gets the fast path, and fall back to ground-and-compile otherwise?
That "the compiler tells you which fragment you're in" story is genuinely
compelling and publishable.

## Bet 2: make the circuit the *product*, not a means to marginals

Today the d-DNNF is a throwaway intermediate — you compile it to get Z and
marginals, then discard it. But a smooth, deterministic, decomposable circuit is
a **tractable probabilistic model** in its own right. Once you have it, a whole
menagerie of queries becomes linear-time on the circuit:

- **MAP / most-probable explanation** (max instead of sum in the same two passes
  — it's just swapping the semiring).
- **Sampling** from the distribution (top-down weighted traversal).
- **Expectations, entropy, moments** — even KL/divergence between two circuits
  over the same vocabulary.
- **Sensitivity** (∂Z/∂weight — already the marginal, see Bet 3).

This reframes `ddnnf.lisp`'s struct from "intermediate representation" to "the
compiled artifact you *keep* and interrogate." Persisting circuits (which you
already do with `.dnnf` save/load) suddenly looks like the *main* workflow:
compile the theory once, ship the circuit, answer everything downstream. That's
the probabilistic-circuits worldview, and FiFO is two-thirds of the way there
without having named it.

## Bet 3: compiled weight learning — the gradient is already in your hands

Here's the one with the highest payoff-to-effort ratio, and it's a genuinely
elegant fact. `maxent.lisp` learns weights, currently by enumeration. For a
log-linear / maxent (= MLN) model, the gradient of the log-likelihood with
respect to a feature's weight is:

```
∂ℒ/∂wᵢ  =  (observed count of featureᵢ)  −  (expected count of featureᵢ)
```

and **the expected feature count is exactly a marginal**. Which means: the
two-pass Darwiche evaluation you already run on the circuit to get all marginals
*is simultaneously computing the entire gradient vector.* Compile the hard
theory **once**, then each gradient step is one linear pass over the fixed
circuit with the current weights at the leaves — no re-grounding, no re-solving,
no enumeration. Weight learning goes from "enumerate the world per step" to "one
circuit sweep per step."

This is the clean marriage of your two subsystems (maxent ⋈ ddnnf), it's
mathematically exact rather than approximate, and it would let weight learning
scale to instances where enumeration is hopeless. If prioritizing *one* thing,
it'd be this — it turns the compiler from an inference tool into a *learning*
tool, and it's mostly wiring you already have.

## Bet 4: generalize WMC to an algebraic semiring — one engine, many queries

Right now you have separate paths for counting, probability, and (implicitly)
optimization. But all of these are the *same computation over different
semirings*:

| Semiring | What the circuit computes |
|---|---|
| (+, ×) on ℝ⁺ | weighted model count / probability |
| (max, ×) | MAP / most-probable explanation |
| (max, +) tropical | shortest-path / min-cost plan |
| gradient / dual numbers | derivatives (→ Bet 3, for free) |
| Boolean (∨, ∧) | plain SAT |
| interval arithmetic | bounds / sensitivity |

This is the **aProbLog / algebraic model counting** insight: parameterize the
leaf semantics and the evaluator, and one compiled circuit answers *all* of
these. Your MaxSAT cost minimization and your WMC would stop being separate
machinery and become the same evaluator with a different semiring plugged in.
It's a refactor that *reduces* code while *multiplying* capability — the rare
kind. It also cleanly subsumes the "cost of slack" sensitivity analysis we did
by hand.

## Bet 5: the planning side — from SatPlan to decision-theoretic planning

You've already got cost-optimal planning (MaxSAT) and marginals. The natural
fusion is **planning under uncertainty**: **marginal-MAP** queries ("find the
plan — a MAP assignment over action variables — that's robust when you *sum out*
an uncertain world state"). That's a genuinely hard query class (NP^PP), but
knowledge compilation is one of the few practical attacks on it, and you have
the compiler. The "cost of slack" tables we built are a baby step toward
*sensitivity analysis of plans* — how does optimal cost/feasibility shift as you
perturb the horizon or the world. There's a real research story in
"probabilistic SatPlan on a compiled circuit."

## Bet 6: language expressiveness — the recursion fork in the road

Zooming out to FiFO-as-a-language, the biggest expressiveness gap is
**recursion / fixpoints / transitive closure**. Adding a least-fixpoint or
stable-model semantics takes FiFO from pure FOL into **Datalog± / Answer Set
Programming** territory — reachability, transitive closure, inductive
definitions, defaults. ASP's stable-model semantics over finite domains is
powerful and would make a lot of planning/graph domains vastly more natural to
express. This is a genuine *fork*, though: it changes the semantics of the
language, not just the back-end, so it's a "what is FiFO *for*" decision, not a
feature toggle. Lesser cousins on the same axis: sorts/types, aggregation
(count/sum over a relation), and light arithmetic (SMT-lite), each of which buys
a lot of modeling convenience for less semantic upheaval.

## The meta-question — what is FiFO's *thesis*?

Underneath all six bets is the real question: **why does FiFO exist next to
ProbLog, MLNs, ASP, and PSDDs?** Right now the honest answer is "a coherent,
personally-owned system spanning logic → planning → WMC → learning." That
breadth is unusual — most systems do *one* of those. But breadth isn't a thesis.
Two candidate theses worth considering:

1. **The unified pipeline as the point.** "One system where you write
   finite-domain FOL, plan with it, count/marginalize over it, *and* learn its
   weights from traces — all sharing one compiled circuit." Nobody has that
   end-to-end loop cleanly. Bets 2 + 3 + 4 basically *are* this thesis made real.

2. **The Lisp substrate as the secret weapon.** FiFO is homoiconic — the logic
   language and the meta-language are the same language. That means theories can
   *generate* theories, macros can synthesize axioms, and you could do
   reflective / meta-level reasoning that a standalone parser-based system
   structurally cannot. This is almost totally unexploited right now, and it's
   the one thing FiFO has that *none* of the competitors do. Speculatively: FiFO
   as a substrate for **program/theory synthesis**, where the SAT/WMC engine is
   in the loop of *constructing* logical programs, not just evaluating them.

## One-sentence steer

Chase **Bet 3 (compiled weight learning) as the near-term win** because it's
mostly wiring you already own and it's exact; hold **Bet 1 (WFOMC / lifted
counting)** as the north star that would actually distinguish FiFO in the
literature; and treat **Bet 4 (semiring generalization)** as the refactor that
quietly makes everything else cheaper.

Three axes to decide between: FiFO as a **research artifact** (something that
says a new thing — Bets 1 and 3 dominate), as a **practical tool** you'll
actually plan and learn with (Bets 2, 4, 5), or as a **language-design
playground** (Bet 6 and the Lisp-reflection angle).

---

# Deep dive: Bet 5 — decision-theoretic planning under uncertainty

Context: the current SatPlan axioms are for **deterministic** domains.
Probabilities in FiFO today are used only for **plan recognition** (subjective
probabilities over what actions/goals we expect to observe); for **planning**,
weights represent **utilities**, not probabilities. Decision-theoretic planning
forces FiFO to use *both* weight-interpretations at once, in the same model,
partitioned by which variable each weight sits on. That partition is the whole
design.

## The reframing: three variable classes + goal-becomes-soft

Partition every propositional variable the grounder emits into three classes:

| Class | Symbol | Weight means | Operator |
|---|---|---|---|
| **Decision** (actions the agent picks) | `a@t` | nothing (free choice) | **max** |
| **Chance** (nature: initial state + action outcomes) | `ω@t`, `s@0` | **probability** | **sum** (marginalize) |
| **Derived** (fluents) | `f@t` | — | functionally determined by D, C |

Second shift, the one that actually changes the axiom set: **in deterministic
SatPlan the goal is a hard clause** (find *any* plan that entails it). **Under
uncertainty the goal/reward becomes soft** — it contributes utility, and we
maximize *expected* utility rather than demand entailment. The hard constraints
that remain (frame axioms, action mutex, precondition-gated effects) must be
*always satisfiable* in every world, so that "the plan fails in world C" is a
low-utility outcome, not an UNSAT.

The query is therefore **maximum expected utility**, a **marginal MAP**:

```
      max      Σ    P(C) · U(D, C)
    D (decisions) C (chance)
```

subject to the hard dynamics Φ(D, C, fluents). This is the E-MAJSAT / stochastic-SAT
object that Majercik & Littman's **MAXPLAN** used for probabilistic planning —
the same lineage, but on a *compiled circuit* instead of DPLL search.

## 1. Stochastic actions — distribution semantics + choice variables

Adopt Poole/Sato **distribution semantics** (the one ProbLog uses): every
stochastic rule gets an independent "choice" atom; the logic is deterministic
*given* the choices. For an action `move` that slips with prob 0.1, introduce a
per-action, per-step **choice variable** `ω_move@t` (weighted `P(succeed)=0.9`,
`P(slip)=0.1`) and gate the effect on it:

```
move@t ∧ ω_move=succeed @t  →  at(dest)@(t+1)
move@t ∧ ω_move=slip    @t  →  at(orig)@(t+1)     ; no-op outcome
```

The subtle part is the **explanatory frame axiom**, which now has to mention the
choice:

```
¬at(dest)@t ∧ at(dest)@(t+1)  →  ⋁_{(a,o) that add at(dest)} ( a@t ∧ ω_a=o @t )
```

That's the entire mechanical change to `satplan.wff`: effect axioms and
explanatory-frame axioms get an extra `ω` conjunct, and the `ω`s are weighted
nature atoms — independent across actions and steps, which keeps them a clean
product and the circuit small.

One more move to make everything *always executable*: turn preconditions from
hard constraints into **effect guards**. Instead of `a@t → precond(a)@t` (hard),
write `a@t ∧ precond@t → effect`, `a@t ∧ ¬precond@t → no-change`. Now any action
sequence is legal in any world (a mis-timed action is a no-op), so the
objective — not satisfiability — discriminates plans.

## 2. Uncertain initial state

The unknown initial fluents are chance variables at t=0: a weighted unit
"clause" per uncertain fluent, `P(f@0)=p_f`, with correlated priors expressed as
a small weighted sub-theory over the `s@0` variables. Conformant planning falls
out for free — the sum over `C` includes the sum over initial states.

## 3. Utility — three ways

- **(A) Utility-as-probability reduction (Cooper '88).** Decompose
  `U = Σ_k u_k·[φ_k]` and use linearity of expectation:
  `E[U | D] = Σ_k u_k · P(φ_k | D)`. Each `P(φ_k | D)` is a marginal. Reuses the
  existing WMC/ddnnf machinery *unchanged* — build this first.
- **(B) Expectation semiring (Eisner).** Carry a pair `(p, p·u)` at every node;
  one WMC pass yields both `Z=Σp` and `Σp·u`, so `EU = Σp·u / Σp` natively.
  Elegant, and it's an instance of Bet 4 — the "right" long-term home.
- **(C) Additive utility indicators** baked into the CNF — really just (A)
  reified.

Why (A) is more than a hack: because `E[U|D] = Σ_k u_k·P(φ_k|D)` and the two-pass
Darwiche evaluation gives all the `P(φ_k|D)` at once, evaluating a candidate
plan's expected utility is *one circuit sweep* — and the same sweep gives
`∂EU/∂(soft decision)`, connecting back to Bet 3. Compile once; then each
candidate plan costs one linear pass to score, sensitivities included.

## 4. The decision query — and the complexity cliff

Compilation nails the *inner sum* over chance. The hardness is the *outer max
over decisions*, and it splits by observability:

- **Conformant (straight-line plan, decisions chosen once).** All max-variables
  outermost: `max_D Σ_C`. If compiled with a **constrained variable order**
  (decisions eliminated *last*, on top of the vtree/d-DNNF), the max is a single
  bottom-up pass — the constrained-MMAP tractability result. The lever: tell the
  compiler to branch decisions first.
- **Contingent (policy: action at t may depend on observations up to t).**
  Decisions and chance *alternate* per timestep —
  `max_{a@1} Σ_{o@1} max_{a@2} Σ_{o@2} …` — the full quantifier alternation of a
  finite-horizon POMDP, i.e. genuine **stochastic SAT**. Two things to encode:
  (1) a **"same observation ⇒ same action" constraint** promoting free choices
  into a policy (an information-set / no-forgetting condition); (2) the
  alternation blocks the single-pass trick, so you compile the sum-blocks and
  *search* over the max-blocks with the circuit as a fast evaluator.

Honest complexity: conformant MEU is NP^PP (marginal MAP); contingent
finite-horizon is PSPACE-ish (SSAT). Compilation makes the inner counting free
and turns the outer problem into search over a cheap evaluator — which is the
point, since counting was the part that killed naïve approaches.

## Mapping onto FiFO

Reused directly: weighted atoms (→ `ω` chance vars and option-A utility
indicators); ddnnf/WMC/ADDMC/d4 (inner-sum engine, plus a **decisions-on-top**
variable-order option); maxent's two-pass marginals (computes `E[U|D]` and its
decision-gradient); MaxSAT cost machinery (deterministic-limit sanity check).

Genuinely new: choice-gated effect + explanatory-frame axiom schemas and
precondition-as-guard in `satplan.wff`; a "problem partition" declaration
(decision vs. chance vs. derived predicates + the utility decomposition
`{(u_k, φ_k)}`); a driver that does `max_D` (start with local search /
branch-and-bound calling the compiled circuit as scorer).

## Where to start

**Milestone 0: conformant "maximize goal probability."** Set `U = [goal@T]` (so
EU = P(goal)); no utility machinery yet — pure WMC of goal-reachability,
maximized over a fixed action sequence. Exercises the choice-variable axioms,
the always-satisfiable dynamics, and the decisions-on-top compile order.
**Milestone 1** swaps in additive utilities via option (A); **Milestone 2**
takes on contingent policies and the observation constraints. This gives
MAXPLAN's expressiveness with the counting done by knowledge compilation, in the
same system that also does plan recognition and weight learning.

---

# Deep dive: the relationship between Bet 5 (DTP) and Bet 4 (semirings)

Decision-theoretic planning is the task that shows exactly where the
single-semiring story ends.

## A semiring is one combiner + one aggregator

Algebraic model counting is parameterized by a commutative semiring
`(R, ⊕, ⊗)`: `⊗` **combines** labels *within* a model, `⊕` **aggregates**
*across* models. Every mode FiFO does today is one choice of that pair:

| Task | ⊗ (combine) | ⊕ (aggregate) | FiFO today |
|---|---|---|---|
| Feasible plan? (SatPlan) | ∧ | ∨ | SAT |
| Cheapest deterministic plan | + | min | MaxSAT |
| Goal probability / recognition | × | + | WMC |
| Single most-likely plan (MPE) | × | max | (max-product) |

Bet 4: these differ *only* in the pair, so compile the Boolean structure once
and read off any of them by swapping the evaluator. Each pair here is itself a
legitimate semiring (min-plus, sum-product, max-product).

## MEU needs *two* aggregators — one level above a semiring

```
MEU  =   max    Σ    P(C) · U(D,C)
        D (dec) C (chance)
```

One combiner (`×`), but **two aggregators**: `Σ` over chance and `max` over
decisions. A semiring gives one `⊕`. MEU needs `×` plus a *pair* `{Σ, max}` with
a fixed precedence — **not a semiring; one level up.** And it's not cosmetic:

```
max_D Σ_C   ≠   Σ_C max_D          (in general)
```

The two aggregators **don't commute as eliminations.** In a single semiring `⊕`
is associative+commutative, so you may eliminate in any order — which is why an
*unconstrained* d-DNNF suffices for WMC alone or MPE alone. Two aggregators kills
order-freedom, and that lost freedom is the exact source of the jump from #P (one
aggregator) to NP^PP / marginal-MAP (two).

## How Bet 4 reconciles with it — three moves

1. **Expectation semiring does the inner half as a genuine single semiring.**
   `E[U|D]` for fixed `D` collapses to one semiring pass; what it *cannot*
   absorb is the outer `max_D`. The max is the irreducible residue above the
   semiring.
2. **Constrained vtree turns the residue into a layered second pass.** Compile
   with **decisions on top**; evaluate bottom with sum-product (or expectation),
   top with max — a two-semiring traversal of *one* circuit. This is Dechter's
   bucket elimination with mixed operators (max-buckets processed last).
3. **The artifact at the intersection already has a name: the *decision
   circuit*** (Bhattacharjya & Shachter) — a compiled arithmetic circuit
   evaluated with **max at decision nodes and sum-product at chance nodes**. That
   is literally Bet 4's "parameterize the evaluator per node" applied to Bet 5's
   decision/chance partition. FiFO already produces the hard part (the circuit).

## The unifying picture

One compiled SatPlan circuit, up a ladder of richer semirings:

```
Boolean (∨,∧)        → is there a feasible plan?
min-plus             → cheapest deterministic plan          (today's MaxSAT)
sum-product          → P(goal) / recognition marginals      (today's WMC)
max-product          → single most-likely world+plan (MPE)
expectation semiring → E[U | fixed plan]
+ outer max (2 aggr) → MEU / optimal policy                 (decision circuit)
```

Everything above the line is a **single-aggregator** evaluation and works on
*any* d-DNNF — Bet 4, free. The last line is the **two-aggregator** evaluation:
the only one that imposes a compile-time constraint (decisions-on-top) and pays
for it in circuit size. That asymmetry *is* the relationship. **Bet 4 is the
substrate that makes Bet 5 natural rather than bolted-on:** once the evaluator is
semiring-parameterized, DTP is "use `max` on the decision block and `Σ` on the
chance block of a constrained-order circuit" — a decision circuit — instead of a
bespoke solver welded onto the WMC engine.

Open research question the connection hands you: for *your* SatPlan encodings,
how much does forcing decisions-on-top inflate the circuit versus the free order?
That inflation is the real price of MEU, and it's measurable with exactly the
d4/home-grown machinery already benchmarked — the constrained order is just a
different variable-ordering flag.

---

# Deep dive: Bet 1 — conditions for polynomial-time WFOMC

Headline: **the boundary is two logical variables.** Under symmetric weights,
WFOMC is polynomial in the domain size for the two-variable fragment (and its
counting extension), and provably *not* polynomial once you reach three
variables.

## The setting — what "polynomial time" means here

1. **Symmetric weights (SWFOMC).** Every grounding of a predicate gets the same
   weight (a function of the predicate, not of specific constants). Symmetry
   creates the exchangeability lifting exploits; drop it and you're doing
   ordinary asymmetric WMC.
2. **Function-free, finite domain** of cardinality `n`.
3. **Polynomial in `n`, formula fixed** — *data complexity*. "Liftable" =
   `poly(n)` versus the naïve `2^(n^arity)`. Dependence on the *formula* can
   still be exponential; lifting buys domain-scaling, not formula-scaling.

**Domain-liftable** = WFOMC computable in `poly(n)`.

## Why two variables is the magic number

Under symmetric weights the count depends only on **how many** elements/pairs
fall into each "type," never on *which*.

- Partition elements by **1-type** (which unary predicates hold). There are
  `2^(#unary)` cell types — constant in `n`.
- WFOMC reduces to a sum over **count vectors** (compositions of `n` into cells),
  each weighted by a **multinomial coefficient** — only `O(n^(#cells))` of them,
  collapsing exponentially-many assignments to polynomially-many count classes.
- With **two variables** you only reason about a *pair* `(x,y)` at a time, so the
  interaction is a fixed-size **2-table** over pairs of 1-types — summarizable by
  counts. With **three variables** you must track *triples*, whose joint is not
  recoverable from pairwise counts. That's where the polynomial collapses.

## The exact conditions

**Sufficient (known liftable classes):**

| Condition | Status | Source |
|---|---|---|
| **FO²** (≤ 2 logical vars; unary+binary preds) | poly | Van den Broeck 2011 |
| **C²** = FO² + counting quantifiers `∃^{=k}, ∃^{≥k}, ∃^{≤k}` | poly | Kuželka 2021 (JAIR) |
| **S²FO², S²RU** (certain structures outside FO²) | poly | Kazemi, Kimmig, Van den Broeck, Poole 2016 |
| C² **+ cardinality constraints** | poly (× poly factor) | van Bremen & Kuželka |
| C² **+ linear-order / tree / DAG / acyclicity axiom** | poly (per-axiom factor) | Tóth & Kuželka, ~2022–23 |
| **Symmetric weights** | required | — |
| **Evidence on unary predicates** | preserves liftability | Van den Broeck & Davis 2012 |

C² is the practical sweet spot: counting quantifiers give functionality
(`∃^{=1} y R(x,y)`), "at least/at most k," etc. — very expressive, still poly.

**Necessary / the negative boundary:**

- **FO³ is not domain-liftable in general.** A specific 3-variable sentence has
  **#P₁-hard** WFOMC (Beame, Van den Broeck, Gribkoff, Suciu, PODS 2015). No
  `poly(n)` for all of FO³ barring complexity collapse.
- **Asymmetric weights** or **evidence on binary+ relations** generally destroy
  liftability (Gribkoff, Van den Broeck, Suciu 2014). Unary evidence is safe;
  binary evidence is not.
- **No clean syntactic iff beyond these fragments.** Some FO³ sentences are
  liftable, some aren't, with no known decidable syntactic characterization. What
  *is* clean: a **completeness** result — the first-order knowledge-compilation
  rules (lifted decomposition + case-analysis + atom-counting) are **complete for
  FO²** and *incomplete* for FO³ (they get stuck and must ground).

**Technical device for existentials:** ordinary Skolemization introduces
function symbols, breaking the function-free setting. WFOMC uses a **weighted
Skolemization with an auxiliary predicate and negative weights** (Van den Broeck,
Meert, Darwiche, KR 2014). So a lifted circuit's leaves can carry negative
weights — a wrinkle the evaluator must tolerate.

## What this means for FiFO

Liftability is, for FiFO, a **syntactic property of wffs**: an axiom set using ≤2
logical variables per formula (with counting) can be counted *without grounding*,
polynomial in domain size — compiling a circuit **parameterized by `n`**,
evaluable at any domain size (a second compile-once/query-many axis, orthogonal
to the evidence one).

The wrinkle for SatPlan: **the axioms straddle the boundary.** A frame/effect
axiom quantifies over an action, a fluent, and a time step — smells like FO³. Two
mitigations pull it back: **time is a linear order** (and linear-order axioms are
among the liftable extensions), and many axioms are effectively binary once time
is the ordered dimension rather than a free logical variable.

So Bet 1's concrete first step is *diagnostic*: **classify which FiFO/SatPlan
axiom schemas fall in C² (+ linear order) and which genuinely need three
variables.** The liftable ones get the polynomial-in-domain path; the rest fall
back to ground-and-compile. "The compiler tells you which fragment each axiom is
in, and lifts what it can" is the distinguishing contribution — and it's
checkable against the real `satplan.wff` before building the full lifted
compiler.
