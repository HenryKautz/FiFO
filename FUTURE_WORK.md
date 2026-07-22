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
