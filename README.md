# FiFO 2.0 Users Guide

henry.kautz@gmail.com
---------------------

[GitHub Repository](https://github.com/HenryKautz/Schema2)

FiFO is a language for specifying logical theories using finite-domain first-order logic syntax. Because domains are finite, the language is a compact representation for propositional logic. The FiFO interpreter produces propositional CNF (conjunctive normal form) which can be input to any satisfiability testing program.

The FiFO interpreter is written in Common Lisp, but it is not necessary to know how to program in Lisp in order to use FiFO.

## Examples of FiFO

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

;; STRIPS planning
;; Define range domain time
(domain time (range 1 100))
;; Define set domain block
(domain block (A B C))
;; Preconditions and effects of move
(all t time true
    (all (x y z) block (alldiff x y z)
         (implies (move x y z t)
                  (and
                      ;; Preconditions hold at time t
                      (clear x t)
                      (on x y t)
                      (clear z t)
                      ;; Effects hold at time t+1
                      (on y z (+ t 1))
                      (clear y (+ t 1))
                      ((not (clear z (+ t 1))))))))
```

Common Lisp API
------------

Invoke any implementation of Common Lisp, and load the file "FiFO.lisp". The following Lisp functions are available. All arguments after the first are Common Lisp keyword arguments, so they are supplied by name, e.g. `(instantiate "test.wff" :scnfile "test.scnf")` or `(interpret "test.out" :sort-by-time nil)`.

**(parse '(SCHEMA+) &key (observation-list '(OBSERVATION+))) returns ((OR LITERAL+)\*)**  
Parse a list of schemas (see BNF syntax below) and return a list of symbolic ground clauses. Each OBSERVATION is a positive ground literal or a observed quantified formula as described below. When the schemas are expanded, they are simplified by replacing observed atoms by true and all non-observed atoms that employ the same predicates by false.

**(instantiate "test.wff" &key scnfile obsfile)**  
Reads the FiFO file "test.wff", instantiates it, and saves the result in symbolic conjunctive normal form in the file given by `:scnfile`. The `:obsfile` file contains a sequence of observed ground atoms.

**(propositionalize "test.scnf" &key cnffile mapfile)**  
Reads the symbolic conjunctive normal form file "test.scnf" and creates a DIMACS format CNF file3 "test.cnf". In DIMACS format (the standard input language for all modern SAT solvers), propositions are represented by positive and negative integers. The mapping from symbolic ground atoms to integers is written to the file "test.map". The file "test.cnf" may then be sent to a SAT solver. When the output file name is not given explicitly and the problem is written in one of the WCNF formats (see Optimization), the default extension is `.wcnf` instead of `.cnf`. `propositionalize` returns the pathname of the cnf/wcnf file it wrote.

**(satisfy "test.cnf" &key satoutfile)**
The solver named by the variable **sat-solver** (default "kissat") is called on "test.cnf" and the output of the solver is captured in the file "test.out".  Satisfy returns 'SAT, 'UNSAT, or nil if the solver fails or its output contains neither the strings SAT nor UNSAT.

**(interpret "test.out" &key mapfile solnfile (sort-by-time t))**  
Reads in the output of a SAT solver "test.out" and a mapping file (`:mapfile`), and creates an answer file (`:solnfile`) containing the positive literals in the satisfying assignment in symbolic form. The file "test.out" specifies a solution by a sequence of positive and negative integers. The format of the file can be flexible; it can simply be a sequence of integers; or be in official DIMACS solution format where lines containing the integers begin with the letter "v"; or free-form text where lines containing only integers are assumed to be the solution. If for some integer, neither the integer nor its complement appears, then it is assumed to be false (negative) for the assignment. By default (`:sort-by-time t`) the results are sorted by the last argument to each predicate, which is often used to specify a time index; pass `:sort-by-time nil` to sort alphabetically instead.

The MaxSAT output format used by solvers such as `tt-open-wbo-inc` is also understood: the satisfiability status is taken from the `s` line, and the model is given as a single `v` line that is a bit string of length *numvar* (one `0`/`1` per variable) rather than a list of signed literals. When the output contains one or more `o <number>` (objective/cost) lines, the value from the last such line is written to "test.answer" as an atom of the form `(*objective* <number>)`, placed before the symbolic atoms.

**(solve "test.wff" &key solnfile obsfile)**
Reads in the FiFO file "test.wff" and an optional observation file (`:obsfile`), solves it using the **sat-solver** and writes the results in symbolic form to the answer file (`:solnfile`).  If "test.wff" contains no **prove** formula, the sat solver will be called a single time.  If it does contain **prove**, then the sat solver may be invoked several times as described in the section below on Answer Extraction for Deduction.  The format of "test.answer" will be one of:

- If the formula does not contain a prove form and:
  - Is satisfiable: SAT followed by the positive ground literals in a satisying model.
  - Is unsatisfiable: UNSAT.

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

Any non-zero numeric value is treated as true and zero (0 or 0.0) is treated as false in numeric expressions. The special constants "true" and "false" are equivalent to 1 and 0 respectively when they appear in numeric expressions. Numeric expressions may include integer or floating-point literals, arithmetic functions (+, -, \*, div, rem, mod), comparison functions (<, <=, =, >=, >, member, eq, neq, alldiff), set composition functions (enumerated sets, ranges, union, intersection, set-difference), logical functions (and, or, not), and observed predicates. Non-observed predicates may not appear in a numeric expression. Note that logical operators in numeric expressions are evaluated by the FiFO interpreter and do not appear in the final CNF, unlike the logical operators that have the same names. When a numeric value is a whole number (e.g. 2.0), it is written as a plain integer (2) in the scnf output.

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

The **collect** operator builds a domain by pattern-matching against observed predicates:

```
(collect <variable> (<observed-predicate> <term-pattern>+))
```

A `<term-pattern>` is like a term but may contain the variable itself or the wildcard symbol `*`. Both are treated as wildcards when matching against the set of observed propositions. The form returns the set of ground terms that the variable matched across all observed literals that fit the pattern. The result never contains duplicates.

For example, given observations `(edge n1 n2)`, `(edge n2 n3)`, `(edge n3 n4)`:

```
;; Collect all source nodes of observed edges
(domain sources (collect x (edge x *)))   ; {n1 n2 n3}

;; Collect all target nodes
(domain targets (collect x (edge * x)))   ; {n2 n3 n4}

;; Self-loops only (variable appears twice — both must agree)
(domain self-loops (collect x (edge x x)))   ; {} — no self-loops observed
```

The variable can be nested inside a compound term pattern. In that case the term at that position (not the outer compound) is what gets collected:

```
;; Given (at (truck 1) (place 1)) and (at (truck 2) (place 2)) are observed:
(domain truck-ids (collect i (at (truck i) *)))   ; {1 2}

;; Collect whole compound terms that fill a pattern position:
(domain trucks-at-p1 (collect x (at x (place 1))))   ; {(truck 1)}
```

`collect` is especially useful in SatPlan-style encodings for deriving action sets directly from observed `Pre`/`Add`/`Del` facts rather than enumerating them manually.

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

FiFO includes both interpreted and uninterpreted functions.  Interpreted functions include mathematical operations and set operations.  A term that does not begin with the name of an interpreted function is taken to be an uninterpreted function.  Thus, the formula using the interpreted function + and the uninterpreted function symbol node

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

## Observed Predicates

Observed predicates are useful for describing fixed relationships in a problem instance. The true ground literals for such predicates are specified in a list provided to the FiFO interpreter.  The interpreter will then assume that all other literals for the predicates that appear in that list are asserted to be false.

For example, consider representing problems about a graph. The observations would specify edges in the graph, for example:

```
(edge N1 N2)  
(edge N3 N4)  
(edge N3 N5)
```

Making "connected" an observed predicate has several advantages:

- The closed world assumption is automatically applied to the predicate. In the example above, (not (connected R1 R5)) is implicitly asserted.
- The predicate may be used inside test expressions.
- The instantiated formula is smaller because observed literals are compiled away.

A predicate can be declared to be observed in two ways. The **observed** form can be used to specify it's positive literals.  These should appear before any other formulas are asserted.  For example:

```
(domain Node (set N1 N2 N3 N4 N5))
(observed 
	(edge N1 N2)  
	(edge N3 N4)  
	(edge N3 N5))
```

An alternative way to declare observed predicates and their true literals is to include the list of observed literals as an optional argument for the LISP API.  In this case, no explicit observations declaration is used.

## Observed Quantified Formulas

Quantified formulas can appear as observations with the restriction that only the forms **all**, **and**, **if**, and positive literals may appear in the body of a quantified formula.  For example, the following first defines a domain of 10 cells, and in the first observed formula asserts that the i-th cell is smaller than the i+1st cell.  The second observed formula asserts that smaller is transitively closed.

```
(domain cell (for i (range 1 10) true (set (cell i))))

(observed
 (all i num (< num limit) (smaller (cell i) (cell (+ 1 i))))
 (all (a b c) cell (and (smaller a b) (smaller b c)) 
      (smaller a c))
 )
```

Note that the expression (and (smaller a b) (smaller b c)) appears as a *test* in the innermost **all**.  Recall that this is valid because observed literals can appear in a test.  Evaluating the form can add additional pairs to the observed predicate "smaller".  The FiFO program therefore re-evaluates *every* observed quantified formula if *any* such formula adds a *new* observed literal.  

## Constraint Satisfaction

Discrete constraint satisfaction problems (CSPs) can easily be represented in FiFO.  The answer can be read off from the symbolic form of the SAT solution generated by the interpret function.

As an example, consider graph 3-coloring: assign one of three colors to each node of a graph so that no two adjacent nodes share a color.  The graph is specified using an observed predicate `edge`, giving the closed-world assumption that unlisted edges do not exist.  Nodes are given colors using a predicate `color`, and two schemas assert (1) every node gets exactly one color and (2) adjacent nodes get different colors.

```
(domain Color (set Red Blue Green))
(domain Node (set a b c d e))

;; Undirected edges (pentagon a-b-c-d-e-a plus chord b-d)
(observed
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

## Optimization (Weighted MaxSAT)

FiFO supports weighted optimization problems via the **weight** form:

```
(weight <literal> <number>)
```

This asserts that if `<literal>` is true in a satisfying assignment, it contributes `<number>` to the objective. A MaxSAT or pseudo-Boolean optimizer can then minimize the total weight of true literals subject to satisfying all clauses.

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
(if (observed-predicate arg) (weight (option arg) 2.5))
```

`weight` may **not** appear inside `or`, `not`, `implies`, or `equiv` — those contexts require formulas that produce clauses.

### Weighted CNF output formats

The option `(option weights <format>)` controls how weights appear in the DIMACS `.cnf` file produced by `propositionalize`. It has no effect when the problem contains no weights.

**`cnf`** (the default) writes a standard `p cnf` file followed by one `cw <literal> <weight>` line per weight. Since these lines begin with the letter `c`, ordinary SAT solvers treat them as comments, so the file remains valid input for solvers like kissat (which simply ignore the weights).

**`wcnf-old`** writes the classic DIMACS weighted CNF format used by MaxSAT solvers: a header `p wcnf <vars> <clauses> <top>`, where every clause line begins with its weight. Hard clauses (the ordinary clauses of the problem) carry the weight `top`, which exceeds the sum of all soft weights.

**`wcnf`** writes the new DIMACS format adopted by the MaxSAT Evaluation in 2022: no `p` header; hard clauses begin with `h`, and soft clauses begin with their weight.

In both wcnf formats, a weight *w* on literal *L* (the cost of making *L* true) becomes the soft unit clause ¬*L* with weight *w*, which a MaxSAT solver pays for exactly when *L* is true. Because these formats require weights to be positive integers, two transformations are applied:

- **Shift**: for each atom, the minimum of its total weight when true and its total weight when false is subtracted from both, so at most one polarity retains a (positive) weight. This also eliminates negative weights: a reward for making a literal true becomes a cost for making it false. The discarded total is a constant offset on the objective, reported in a comment line `c weight shift offset <n>`.
- **Scale**: all weights are multiplied by the smallest positive integer making them integral (e.g., weights 0.4 and 2 are scaled by 5 to 2 and 10), reported in a comment line `c weights scaled by <n>`.

The true cost of a solution is the MaxSAT solver's reported cost divided by the scale, plus the offset. Note that the built-in `solve` pipeline runs an ordinary SAT solver, which will not accept wcnf files; the wcnf formats are intended for `.cnf` files handed to an external MaxSAT solver.

### Weighted CNF solvers

Solvers for weighted CNF include:

**RC2 via PySAT**

- pip install python-sat (PyPI: https://pypi.org/project/python-sat/)
- Source: https://github.com/pysathq/pysat
- Docs: https://pysathq.github.io/

RC2 ships inside the package — from pysat.examples.rc2 import RC2 plus from pysat.formula import WCNF and you're solving in about five lines. There's also a command-line entry point (rc2.py).

**MaxHS**

- Source: https://github.com/fbacchus/MaxHS

One important caveat: MaxHS uses CPLEX from IBM as its MIP solver, so you need the CPLEX static libraries to link against; CPLEX is free to faculty and graduate students through the IBM Academic Initiative (https://www.ibm.com/academic), and you set the CPLEX library/include paths in the Makefile before building. If the CPLEX dependency is a blocker for you, precompiled MaxHS binaries from past MaxSAT Evaluations are available on the evaluation sites (e.g., https://maxsat-evaluations.github.io/ → pick a year → "Descriptions/Downloads"), and an alternative IHS solver without that build step is worth knowing about.

**TT-Open-WBO-Inc**

- Source: https://github.com/alexander-nadel-academic/tt-open-wbo-inc (the GitHub version corresponds to the MaxSAT Evaluation 2023 submission)

Standard C++ build (make), no commercial dependencies; reads WCNF and prints improving solutions as it finds them (o lines), with the best model on the v line.

**CP-SAT (Google OR-Tools)**

- Easiest: pip install ortools (PyPI: https://pypi.org/project/ortools/)
- Source and binaries: https://github.com/google/or-tools
- Docs: https://developers.google.com/optimization/cp/cp_solver

No license hassle, no compilation, and the Python API is pleasant. Note CP-SAT takes its own model format rather than WCNF, so you'd build the model programmatically (clauses as AddBoolOr, objective as Minimize).  Utilities for converting wcnf files to Python code for CP-SAT are included in [wcnfsolvers](https://github.com/HenryKautz/wcnfsolvers).

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

Compact Encodings
-----------------

The input formulas need not be in conjunctive normal form. Converting a formula to CNF using only the user-defined propositions can cause its size to increase exponentially. By creating new propositions, the FiFO interpreter can guarantee the size of the output CNF formula is only exponential in the nesting of quantifiers. Specifically, where

> M = number of input formulas  
> L = length of the longest input formula  
> D = size of the largest set appearing in a quantification statement  
> N = deepest nesting of quantifiers in a formula

the size of the output CNF is $O(M*L*D^N)$.

When new propositions are introduced in this manner, the relationship between the input and output formulas is that the output formula entails the input formula and any model of the input formula can be extended to a model of the output formula.

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

; Format used for the DIMACS cnf file when the problem contains weighted literals (see
; the Optimization section): CNF (default), WCNF-OLD, or WCNF.
(option *cnf-format* CNF)
(option *cnf-format* WCNF-OLD)
(option *cnf-format* WCNF)

; SAT solver to use (default: kissat).  Quotation marks may be omitted when the
; solver name contains only letters, digits, hyphens, and underscores.
(option *solver* kissat)
(option *solver* "my-solver")

; The solver name may also be an abbreviation, in which case the solver is set to
; the corresponding full name.  Two abbreviations are predefined:
;   tt-glucose   -> tt-open-wbo-inc-Glucose4_1
;   tt-intelsat  -> tt-open-wbo-inc-IntelSATSolver
(option *solver* tt-glucose)

; Redefine the abbreviation table.  The value is a list of (abbreviation full-name)
; pairs.  Full names must be written as strings to preserve their case, since the
; Lisp reader uppercases bare symbols.  Abbreviations are matched case-insensitively.
(option *solver-abbreviations* (("glu" "glucose-4.2.1") ("ms" "minisat-2.2")))

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

Every option is a Lisp global variable whose name is the same in both forms. There are two ways to set it:

- **In a `.wff` file**, with an `(option <name> <value>)` form placed before any formulas.
- **On the command line**, with an `--eval '(setq <name> <value>)'` form (or `(set ...)` for an unbound variable) given to `sbcl` after `--load FiFO.lisp`. A command-line setting persists for the whole Lisp session; an `(option ...)` form in a file overrides it when that file is processed.

The two forms differ only in how some values are written: booleans use `1`/`0` in a file but `t`/`nil` on the command line, and list-valued options are written unquoted in a file but must be quoted (`(quote ...)`) for `setq`.

| Option (variable) | Meaning | Default | In a `.wff` file | On the command line |
|---|---|---|---|---|
| `*compact-encoding*` | Introduce auxiliary (Tseitin) propositions to keep the instantiated formula small | `t` (on) | `(option *compact-encoding* 0)` | `--eval '(setq *compact-encoding* nil)'` |
| `*tracing*` | Print `[TRACE]` diagnostics during instantiation | `nil` (off) | `(option *tracing* 1)` | `--eval '(setq *tracing* t)'` |
| `*cnf-format*` | DIMACS output format for weighted problems: `CNF`, `WCNF-OLD`, or `WCNF` | `CNF` | `(option *cnf-format* WCNF)` | `--eval '(setq *cnf-format* (quote WCNF))'` |
| `*solver*` | SAT solver executable invoked by `satisfy`/`solve`; abbreviations are resolved via `*solver-abbreviations*` | `"kissat"` | `(option *solver* tt-glucose)` | `--eval '(setq *solver* "kissat")'` |
| `*solver-abbreviations*` | Table of `(abbreviation full-name)` pairs for `*solver*`; full names must be strings | `tt-glucose`, `tt-intelsat` | `(option *solver-abbreviations* (("ms" "minisat-2.2")))` | `--eval '(setq *solver-abbreviations* (quote (("ms" "minisat-2.2"))))'` |
| `*satplan-numslices*` | SatPlan time horizon read by `pddl2fifo`-generated wff files | unbound (treated as `2`) | `(option *satplan-numslices* 10)` | `--eval '(setq *satplan-numslices* 10)'` |

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

Requires SBCL and Quicklisp. The SAT solver defaults to `kissat` (configurable via `(option *solver* <name>)` in a `.wff` file or `(setq *solver* "<name>")` on the command line).

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

With `(option *compact-encoding* 0)`, the OR-distribution step performs a full cross-product of clauses instead of introducing auxiliary Tseitin propositions. Nested `exists` quantifiers over large domains can cause exponential clause blowup. Keep domains small (<= 3 values) when using `*compact-encoding* 0` with nested quantifiers, or omit the option to use the default Tseitin encoding.

## Implementing SatPlan in FiFO

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

      ;; Interfering actions are mutually exclusive.
      ;;   a2 interferes with a1 if a2 deletes a precondition or add-effect of a1,
      ;;   or if a2 adds a negative precondition of a1, where a1 and a2 are not
      ;;   equal.  Inequality is required because an action may delete its own
      ;;   precondition or add its own negative precondition.
      (all (a1 a2) actions (neq a1 a2)
         (all flu fluents (and (or (Pre a1 flu) (Add a1 flu)) (Del a2 flu))
            (or (not (Occurs a1 s)) (not (Occurs a2 s)))))
      (all (a1 a2) actions (neq a1 a2)
         (all flu fluents (and (PreNeg a1 flu) (Add a2 flu))
            (or (not (Occurs a1 s)) (not (Occurs a2 s)))))

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

**Negative preconditions** are expressed with `(PreNeg action fluent)`, meaning the action requires the fluent to be false. An action occurrence implies its negative preconditions are false at that time step, and an action may add its own negative precondition, just as an action may delete its own positive precondition. Fluents appearing in `PreNeg` facts must be included in the `fluents` domain.

The **frame axioms** ensure that fluents persist across time steps unless an action explicitly changes them. They are encoded as explanatory frame axioms: if a fluent changes value, some action must be responsible.

The **cost axioms** use `Weight` (FiFO's weighted MaxSAT mechanism) to assign a cost to each action occurrence. Minimizing total weight then yields a minimum-cost plan.

### Example: Logistics Domain

The file `SatPlan/Examples/HandEncodings/logistics-hand-encoding.wff` encodes a logistics planning problem: packages must be transported between places using trucks. A truck can drive between any two places in one step; packages are loaded onto and unloaded from trucks.

```lisp
;; SatPlan Logistics Problem

;; Time horizon
(alias numslices 6)
(domain slices (range 1 numslices))
(domain actslices (range 1 (- numslices 1)))

(alias numpackages 3)
(alias numtrucks 2)
(alias numplaces 3)

(domain packages (for i (range 1 numpackages) true (set (package i))))
(domain trucks   (for i (range 1 numtrucks)   true (set (truck i))))
(domain places   (for i (range 1 numplaces)   true (set (place i))))

(observed
   (all tr trucks true
      (all pl places true
         (all pk packages true
            (and (Pre (load pk tr pl) (at tr pl))
               (Pre (load pk tr pl) (at pk pl))
               (Pre (unload pk tr pl) (in pk tr))
               (Pre (unload pk tr pl) (at tr pl))
               (Add (load pk tr pl) (in pk tr))
               (Add (unload pk tr pl) (at pk pl))
               (Del (load pk tr pl) (at pk pl))
               (Del (unload pk tr pl) (in pk tr))
               (Cost (load pk tr pl) 0.7)
               (Cost (unload pk tr pl) 0.5)))))

   (all tr trucks true
      (all (pl1 pl2) places (neq pl1 pl2)
         (and (Pre (drive tr pl1 pl2) (at tr pl1))
            (Add (drive tr pl1 pl2) (at tr pl2))
            (Del (drive tr pl1 pl2) (at tr pl1))
            (Cost (drive tr pl1 pl2) 4.5)))))

;; Initial and goal states

(domain initial-state
   (set
      (at (package 1) (place 1))
      (at (package 2) (place 2))
      (at (package 3) (place 3))
      (at (truck 1) (place 1))
      (at (truck 2) (place 2))))

(domain goal-state
   (set
      (at (package 1) (place 2))
      (at (package 3) (place 2))
      (at (package 2) (place 1))))

;; Derive action, fluent, and cost domains from the observed schemas
(domain actions (collect act (Pre act *)))
(domain fluents (collect fl  (Pre * fl)))
(domain costs   (collect c   (Cost * c)))

(include "satplan.wff")
```

The `observed` block defines the action schemas. Because `Pre`, `Add`, `Del`, and `Cost` are observed predicates, the SatPlan axioms in `satplan.wff` can use them as tests in quantified filters (e.g., `(all flu fluents (Pre act flu) ...)`), generating clauses only for relevant fluent–action pairs rather than all combinations.

The `collect` forms derive the `actions`, `fluents`, and `costs` domains directly from the observed schemas, so there is no need to enumerate them manually. They must appear *after* the `observed` block so that `ObservedLiterals` is fully populated when they are evaluated. `collect` scans all true observed literals matching the pattern and returns the set of ground terms bound to the variable; `*` is an anonymous wildcard.

### Running the Logistics Example

To instantiate (expand to symbolic CNF):

```sh
sbcl --load FiFO.lisp --eval '(instantiate "SatPlan/Examples/HandEncodings/logistics-hand-encoding.wff")' --eval '(quit)'
```

To solve end-to-end:

```sh
sbcl --load FiFO.lisp --eval '(solve "SatPlan/Examples/HandEncodings/logistics-hand-encoding.wff")' --eval '(quit)'
```

### Translating PDDL to FiFO with pddl2fifo

The program `SatPlan/pddl2fifo.lisp` translates a planning problem written in PDDL (the standard Planning Domain Definition Language) into a FiFO wff file in the form described above. It supports the PDDL requirements `:strips`, `:typing`, `:negative-preconditions`, and `:action-costs`. Action costs must be simple static numbers, i.e. effects of the form `(increase (total-cost) <number>)`.

To run from the shell:

```sh
sbcl --script SatPlan/pddl2fifo.lisp <problem.pddl> [<domain.pddl>]
```

Or from a Lisp listener:

```lisp
(load "SatPlan/pddl2fifo.lisp")
(pddl2fifo "problem.pddl")                            ; domain file found automatically
(pddl2fifo "problem.pddl" :domain-file "domain.pddl") ; domain file given explicitly
(pddl2fifo "problem.pddl" :satplan-path "../../satplan.wff") ; custom include path
```

The `:satplan-path` keyword (default `"satplan.wff"`) sets the path written into the generated `(include ...)` form for the SatPlan axioms. It is resolved relative to the directory of the generated wff, so pass the appropriate relative path when the problem file lives in a subdirectory below `satplan.wff` — e.g. `"../../satplan.wff"` for the bundled examples, which sit two levels down in `SatPlan/Examples/<Category>/`.

If the domain file is not given, the root of its file name is taken from the `(:domain <name>)` form in the problem file, and `<name>.pddl` is looked up in the directory of the problem file.

The translation is written to `<problem-root>.wff` in the directory of the problem file. The output:

- Defines a universal `objects` domain plus one FiFO domain per PDDL type. A type's domain contains the objects declared with that type or any of its subtypes, following the `(:types ...)` hierarchy; objects and parameters left untyped fall back to `objects`. Each PDDL action schema is translated into a quantified `observed` formula asserting `Pre`, `Add`, `Del`, and `Cost` facts, with each parameter quantified over its type's domain.
- Derives the `actions`, `fluents`, and `costs` domains from the observed facts using `collect`, as in `logistics-hand-encoding.wff`.
- Emits the time horizon as `(alias numslices (lisp ...))`, which evaluates to the Lisp variable `*satplan-numslices*` when it is bound to an integer and otherwise to `2`. Set the horizon without editing the output by binding `*satplan-numslices*` — e.g. `(setq *satplan-numslices* 10)` on the command line before `solve`/`instantiate`, or `(option *satplan-numslices* 10)` ahead of the alias — or edit the alias line directly.
- Ends with `(include "satplan.wff")` (or whatever `:satplan-path` was given), so the SatPlan axiom file must be reachable from the directory containing the output file.

Negative preconditions are translated into `PreNeg` observed facts, which the axioms in `satplan.wff` handle directly. Negative goals produce a `negative-goal-state` domain together with an axiom asserting those fluents are false at the final time slice.

Two example problems are provided. The untyped pair `SatPlan/Examples/Switch/switches.pddl` (domain) and `SatPlan/Examples/Switch/switchprob.pddl` (problem) exercises negative preconditions, negative goals, and action costs:

```sh
sbcl --load SatPlan/pddl2fifo.lisp --eval '(pddl2fifo "SatPlan/Examples/Switch/switchprob.pddl" :satplan-path "../../satplan.wff")' --eval '(quit)'
sbcl --load FiFO.lisp --eval '(solve "SatPlan/Examples/Switch/switchprob.wff")' --eval '(quit)'
```

The typed pair `SatPlan/Examples/TruckLog/trucklog.pddl` and `SatPlan/Examples/TruckLog/trucklogprob.pddl` encodes the same logistics task as `SatPlan/Examples/HandEncodings/logistics-hand-encoding.wff` using PDDL types, including a type hierarchy (`truck` is a subtype of `mobile`, and the drive action ranges over `mobile`):

```sh
sbcl --load SatPlan/pddl2fifo.lisp --eval '(pddl2fifo "SatPlan/Examples/TruckLog/trucklogprob.pddl" :satplan-path "../../satplan.wff")' --eval '(quit)'
sbcl --load FiFO.lisp --eval '(solve "SatPlan/Examples/TruckLog/trucklogprob.wff")' --eval '(quit)'
```

Schema BNF
----------

    <schema> = <option> | <domain declaration> | <alias declaration> | <formula> | <observations> | <weight>
    
    <option> = (option <option name> <option value>)
    
    <option name> = *compact-encoding* | *tracing* | *cnf-format* | *solver* | *solver-abbreviations* | *satplan-numslices*
    
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
    
    <body> = <formula> | <weight>
    
    <proposition> = <predicate symbol> | true | false | 
        (<predicate symbol> <term>*) |
    
    <set expression> = <domain name> | (set <term>+) | 
        (range <numeric expression> <numeric expression>) |  
        (union <set expression> <set expression>) | 
        (intersection <set expression> <set expression>) |  
        (set-difference <set expression> <set expression>) | 
        (for <variable> <set expression> <test> <set expression>) |
        (for (<variable>+) <set expression> <test> <set expression>) |
        (collect <variable> (<observed predicate symbol> <term-pattern>+)) |
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
        (<observed predicate symbol> <term>*) |  
        (member <term> <set expression>) | 
        (alldiff <term> <term>+) |  
        (not <numeric expression>) | 
        (and <numeric expression>\*) | 
        (or <numeric expression>\*) |  
        (<operator> <numeric expression> <numeric expression>) |  
        (lisp <lisp number valued expression>)
    
    <operator> = + | - | \* | div | rem | mod | < | <= | > | >= | = | eq | neq | \*\* | bit
    
    <weight> = (weight <literal> <numeric expression>)
    
    <literal> = <proposition> | (not <proposition>)
    
    <observations> = (observed <observed-formula>+)
    
    <observed-formula> = <proposition> |
        (and <observed-formula>*) | 
        (all <variable> <set expression> <test> <observed-formula>) |  
        (all (<variable>+) <set expression> <test> <observed-formula>) |  
        (if <test> <observed-formula>) 

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

status, literals = fifo_solve("SatPlan/Examples/HandEncodings/logistics-hand-encoding.wff")
```

Each literal line is an s-expression such as `(OCCURS (LOAD (PACKAGE 1) (TRUCK 1) (PLACE 1)) 1)`. The small `sexpdata` library (`pip install sexpdata`) parses these into nested Python lists:

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

lisp.eval(('solve', '"SatPlan/Examples/HandEncodings/logistics-hand-encoding.wff"'))
```

cl4py converts data between the languages automatically, but note which Python type maps to which Lisp type:

| Python | Lisp |
|--------|------|
| tuple `(1, 2, 3)` | list `(1 2 3)` |
| list `[1, 2, 3]` | vector `#(1 2 3)` |
| `'name'` (string) | raw Lisp source text, so `'a'` is the symbol `a` and `'"a"'` is the string `"a"` |
| int, float | number |

So FiFO formulas and schemas should be built as nested **tuples**, with bare strings for symbols. Results return as `cl4py.List` and `cl4py.Symbol` objects; a `List` behaves as a Python sequence and can be converted with `list(...)`.
