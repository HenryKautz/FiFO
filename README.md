# SCHEMA 2.0 USERS GUIDE

henry.kautz@gmail.com
---------------------

[GitHub Repository](https://github.com/HenryKautz/Schema2)

Schema is a language for specifying logical theories using finite-domain first-order logic syntax. Because domains are finite, the language is a compact representation for propositional logic. The Schema interpreter produces propositional CNF (conjunctive normal form) which can be input to any satisfiability testing program.

The Schema interpreter is written in Common Lisp, but it is not necessary to know how to program in Lisp in order to use Schema.

## Examples of Schema

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

Invoke any implementation of Common Lisp, and load the file "schema.lisp". The following Lisp functions are available:

**(parse '(SCHEMA+) &optional '(OBSERVATION+)) returns ((OR LITERAL+)\*)**  
Parse a list of schemas (see BNF syntax below) and return a list of symbolic ground clauses. Each OBSERVATION is a positive ground literal or a observed quantified formula as described below. When the schemas are expanded, they are simplified by replacing observed atoms by true and all non-observed atoms that employ the same predicates by false.

**(instantiate "test.wff" &optional "test.scnf" "test.obs")**  
Reads the Schema file "test.wff", instantiates it, and saves the result in symbolic conjunctive normal form in the file "test.scnf". The optional file "test.obs" contains a sequence of observed ground atoms.

**(propositionalize "test.scnf" &optional "test.cnf" "test.map")**  
Reads the symbolic conjunctive normal form file "test.scnf" and creates a DIMACS format CNF file3 "test.cnf". In DIMACS format (the standard input language for all modern SAT solvers), propositions are represented by positive and negative integers. The mapping from symbolic ground atoms to integers is written to the file "test.map". The file "test.cnf" may then be sent to a SAT solver.

**(satisfy "test.cnf" &optional "test.out")**
The solver named by the variable **sat-solver** (default "kissat") is called on "test.cnf" and the output of the solver is captured in the file "test.out".  Satisfy returns 'SAT, 'UNSAT, or nil if the solver fails or its output contains neither the strings SAT nor UNSAT.

**(interpret "test.out" &optional "test.map" "test.answer" sort-by-time)**  
Reads in the output of a SAT solver "test.out" and a mapping file "test.map", and creates a file "test.answer" containing the positive literals in the satisfying assignment in symbolic form. The file "test.out" specifies a solution by a sequence of positive and negative integers. The format of the file can be flexible; it can simply be a sequence of integers; or be in official DIMACS solution format where lines containing the integers begin with the letter "v"; or free-form text where lines containing only integers are assumed to be the solution. If for some integer, neither the integer nor its complement appears, then it is assumed to be false (negative) for the assignment. The results are sorted alphabetically unless sort-by-time is set to t, in which case the results are sorted by the last argument to each predicate, which is often used to specify a time index.

**(solve "test.wff" &optional "test.answer"  "test.obs")**
Reads in the Schema file "test.wff" and an optional "test.obs" observation file, solves it using the **sat-solver** and writes the results in symbolic form to "test.answer".  If "test.wff" contains no **prove** formula, the sat solver will be called a single time.  If it does contain **prove**, then the sat solver may be invoked several times as described in the section below on Answer Extraction for Deduction.  The format of "test.answer" will be one of:

- If the formula does not contain a prove form and:
  - Is satisfiable: SAT followed by the positive ground literals in a satisying model.
  - Is unsatisfiable: UNSAT.

- If the formula contains a prove form and
  - Is satisfiable: COUNTEREXAMPLE followed by the positive ground literals in a counterexample (satisfying model).
  - Is unsatisfiable and answer extraction succeeds: PROVEN followed by a sequence of variable bindings. Each variable binding is of the form `(<variable> <value>)`
  - Is unsatisfiable but answer extraction failed: NOANSWER.


Language
--------

Schema is a language for specifying logical theories using finite-domain first-order logic syntax.  Because domains are finite, the Schema interpreter compiles its input into propositional logic for solution by any SAT solver. A Schema program consists of a sequence of options, domain declarations, and formulas. Options control certain details of the intrepreter. Domain declarations bind domain names to sets of Herbrand terms.  Domains may share elements.  No domain declarations are associated with predicates; every predicate may accept terms of any domain as arguments.  It is also permissible for different instances of predicates to take different number of arguments.

Formulas are composed, as in first-order logic, of predicates, variables, constants, function symbols, logical connections, and quantifiers. The basic function of the Schema interpreter is to instantiate the variables in each formula and convert the result to CNF.

Formulas and terms are specified in prefix (LISP) notation. The quantifiers, all and exists, iterate over sets of Herbrand terms. Terms are integers, constants, or complex terms built using uninterpreted function symbols. A quantified formula is represented by a list containing the quantifier, a variable, a set of terms, a test (integer valued) expression, and the subformula to which the quantification is applied. The subformula is instantiated only for bindings of the variable for which the test is true. For example,

```
(all x (range 1 10) (= 0 (mod x 2)) (p x))
```

can be read, "for all x in the range 1 through 10, such that x is even, assert (p x)".

Propositions are expressed in Schema as either atomic symbols or complex propositions specified by a list beginning with a predicate followed by zero or more terms.  The special proposition "true" and "false" have the expected meaning.  Terms can be built from interpreted functions such as + and uninterpreted function symbols. For example, the literal expression (winner john (round (\* 3 8))) is instantiated as

```
(winner john (round 24))
```

where "winner" is a predicate, "john" is a simple term, "round" is an uninterpreted function symbol, and "(round 24)" is a complex term.

The integer values 1 and 0 are used to represent true and false respectively in integer expressions. The special constants "true" and "false" are equivalent to 1 and 0 respectively when they appear in integer expressions. Integer expressions may include arithmetic functions (+, -, \*, div, rem, mod), comparison functions (<, <=, =, >=, >, member, eq, neq, alldiff), set composition functions (enumerated sets, ranges of integers, union, intersection, set-difference), logical functions (and, or, not), and observed predicates. Non-observed predicates may not appear in an integer expression. Note that logical operators in integer expressions are evaluated by the Schema interpreter and do not appear in the final CNF, unlike the logical operators that have the same names.

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

Schema includes both interpreted an uninterpreted functions.  Interpreted functions include mathematical operations and set operations.  A term that does note begin with the name of an interpreted function is taken to be an uninterpreted function.  Thus, the formula using the interpreted function + and the uninterpreted function symbol node

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

Observed predicates are useful for describing fixed relationships in a problem instance. The true ground literals for such predicates are specified in a list provided to the Schema interpreter.  The interpreter will then assume that all other literals for the predicates that appear in that list are asserted to be false.

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

Note that the expression (and (smaller a b) (smaller b c)) appears as a *test* in the innermost **all**.  Recall that this is valid because observed literals can appear in a test.  Evaluating the form can add additional pairs to the observed predicate "smaller".  The Schema program therefore re-evaluates *every* observed quantified formula if *any* such formula adds a *new* observed literal.  

## Constraint Satisfaction

Discrete constraint satisfaction problems (CSPs) can easily be represented in Schema.  The answer can be read off from the symbolic form of the SAT solution generated by the interpret function.

Multi-valued variables in CSPs can be encoded as follows.  Suppose the CSP has a variable named Color whose values can be Red, Blue, or Green.  In Schema, we create a proposition named Color, a domain ColorValues containing the constants Red, Blue, and Green, and assert that Color holds for exactly one ColorValue.

```
(domain ColorValue (set Red Blue Green))
(exists c ColorValue (Color c))
(not (exists (c1 c2) ColorValue (neq c1 c2) (and (Color c1) (Color c2))))
```

Deduction 
---------------------------------------

Satisfiability testing can be used for deduction by negating the conclusion to be drawn from a set of assumptions. For example, suppose that Bob is shorter than Alice, Alice is shorter than Charlie, and shorter is transitive. Can you conclude that there is someone who is shorter than two other people? This problem could be encoded in Schema as follows for proof by refutation.  The (unnegated) conclusion holds if the formula is unsatisfiable.

```
(domain Person (set Alice Bob Charlie))  
(shorter Alice Bob)  
(shorter Bob Charlie)  
(all (x y z) Person true (implies (and (shorter x y) (shorter y z)) (shorter x z)))  
(not (exists (x y z) Person (neq y z) (and (shorter x y) (shorter x z))))
```

Schema provides an alternative way of encoding a deduction problem by using the **prove** construct.  In this case, the last line above would be replaced by:

```
(prove () true (exists (x y z) Person (neq y z) (and (shorter x y) (shorter x z))))
```

Note that the formula to be deduced is not negated.  Use of prove makes makes the goal of the Schema problem clearer to a user.  

## Answer Extraction for Deduction

 Suppose we want to also *derive* the constant for person who is shorter than two other people. Schema provides the operator "prove" to support answer extraction from proofs of unsatisfiability. A single prove operation may appear as the last schema in the list of input schemas. The last schema in previous example would be changed to:

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

The input formulas need not be in conjunctive normal form. Converting a formula to CNF using only the user-defined propositions can cause its size to increase exponentially. By creating new propositions, the Schema interpreter can guarantee the size of the output CNF formula is only exponential in the nesting of quantifiers. Specifically, where

> M = number of input formulas  
> L = length of the longest input formula  
> D = size of the largest set appearing in a quantification statement  
> N = deepest nesting of quantifiers in a formula

the size of the output CNF is $O(M*L*D^N)$.

When new propositions are introduced in this manner, the relationship between the input and output formulas is that the output formula entails the input formula and any model of the input formula can be extended to a model of the output formula.

## Options

The input to Schema may include the following options, which should appear before any formulas.

```
; Allow new propositions to be created to reduce the size of the instantiated formula (default).
(option compact-encoding 1) 
; Do not create new propositions 
(option compact-encoding 0) 

; Enable tracing: prints [TRACE] lines showing domains, variable bindings, and clause counts.
(option trace 1)
; Disable tracing (default).
(option trace 0)
```

When tracing is enabled, the interpreter prints diagnostic output to standard output as it works:

- `[TRACE] Domain NAME = (val ...)` — each domain as it is defined
- `[TRACE] Formula: (OP ...)` — each top-level formula entering the parser
- `[TRACE] ALL/EXISTS/FOR VAR = VAL` — each variable binding tried by a quantifier
- `[TRACE] Multiply: N x M -> K clauses` — clause counts at each OR-distribution step

The multiply trace is especially useful for diagnosing exponential clause blowup. When compact encoding is disabled, each multiply step performs a full cross-product; the clause count shown will grow multiplicatively. With compact encoding enabled, auxiliary propositions are introduced and the count grows only linearly.

## Running Schema

Requires SBCL and Quicklisp. The SAT solver defaults to `kissat` (configurable via the `sat-solver` variable in `schema.lisp`).

Load the interpreter interactively:

```sh
sbcl --eval "(load \"schema.lisp\")"
```

Run end-to-end on a `.wff` file:

```sh
sbcl --eval "(load \"schema.lisp\")" \
     --eval "(solve \"myfile.wff\")" \
     --eval "(quit)"
```

**Note:** On some SBCL installations the short flag `-e` is not recognized. Always use `--eval` (long form).

## Testing

Tests are split into two categories: `instantiate` tests (checking CNF generation) and `solve` tests (checking end-to-end SAT solving and answer extraction). Each category has three directories:

| Directory | Purpose |
|---|---|
| `tests_instantiate/` | `.wff` files for instantiate tests in progress |
| `passed_instantiate/` | `.wff` and `.scnf` files for verified passing instantiate tests |
| `gold_instantiate/` | Reference `*_gold.scnf` files for instantiate comparison |
| `tests_solve/` | `.wff` files for solve tests in progress |
| `passed_solve/` | `.wff` and `.answer` files for verified passing solve tests |
| `gold_solve/` | Reference `*_gold.answer` files for solve comparison |

### Running instantiate tests

```sh
bash run-test-instantiate.sh <testname>   # e.g. bash run-test-instantiate.sh test_all_exists
```

This instantiates `tests_instantiate/<testname>.wff`, writes `tests_instantiate/<testname>.scnf`, and prints the output. Compare against the gold file:

```sh
diff tests_instantiate/<testname>.scnf gold_instantiate/<testname>_gold.scnf
```

### Running solve tests

```sh
bash run-test-solve.sh <testname>   # e.g. bash run-test-solve.sh test_simple_deduction
```

This runs `solve` on `tests_solve/<testname>.wff`, writes `tests_solve/<testname>.answer`, and prints the output. Compare against the gold file:

```sh
diff tests_solve/<testname>.answer gold_solve/<testname>_gold.answer
```

**Note:** Gensym symbols (`#:XXnnn`) in instantiate output will have different numbers across SBCL sessions. When gensyms are present, compare clause counts and structure rather than exact text.

### Known limitation: compact-encoding and nested exists

With `(option compact-encoding 0)`, the OR-distribution step performs a full cross-product of clauses instead of introducing auxiliary Tseitin propositions. Nested `exists` quantifiers over large domains can cause exponential clause blowup. Keep domains small (≤ 3 values) when using `compact-encoding 0` with nested quantifiers, or omit the option to use the default Tseitin encoding.

## Implementing SatPlan in Schema

To be written.

Schema BNF
----------

    <schema> = <option> | <domain declaration> | <alias declaration> | <formula> | <observations>
    
    <option> = (option <option name> <integer expression>)
    
    <option name> = compact-encoding | trace
    
    <domain declaration> = (domain <domain name> <set expression>)
    
    <alias declaration> = (alias <term name> <term>)
    
    <formula> = <proposition> | (not <formula>) | 
    		(and <formula>*) | (or <formula>*) |  
        (implies <formula> <formula>) | (equiv <formula> <formula>) |  
        (all <variable> <set expression> <test> <formula>) |  
        (all (<variable>+) <set expression> <test> <formula>) |  
        (exists <variable> <set expression> <test> <formula>) |  
        (exists (<variable>+) <set expression> <test> <formula>) |  
        (if <test> <formula>) |  
        (prove ((<variable> <set expression>)*) <test> <formula>)
    
    <proposition> = <predicate symbol> | true | false | 
    		(<predicate symbol> <term>*) |
    
    <set expression> = <domain name> | (set <term>+) | 
    		(range <integer expression> <integer expression>) |  
        (union <set expression> <set expression>) | 
        (intersection <set expression> <set expression>) |  
        (set-difference <set expression> <set expression>) | 
        (for <variable> <set expression> <test> <set expression>) |
        (for (<variable>+) <set expression> <test> <set expression>) |
        (lisp <lisp list valued expression>)
    
    <test> = <integer expression>
    
    <term> = <constant symbol> | <integer expression> | 
    		<variable> | <term name> |
        (<uninterpreted function symbol> <term>*)
    
    <integer expression> = <integer> | 
    		true | false |
    		<variable ranging over an integer domain> | 
    		(<observed predicate symbol> <term>*) |  
        (member <term> <set expression>) | 
        (alldiff <term> <term>+) |  
        (not <integer expression>) | 
        (and <integer expression>\*) | 
        (or <integer expression>\*) |  
        (<operator> <integer expression> <integer expression>) |  
        (lisp <lisp integer valued expression>)
    
    <operator> = + | - | \* | div | rem | mod | < | <= | > | >= | = | eq | neq | \*\* | bit
    
    <observations> = (observed <observed-formula>+)
    
    <observed-formula> = <proposition> |
    		(and <observed-formula>*) | 
        (all <variable> <set expression> <test> <observed-formula>) |  
        (all (<variable>+) <set expression> <test> <observed-formula>) |  
        (if <test> <observed-formula>) 

## Using Schema with Python

## Using Schema as an LLM Tool
