# Implementing SatPlan in FiFO

Part of the [FiFO documentation](../README.md).

Planning as Satisfiability (SatPlan) encodes an AI planning problem as a propositional satisfiability problem. The idea is to fix a time horizon of *T* steps, assert the initial state, the goal state, and the action semantics, and let the SAT solver find a sequence of actions (a plan) that achieves the goal. FiFO's observed predicates and quantified formulas make the encoding concise and readable.

### Representation

A planning problem consists of:

- **Fluents** — state variables that are true or false at each time step (e.g., `(at (package 1) (place 2))`)
- **Actions** — things that can happen at each time step (e.g., `(load (package 1) (truck 1) (place 1))`)
- **Initial state** — the set of fluents that are true at time 1 (all others are false)
- **Goal state** — a set of fluents that must be true at the final time step

Action schemas are described using four PDDL-style observed predicates:

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

;; Register all observed predicates used in tests below, so that they are
;; recognized even when a problem asserts no facts for some of them.
;; The dummy constants never appear in any actions/fluents/costs domain,
;; so these facts generate no clauses.
(observed
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

The `observed` block at the top registers the five observed predicates so that the quantified tests below parse even when a problem asserts no facts for some of them (for example, a problem with no negative preconditions or no action costs). The dummy constants never appear in any domain, so the registration generates no clauses.

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

`pddl2fifo` turns this into exactly the FiFO encoding described above: an `observed` block of `Pre`/`Add`/`Del`/`Cost` facts for each ground action, the `actions`/`fluents`/`costs` domains derived from those facts with `collect`, the `initial-state` and `goal-state` domains, and a trailing `(include "satplan.wff")`. Because `Pre`, `Add`, `Del`, and `Cost` are observed predicates, the axioms use them as tests in quantified filters (e.g. `(all flu fluents (Pre act flu) ...)`), generating clauses only for relevant fluent–action pairs.

The optimal plan runs the two deliveries in lockstep over five parallel action slices (drive → unload-truck → load-airplane → fly → unload-airplane), so it solves at a horizon of six time slices.

### Translating PDDL to FiFO with pddl2fifo

The program `lisp/pddl2fifo.lisp` translates a planning problem written in PDDL (the standard Planning Domain Definition Language) into a FiFO wff file in the form described above. It supports the PDDL requirements `:strips`, `:typing`, `:negative-preconditions`, `:disjunctive-preconditions`, `:constraints`, `:preferences`, and `:action-costs`. Action costs must be simple static numbers. They may be given either as an effect `(increase (total-cost) <number>)` or, more directly, as a `:cost <number>` slot on the action (a FiFO-specific convenience):

```lisp
(:action turn-off
   :parameters (?x)
   :precondition (on ?x)
   :effect (not (on ?x))
   :cost 2)
```

The two forms are equivalent; giving both on the same action is an error. The cost must be a constant number (a cost that varies with the action's parameters is not supported by either form).

#### Learning costs and weights from probabilities

Anywhere a cost or weight is specified, you can instead give a **`:probability <p>`** (with `0 < p < 1`) — the learnable alternative. The probability flows into the wff as a target marginal, is **tied** so related ground instances share one weight, and is learned by the weight pipeline. The three places, and what each becomes in the *learned* copy:

| Spec (in PDDL) | Where | `:probability` means | Tied | Becomes |
|---|---|---|---|---|
| action `:probability p` | domain | P(the action occurs, per slice) | per action schema | action `:cost w` |
| `(preference n body :probability p)` | instance (in `:goal`/`:constraints`) | P(the preference is **satisfied**) | per preference | `(preference n body w)` |
| `(:fluent-cost lit :probability p)` | instance | P(the fluent holds, per slice) | per fluent | `(:fluent-cost lit w)` |

A cost/weight and a probability are alternatives for the same spec (not both at once); existing fixed costs/weights are left untouched. Learned weights may be **negative** (a signed cost — when the target probability favors the penalized state), which the forms now accept.

`bin/learn-pddl.sh` runs the whole pipeline: translate → instantiate (at a small `--numslices` horizon) → learn (`--method log-odds` (default) or `--maxent`) → write `<domain>_learned.pddl` and/or `<problem>_learned.pddl` (whichever carried probabilities) with each `:probability` replaced by the learned value. For example:

```lisp
(:action turn-on :parameters (?x) :precondition (not (on ?x)) :effect (on ?x) :probability 0.7)
;; after `learn-pddl.sh prob.pddl --domain dom.pddl`:
(:action turn-on :parameters (?x) :precondition (not (on ?x)) :effect (on ?x) :cost -85)
```

Run `learn-pddl.sh --help` for all options. With `--maxent` the problem must be feasible at the chosen `--numslices`; log-odds is horizon-independent.

With `:disjunctive-preconditions`, the problem `:goal` may be a general goal description built from `and`, `or`, `not`, and `imply` over the goal atoms, not just a conjunction of literals. For example `(:goal (or (at pkg1 a2) (at pkg1 l1)))` is satisfied by a plan that achieves either disjunct. The reachability lower bound used to default `minslices` is weakened to stay admissible for disjunctive goals (it requires only the cheapest disjunct to be reachable). Note that even though `:disjunctive-preconditions` is accepted, only disjunctions in the goal are supported: a disjunctive or quantified precondition on an `:action` is rejected with an error.

#### Trajectory constraints

With `:constraints`, the problem may carry a `(:constraints ...)` section of hard state-trajectory constraints over the plan's slice timeline (slice 1 is the initial state, `numslices` the final state). The contents are a single modal formula or an `and` of them. Four operators are supported:

| Constraint | Meaning | Encoding |
|---|---|---|
| `(always φ)` | φ holds in every state | `(all s slices true (holds φ s))` |
| `(at-end φ)` | φ holds in the final state | `(holds φ numslices)` |
| `(hold-during t1 t2 φ)` | φ holds in every state of the inclusive slice window `[t1, t2]` | `(all s slices (and (>= s t1) (<= s t2)) (holds φ s))` |
| `(occur-sometime t1 t2 a)` | the ground action `a` occurs at some slice in `[t1, t2]` | `(exists s actslices (and (>= s t1) (<= s t2)) (occurs a s))` |

Here φ is a state description (a literal, or an `and`/`or`/`not`/`imply` combination of literals) and `a` is a fully instantiated action term, e.g. `(fly-airplane p1 a1 a2)`. The time bounds `t1`/`t2` are inclusive integer slice numbers. `occur-sometime` is a FiFO-specific extension (it has no standard PDDL counterpart). Constraints only restrict the set of valid plans, so they do not change the reachability lower bound on `minslices`. φ must refer to dynamic fluents (predicates that some action adds or deletes); a constraint over a static predicate, or any unsupported operator, is rejected with an error. For example:

```lisp
(:constraints
   (and
      (always (not (at pkg1 l2)))            ; pkg1 never passes through l2
      (hold-during 1 2 (in pkg1 t1))         ; pkg1 stays in t1 for the first two slices
      (occur-sometime 4 5 (fly-airplane p1 a1 a2))))  ; that flight happens in slice 4 or 5
```

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

The plan must reach the goal *and* respect both constraints, so the planner holds the plane in Washington and fires the flight at the earliest allowed step (3, landing in Boston at step 4), while `pkg1` — which starts at Boston and is never moved — satisfies the `hold-during` window. Recall the windows use absolute slice numbers and do not raise the reachability bound, so ensure the search horizon reaches them (here the `occur-sometime` window already forces a horizon of 4); the `hold-during` body must name a dynamic fluent.

#### Preferences (soft goals and soft constraints)

With `:preferences`, the `:goal` and `:constraints` sections may contain `(preference <name> <body> [<weight>])` forms. A preference is a *soft* requirement: a plan need not satisfy it, but each violation adds its weight to the plan metric. A preference in the `:goal` has a state-description body (satisfied iff it holds in the final state); a preference in `:constraints` has a trajectory-constraint body (one of the four operators above). To prefer that something *not* hold, negate the body (e.g. `(preference tidy (not (at junk depot)) 5)`); weights are always non-negative penalties, so a negative weight is an error.

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

- Defines a universal `objects` domain plus one FiFO domain per PDDL type. A type's domain contains the objects declared with that type or any of its subtypes, following the `(:types ...)` hierarchy; objects and parameters left untyped fall back to `objects`. Each PDDL action schema is translated into a quantified `observed` formula asserting `Pre`, `Add`, `Del`, and `Cost` facts, with each parameter quantified over its type's domain.
- Derives the `actions`, `fluents`, and `costs` domains from the observed facts using `collect`.
- Emits the time horizon as `(alias numslices (lisp ...))`, which evaluates to the Lisp variable `*satplan-numslices*` when it is bound to an integer and otherwise to `2`. Set the horizon without editing the output by binding `*satplan-numslices*` — e.g. `(setq *satplan-numslices* 10)` on the command line before `solve`/`instantiate`, or `(option *satplan-numslices* 10)` ahead of the alias — or edit the alias line directly.
- Ends with `(include "satplan.wff")` (or whatever `:satplan-path` was given), so the SatPlan axiom file must be reachable from the directory containing the output file.

Negative preconditions are translated into `PreNeg` observed facts, which the axioms in `satplan.wff` handle directly. Negative goals produce a `negative-goal-state` domain together with an axiom asserting those fluents are false at the final time slice.

`pddl2fifo` also runs a relaxed planning-graph reachability analysis on the problem and returns, as a second value, a lower bound on the number of time slices a plan needs (or `:unreachable` if the goals cannot be reached even in the relaxation). The planner uses this to choose its default horizon range; see *Running the planner* below.

Other example problems are provided. The untyped pair `SatPlan/Examples/Switch/switches.pddl` (domain) and `SatPlan/Examples/Switch/switchprob.pddl` (problem) exercises negative preconditions, negative goals, and action costs. The typed pair `SatPlan/Examples/TruckLog/trucklog.pddl` and `SatPlan/Examples/TruckLog/trucklogprob.pddl` is a logistics task using PDDL types, including a type hierarchy (`truck` is a subtype of `mobile`, and the drive action ranges over `mobile`).

### Running the planner

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

`--stop-after <wff|scnf>` halts the pipeline early, for inspecting or editing the intermediate files: `--stop-after wff` writes the `.wff` translation and stops (no instantiation or solving), and `--stop-after scnf` additionally instantiates it once — at `--numslices`, or the smallest/reachability horizon otherwise — writing the `.scnf` without solving.

The intermediate files the pipeline leaves behind (`.scnf`, `.cnf`, `.wcnf`, `.map`, `.satout`, `.soln`, `.answer`) can be cleared with `bin/cleanupfifo.sh [<dir>|<file>]` — it deletes those byproducts from a directory (the current one, the given directory, or the directory containing the given file), never touching source files like `.wff` or `.pddl`. Add `-r`/`--recursive` to clean subdirectories too (with care — it removes matching files anywhere below the target, including committed fixtures such as `*_gold.scnf`), and `--dry-run` to preview.

The logic lives in `lisp/planner.lisp`: `(plan problem &key minslices maxslices sat-solver weighted-solver domain-file satplan-path)` runs the search and returns the status, horizon, and answer-file path, and `(plan-and-report ...)` is the CLI helper the script calls. Load `lisp/FiFO.lisp`, `lisp/pddl2fifo.lisp`, and `lisp/planner.lisp` to call them from a Lisp listener.
