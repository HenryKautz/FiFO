# FiFO

FiFO is a finite-domain first-order logic language that compiles to propositional CNF for SAT solving. The interpreter is written in Common Lisp (SBCL).

## Project Structure

- `lisp/` — All Lisp sources and the SatPlan axioms (the installable library):
  - `lisp/FiFO.lisp` — Main interpreter: parser, CNF generation, SAT integration, answer extraction
  - `lisp/pddl2fifo.lisp` — PDDL → FiFO wff translator (SatPlan); `:pddl-evidence` translates PDDL modal evidence forms (`translate-evidence-form`: always/at-end/hold-during/occur-sometime/never/at) to FiFO and returns them (3rd value) for the planner's separate evidence scnf
  - `lisp/planner.lisp` — smallest-horizon planning driver; also tier-3 conditioning (`--evidence`/`--evidence-file` FiFO forms, or `--pddl-evidence`/`--pddl-evidence-file` PDDL modal forms translated via pddl2fifo, instantiated via `parse-same-env` into a separate `<root>-evidence.scnf`) and `--marginals` (weighted model counting via `--counter maxent|<addmc>`)
  - `lisp/reweight.lisp`, `lisp/maxent.lisp` — weight-learning pipeline; `maxent.lisp` also has `(marginals ...)` (exact marginal inference by enumeration)
  - `lisp/plearn.lisp` — PDDL weight-learning orchestrator (`learn-pddl`)
  - `lisp/wmc.lisp` — FiFO→ADDMC bridge: `(wmc ...)` weighted model count and `(marginals-addmc ...)` marginals via the external ADDMC counter (emits MCC weighted CNF, shells out, parses the count)
  - `lisp/ddnnf.lisp` — FiFO's own pure-Lisp d-DNNF compiler + circuit evaluator (no external binary). `(ddnnf-compile ...)` trace-compiles the hard clauses (grown from maxent's DPLL: decisions→OR, disjoint components→AND, component cache→DAG; smooth-by-construction) into a circuit; `(ddnnf-query ...)`/`(ddnnf-marginals ...)` get Z and ALL marginals in two passes. Unit-literal evidence reuses the compiled circuit (compile-once/query-many); non-unit evidence recompiles from the stored clauses. `(ddnnf-save ...)`/`(ddnnf-load ...)` persist a circuit to a readable `.dnnf` file (`(ddnnf-marginals-sets ...)` queries many evidence sets against one compile). Node cap `*ddnnf-node-limit*`; FiFO-scale instances only — use ADDMC for large/high-treewidth ones. `(ddnnf-compile-d4 ...)` is an alternative producer: it shells out to the external **d4** (d4v2) compiler (`*d4*`/`D4` env), parses + smooths its arc-format dump into the SAME struct, so all of query/evidence/persistence is reused (d4 compiles only the Boolean structure; weights stay on the FiFO side). `ddnnf-marginals` takes `:compiler :home|:d4`
  - `lisp/satplan.wff` — domain-independent SatPlan axioms (a runtime dependency)
- `bin/` — Shell scripts: `planner.sh` (planner CLI), `learn.sh` (scnf weight-learning CLI), `learn-pddl.sh` (PDDL weight-learning CLI), `marginals.sh` (marginal inference on an scnf; `--solver maxent` enumeration (default), `--solver addmc`, `--solver ddnnf` (FiFO's own d-DNNF compiler), or `--solver d4` (compile the structure with the external d4 compiler, same circuit machinery); `--save-circuit`/`--circuit` persist & reuse a compiled circuit for ddnnf/d4), `wmc.sh` (weighted model count / partition function via ADDMC), `cleanupfifo.sh` (delete intermediate files), `run_regression_tests.sh`
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

The weighted-model-counting bridge (`lisp/wmc.lisp`, `bin/wmc.sh`, `marginals.sh --solver addmc`) shells out to a separate **ADDMC** executable — a macOS fork at `github.com/HenryKautz/ADDMC` (built locally at `../ADDMC/addmc`). It is located via the `*addmc*` lisp variable, which defaults to the `ADDMC` environment variable, else `addmc` on `PATH`; the shell scripts also accept `--addmc-bin <path>`. ADDMC is optional — only the WMC features need it.

Similarly, `marginals.sh --solver d4` (and `ddnnf-compile-d4` in `lisp/ddnnf.lisp`) shells out to the **d4** (d4v2) d-DNNF compiler — a macOS fork at `github.com/HenryKautz/d4v2`, whose `demo/compiler` is built locally at `../d4v2/demo/compiler/build/compiler`. Located via the `*d4*` lisp variable (defaults to the `D4` env var, else that sibling-checkout path); the shell script also accepts `--d4-bin <path>`. Optional — only `--solver d4` needs it. d4 compiles only the Boolean structure; FiFO smooths the dump and applies weights at the leaves, reusing all the ddnnf circuit machinery.

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
