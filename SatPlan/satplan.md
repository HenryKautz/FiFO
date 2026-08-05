# Implementing SatPlan in FiFO

### Table of Contents

- [README.md](../README.md) — the FiFO language reference and user guide.
- $\color{red}{\textbf{SatPlan/satplan.md}}$ — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](../Probability/probability.md) — the probabilistic layer in practice: computing marginals under a weighted theory and learning weights from target probabilities.
- [Probability/probability-background.md](../Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [FAQ.md](../FAQ.md) — frequently asked questions about modeling with FiFO.

Planning as Satisfiability (SatPlan) encodes an AI planning problem as a propositional satisfiability problem. The idea is to fix a time horizon of *T* steps, assert the initial state, the goal state, and the action semantics, and let the SAT solver find a sequence of actions (a plan) that achieves the goal. FiFO's static predicates and quantified formulas make the encoding concise and readable.

### Representation

A planning problem consists of:

- **Fluents** — state variables that are true or false at each time step (e.g., `(at (package 1) (place 2))`)
- **Actions** — things that can happen at each time step (e.g., `(load (package 1) (truck 1) (place 1))`)
- **Initial state** — the set of fluents that are true at time 1 (all others are false)
- **Goal state** — a set of fluents that must be true at the final time step

Action schemas are described using four PDDL-style static predicates:

| Predicate | Meaning |
|-----------|---------|
| `(Pre action fluent)` | *fluent* is a precondition of *action* |
| `(PreNeg action fluent)` | *action* requires *fluent* to be false (negative precondition) |
| `(Add action fluent)` | *action* adds *fluent* (makes it true) |
| `(Del action fluent)` | *action* deletes *fluent* (makes it false) |
| `(Cost action value)` | *action* has numeric cost *value* |

The FiFO propositions used in the encoding are:

| Proposition | Meaning |
|-------------|---------|
| `(Holds fluent s)` | *fluent* is true at time step *s* |
| `(Occurs action s)` | *action* happens at time step *s* |

### Domain-Independent SatPlan Axioms

The file `SatPlan/satplan.wff` contains domain-independent axioms that apply to any planning problem expressed using the predicates above. It assumes the following domains are already defined by the problem file: `actions`, `fluents`, `costs`, `slices`, `actslices`, `initial-state`, `goal-state`, `numslices`.

```lisp
;; Domain Independent SatPlan axioms
;; Parallel Execution Semantics

;; Register all static predicates used in tests below, so that they are
;; recognized even when a problem asserts no facts for some of them.
;; The dummy constants never appear in any actions/fluents/costs domain,
;; so these facts generate no clauses.
(static
   (Pre dummy-action dummy-fluent)
   (PreNeg dummy-action dummy-fluent)
   (Add dummy-action dummy-fluent)
   (Del dummy-action dummy-fluent)
   (Cost dummy-action 0))

(all s actslices true
   (and
      ;; Actions imply their preconditions
      (all act actions true
         (all flu fluents (Pre act flu)
            (implies (Occurs act s)
               (Holds flu s))))

      ;; Actions imply their negative preconditions are false.
      ;;   (PreNeg act flu) asserts that act requires flu to be false.
      (all act actions true
         (all flu fluents (PreNeg act flu)
            (implies (Occurs act s)
               (not (Holds flu s)))))

      ;; Actions imply their effects
      (all act actions true
         (all flu fluents (Add act flu)
            (implies (Occurs act s)
               (Holds flu (+ s 1)))))
      (all act actions true
         (all flu fluents (Del act flu)
            (implies (Occurs act s)
               (not (Holds flu (+ s 1))))))

      ;; (Interfering-action mutexes are lifted out of this per-slice loop; see
      ;; below.)

      ;; Frame axioms
      (all flu fluents true
         (implies (and (Holds flu s) (not (Holds flu (+ s 1))))
            (exists a actions (Del a flu)
               (Occurs a s))))

      (all flu fluents true
         (implies (and (not (Holds flu s)) (Holds flu (+ s 1)))
            (exists a actions (Add a flu)
               (Occurs a s))))

      ;; Actions have costs
       (all a actions true
            (all c costs (Cost a c)
                (Weight (Occurs a s) c)))))

;; Interfering actions are mutually exclusive.
;;   a2 interferes with a1 if a2 deletes a precondition or add-effect of a1, or
;;   if a2 adds a negative precondition of a1, where a1 and a2 are not equal.
;;
;; These are indexed by fluent rather than iterated over all action pairs: for
;; each fluent, only the (few) actions that need it conflict with the (few) that
;; change it -- avoiding an O(actions^2 x fluents) blowup.  The interfering pairs
;; do not depend on the time slice, so the per-fluent collects are done once here
;; (slice loop innermost) rather than repeated for every slice.
(all flu fluents true
   (all a1 (union (collect a (Pre a flu)) (collect a (Add a flu))) true
      (all a2 (collect a (Del a flu)) (neq a1 a2)
         (all s actslices true
            (or (not (Occurs a1 s)) (not (Occurs a2 s)))))))
(all flu fluents true
   (all a1 (collect a (PreNeg a flu)) true
      (all a2 (collect a (Add a flu)) (neq a1 a2)
         (all s actslices true
            (or (not (Occurs a1 s)) (not (Occurs a2 s)))))))

;; Initial state is completely specified
(all f initial-state true
   (Holds f 1))
(all f (set-difference fluents initial-state) true
   (not (Holds f 1)))

;; Goal state is partially specified
(all f goal-state true
   (Holds f numslices))
```

The `static` block at the top registers the five static predicates so that the quantified tests below parse even when a problem asserts no facts for some of them (for example, a problem with no negative preconditions or no action costs). The dummy constants never appear in any domain, so the registration generates no clauses.

The axioms use **parallel execution semantics**: multiple non-interfering actions may occur at the same time step. Two actions interfere if one deletes a precondition or add-effect of the other, or if one adds a negative precondition of the other.

The interference mutexes are written **indexed by fluent**: for each fluent, the actions that need it (`Pre`/`Add`, or `PreNeg`) are paired with the actions that change it (`Del`, or `Add`), gathered with `collect`. This generates exactly the interfering pairs without quantifying over every pair of actions, which would be O(actions² × fluents). They are also kept **outside the per-slice loop** (with the slice quantifier innermost), because the interfering pairs are the same at every step — so the per-fluent `collect`s run once rather than once per time slice. Together these let the encoding scale to many time steps.

**Negative preconditions** are expressed with `(PreNeg action fluent)`, meaning the action requires the fluent to be false. An action occurrence implies its negative preconditions are false at that time step, and an action may add its own negative precondition, just as an action may delete its own positive precondition. Fluents appearing in `PreNeg` facts must be included in the `fluents` domain.

The **frame axioms** ensure that fluents persist across time steps unless an action explicitly changes them. They are encoded as explanatory frame axioms: if a fluent changes value, some action must be responsible.

The **cost axioms** use `Weight` (FiFO's weighted MaxSAT mechanism) to assign a cost to each action occurrence. Minimizing total weight then yields a minimum-cost plan.

### Example: a small logistics problem

The bundled examples under `SatPlan/Examples/` are written in PDDL and translated to FiFO by `pddl2fifo` (below) rather than hand-written. The smallest, `SatPlan/Examples/Logistics/pb6.pddl`, is a two-city logistics problem: each city has an ordinary location and an airport, a truck (holding a package) and an airplane; each package must be delivered to the *other* city's airport.

```lisp
(define (problem pb6)
  (:domain logistics)
  (:requirements :strips :typing)
  (:objects
     pkg1 pkg2   - package
     t1 t2       - truck
     p1 p2       - airplane
     l1 l2       - location
     a1 a2       - airport
     c1 c2       - city)
  (:init
     (in-city l1 c1) (in-city a1 c1)
     (in-city l2 c2) (in-city a2 c2)
     (at t1 l1) (at t2 l2)
     (at p1 a1) (at p2 a2)
     (in pkg1 t1) (in pkg2 t2))
  (:goal (and (at pkg1 a2) (at pkg2 a1))))
```

`pddl2fifo` turns this into exactly the FiFO encoding described above: a `static` block of `Pre`/`Add`/`Del`/`Cost` facts for each ground action, the `actions`/`fluents`/`costs` domains derived from those facts with `collect`, the `initial-state` and `goal-state` domains, and a trailing `(include "satplan.wff")`. Because `Pre`, `Add`, `Del`, and `Cost` are static predicates, the axioms use them as tests in quantified filters (e.g. `(all flu fluents (Pre act flu) ...)`), generating clauses only for relevant fluent–action pairs.

The optimal plan runs the two deliveries in lockstep over five parallel action slices (drive → unload-truck → load-airplane → fly → unload-airplane), so it solves at a horizon of six time slices.

### Translating PDDL to FiFO with pddl2fifo

The program `lisp/pddl2fifo.lisp` translates a planning problem written in PDDL (the standard Planning Domain Definition Language) into a FiFO wff file in the form described above. It supports the PDDL requirements `:strips`, `:typing`, `:negative-preconditions`, `:disjunctive-preconditions`, `:quantified-preconditions` (equivalently `:universal-preconditions` / `:existential-preconditions` — quantifiers are supported in the problem `:goal`, `:constraints`, and preference bodies, but not in action preconditions), `:constraints`, `:preferences`, and `:action-costs`. Action costs must be simple static numbers. They may be given either as an effect `(increase (total-cost) <number>)` or, more directly, as a `:cost <number>` slot on the action (a FiFO-specific convenience):

```lisp
(:action turn-off
   :parameters (?x)
   :precondition (on ?x)
   :effect (not (on ?x))
   :cost 2)
```

The two forms are equivalent; giving both on the same action is an error. The cost must be a constant number (a cost that varies with the action's parameters is not supported by either form).

#### Trajectory constraints

With `:constraints`, the problem may carry a `(:constraints ...)` section of hard state-trajectory constraints over the plan's slice timeline (slice 1 is the initial state, `numslices` the final state), written in the PDDL 3.0 con-GD grammar: modal formulas combined with `(and ...)` and universally quantified with `(forall (<typed vars>) ...)` (existential quantification *over* a modal is not part of PDDL 3.0 and is rejected; use `exists` inside the modal's state formula instead). Four modal operators are supported:

| Constraint | Meaning | Encoding |
|---|---|---|
| `(always φ)` | φ holds in every state | `(all s slices true (holds φ s))` |
| `(at-end φ)` | φ holds in the final state | `(holds φ numslices)` |
| `(hold-during t1 t2 φ)` | φ holds in every state of the inclusive slice window `[t1, t2]` | `(all s slices (and (>= s t1) (<= s t2)) (holds φ s))` |
| `(occur-sometime t1 t2 a)` | the ground action `a` occurs at some slice in `[t1, t2]` | `(exists s actslices (and (>= s t1) (<= s t2)) (occurs a s))` |

Here φ is a full state description — a literal, or an `and`/`or`/`not`/`imply`/`forall`/`exists` combination of literals — and `a` is an action term, fully instantiated (e.g. `(fly-airplane p1 a1 a2)`) except for variables bound by enclosing `forall` quantifiers. The time bounds `t1`/`t2` are inclusive integer slice numbers. `occur-sometime` is a FiFO-specific extension (it has no standard PDDL counterpart). Constraints only restrict the set of valid plans, so they do not change the reachability lower bound on `minslices`. Inside φ, an atom of a *dynamic* fluent becomes a time-indexed `Holds` proposition, while an atom of a *static* predicate (one no action adds or deletes) is left as a bare FiFO literal, resolved at instantiation time — so static predicates work as guards inside quantified constraints. For example:

```lisp
(:constraints
   (and
      (always (not (at pkg1 l2)))            ; pkg1 never passes through l2
      (hold-during 1 2 (in pkg1 t1))         ; pkg1 stays in t1 for the first two slices
      (occur-sometime 4 5 (fly-airplane p1 a1 a2))  ; that flight happens in slice 4 or 5
      (forall (?t - truck)                   ; every truck always sits at some
         (always (exists (?l - location)     ; location of city c1 (in-city is
            (and (in-city ?l c1) (at ?t ?l)))))))  ; static: a compile-time guard)
```

A PDDL quantifier compiles directly to FiFO's guarded quantifier over the type's domain — `(forall (?t - truck) ...)` becomes `(all t truck true ...)` — so grounding happens at FiFO instantiation time, and `either`-types become domain unions. The same quantifier syntax is accepted in the problem `:goal` (both `forall` and `exists`, arbitrarily nested with the other connectives) under the `:quantified-preconditions` requirement flag.

#### Forcing Plan to Incorporate Known Facts

Trajectory constraints are also useful for pinning a plan to facts you already know about *when* things happen — forcing a particular action into a time window, or requiring a fluent to persist across a range of steps. For example, requiring the Washington→Boston flight to occur somewhere in steps 3–5 while package `pkg1` stays at the Boston airport throughout steps 1–4:

```lisp
(:requirements :strips :typing :constraints)
...
(:init (at plane1 washington) (at pkg1 boston))
(:goal (at plane1 boston))
(:constraints
   (and
      (occur-sometime 3 5 (fly-airplane plane1 washington boston))  ; flight fires in step 3..5
      (hold-during 1 4 (at pkg1 boston))))                        ; pkg1 at boston in steps 1..4
```

The plan must reach the goal *and* respect both constraints, so the planner holds the plane in Washington and fires the flight at the earliest allowed step (3, landing in Boston at step 4), while `pkg1` — which starts at Boston and is never moved — satisfies the `hold-during` window. Recall the windows use absolute slice numbers and do not raise the reachability bound, so ensure the search horizon reaches them (here the `occur-sometime` window already forces a horizon of 4); a `hold-during` body should name dynamic fluents (static atoms in it are resolved once at instantiation time, so a window over only static atoms constrains nothing slice by slice).

#### Preferences (soft goals and soft constraints)

With `:preferences`, the `:goal` and `:constraints` sections may contain `(preference <name> <body> [<weight>])` forms. A preference is a *soft* requirement: a plan need not satisfy it, but each violation adds its weight to the plan metric. A preference in the `:goal` has a state-description body (satisfied iff it holds in the final state); a preference in `:constraints` has a trajectory-constraint body (a con-GD: the four modal operators above, possibly combined with `and` / `forall` — e.g. `(preference everywhere (forall (?p - package) (at-end (at ?p depot))))` is satisfied only if *every* package ends at the depot). To prefer that something *not* hold, negate the body (e.g. `(preference tidy (not (at junk depot)) 5)`); weights are always non-negative penalties, so a negative weight is an error.

The optional fourth element gives the violation weight inline. When it is omitted, the weight comes from the `(:metric minimize ...)` form, whose `(is-violated <name>)` terms name the preferences. So the same preferences can be written either way:

```lisp
;; Inline weights -- no :metric needed
(:goal (and (at pkg1 a2)                              ; hard goal
            (preference deliver2 (at pkg2 a1) 3)      ; soft, weight 3
            (preference park1 (at-end (at p1 a1)) 7)))

;; Or weights drawn from the metric
(:goal (and (at pkg1 a2)
            (preference deliver2 (at pkg2 a1))
            (preference park1 (at-end (at p1 a1)))))
(:metric minimize (+ (* 3 (is-violated deliver2))
                     (* 7 (is-violated park1))))
```

An inline weight takes precedence over a `:metric` coefficient for the same preference (a warning is issued if both are given). If a preference has neither an inline weight nor a metric coefficient, it defaults to weight 1 when there is no `:metric` (so the planner minimizes the number of violations) and to 0 (ignored) when a metric is present but does not mention it.

Each preference is compiled to a fresh proposition `(pref-violated <name>)`: the hard clause `(or <body> (pref-violated <name>))` forces it true whenever the body fails, and a soft `(weight (pref-violated <name>) w)` charges the weight `w`. The planner then solves the problem as weighted MaxSAT, minimizing the total weight, and the answer lists `(pref-violated <name>)` for exactly the violated preferences along with the `*objective*` (the minimized total). The coefficient of `(total-cost)` in the metric scales the action costs and combines with the preference weights in the same objective. A preference appearing in an action `:precondition` is not supported and is rejected with an error.

Because the planner searches for the *smallest* feasible horizon and only then minimizes weight, preference satisfaction is optimized at that smallest horizon (a preference satisfiable only at a larger horizon will be reported violated) — the same makespan-then-cost tradeoff used for action costs.

#### Preferences Between Disjunctive Goals

Combining a disjunctive goal with a preference expresses "either of these, but I'd rather have this one." For example, to require an airplane to end in Boston *or* Washington while preferring Washington:

```lisp
(:requirements :strips :typing :disjunctive-preconditions :preferences)
...
(:goal (and (or (at plane1 boston) (at plane1 washington))     ; hard: one of the two
            (preference end-in-washington (at plane1 washington) 10)))  ; soft: prefer Washington
```

The disjunction is the hard requirement, so the plan must reach one of the two airports; the preference adds a penalty of 10 for not ending in Washington. Since the hard goal already guarantees Boston-or-Washington, the only way to avoid the penalty is to end in Washington, so the planner chooses Washington when it can and falls back to Boston (objective 10, with `(pref-violated end-in-washington)` reported) only when Washington is unreachable. When the preference is the only soft term its weight is arbitrary — any positive value picks Washington; the magnitude matters only when traded off against other costs.

#### Per-step fluent costs

Standard PDDL attaches costs to actions, never to states. The FiFO-specific `(:fluent-cost <literal> <cost>)` form attaches a cost to a *fluent*: it charges `<cost>` for every time slice in which the literal holds. A problem may contain any number of these forms.

```lisp
(:fluent-cost (congested r1) 2)         ; +2 for each slice (congested r1) is true
(:fluent-cost (not (powered pump)) 5)   ; +5 for each slice the pump is unpowered
```

Each compiles to a per-slice weight — the same pattern satplan.wff uses for action costs — `(all s slices true (weight (holds <literal> s) <cost>))` (with `(not (holds ...))` for a negated literal), so the total contribution is `<cost>` times the number of slices the literal holds. This lets you express things PDDL cannot: fuel/time burned while a condition persists, occupancy costs, "minimize time spent in a bad state," and (by negating the literal) a per-slice *reward* for keeping something true. The literal must name a dynamic fluent. Like preferences, fluent costs make the problem a weighted-MaxSAT instance and add to the same `*objective*`; because cost accrues per slice, a fluent cost is sensitive to the horizon (a longer plan can accrue more). Costs are non-negative.

#### The `:metric` is optional

`:metric` is now an *override*, not a requirement. Action costs (whether written as `:cost` slots or `(increase (total-cost) …)` effects), inline preference weights, and `:fluent-cost` forms all declare their own weights, and the objective is implicitly "minimize the sum of all of them." So a problem can omit `:metric` entirely and still be optimized. Supply `:metric minimize …` only when you want to (a) give preference weights without writing them inline (via `(is-violated <name>)` terms) or (b) scale the action-cost total with a coefficient on `(total-cost)`. An inline preference weight overrides the corresponding metric term, and `:fluent-cost` weights are independent of the metric.

To run from the shell:

```sh
sbcl --script lisp/pddl2fifo.lisp <problem.pddl> [<domain.pddl>]
```

Or from a Lisp listener:

```lisp
(load "lisp/pddl2fifo.lisp")
(pddl2fifo "problem.pddl")                            ; domain file found automatically
(pddl2fifo "problem.pddl" :domain-file "domain.pddl") ; domain file given explicitly
(pddl2fifo "problem.pddl" :satplan-path "/path/to/lisp/satplan.wff") ; custom include path
```

The `:satplan-path` keyword (default `"satplan.wff"`) sets the path written into the generated `(include ...)` form for the SatPlan axioms. It is resolved relative to the directory of the generated wff, so pass the path to `satplan.wff` (in the installed `~/lib/fifo/lisp/` or a source checkout's `lisp/`) relative to the problem file's directory. The `planner.sh` driver computes this automatically, so you only need `:satplan-path` for manual `pddl2fifo` use.

If the domain file is not given, the root of its file name is taken from the `(:domain <name>)` form in the problem file, and `<name>.pddl` is looked up in the directory of the problem file.

The translation is written to `<problem-root>.wff` in the directory of the problem file. The output:

- Defines a universal `objects` domain plus one FiFO domain per PDDL type. A type's domain contains the objects declared with that type or any of its subtypes, following the `(:types ...)` hierarchy; objects and parameters left untyped fall back to `objects`. Each PDDL action schema is translated into a quantified `static` formula asserting `Pre`, `Add`, `Del`, and `Cost` facts, with each parameter quantified over its type's domain.
- Derives the `actions`, `fluents`, and `costs` domains from the static facts using `collect`.
- Emits the time horizon as `(alias numslices (lisp ...))`, which evaluates to the Lisp variable `*satplan-numslices*` when it is bound to an integer and otherwise to `2`. Set the horizon without editing the output by binding `*satplan-numslices*` — e.g. `(setq *satplan-numslices* 10)` on the command line before `solve`/`instantiate`, or `(option *satplan-numslices* 10)` ahead of the alias — or edit the alias line directly.
- Ends with `(include "satplan.wff")` (or whatever `:satplan-path` was given), so the SatPlan axiom file must be reachable from the directory containing the output file.

Negative preconditions are translated into `PreNeg` static facts, which the axioms in `satplan.wff` handle directly. Negative goals produce a `negative-goal-state` domain together with an axiom asserting those fluents are false at the final time slice.

`pddl2fifo` also runs a relaxed planning-graph reachability analysis on the problem and returns, as a second value, a lower bound on the number of time slices a plan needs (or `:unreachable` if the goals cannot be reached even in the relaxation). The planner uses this to choose its default horizon range; see *Running the planner* below.

Other example problems are provided. The untyped pair `SatPlan/Examples/Switch/switches.pddl` (domain) and `SatPlan/Examples/Switch/switchprob.pddl` (problem) exercises negative preconditions, negative goals, and action costs. The typed pair `SatPlan/Examples/TruckLog/trucklog.pddl` and `SatPlan/Examples/TruckLog/trucklogprob.pddl` is a logistics task using PDDL types, including a type hierarchy (`truck` is a subtype of `mobile`, and the drive action ranges over `mobile`).

### Learning and Inference

We now describe our pipelines for 

- Computing costs and weights from probabilities
- Cost-optimal planning and maximum likelihood plan recognition
- Computing marginal probabilities from a planning domain together with evidence

#### Computing costs and weights from probabilities

Anywhere a cost or weight is specified, you can instead give a **`:probability <p>`** (with `0 < p < 1`) — the learnable alternative. The probability flows into the wff as a target marginal, is **tied** so related ground instances share one weight, and is learned by the weight pipeline. The three places, and what each becomes in the *learned* copy:

| Spec (in PDDL)                       | Where                                | `:probability` means               | Tied              | Becomes                 |
| ------------------------------------ | ------------------------------------ | ---------------------------------- | ----------------- | ----------------------- |
| action `:probability p`              | domain                               | P(the action occurs, per slice)    | per action schema | action `:cost w`        |
| `(preference n body :probability p)` | instance (in `:goal`/`:constraints`) | P(the preference is **satisfied**) | per preference    | `(preference n body w)` |
| `(:fluent-cost lit :probability p)`  | instance                             | P(the fluent holds, per slice)     | per fluent        | `(:fluent-cost lit w)`  |

A cost/weight and a probability are alternatives for the same spec (not both at once); existing fixed costs/weights are left untouched. Learned weights may be **negative** (a signed cost — when the target probability favors the penalized state), which the forms now accept.

`bin/learn-pddl.sh` runs the whole pipeline: translate → instantiate (at a small `--numslices` horizon) → learn (`--method log-odds` (default) or `--maxent`) → write `<domain>_learned.pddl` and/or `<problem>_learned.pddl` (whichever carried probabilities) with each `:probability` replaced by the learned value. For example:

```lisp
(:action turn-on :parameters (?x) :precondition (not (on ?x)) :effect (on ?x) :probability 0.7)
;; after `learn-pddl.sh prob.pddl --domain dom.pddl`:
(:action turn-on :parameters (?x) :precondition (not (on ?x)) :effect (on ?x) :cost -85)
```

Run `learn-pddl.sh --help` for all options. With `--maxent` the problem must be feasible at the chosen `--numslices`; log-odds is horizon-independent.

With `:disjunctive-preconditions`, the problem `:goal` may be a general goal description built from `and`, `or`, `not`, and `imply` over the goal atoms, not just a conjunction of literals. For example `(:goal (or (at pkg1 a2) (at pkg1 l1)))` is satisfied by a plan that achieves either disjunct. The reachability lower bound used to default `minslices` is weakened to stay admissible for disjunctive goals (it requires only the cheapest disjunct to be reachable). Note that even though `:disjunctive-preconditions` is accepted, only disjunctions in the goal are supported: a disjunctive or quantified precondition on an `:action` is rejected with an error.

#### Running the planner

`bin/planner.sh` is an end-to-end driver. It translates a PDDL problem with `pddl2fifo` (or takes a `.wff` directly), then **searches for the smallest workable time horizon** and solves at it. At each horizon it instantiates the problem and tests feasibility with a pure SAT solver; if the domain has action costs, it then re-solves the smallest feasible horizon with a weighted (MaxSAT) solver to minimize total cost. The two solvers are configured at the top of the script (`kissat` and `tt-open-wbo-inc-Glucose4_1` by default).

```sh
# search horizons 2..6 (the defaults) for the smallest plan
bin/planner.sh SatPlan/Examples/Logistics/pb6.pddl

# the switch problem -- has costs, so the weighted solver minimizes total cost
bin/planner.sh SatPlan/Examples/Switch/switchprob.pddl

# the typed trucklog problem
bin/planner.sh SatPlan/Examples/TruckLog/trucklogprob.pddl
```

After `make install`, `planner.sh` is on your PATH (so just `planner.sh <problem>`). Running it from a source checkout without installing requires pointing it at the lisp: `FIFO_LISP=$PWD/lisp bin/planner.sh <problem>`.

`--minslices`/`--maxslices` bound the horizon search, `--numslices N` fixes the horizon, and `--domain <file>` supplies a domain explicitly. When the bounds are omitted, `pddl2fifo` runs a relaxed planning-graph **reachability analysis** (ignoring delete effects and negative preconditions) to compute a lower bound on the horizon: `--minslices` defaults to that bound (2 for a `.wff`, which has no PDDL to analyze) and `--maxslices` defaults to twice `--minslices`. If the reachability analysis shows the goals are unreachable even in the relaxation, the problem is reported unsolvable without any search. All intermediate files and the `.answer` file are written next to the problem file; on success the answer is printed to stdout.

`--stop-after <wff|scnf>` halts the pipeline early, for inspecting or editing the intermediate files: `--stop-after wff` writes the `.wff` translation and stops (no instantiation or solving), and `--stop-after scnf` additionally instantiates it once — at `--numslices`, or the smallest/reachability horizon otherwise — writing the `.scnf` without solving. With evidence (below) it also writes the separate `<root>-evidence.scnf`, leaving the two files for inspection.

`--longer K` trades plan length for cost. By default the planner minimizes cost only at the smallest feasible horizon *s*; with `--longer K` it instead minimizes cost at each horizon *s* … *s+K* and returns the **cheapest** plan found across that range — useful because a longer horizon can admit a lower-cost plan (e.g. a cheap sequence of actions in place of one expensive parallel step). Costs at different horizons are compared as true plan costs (the MaxSAT objective, corrected by the weight scale/offset when weights were shifted, as with negative learned costs). `--longer` has no effect on a domain without action costs (every feasible plan then has cost 0). For example, `bin/planner.sh prob.pddl --longer 3` reports the cost at each of *s* … *s+3* slices and keeps the lowest.

#### Conditioning on evidence and marginal inference

`--evidence '<formula>'` (repeatable) and `--evidence-file <file>` **condition** the problem on a FiFO formula. Unlike the `.scnf`-level evidence of `marginals.sh`/`wmc.sh` (which must be ground), here the formula may be **quantified over the problem's domains** — e.g. `--evidence '(all (s) actslices true (not (occurs (turn-on s1) s)))'` — because the planner instantiates it through the full pipeline. At each working horizon the evidence is parsed **in the same environment as the problem**, so its quantifiers ground over the same `slices`/`objects`/… domains at that horizon, and the resulting hard clauses are written to a **separate** `<root>-evidence.scnf`. That file is then concatenated with the problem `.scnf` and handed downstream — so without `--marginals`, the planner searches for the smallest-horizon, lowest-cost plan **that also satisfies the evidence** (the evidence is a hard constraint). For instance, forbidding an action the shortest plan relies on can push the solution to a longer horizon that routes around it.

**Evidence in PDDL syntax.** Writing FiFO evidence means knowing the SatPlan encoding (`occurs`/`holds` wrappers, explicit slice arguments). `--pddl-evidence '<form>'` (repeatable) and `--pddl-evidence-file <file>` let you instead use the **PDDL modal language** — the same operators as the `:constraints` section — over PDDL predicate and action names, which `pddl2fifo` translates to FiFO for you:

| PDDL evidence | Conditions that… |
|---|---|
| `(at-end (on s2))` | the fluent holds at the final slice |
| `(always (on s1))` | it holds at every slice |
| `(hold-during 2 3 (on s1))` | it holds throughout slices 2–3 |
| `(occur-sometime 1 2 (turn-on s1))` | the action occurs somewhere in slices 1–2 |
| `(never (turn-on s1))` | the action never occurs |
| `(at 3 (turn-off s1))` | the action occurs at slice 3 |

State formulas inside the operators may use `and`/`or`/`not`/`imply` over fluents (e.g. `(at-end (or (on s1) (on s2)))`). For example, `--pddl-evidence '(never (turn-on s1))'` becomes `(all s actslices true (not (occurs (turn-on s1) s)))`, written to `<root>-evidence.scnf` exactly as a FiFO `--evidence` would be — the two flags can be mixed, and the fluents an evidence form names are registered so they get `Holds` variables and frame axioms. PDDL evidence requires a PDDL problem (there is no translation step for a `.wff` input). This first version is ground; quantifying over object types (`forall ?x - switch`) is a planned extension.

`--marginals` switches from planning to **inference**: instead of searching for a plan, the planner instantiates the problem (conjoined with any evidence) once at the working horizon and runs **weighted model counting**, printing `(MARGINAL <atom> <p>)` — the probability `P(atom | evidence)` of each atom under the Gibbs distribution defined by the action costs. The horizon is the fixed `--numslices`, or the reachability/`--minslices` lower bound. `--counter <name>` selects the model counter: `maxent` (the default, the built-in exact enumeration of `lisp/maxent.lisp`) or the name/path of an **ADDMC** binary (e.g. `--counter addmc`, or `--counter /path/to/addmc`), which scales much further. See [../Probability/probability.md](../Probability/probability.md) for the counting back ends and the weight-scale handling. If the evidence contradicts the problem, the count is 0 (no feasible set) and that is reported.

#### Worked example: the Switch domain, end to end

`SatPlan/Examples/Switch/` has a tiny domain — three switches `s1 s2 s3`, actions `(turn-on ?s)` (cost 1) and `(turn-off ?s)` (cost 2), starting with `s1` on and the goal `s1` off, `s2` and `s3` on. The plain run finds the obvious two-step plan:

```
$ planner.sh switchprob.pddl --domain switches.pddl
SOLVED with 2 time slices.
(*OBJECTIVE* 4)
(OCCURS (TURN-OFF S1) 1)
(OCCURS (TURN-ON S2) 1)
(OCCURS (TURN-ON S3) 1)
```

Now **condition the plan** so `s1` is turned off at slice 2 rather than slice 1, using PDDL-syntax evidence — `pddl2fifo` translates `(occur-sometime 2 2 (turn-off s1))` to `(exists s actslices (and (>= s 2) (<= s 2)) (occurs (turn-off s1) s))`. The two-slice horizon has no slice 2 to act in, so it goes unsatisfiable and the planner **adapts to three slices**, deferring the turn-off as required:

```
$ planner.sh switchprob.pddl --domain switches.pddl --pddl-evidence '(occur-sometime 2 2 (turn-off s1))'
  unsatisfiable with 2 time slices
SOLVED with 3 time slices.
(*OBJECTIVE* 4)
(OCCURS (TURN-ON S2) 1)
(HOLDS (ON S1) 2)
(OCCURS (TURN-OFF S1) 2)
(OCCURS (TURN-ON S3) 2)
```

To see the pieces, stop after instantiation — the evidence lands in its own file:

```
$ planner.sh switchprob.pddl --domain switches.pddl --numslices 3 --stop-after scnf \
             --pddl-evidence '(occur-sometime 2 2 (turn-off s1))'
Stopped after generating the scnf files at 3 time slices:
  problem:  .../switchprob.scnf
  evidence: .../switchprob-evidence.scnf

$ cat switchprob-evidence.scnf
(OR (OCCURS (TURN-OFF S1) 2))
```

Finally, **inference instead of planning.** At three slices the turn-off of `s1` can fall at slice 1 or slice 2 for the same cost, so its marginal splits evenly over the two plans:

```
$ planner.sh switchprob.pddl --domain switches.pddl --numslices 3 --marginals --counter addmc
(MARGINAL (OCCURS (TURN-OFF S1) 1) 0.5000...)
(MARGINAL (OCCURS (TURN-OFF S1) 2) 0.5000...)
```

Add the same evidence and the marginals become the conditional `P(atom | evidence)` — the turn-off is pinned to slice 2:

```
$ planner.sh switchprob.pddl --domain switches.pddl --numslices 3 --marginals --counter addmc \
             --pddl-evidence '(occur-sometime 2 2 (turn-off s1))'
(MARGINAL (OCCURS (TURN-OFF S1) 1) 0.0000...)
(MARGINAL (OCCURS (TURN-OFF S1) 2) 1.0000...)
```

The same flags accept FiFO evidence directly (`--evidence '(not (occurs (turn-off s1) 1))'`) when you'd rather not go through the PDDL modal language, and incompatible evidence (e.g. `(never (turn-off s1))`, which makes the goal unreachable) is reported as a zero count / no feasible set.

The intermediate files the pipeline leaves behind (`.scnf`, `.cnf`, `.wcnf`, `.map`, `.satout`, `.soln`, `.answer`) can be cleared with `bin/cleanupfifo.sh [<dir>|<file>]` — it deletes those byproducts from a directory (the current one, the given directory, or the directory containing the given file), never touching source files like `.wff` or `.pddl`. Add `-r`/`--recursive` to clean subdirectories too (with care — it removes matching files anywhere below the target, including committed fixtures such as `*_gold.scnf`), and `--dry-run` to preview.

The logic lives in `lisp/planner.lisp`: `(plan problem &key minslices maxslices sat-solver weighted-solver domain-file satplan-path stop-after longer evidence evidence-file pddl-evidence pddl-evidence-file marginals counter)` runs the search (or, with `marginals`, the inference) and returns the status, horizon, and answer/scnf-file path, and `(plan-and-report ...)` is the CLI helper the script calls. Load `lisp/FiFO.lisp`, `lisp/pddl2fifo.lisp`, and `lisp/planner.lisp` to call them from a Lisp listener.

### Benchmark: smallest horizons for the LogisticsCosts problems

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

------

### References

- **Planning as satisfiability** — H. Kautz & B. Selman (1992). Planning as satisfiability. *ECAI-92*, pp. 359–363.
- **Parallel encodings, mutexes, and explanatory frame axioms in SAT planning** — H. Kautz & B. Selman (1996). Pushing the envelope: Planning, propositional logic, and stochastic search. *AAAI-96*, pp. 1194–1201.
- **Combining planning-graph reachability with SAT** (the pattern behind the relaxed reachability bound feeding the horizon search) — H. Kautz & B. Selman (1999). Unifying SAT-based and graph-based planning. *IJCAI-99*, pp. 318–325.
- **The SatPlan system** — H. Kautz, B. Selman & J. Hoffmann (2006). SatPlan: Planning as satisfiability. In *Abstracts of the 5th International Planning Competition*.
- **Planning graphs and mutual exclusion** — A. Blum & M. Furst (1997). Fast planning through planning graph analysis. *Artificial Intelligence* 90(1–2):281–300.
- **Delete-relaxation reachability** (the `reachable-min-slices` lower bound ignores delete effects) — J. Hoffmann & B. Nebel (2001). The FF planning system: Fast plan generation through heuristic search. *Journal of Artificial Intelligence Research* 14:253–302.
- **Explanatory frame axioms** — A. Haas (1987). The case for domain-specific frame axioms. In F. Brown (ed.), *The Frame Problem in Artificial Intelligence: Proc. of the 1987 Workshop*; L. Schubert (1990). Monotonic solution of the frame problem in the situation calculus. In *Knowledge Representation and Defeasible Reasoning*, Kluwer, pp. 23–67.
- **PDDL** — D. McDermott, M. Ghallab, A. Howe, C. Knoblock, A. Ram, M. Veloso, D. Weld & D. Wilkins (1998). PDDL — The Planning Domain Definition Language. Tech. Rep. CVC TR-98-003 / DCS TR-1165, Yale University.
- **PDDL 3.0: trajectory constraints and preferences** — A. Gerevini & D. Long (2005). Plan constraints and preferences in PDDL3. Tech. Rep. RT 2005-08-47, Università degli Studi di Brescia; A. Gerevini, P. Haslum, D. Long, A. Saetti & Y. Dimopoulos (2009). Deterministic planning in the fifth international planning competition: PDDL3 and experimental evaluation of the planners. *Artificial Intelligence* 173(5–6):619–668.
- **Anytime weighted MaxSAT** (the cost-minimization step; TT-Open-WBO-Inc) — A. Nadel (2019). Anytime weighted MaxSAT with improved polarity selection and bit-vector optimization. *FMCAD 2019*, pp. 193–202.
- **Plan recognition as planning** (the conditioning / maximum-likelihood plan-recognition tier) — M. Ramírez & H. Geffner (2009). Plan recognition as planning. *IJCAI-09*, pp. 1778–1783; M. Ramírez & H. Geffner (2010). Probabilistic plan recognition using off-the-shelf classical planners. *AAAI-10*, pp. 1121–1126; M. Ramírez & H. Geffner (2011). Goal recognition over POMDPs: Inferring the intention of a POMDP agent. *IJCAI-11*.
- **Recognition with unreliable observations, approximated by top-k plans** (where FiFO instead sums over all trajectories by weighted model counting) — S. Sohrabi, A. Riabov & O. Udrea (2016). Plan recognition as planning revisited. *IJCAI-16*; S. Sohrabi, O. Udrea & A. Riabov (2013). Hypothesis exploration for malware detection using planning. *AAAI-13*.
- **Top-k planning** — A. Riabov, S. Sohrabi & O. Udrea (2014). New algorithms for the top-k planning problem. *ICAPS 2014 Scheduling and Planning Applications Workshop (SPARK)*; M. Katz, S. Sohrabi, O. Udrea & D. Winterer (2018). A novel iterative approach to top-k planning. *ICAPS-18*.
- **Landmark-based goal recognition** — R. F. Pereira, N. Oren & F. Meneguzzi (2017). Landmark-based heuristics for goal recognition. *AAAI-17*.
