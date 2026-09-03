# FiFO 2.0 Users Guide

## Documentation

- $\color{red}{\textbf{README.md}}$ — the FiFO language reference and user guide.
- [software-components.md](software-components.md) - summary of FiFO scripts and all the systems for logical and probabilistic reasoning and scripts that FiFO uses.
- [SatPlan/satplan.md](SatPlan/satplan.md) — implementing SatPlan in FiFO: the PDDL translation and the planning/conditioning/marginal-inference driver.
- [Probability/probability.md](Probability/probability.md) — the probabilistic layer in practice: MAP inference, computing marginals under a weighted theory, and learning weights from target probabilities.
- [Probability/probability-background.md](Probability/probability-background.md) — the theory behind the probabilistic layer: learning across data regimes, sampling-based inference, and related work.
- [benchmarks.md](benchmarks.md) — measured results: horizons, CNF sizes, and compilation costs.
- [discussion.md](discussion.md) — discussion and open issues.

## Table of Contents

- [Example of FiFO](#example-of-fifo)
- [Installation](#installation)
- [Domains](#domains)
- [Functions and Equality](#functions-and-equality)
- [Static Predicates](#static-predicates)
- [Static Quantified Formulas](#static-quantified-formulas)
- [SAT solvers](#sat-solvers)
- [Constraint Satisfaction](#constraint-satisfaction)
- [Answer Extraction for Deduction](#answer-extraction-for-deduction)
- [Optimization (Weighted MaxSAT)](#optimization-weighted-maxsat)
- [Common Binary Relationship Patterns](#common-binary-relationship-patterns)
- [Options](#options)
- [Running FiFO](#running-fifo)
- [Testing](#testing)
- [Implementing SatPlan in FiFO](#implementing-satplan-in-fifo)
- [Using FiFO with Python](#using-fifo-with-python)
- [References](#references)

henry.kautz@gmail.com
---------------------

[GitHub Repository](https://github.com/HenryKautz/Schema2)

FiFO is a language for specifying logical theories using finite-domain first-order logic syntax. Because domains are finite, the language is a compact representation for propositional logic. The FiFO interpreter produces propositional CNF (conjunctive normal form) which can be input to any satisfiability testing program.

FiFO is a variant of Markov Logic (Richardson, M., & Domingos, P. (2006). Markov logic networks. *Machine Learning*, 62(1-2), 107-136). A weight or target probability may be attached to any formula (as in Markov Logic); a compound formula is reified into a fresh atom carrying the weight (see [Optimization](#optimization-weighted-maxsat)). Its main additions over Markov Logic are a richer set of operators for working with static predicates and domains.

The FiFO interpreter is written in Common Lisp, but it is not necessary to know how to program in Lisp in order to use FiFO.

## Example of FiFO

```
;; Define set domains boy, girl, and child
(domain boy (set jon alex max sam))
(domain girl (set mary sue ann june))
(domain child (union boy girl))
;; Three different children all love the same the same girl
(exists g girl true
		(exists (c1 c2 c3) (alldiff g c1 c2 c3)
				(and 
						(loves c1 g)
						(loves c2 g)
						(loves c3 g))))
```

## Installation

The repository is organized into `lisp/` (the interpreter, the SatPlan tools, the weight-learning pipeline, and the `satplan.wff` axioms) and `bin/` (the shell scripts). To install:

```sh
make install
```

This copies `bin/` into `~/bin` and `lisp/` into `~/lib/fifo/lisp`, creating the directories as needed. Override the destinations with `make install BINDIR=... LISPDIR=...`. Make sure `~/bin` is on your `PATH`.

The shell scripts locate the lisp code via the `FIFO_LISP` environment variable, which defaults to `~/lib/fifo/lisp` (the install location). To run from a source checkout without installing — or to point the tools at a non-default install — set `FIFO_LISP` to the directory containing `FiFO.lisp`, e.g. `FIFO_LISP=$PWD/lisp`.

You also need SBCL with Quicklisp, and a SAT solver on your `PATH` (`kissat` by default; see [SAT solvers](#sat-solvers)).

To fetch and build the solvers, run

```sh
bin/install-solvers.sh          # add --all to rebuild ones you already have
```

which clones each repository into `Solvers/`, builds it, and installs the binary into `~/bin`, skipping whatever is already usable and printing a summary of what succeeded and what failed. For information about installing other solvers for logical or probabilistic reasoning see [software-components.md](software-components.md#solvers-and-external-tools).

Common Lisp API
------------

Invoke any implementation of Common Lisp, and load the file `lisp/FiFO.lisp` (or `~/lib/fifo/lisp/FiFO.lisp` once installed). The following Lisp functions are available. All arguments after the first are Common Lisp keyword arguments, so they are supplied by name, e.g. `(instantiate "test.wff" :scnfile "test.scnf")` or `(interpret "test.out" :sort-by-time nil)`.

**(parse '(SCHEMA+) &key (static-list '(FACT+))) returns ((OR LITERAL+)\*)**  
Parse a list of schemas (see BNF syntax below) and return a list of symbolic ground clauses. Each FACT is a positive ground literal or a static quantified formula as described below. When the schemas are expanded, they are simplified by replacing static atoms by true and all non-static atoms that employ the same predicates by false. (`:observation-list` is accepted as a deprecated synonym for `:static-list`.)

**(instantiate "test.wff" &key scnfile staticfile)**  
Reads the FiFO file "test.wff", instantiates it, and saves the result in symbolic conjunctive normal form in the file given by `:scnfile`. The `:staticfile` file contains a sequence of static ground atoms. (`:obsfile` is accepted as a deprecated synonym for `:staticfile`.)

**(propositionalize "test.scnf" &key cnffile mapfile)**  
Reads the symbolic conjunctive normal form file "test.scnf" and creates a DIMACS format CNF file3 "test.cnf". In DIMACS format (the standard input language for all modern SAT solvers), propositions are represented by positive and negative integers. The mapping from symbolic ground atoms to integers is written to the file "test.map". The file "test.cnf" may then be sent to a SAT solver. When the output file name is not given explicitly and the problem is written in one of the WCNF formats (see Optimization), the default extension is `.wcnf` instead of `.cnf`. `propositionalize` returns the pathname of the cnf/wcnf file it wrote.

**(satisfy "test.cnf" &key satoutfile)**
The solver named by the variable **`*solver*`** (default `"kissat"`) is called on "test.cnf" and the output is captured in "test.out".  The run is bounded by **`*solver-timeout*`** (default 600 s; `0`, `-1` or `nil` for no limit), enforced with `SIGTERM` so an anytime MaxSAT solver still prints its best solution.  When **`*preprocessor*`** names a MaxPre 2 binary, the weighted CNF is preprocessed first and the model reconstructed afterwards.  Satisfy returns `'SAT`, `'UNSAT`, or `nil` when the solver gave no verdict.  The verdict is taken from the DIMACS `s` line first, falling back to a scan for the whole words SATISFIABLE / UNSATISFIABLE (or a line that is exactly SAT or UNSAT).  It deliberately does **not** look for the substring "SAT": every MaxSAT solver's banner contains it, so a run that printed a banner and no verdict would otherwise be read as satisfiable.

**(interpret "test.out" &key mapfile solnfile (sort-by-time t))**  
Reads in the output of a SAT solver "test.out" and a mapping file (`:mapfile`), and creates an answer file (`:solnfile`) containing the positive literals in the satisfying assignment in symbolic form. The file "test.out" specifies a solution by a sequence of positive and negative integers. The format of the file can be flexible; it can simply be a sequence of integers; or be in official DIMACS solution format where lines containing the integers begin with the letter "v"; or free-form text where lines containing only integers are assumed to be the solution. If for some integer, neither the integer nor its complement appears, then it is assumed to be false (negative) for the assignment. By default (`:sort-by-time t`) the results are sorted by the last argument to each predicate, which is often used to specify a time index; pass `:sort-by-time nil` to sort alphabetically instead.

The MaxSAT output format used by solvers such as `tt-open-wbo-inc` is also understood: the satisfiability status is taken from the `s` line, and the model is given as a single `v` line that is a bit string of length *numvar* (one `0`/`1` per variable) rather than a list of signed literals. When the output contains one or more `o <number>` (objective/cost) lines, the value from the last such line is written to "test.answer" as an atom of the form `(*objective* <number>)`, placed before the symbolic atoms.

**(solve "test.wff" &key solnfile staticfile solver cnf-format preprocessor preprocessor-techniques timeout)**
Reads in the FiFO file "test.wff" and an optional static facts file (`:staticfile`; `:obsfile` is accepted as a deprecated synonym), solves it and writes the results in symbolic form to the answer file (`:solnfile`).  If "test.wff" contains no **prove** formula, the sat solver will be called a single time.  If it does contain **prove**, then the sat solver may be invoked several times as described in the section below on Answer Extraction for Deduction.  The format of "test.answer" will be one of:

- If the formula does not contain a prove form and:
  - Is satisfiable: SAT followed by the positive ground literals in a satisying model.
  - Is unsatisfiable: UNSAT.

The solver keywords bind the corresponding globals for the call only, so they need not be set beforehand: `:solver` (abbreviations are resolved, so `:solver "nuwls"` works), `:cnf-format` (`CNF`, `WCNF` or `WCNF-OLD`), `:preprocessor`, `:preprocessor-techniques` and `:timeout`.  An `(option ...)` form inside the `.wff` runs while the file is parsed, so it still has the last word.

- If the formula contains a prove form and
  - Is satisfiable: COUNTEREXAMPLE followed by the positive ground literals in a counterexample (satisfying model).
  - Is unsatisfiable and answer extraction succeeds: PROVEN followed by a sequence of variable bindings. Each variable binding is of the form `(<variable> <value>)`
  - Is unsatisfiable but answer extraction failed: NOANSWER.


Language
--------

FiFO is a language for specifying logical theories using finite-domain first-order logic syntax.  Because domains are finite, the FiFO interpreter compiles its input into propositional logic for solution by any SAT solver. A FiFO program consists of a sequence of options, domain declarations, and formulas. Options control certain details of the interpreter. Domain declarations bind domain names to sets of Herbrand terms.  Domains may share elements.  No domain declarations are associated with predicates; every predicate may accept terms of any domain as arguments.  It is also permissible for different instances of predicates to take different number of arguments.

Formulas are composed, as in first-order logic, of predicates, variables, constants, function symbols, logical connections, and quantifiers. The basic function of the FiFO interpreter is to instantiate the variables in each formula and convert the result to CNF.

Formulas and terms are specified in prefix (LISP) notation. The quantifiers, all and exists, iterate over sets of Herbrand terms. Terms are numbers, constants, or complex terms built using uninterpreted function symbols. A quantified formula is represented by a list containing the quantifier, a variable, a set of terms, a test (numeric) expression, and the subformula to which the quantification is applied. The subformula is instantiated only for bindings of the variable for which the test is true. For example,

```
(all x (range 1 10) (= 0 (mod x 2)) (p x))
```

can be read, "for all x in the range 1 through 10, such that x is even, assert (p x)".

Propositions are expressed in FiFO as either atomic symbols or complex propositions specified by a list beginning with a predicate followed by zero or more terms.  The special proposition "true" and "false" have the expected meaning.  Terms can be built from interpreted functions such as + and uninterpreted function symbols. For example, the literal expression (winner john (round (\* 3 8))) is instantiated as

```
(winner john (round 24))
```

where "winner" is a predicate, "john" is a simple term, "round" is an uninterpreted function symbol, and "(round 24)" is a complex term.

Any non-zero numeric value is treated as true and zero (0 or 0.0) is treated as false in numeric expressions. The special constants "true" and "false" are equivalent to 1 and 0 respectively when they appear in numeric expressions. Numeric expressions may include integer or floating-point literals, arithmetic functions (+, -, \*, div, rem, mod), comparison functions (<, <=, =, >=, >, member, eq, neq, alldiff), set composition functions (enumerated sets, ranges, union, intersection, set-difference), logical functions (and, or, not), and static predicates. Non-static predicates may not appear in a numeric expression. Note that logical operators in numeric expressions are evaluated by the FiFO interpreter and do not appear in the final CNF, unlike the logical operators that have the same names. When a numeric value is a whole number (e.g. 2.0), it is written as a plain integer (2) in the scnf output.

Comments can appear in the input.  They begin with ;; (double semicolon) and extend to the end of the line.

## Domains

A  **domain** declaration defines a domain name as a set of of ground terms.  Terms can appear in more than one domain.  Domains are used to expand quantified **all** and **exists** forms, but predicates themselves do not have domain constraints on their arguments.  Examples of domain declarations:

```
(domain fruit (set apple orange banana))
(domain berry (set carrot cabbage))
(domain plant (union fruit vegetable))
```

The for operator is used to compactly create a set of non-atomic ground terms.  Consider a problem where we wish to define a domain Node that contains 100 terms.  Instead of listing the names of the terms individually as in the previous section, we can write:

```
(domain node (for i (range 1 100) (= 0 (mod i 2)) (set (n i))))
```

This defines Node as a set containing the terms (n 2), (n 4), and so on up to (n 100).

The **collect** operator builds a domain by pattern-matching against static predicates:

```
(collect <variable> (<static-predicate> <term-pattern>+))
```

A `<term-pattern>` is like a term but may contain the variable itself or the wildcard symbol `*`. Both are treated as wildcards when matching against the set of static propositions. The form returns the set of ground terms that the variable matched across all static literals that fit the pattern. The result never contains duplicates.

For example, given static facts `(edge n1 n2)`, `(edge n2 n3)`, `(edge n3 n4)`:

```
;; Collect all source nodes of static edges
(domain sources (collect x (edge x *)))   ; {n1 n2 n3}

;; Collect all target nodes
(domain targets (collect x (edge * x)))   ; {n2 n3 n4}

;; Self-loops only (variable appears twice — both must agree)
(domain self-loops (collect x (edge x x)))   ; {} — no static self-loop facts
```

The variable can be nested inside a compound term pattern. In that case the term at that position (not the outer compound) is what gets collected:

```
;; Given (at (truck 1) (place 1)) and (at (truck 2) (place 2)) are static facts:
(domain truck-ids (collect i (at (truck i) *)))   ; {1 2}

;; Collect whole compound terms that fill a pattern position:
(domain trucks-at-p1 (collect x (at x (place 1))))   ; {(truck 1)}
```

`collect` is especially useful in SatPlan-style encodings for deriving action sets directly from static `Pre`/`Add`/`Del` facts rather than enumerating them manually.

While **domain** gives a name to a set of terms, **alias** gives a name to a single term, as in the following example.

```
(alias limit 100)
(domain node (for i (range 1 limit) true (set (n i))))
```

Care needs to be taken in translating problems stated in English.  Consider the problem:

> Some cars are Fords.
> Some cars are reliable.
> Are Fords reliable?

Translating this as

```
(domain Cars (set Ford))
(exists x Cars true (reliable x))
;; Negated conclusion
(not (reliable Ford))
```

This formula is unsatisfiable, and so one concludes that Fords are reliable.  The second line in the input expands to `(reliable Ford)` because Ford is the only known member of the domain Cars.  A better translation of the problem would include some other anonymous member of domain Car which might be the reliable brand; for example,

```
(domain Cars (set Ford CarBrand02))
(exists x Cars true (reliable x))
;; Negated conclusion
(not (reliable Ford))
```

This formula is satisfiable, so the unwanted conclusion does not hold.

## Functions and Equality

FiFO includes both interpreted and uninterpreted functions.  Interpreted functions include mathematical operations and set operations.  A term that does not begin with the name of an interpreted function is taken to be an uninterpreted function.  Thus, the formula using the interpreted function + and the uninterpreted function symbol `vertex`

```
(all i (range 1 3) true (edge (vertex x) (vertex (+ x 1))))
```

is expanded to

```
(edge (vertex 1) (vertex 2))
(edge (vertex 2) (vertex 3))
(edge (vertex 3) (vertex 4))
```

As in logic programming, ground terms refer to themselves, or in other words, formulas are interpreted over a Herbrand universe.  The predicates **eq** and **neq** check for syntactic equality at the time that formulas are instantiated.  The mathematical comparison predicates cited above check for numeric equality at instantiation time.  There is no semantic equality operator that would allow one to assert that two different Herbrand terms refer to the same entity.

## Static Predicates

Static predicates are useful for describing fixed relationships in a problem instance. The true ground literals for such predicates are specified in a list provided to the FiFO interpreter.  The interpreter will then assume that all other literals for the predicates that appear in that list are asserted to be false.

For example, consider representing problems about a graph. The static facts would specify edges in the graph, for example:

```
(edge N1 N2)  
(edge N3 N4)  
(edge N3 N5)
```

Making "connected" a static predicate has several advantages:

- The closed world assumption is automatically applied to the predicate. In the example above, (not (connected R1 R5)) is implicitly asserted.
- The predicate may be used inside test expressions.
- The instantiated formula is smaller because static literals are compiled away.

A predicate can be declared to be static in two ways. The **static** form can be used to specify it's positive literals.  These should appear before any other formulas are asserted.  For example:

```
(domain Node (set N1 N2 N3 N4 N5))
(static 
	(edge N1 N2)  
	(edge N3 N4)  
	(edge N3 N5))
```

For backward compatibility, the keyword **observed** is accepted as a deprecated synonym for **static** (static predicates were originally called "observed predicates").

An alternative way to declare static predicates and their true literals is to include the list of static literals as an optional argument for the LISP API.  In this case, no explicit static declaration is used.

## Static Quantified Formulas

Quantified formulas can appear as static facts with the restriction that only the forms **all**, **and**, **if**, and positive literals may appear in the body of a quantified formula.  For example, the following first defines a domain of 10 cells, and in the first static formula asserts that the i-th cell is smaller than the i+1st cell.  The second static formula asserts that smaller is transitively closed.

```
(domain cell (for i (range 1 10) true (set (cell i))))

(static
 (all i num (< num limit) (smaller (cell i) (cell (+ 1 i))))
 (all (a b c) cell (and (smaller a b) (smaller b c)) 
      (smaller a c))
 )
```

Note that the expression (and (smaller a b) (smaller b c)) appears as a *test* in the innermost **all**.  Recall that this is valid because static literals can appear in a test.  Evaluating the form can add additional pairs to the static predicate "smaller".  The FiFO program therefore re-evaluates *every* static quantified formula if *any* such formula adds a *new* static literal.  

## SAT solvers

The `solve` pipeline and the planner's feasibility phase use a plain (non-weighted) SAT solver that reads DIMACS CNF. The default is `kissat`, but any solver with the same command-line behavior can be selected — with `(solve "problem.wff" :solver <name>)`, `(setq *solver* "<name>")`, `solve.sh --solver`, or the planner's `SAT_SOLVER` / `--solver` setting. A `.wff` cannot choose its own solver; see [Solving policy is the caller's](#solving-policy-is-the-callers).

The catalog of solvers FiFO can use — SAT solvers, weighted MaxSAT solvers, model counters, knowledge compilers, and the MC-SAT sampler — with what each one does, where to get it, and installation notes, is in [software-components.md](software-components.md#solvers-and-external-tools).

## Constraint Satisfaction

Discrete constraint satisfaction problems (CSPs) can easily be represented in FiFO.  The answer can be read off from the symbolic form of the SAT solution generated by the interpret function.

As an example, consider graph 3-coloring: assign one of three colors to each node of a graph so that no two adjacent nodes share a color.  The graph is specified using a static predicate `edge`, giving the closed-world assumption that unlisted edges do not exist.  Nodes are given colors using a predicate `color`, and two schemas assert (1) every node gets exactly one color and (2) adjacent nodes get different colors.

```
(domain Color (set Red Blue Green))
(domain Node (set a b c d e))

;; Undirected edges (pentagon a-b-c-d-e-a plus chord b-d)
(static
  (edge a b) (edge b a)
  (edge b c) (edge c b)
  (edge c d) (edge d c)
  (edge d e) (edge e d)
  (edge e a) (edge a e)
  (edge b d) (edge d b))

;; Every node gets exactly one color
(all x Node true (exists c Color true (color x c)))
(all x Node true
  (not (exists (c1 c2) Color (neq c1 c2)
        (and (color x c1) (color x c2)))))

;; Adjacent nodes must have different colors
(all (x y) Node (edge x y)
  (not (exists c Color true (and (color x c) (color y c)))))
```

Running `solve` on this problem yields a satisfying 3-coloring, for example:

```
SAT
(COLOR A BLUE)
(COLOR B RED)
(COLOR C BLUE)
(COLOR D GREEN)
(COLOR E RED)
```

Deduction 
---------------------------------------

Satisfiability testing can be used for deduction by negating the conclusion to be drawn from a set of assumptions. For example, suppose that Bob is shorter than Alice, Alice is shorter than Charlie, and shorter is transitive. Can you conclude that there is someone who is shorter than two other people? This problem could be encoded in FiFO as follows for proof by refutation.  The (unnegated) conclusion holds if the formula is unsatisfiable.

```
(domain Person (set Alice Bob Charlie))  
(shorter Alice Bob)  
(shorter Bob Charlie)  
(all (x y z) Person true (implies (and (shorter x y) (shorter y z)) (shorter x z)))  
(not (exists (x y z) Person (neq y z) (and (shorter x y) (shorter x z))))
```

FiFO provides an alternative way of encoding a deduction problem by using the **prove** construct.  In this case, the last line above would be replaced by:

```
(prove () true (exists (x y z) Person (neq y z) (and (shorter x y) (shorter x z))))
```

Note that the formula to be deduced is not negated.  Use of prove makes the goal of the FiFO problem clearer to a user.  

## Answer Extraction for Deduction

 Suppose we want to also *derive* the constant for person who is shorter than two other people. FiFO provides the operator "prove" to support answer extraction from proofs of unsatisfiability. A single prove operation may appear as the last schema in the list of input schemas. The last schema in previous example would be changed to:

```
(prove ((x Person)) true (exists (y z) Person (neq y z) (and (shorter x y) (shorter x z))))
```

Prove can also be used to extract the bindings for several variables by specifying a series of variables and domains in the operator. For example, suppose the problem involves people and jobs, and states that all mechanics are also drivers and Alice is a mechanic. We wish to find a person with two jobs and the names of those jobs.

```
(domain Person (set Alice Bob))  
(domain Job (set Mechanic Driver Programmer))  
(all x Person true (and (works x Mechanic) (works x Driver)))
(works Alice Mechanic)  
(works Bob Programmer)  
(prove ((p Person) ((j1 j2) Job)) (neq j1 j2) (and (works p j1) (works p j2)))
```

Schema performs binary search on each answer variable to find the answer bindings.  Suppose the first variable is $t_1$. The parser makes $t_1$ universally quantified over half of its domain and variables $t_2, t_3, ...$ universally quantified over their full domains.  If this formula is satisfable, it repeats the process but making $t_1$ universally quantified over a quarter of its domain.  If the formula is unsatisfiable, then the process is repeated with $t_1$ universally quantified over the other half of its domain.  Eventually the process will fail or result in an answer binding for $t_1$.  The parser then continues on to search for a binding for $t_1, t_2$, etc. The maximum number of wffs returned by GetCNF before it returns FAIL or DONE, and thus the maximum number of calls to a SAT solver, is $\sum{\log|T_i|}$ where $T_i$ is the domain of answer variable $i$.  Note that is this is an improvement over a naive implementation of answer extraction which would be $\prod |T_i|$.

Compact Encodings
-----------------

The input formulas need not be in conjunctive normal form. Converting a formula to CNF using only the user-defined propositions can cause its size to increase exponentially. By creating new propositions, the FiFO interpreter can guarantee the size of the output CNF formula is only exponential in the nesting of quantifiers. Specifically, where

> M = number of input formulas  
> L = length of the longest input formula  
> D = size of the largest set appearing in a quantification statement  
> N = deepest nesting of quantifiers in a formula

the size of the output CNF is $O(MLD^N)$.

When new propositions are introduced in this manner, the relationship between the input and output formulas is that the output formula entails the input formula and any model of the input formula can be extended to a model of the output formula.

## Optimization (Weighted MaxSAT)

FiFO supports weighted optimization problems via the **weight** form:

```
(weight <formula> <number>)
```

This asserts that if `<formula>` is true in a satisfying assignment, it contributes `<number>` to the objective. A MaxSAT or pseudo-Boolean optimizer can then minimize the total weight of true formulas subject to satisfying all clauses. The argument is most often a literal, but may be any formula (see **Formula-valued weights** below).

Unlike clauses, weight assertions are not wrapped in `OR` in the `.scnf` file — they appear as bare `(WEIGHT literal number)` lines after all clause lines.

A simple example:

```
(domain item (set banana steak milk))
(weight (buy banana) 1.25)
(weight (buy steak) 15.50)
(weight (buy milk) 3.10)
;; Must buy at least one item
(or (buy banana) (buy steak) (buy milk))
```

The `.scnf` output separates clauses from weights:

```
(OR (BUY BANANA) (BUY STEAK) (BUY MILK))
(WEIGHT (BUY BANANA) 1.25)
(WEIGHT (BUY STEAK) 15.5)
(WEIGHT (BUY MILK) 3.1)
```

**Placement rules.** A `weight` form may appear:

- At the top level of a `.wff` file.
- In the body of `and`, `all`, `exists`, or `if` — nested arbitrarily. For example, the following assigns a weight to every member of a domain:

```
(all x items true (weight (cost x) 5.0))
```

And conditional weights work too:

```
(if (static-predicate arg) (weight (option arg) 2.5))
```

`weight` may **not** appear inside `or`, `not`, `implies`, or `equiv` — those contexts require formulas that produce clauses (a `weight`/`probability` form contributes none of its own). Using one there is an error.

**Formula-valued weights.** The argument may be an arbitrary formula, not just a literal:

```
(weight (and (buy bread) (buy jam)) 4.0)
(weight (or (late train) (late bus)) 2.0)
```

A compound argument is *reified*: FiFO mints a fresh atom `(WEIGHTED-FORMULA n)`, adds the hard biconditional `(WEIGHTED-FORMULA n) ⇔ <formula>`, and puts the weight on that atom. For `(weight (and a b) 4.0)` the `.scnf` is:

```
(OR (NOT A) (NOT B) (WEIGHTED-FORMULA 1))
(OR (NOT (WEIGHTED-FORMULA 1)) A)
(OR (NOT (WEIGHTED-FORMULA 1)) B)
(WEIGHT (WEIGHTED-FORMULA 1) 4)
```

Because the biconditional fully determines the fresh atom from the formula's own atoms, it constrains nothing else (it is *count-neutral* under weighted model counting), so the atom is true exactly when the formula is and the cost is charged exactly then. A literal argument is **not** reified — it still emits a bare `(WEIGHT <literal> w)` line, unchanged.

### Probabilities (target marginals)

Instead of stating a weight directly, you can state a **target marginal probability** with the **probability** form, and let the learning pipeline ([Probability/](Probability/)) compute the weight that realizes it:

```
(probability <formula> <p> [<tie-label>])
```

`<p>` is the desired probability (in `[0,1]`) that `<formula>` is true. `probability` is parsed and placed exactly like `weight` (top level, or in the body of `and`/`all`/`exists`/`if`), and `instantiate` passes it through to the `.scnf` as `(PROBABILITY <literal> <p> <gid>)`. A compound formula argument is reified the same way as for `weight` — `(probability (and a b) 0.3)` targets `P((and a b)) = 0.3` on the fresh atom `(WEIGHTED-FORMULA n)`, whose marginal equals the formula's probability. (These internal atoms are hidden from the default `marginals` listing but shown under `--weighted-only`, where their marginal is exactly `P(formula)`.)

**Tie groups.** Every ground instance of one source `probability` form shares a **tie-group id** `<gid>`, so the learner fits **one** weight for the whole group (parameter tying — see [Probability/probability-background.md](Probability/probability-background.md)). By default each `probability` form is its own group (an auto-assigned integer); an optional trailing symbol `<tie-label>` overrides this to merge forms into a shared group or split them. For example, `(all x items true (probability (faulty x) 0.05))` gives every `(faulty x)` the same target and the same learned weight.

A `.scnf` containing `(PROBABILITY ...)` forms carries *target probabilities, not weights*, so `propositionalize` rejects it with an error: convert it to a weight-only file first with the learning pipeline. That pipeline can also write the learned weights back into a copy of the source `.wff` (replacing each `probability` form with the tied `weight`), which you can then edit and re-instantiate at a different domain size. See [Probability/probability.md](Probability/probability.md).

### Weighted CNF output formats

`*cnf-format*` controls how weights appear in the DIMACS file produced by `propositionalize`. It has no effect when the problem contains no weights. Set it with `(solve "problem.wff" :cnf-format <format>)`, `(setq *cnf-format* '<format>)`, or by choosing the right driver — `solve.sh` fixes `CNF` and `map.sh` fixes `WCNF`.

`instantiate` reads `*cnf-format*` and records its decision in the `.scnf` as a trailing `(OPTION WEIGHTS <format>)` line, and that line — not the global — is what `propositionalize` reads back. To emit one existing `.scnf` in a different dialect, override the recorded line with `propositionalize`'s own `:cnf-format` argument:

```lisp
(propositionalize "problem.scnf" :cnf-format 'CNF   :cnffile "sat.cnf"  :mapfile "p.map")
(propositionalize "problem.scnf" :cnf-format 'WCNF  :cnffile "map.wcnf" :mapfile "p.map")
```

Without the argument the file's own recorded format is used, so the round trip through a `.scnf` is faithful by default.

**`cnf`** (the default) writes a standard `p cnf` file followed by one `cw <literal> <weight>` line per weight. Since these lines begin with the letter `c`, ordinary SAT solvers treat them as comments, so the file remains valid input for solvers like kissat (which simply ignore the weights).

**`wcnf-old`** writes the classic DIMACS weighted CNF format used by MaxSAT solvers: a header `p wcnf <vars> <clauses> <top>`, where every clause line begins with its weight. Hard clauses (the ordinary clauses of the problem) carry the weight `top`, which exceeds the sum of all soft weights.

**`wcnf`** writes the new DIMACS format adopted by the MaxSAT Evaluation in 2022: no `p` header; hard clauses begin with `h`, and soft clauses begin with their weight.

In both wcnf formats, a weight *w* on literal *L* (the cost of making *L* true) becomes the soft unit clause ¬*L* with weight *w*, which a MaxSAT solver pays for exactly when *L* is true. Because these formats require weights to be positive integers, two transformations are applied:

- **Shift**: for each atom, the minimum of its total weight when true and its total weight when false is subtracted from both, so at most one polarity retains a (positive) weight. This also eliminates negative weights: a reward for making a literal true becomes a cost for making it false. The discarded total is a constant offset on the objective, reported in a comment line `c weight shift offset <n>`.
- **Scale**: all weights are multiplied by the smallest positive integer making them integral (e.g., weights 0.4 and 2 are scaled by 5 to 2 and 10), reported in a comment line `c weights scaled by <n>`.

The true cost of a solution is the MaxSAT solver's reported cost divided by the scale, plus the offset. Note that `solve` runs whichever binary `*solver*` names, and the default (`kissat`) is an ordinary SAT solver that will not accept a wcnf file — so a weighted problem needs a MaxSAT solver alongside a weighted format. Both are the caller's to set, together:

```lisp
(solve "problem.wff" :cnf-format 'WCNF :solver "tt-glucose")
```

or simply `map.sh problem.wff`, which pins the pair for you and refuses a solver of the wrong kind. With both set, `solve` performs MAP inference end to end and `interpret` reports the objective; see [Probability/probability.md](Probability/probability.md#map-inference-the-most-probable-model).

### Weighted CNF solvers

The MaxSAT solvers FiFO can drive — TT-Open-WBO-Inc (the default), NuWLS-c, RC2 via PySAT, MaxHS, and CP-SAT — are cataloged in [software-components.md](software-components.md#weighted-maxsat-solvers), with sources and installation notes. Driving one end to end to get the most probable model is covered in [Probability/probability.md](Probability/probability.md#map-inference-the-most-probable-model).

`solve` also takes the solver settings as keyword arguments, which bind the corresponding globals for that call only:

```lisp
(solve "problem.wff" :solver "nuwls" :cnf-format 'WCNF :timeout 120)
```

The keywords are `:solver`, `:cnf-format`, `:preprocessor`, `:preprocessor-techniques`, and `:timeout`. An `(option ...)` form inside the `.wff` is executed while the file is parsed, so it still has the last word — exactly as it does over a prior `setq`.

### Solver time limits

Anytime MaxSAT solvers do not stop on their own: they keep improving until they are stopped, and print the best solution found so far when they receive `SIGTERM`. That is how the MaxSAT Evaluation harness runs them — NuWLS-c's own submission wrapper is simply `timeout -s 15 $wl ./nuwls-c_static $1` — and it is how FiFO runs them too. Neither TT-Open-WBO-Inc nor NuWLS-c accepts a time limit as a command-line flag, so the limit is enforced externally.

`*solver-timeout*` (default **600** seconds) bounds every solver invocation. When it expires FiFO sends `SIGTERM`, waits `*solver-kill-grace*` seconds (default 10) for the solver to flush its answer, and only then sends `SIGKILL`. A run that is cut short prints a note and still yields the best model the solver had reached:

```
; solver nuwls-c stopped after the 120 s limit (*solver-timeout*);
; reporting the best solution it had found
```

Set the limit to `0`, `-1`, or `nil` to disable it entirely. Because the limit applies to *every* solver call, including the plain SAT solver used by the planner's feasibility search, lowering it materially will cut off long searches — the note above is the signal that this has happened.

### Preprocessing with MaxPre 2

Setting `*preprocessor*` to a [MaxPre 2](https://bitbucket.org/coreo-group/maxpre2/src/master/) binary inserts a preprocessing pass in front of the solver:

```lisp
(solve "problem.wff" :cnf-format 'WCNF :solver "tt-glucose" :preprocessor "maxpre")
```

FiFO runs `maxpre <file> preprocess -mapfile=…` to produce a simplified instance, solves *that*, and then runs `maxpre <solution> reconstruct -mapfile=…` to map the model back.

**The reconstruction step is not optional bookkeeping.** MaxPre eliminates and renumbers variables — on the small grocery example above it collapses three variables to one — so a model of the preprocessed instance means nothing in the original variable space that the `.map` file describes. Interpreted directly it does not fail; it silently names the wrong atoms. FiFO always reconstructs before `interpret` sees the file.

Two details are handled for you. MaxPre's `reconstruct` parses only `s OPTIMUM FOUND`, and reports `Failed to parse solution` on the `s SATISFIABLE` an anytime solver prints when it has not proved optimality; it also emits an uninitialised objective if no `o` line is present. FiFO therefore normalises the solver's output to `o`/`s`/`v` before calling it, and restores the solver's own status line afterwards, so the reported status still reflects what was actually proved.

**MaxPre is for optimization only — never for probabilities.** Its techniques (bounded variable elimination, blocked clause elimination, subsumption) preserve the optimum cost and an optimal model, but they do not preserve the *number* of models, so they change `Z` and every marginal derived from it. The marginal-inference back ends never go through this path — they read the `.scnf` directly — and preprocessing a plain (unweighted) `CNF` is rejected with an error rather than silently attempted.

### Weight Learning

For a discussion about learning weights in FiFO, see [Probability/probability-background.md](Probability/probability-background.md).

For the implemented learning pipeline — turning target marginal probabilities into integer literal weights — and how to run it, see [Probability/probability.md](Probability/probability.md).

The driver `bin/learn.sh` wraps the pipeline: it reads an instantiated `.scnf` of `(PROBABILITY ...)` targets and writes a reweighted `.scnf` of integer `(WEIGHT ...)` costs (and, with `--wff`, a weighted copy of the source `.wff`). It selects the estimator with `--method log-odds` (default) or `--maxent`. Run `learn.sh --help` for the full list of options.

```sh
# log-odds reweight, also writing the weights back into a copy of the source wff
bin/learn.sh myproblem.scnf --wff myproblem.wff

# exact tied max-ent (small instances), custom output
bin/learn.sh myproblem.scnf --maxent --out learned.scnf
```

### Marginal Inference and Weighted Model Counting

Weight learning runs in the *inverse* direction of inference: it turns target marginal probabilities into weights. Going forward — weights to marginals — is **marginal inference**, the probability that each atom is true under the weighted theory `P(x) ∝ exp(−(sum of the weights of the true literals))` over the feasible set. Two back ends compute this exactly:

- **`bin/marginals.sh problem.scnf`** — Lisp enumeration of the feasible set. Exact, simple, but exponential; intended for small instances. `--weighted-only` restricts it to the weighted atoms.
- **`bin/marginals.sh problem.scnf --solver addmc`** — the same marginals via the **ADDMC** weighted model counter (algebraic decision diagrams), which scales far past brute enumeration. (`--solver maxent`, the enumeration above, is the default.) **`bin/wmc.sh problem.scnf`** prints just the partition function `Z` (a weighted model count).

Two further exact back ends compile the theory into a d-DNNF circuit and read *all* marginals off it in two passes — `--solver ddnnf` (FiFO's own compiler, no external binary) and `--solver d4` (the same circuit machinery, with the Boolean structure compiled by the external d4 compiler). Past the reach of exact counting there is an **approximate** back end:

- **`bin/marginals.sh problem.scnf --solver mc-sat`** — **MC-SAT** sampling (Poon & Domingos 2006), an MCMC chain whose stationary distribution is exactly the weighted theory's. One run yields every marginal, so it returns in seconds on instances the exact counters cannot finish; the results carry Monte-Carlo error, so fix `--seed` for reproducibility and raise `--samples` for accuracy. Each run also reports its effective sample size — MC-SAT mixes poorly on strongly coupled models, and a very low reported efficiency means the marginals are unreliable rather than merely noisy. This needs **WalkSAT version 58 or later** ([gitlab.com/HenryKautz/Walksat](https://gitlab.com/HenryKautz/Walksat), the `Walksat_v58_MC-SAT` directory), whose `-mcsat` mode carries the whole sampler in C; put it on `PATH` as `walksat`.

ADDMC is a separate executable — a macOS fork at [github.com/HenryKautz/ADDMC](https://github.com/HenryKautz/ADDMC) (of [vardigroup/ADDMC](https://github.com/vardigroup/ADDMC)). Build it and put `addmc` on `PATH` (`bin/install-solvers.sh --only addmc` does both). A handy way to produce the `.scnf` input is `bin/planner.sh <problem.pddl> --stop-after scnf`. ADDMC counts at full double precision by default; `--epsilon <e>` exposes its CUDD terminal-merging tolerance to trade exactness for speed.

For **conditional** probabilities, `--solver addmc` (and likewise `ddnnf`, `d4`, and `mc-sat`) accepts `--evidence '<ground formula>'` (repeatable) and `--evidence-file <f>`: the ground FiFO formula is clausified and conjoined with the theory as a hard constraint, so each reported marginal becomes `P(atom | evidence)` (and `wmc.sh` returns the conditioned partition function). Quantified evidence isn't ground, so it belongs at the `.wff` level (add the assertion and re-instantiate).

Because the learning pipeline scales costs by an integer factor (100 by default, set with `learn.sh --scale`) to get integer MaxSAT weights — and the absolute scale, irrelevant to MaxSAT, completely changes a probability distribution — both tools divide the integer weights by the `scale: N` recorded in the `.scnf` header before exponentiating, so the marginals reflect the *real* learned costs (use `--scale 1` for the raw weights). For the encoding details (MCC weighted CNF), the cross-check against enumeration, the weight-scale issue, and the cost model, see [Probability/probability.md](Probability/probability.md).

## Common Binary Relationship Patterns

Suppose R is a binary relation.  Properties of R can be asserted as follows.

### R is a strict order

Suppose R is a relation over pairs of domain E

```
;; R is a strict order
(all (x y z) E true (implies (and (r x y) (r y z)) (r x z))))
(all x E (not (R x x)))
```

### R is a strict total order

```
;; R is a strict total order
(all (x y z) E true (implies (and (r x y) (r y z)) (r x z))))
(all x E true (not (R x x)))
(all (x y) E (neq x y) (or (R x y) (R y x)))
```

### R is functional

We say that a relationship over domains E and V is functional if for every E there is exactly one V such that R holds.  Functional relations are often used when E is a set of entities and V is a set of possible values of some property of the entities.

```
;; R is functional
(all x E true (exists y V true (R x y)))
(all x E true (not (exists (y z) V (neq y z) (and (R x y) (R x z)))))
```

### R is a bijection

We say that a relationship over domains E and V is a mapping if (1) R is functional (2) R is onto, meaning for every V there is some E related to it by R, and (3) R is one-to-one, meaning no two E are related to the same V.  Bijections are often used in representing matching problems where a set of entities must be matched to a set of unique values.

```
;; R is a bijection
;; (1) R is functional
(all x E true (exists y V true (R x y)))
(all x E true (not (exists (y z) V (neq y z) (and (R x y) (R x z)))))
;; (2) R is onto
(all y V true (exists x E true (R x y)))
;; (3) R is one to one
(not (exists (x1 x2) E (neq x1 x2) (exists y V true (and (R x1 y) (R x2 y)))))
```

## Options

The input to FiFO may include the following options, which should appear before any formulas.  Each option name is also the name of the corresponding Lisp global variable, so the same name works in both `(option ...)` forms and `setq` on the command line.

```
; Allow new propositions to be created to reduce the size of the instantiated formula (default).
(option *compact-encoding* 1)
; Do not create new propositions.
(option *compact-encoding* 0)

; Enable tracing: prints [TRACE] lines showing domains, variable bindings, and clause counts.
(option *tracing* 1)
; Disable tracing (default).
(option *tracing* 0)

; Time horizon for SatPlan problems generated by pddl2fifo (see the Planning section).
; Must be an integer.  Set this before the (alias numslices ...) line that reads it.
(option *satplan-numslices* 10)
```

When tracing is enabled, the interpreter prints diagnostic output to standard output as it works:

- `[TRACE] Domain NAME = (val ...)` -- each domain as it is defined
- `[TRACE] Formula: (OP ...)` -- each top-level formula entering the parser
- `[TRACE] ALL/EXISTS/FOR VAR = VAL` -- each variable binding tried by a quantifier
- `[TRACE] Multiply: N x M -> K clauses` -- clause counts at each OR-distribution step

The multiply trace is especially useful for diagnosing exponential clause blowup. When compact encoding is disabled, each multiply step performs a full cross-product; the clause count shown will grow multiplicatively. With compact encoding enabled, auxiliary propositions are introduced and the count grows only linearly.

### Summary of all options

Every option is a Lisp global variable whose name is the same in both forms. There are two ways to set one:

- **In a `.wff` file**, with an `(option <name> <value>)` form placed before any formulas.
- **On the command line**, with an `--eval '(setq <name> <value>)'` form (or `(set ...)` for an unbound variable) given to `sbcl` after `--load FiFO.lisp`. A command-line setting persists for the whole Lisp session; an `(option ...)` form in a file overrides it when that file is processed.

The two forms differ only in how some values are written: booleans use `1`/`0` in a file but `t`/`nil` on the command line, and list-valued options are written unquoted in a file but must be quoted (`(quote ...)`) for `setq`.

Only the options below may appear in a `.wff`. They all shape *what problem gets generated*; anything that says *how to solve it* belongs to the caller (next section).

| Option (variable) | Meaning | Default | In a `.wff` file | On the command line |
|---|---|---|---|---|
| `*compact-encoding*` | Introduce auxiliary (Tseitin) propositions to keep the instantiated formula small | `t` (on) | `(option *compact-encoding* 0)` | `--eval '(setq *compact-encoding* nil)'` |
| `*tracing*` | Print `[TRACE]` diagnostics during instantiation | `nil` (off) | `(option *tracing* 1)` | `--eval '(setq *tracing* t)'` |
| `*satplan-numslices*` | SatPlan time horizon read by `pddl2fifo`-generated wff files | unbound (treated as `2`) | `(option *satplan-numslices* 10)` | `--eval '(setq *satplan-numslices* 10)'` |

### Solving policy is the caller's

The variables below say *how to attack* a problem rather than what the problem is, so a `.wff` may not set them — `(option *solver* ...)` and its relatives are rejected with an error naming the replacement. There are three places to say it instead: a `solve` keyword (which binds the variable for that call only), a `setq` for the whole session, or the matching flag on `solve.sh` / `map.sh` / `planner.sh`.

Keeping them out of the `.wff` is what lets `solve.sh` and `map.sh` guarantee the format/solver pairing they exist to enforce, and what stops a file from silently overriding the planner's own choice at every horizon.

| Variable | Meaning | Default | `solve` keyword | On the command line |
|---|---|---|---|---|
| `*cnf-format*` | DIMACS output format for weighted problems: `CNF`, `WCNF-OLD`, or `WCNF`. Also a `propositionalize` argument, which overrides the format recorded in a `.scnf` | `CNF` | `:cnf-format 'WCNF` | `--eval '(setq *cnf-format* (quote WCNF))'` |
| `*solver*` | SAT or MaxSAT executable invoked by `satisfy`/`solve`; abbreviations are resolved via `*solver-abbreviations*` | `"kissat"` | `:solver "tt-glucose"` | `--eval '(setq *solver* "kissat")'` |
| `*solver-timeout*` | Seconds before the solver is stopped with `SIGTERM`. `0`, `-1` and `nil` all mean no limit. See [Solver time limits](#solver-time-limits) | `600` | `:timeout 60` | `--eval '(setq *solver-timeout* 60)'` |
| `*preprocessor*` | MaxPre 2 binary used to preprocess a weighted CNF before solving, reconstructing the model afterwards; `nil` for none. See [Preprocessing with MaxPre 2](#preprocessing-with-maxpre-2) | `nil` | `:preprocessor "maxpre"` | `--eval '(setq *preprocessor* "maxpre")'` |
| `*preprocessor-techniques*` | MaxPre's `-techniques=` string; `nil` uses MaxPre's own default | `nil` | `:preprocessor-techniques "[bu]#[buvsrg]"` | `--eval '(setq *preprocessor-techniques* "[bu]#[buvsrg]")'` |
| `*solver-abbreviations*` | Table of `(abbreviation full-name)` pairs for `*solver*`; full names must be strings. Resolved by `solve`'s `:solver` | `tt-glucose`, `tt-intelsat`, `nuwls`, `evalmaxsat` | — | `--eval '(setq *solver-abbreviations* (quote (("ms" "minisat-2.2"))))'` |

### Example: setting several options from the command line

To solve a problem with tracing enabled, a different solver, and weighted output in the new DIMACS format, chain the `setq` forms before the call to `solve`:

```sh
sbcl --load FiFO.lisp \
     --eval '(setq *tracing* t)' \
     --eval '(setq *solver* "glucose")' \
     --eval '(setq *cnf-format* (quote WCNF))' \
     --eval '(solve "problem.wff")' \
     --eval '(quit)'
```

## Running FiFO

Requires SBCL and Quicklisp. The SAT solver defaults to `kissat` (configurable with `(solve "problem.wff" :solver "<name>")` or `(setq *solver* "<name>")` on the command line).

Load the interpreter interactively:

```sh
sbcl --eval "(load \"FiFO.lisp\")"
```

Run end-to-end on a `.wff` file:

```sh
sbcl --eval "(load \"FiFO.lisp\")" \
     --eval "(solve \"myfile.wff\")" \
     --eval "(quit)"
```

**Note:** On some SBCL installations the short flag `-e` is not recognized. Always use `--eval` (long form).

## Testing

Tests are split into two categories: `instantiate` tests (checking CNF generation) and `solve` tests (checking end-to-end SAT solving and answer extraction). All test files live under `tests/`. Each category has three directories:

| Directory | Purpose |
|---|---|
| `tests/tests_instantiate/` | `.wff` files for instantiate tests in progress |
| `tests/passed_instantiate/` | `.wff` and `.scnf` files for verified passing instantiate tests |
| `tests/gold_instantiate/` | Reference `*_gold.scnf` files for instantiate comparison |
| `tests/tests_solve/` | `.wff` files for solve tests in progress |
| `tests/passed_solve/` | `.wff` and `.answer` files for verified passing solve tests |
| `tests/gold_solve/` | Reference `*_gold.answer` files for solve comparison |

The run scripts must be invoked from inside the `tests/` directory.

### Running instantiate tests

```sh
cd tests
bash run-test-instantiate.sh <testname>   # e.g. bash run-test-instantiate.sh test_all_exists
```

This instantiates `tests_instantiate/<testname>.wff`, writes `tests_instantiate/<testname>.scnf`, and prints the output. Compare against the gold file:

```sh
diff tests_instantiate/<testname>.scnf gold_instantiate/<testname>_gold.scnf
```

### Running solve tests

```sh
cd tests
bash run-test-solve.sh <testname>   # e.g. bash run-test-solve.sh test_simple_deduction
```

This runs `solve` on `tests_solve/<testname>.wff`, writes `tests_solve/<testname>.answer`, and prints the output. Compare against the gold file:

```sh
diff tests_solve/<testname>.answer gold_solve/<testname>_gold.answer
```

**Note:** Gensym symbols (`#:XXnnn`) in instantiate output will have different numbers across SBCL sessions. When gensyms are present, compare clause counts and structure rather than exact text.

### Known limitation: compact-encoding and nested exists

With `(option *compact-encoding* 0)`, the OR-distribution step performs a full cross-product of clauses instead of introducing auxiliary Tseitin propositions. Nested `exists` quantifiers over large domains can cause exponential clause blowup. Keep domains small (<= 3 values) when using `*compact-encoding* 0` with nested quantifiers.

## Implementing SatPlan in FiFO

FiFO includes a SatPlan-style planner built on static predicates and quantified formulas: a PDDL&rarr;FiFO translator (`pddl2fifo`), domain-independent SatPlan axioms, trajectory constraints, soft goals/preferences, per-step fluent costs, learning action/preference weights from probabilities, and an end-to-end planner driver (`planner.sh`). This material has its own document:

**&rarr; [Implementing SatPlan in FiFO](SatPlan/satplan.md)**

Schema BNF
----------

    <schema> = <option> | <domain declaration> | <alias declaration> | <formula> | <statics> | <weight> | <probability>
    
    <option> = (option <option name> <option value>)
    
    <option name> = *compact-encoding* | *tracing* | *cnf-format* | *solver* | *solver-abbreviations*
                  | *solver-timeout* | *preprocessor* | *preprocessor-techniques* | *satplan-numslices*
    
    <option value> = <numeric expression> | cnf | wcnf-old | wcnf
    
    <domain declaration> = (domain <domain name> <set expression>)
    
    <alias declaration> = (alias <term name> <term>)
    
    <formula> = <proposition> | (not <formula>) | 
        (and <body>*) | (or <formula>*) |  
        (implies <formula> <formula>) | (equiv <formula> <formula>) |  
        (all <variable> <set expression> <test> <body>) |  
        (all (<variable>+) <set expression> <test> <body>) |  
        (exists <variable> <set expression> <test> <body>) |  
        (exists (<variable>+) <set expression> <test> <body>) |  
        (if <test> <body>) |  
        (prove ((<variable> <set expression>)*) <test> <formula>)
    
    <body> = <formula> | <weight> | <probability>
    
    <proposition> = <predicate symbol> | true | false | 
        (<predicate symbol> <term>*) |
    
    <set expression> = <domain name> | (set <term>+) | 
        (range <numeric expression> <numeric expression>) |  
        (union <set expression> <set expression>) | 
        (intersection <set expression> <set expression>) |  
        (set-difference <set expression> <set expression>) | 
        (for <variable> <set expression> <test> <set expression>) |
        (for (<variable>+) <set expression> <test> <set expression>) |
        (collect <variable> (<static predicate symbol> <term-pattern>+)) |
        (lisp <lisp list valued expression>)
    
    <term-pattern> = <variable> | * | <term>
    
    <test> = <numeric expression>
    
    <term> = <constant symbol> | <numeric expression> | 
        <variable> | <term name> |
        (<uninterpreted function symbol> <term>*) |
        (lisp <lisp symbol or number valued expression>)
    
    <numeric expression> = <number> | 
        true | false |
        <variable ranging over a numeric domain> | 
        (<static predicate symbol> <term>*) |  
        (member <term> <set expression>) | 
        (alldiff <term> <term>+) |  
        (not <numeric expression>) | 
        (and <numeric expression>\*) | 
        (or <numeric expression>\*) |  
        (<operator> <numeric expression> <numeric expression>) |  
        (lisp <lisp number valued expression>)
    
    <operator> = + | - | \* | div | rem | mod | < | <= | > | >= | = | eq | neq | \*\* | bit
    
    <weight> = (weight <formula> <numeric expression>)
    
    <probability> = (probability <formula> <numeric expression> [<tie-label>])
    
    <literal> = <proposition> | (not <proposition>)
    
    <statics> = (static <static-formula>+)
    
    <static-formula> = <proposition> |
        (and <static-formula>*) | 
        (all <variable> <set expression> <test> <static-formula>) |  
        (all (<variable>+) <set expression> <test> <static-formula>) |  
        (if <test> <static-formula>) 
    
    ;; "observed" is accepted as a deprecated synonym for "static" 

## Using FiFO with Python

There are two good ways to drive FiFO from Python: calling SBCL as a subprocess, which requires no extra libraries and matches FiFO's file-based design, or using the `cl4py` library, which keeps a persistent Lisp session and converts data between the two languages.

### The subprocess method

Since `instantiate` and `solve` read and write files, the simplest bridge is to invoke SBCL directly and read the output file:

```python
import subprocess

def fifo_solve(wff_path):
    subprocess.run(
        ["sbcl", "--non-interactive", "--load", "FiFO.lisp",
         "--eval", f'(solve "{wff_path}")'],
        check=True, capture_output=True)
    answer_path = wff_path.rsplit(".", 1)[0] + ".answer"
    with open(answer_path) as f:
        lines = f.read().splitlines()
    return lines[0], lines[1:]     # "SAT"/"UNSAT"/..., literals

status, literals = fifo_solve("SatPlan/Examples/Switch/switchprob.wff")
```

Each literal line is an s-expression such as `(OCCURS (TURN-ON S2) 1)`. The small `sexpdata` library (`pip install sexpdata`) parses these into nested Python lists:

```python
import sexpdata
parsed = [sexpdata.loads(lit) for lit in literals]
```

This method pays SBCL's startup time (under a second) on every call, which is negligible for one-shot solves.

### The cl4py method

The `cl4py` library (`pip install cl4py`) starts an SBCL subprocess once and exchanges s-expressions with it, so FiFO loads a single time and repeated calls are fast. On recent Python versions cl4py also needs `pip install "setuptools<81"` for its `pkg_resources` dependency. Because cl4py starts SBCL with `--script`, the init file is skipped, so Quicklisp must be loaded explicitly before FiFO:

```python
import cl4py

lisp = cl4py.Lisp()
lisp.eval(('load', '"~/quicklisp/setup.lisp"'))
lisp.eval(('load', '"FiFO.lisp"'))

clauses = lisp.eval(('parse', ('quote',
    (('domain', 'd', ('set', 'a', 'b')),
     ('all', 'x', 'd', 'true', ('p', 'x'))))))
# => List(List(Symbol("OR"), List(Symbol("P"), Symbol("B"))),
#         List(Symbol("OR"), List(Symbol("P"), Symbol("A"))))

lisp.eval(('solve', '"SatPlan/Examples/Switch/switchprob.wff"'))
```

cl4py converts data between the languages automatically, but note which Python type maps to which Lisp type:

| Python | Lisp |
|--------|------|
| tuple `(1, 2, 3)` | list `(1 2 3)` |
| list `[1, 2, 3]` | vector `#(1 2 3)` |
| `'name'` (string) | raw Lisp source text, so `'a'` is the symbol `a` and `'"a"'` is the string `"a"` |
| int, float | number |

So FiFO formulas and schemas should be built as nested **tuples**, with bare strings for symbols. Results return as `cl4py.List` and `cl4py.Symbol` objects; a `List` behaves as a Python sequence and can be converted with `list(...)`.

## References

- **Tseitin encoding** (the default CNF conversion; `option compact-encoding` disables it) — G. S. Tseitin (1968). On the complexity of derivation in the propositional calculus. In A. O. Slisenko (ed.), *Studies in Constructive Mathematics and Mathematical Logic, Part II*, pp. 115–125 (English translation: Consultants Bureau, 1970).
- **Kissat** (the default SAT solver) — A. Biere, K. Fazekas, M. Fleury & M. Heisinger (2020). CaDiCaL, Kissat, Paracooba, Plingeling and Treengeling entering the SAT Competition 2020. In *Proc. of SAT Competition 2020 — Solver and Benchmark Descriptions*, University of Helsinki, pp. 51–53.
- **TT-Open-WBO-Inc** (the default MaxSAT solver for weighted problems) — A. Nadel (2019). Anytime weighted MaxSAT with improved polarity selection and bit-vector optimization. *FMCAD 2019*, pp. 193–202. Built on Open-WBO: R. Martins, V. Manquinho & I. Lynce (2014). Open-WBO: A modular MaxSAT solver. *SAT 2014*, LNCS 8561, pp. 438–445.
- **Weighted partial MaxSAT and the WCNF format** — F. Bacchus, M. Järvisalo & R. Martins (2021). Maximum satisfiability. In *Handbook of Satisfiability*, 2nd ed., IOS Press, ch. 24, pp. 929–991.
- **Weighted literals as a log-linear model** (the `weight`/`probability` semantics) — M. Richardson & P. Domingos (2006). Markov logic networks. *Machine Learning* 62(1–2):107–136.
- **Probabilistic inference by weighted model counting** (`wmc.sh`, `marginals.sh`) — T. Sang, P. Beame & H. Kautz (2005). Performing Bayesian inference by weighted model counting. *AAAI-05*, pp. 475–482; M. Chavira & A. Darwiche (2008). On probabilistic inference by weighted model counting. *Artificial Intelligence* 172(6–7):772–799.
- **MC-SAT** (`marginals.sh --solver mc-sat`) — H. Poon & P. Domingos (2006). Sound and efficient inference with probabilistic and deterministic dependencies. *AAAI-06*, pp. 458–463. Its inner near-uniform sampler is SampleSAT: W. Wei, J. Erenrich & B. Selman (2004). Towards efficient sampling: Exploiting random walk strategies. *AAAI-04*, pp. 670–676.
- **ADDMC** (the external weighted model counter) — J. M. Dudek, V. H. N. Phan & M. Y. Vardi (2020). ADDMC: Weighted model counting with algebraic decision diagrams. *AAAI-20*, pp. 1468–1476.
