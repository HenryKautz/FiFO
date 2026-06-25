# FiFO

FiFO is a finite-domain first-order logic language that compiles to propositional CNF for SAT solving. The interpreter is written in Common Lisp (SBCL).

## Project Structure

- `lisp/` — All Lisp sources and the SatPlan axioms (the installable library):
  - `lisp/FiFO.lisp` — Main interpreter: parser, CNF generation, SAT integration, answer extraction
  - `lisp/pddl2fifo.lisp` — PDDL → FiFO wff translator (SatPlan)
  - `lisp/planner.lisp` — smallest-horizon planning driver
  - `lisp/reweight.lisp`, `lisp/maxent.lisp` — weight-learning pipeline
  - `lisp/plearn.lisp` — PDDL weight-learning orchestrator (`learn-pddl`)
  - `lisp/satplan.wff` — domain-independent SatPlan axioms (a runtime dependency)
- `bin/` — Shell scripts: `planner.sh` (planner CLI), `learn.sh` (scnf weight-learning CLI), `learn-pddl.sh` (PDDL weight-learning CLI), `run_regression_tests.sh`
- `Makefile` — `make install` copies `bin/` → `~/bin` and `lisp/` → `~/lib/fifo/lisp` (override `BINDIR`/`LISPDIR`)
- `SatPlan/Examples/` — example PDDL domains/problems
- `Learning/` — weight-learning docs (`learning.md`) and example `.scnf` files
- `*.wff` — FiFO formula input files
- `*.scnf` — Symbolic CNF output files (intermediate)
- `*.cnf` — DIMACS CNF files (input to SAT solver)
- `*.satout` — SAT solver output
- `README.md` — Full language reference and user guide
- `tests/` — All test infrastructure (see below)

**Locating the lisp:** the shell scripts find the lisp via the `FIFO_LISP`
environment variable. `bin/planner.sh` defaults it to the installed
`~/lib/fifo/lisp`; the test scripts default it to the source checkout's `lisp/`
so they exercise the working copy. Set `FIFO_LISP` to override either.

## Key APIs (in lisp/FiFO.lisp)

- `(parse schemas &key observation-list)` — Parse FiFO forms to ground clauses (all post-first args are keyword args)
- `(instantiate "file.wff")` — File-based: wff -> scnf
- `(propositionalize "file.scnf")` — File-based: scnf -> DIMACS cnf + map
- `(satisfy "file.cnf")` — Run SAT solver (default: kissat)
- `(interpret "file.satout")` — Map SAT output back to symbolic literals
- `(solve "file.wff")` — End-to-end: wff -> solution

## Running

Requires SBCL with Quicklisp. The SAT solver defaults to `kissat` (configurable via `sat-solver` variable).

**Important:** SBCL on this system requires `--eval` (long form); `-e` is not recognized and silently drops all eval forms.

## Testing

All test files and scripts live under `tests/`. Two test runners (must be run from inside `tests/`):

```sh
cd tests
bash run-test-instantiate.sh <testname>   # e.g. bash run-test-instantiate.sh test_all_exists
bash run-test-solve.sh <testname>         # e.g. bash run-test-solve.sh test_simple_deduction
```

`run-test-instantiate.sh` runs `instantiate` on `tests_instantiate/<testname>.wff`, writes `tests_instantiate/<testname>.scnf`, and cats the output.

`run-test-solve.sh` runs `solve` on `tests_solve/<testname>.wff`, writes `tests_solve/<testname>.answer`, and cats the output.

The full suite runs from the repo root with `bash bin/run_regression_tests.sh` (it tests `lisp/` by default; set `FIFO_LISP` to test an installed copy).

Compare output against gold:
```sh
diff tests_instantiate/<testname>.scnf gold_instantiate/<testname>_gold.scnf
diff tests_solve/<testname>.answer gold_solve/<testname>_gold.answer
```

Test directories under `tests/`:

| Directory | Purpose |
|---|---|
| `tests_instantiate/` | In-progress `.wff` files for `instantiate` tests |
| `passed_instantiate/` | Verified passing `.wff` and `.scnf` pairs for `instantiate` |
| `gold_instantiate/` | Reference `*_gold.scnf` files for `instantiate` comparison |
| `tests_solve/` | In-progress `.wff` files for `solve` tests |
| `passed_solve/` | Verified passing `.wff` and `.answer` pairs for `solve` |
| `gold_solve/` | Reference `*_gold.answer` files for `solve` comparison |

Note: `#:XXnnn` gensym numbers will differ across SBCL sessions — compare clause counts and structure rather than exact text when gensyms are present.

### Known issues

- Nested `exists` with `(option compact-encoding 0)` causes exponential clause blowup (cross-product expansion). Keep domains small (≤3 values) or omit the option to use Tseitin encoding.
- `test_nested_exists_nocompact.wff` uses 3 boys / 2 girls to stay tractable with compact-encoding disabled.
- `test_nested_exists_compact.wff` uses full 4-boy / 4-girl domains with compact-encoding enabled.
