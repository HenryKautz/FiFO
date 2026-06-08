# Schema 2.0

Schema is a finite-domain first-order logic language that compiles to propositional CNF for SAT solving. The interpreter is written in Common Lisp (SBCL).

## Project Structure

- `schema.lisp` — Main interpreter: parser, CNF generation, SAT integration, answer extraction
- `satplan.lisp` — SatPlan implementation using Schema
- `run-schema.sh` / `run-schema-script.lisp` — Shell/Lisp scripts to run Schema
- `*.wff` — Schema formula input files
- `*.scnf` — Symbolic CNF output files (intermediate)
- `*.cnf` — DIMACS CNF files (input to SAT solver)
- `*.out` / `*.satout` — SAT solver output
- `README.md` — Full language reference and user guide
- `tests/` — Test `.wff` inputs not yet verified (includes new/in-progress tests)
- `passed/` — Test `.wff` and `.scnf` files for tests that have been verified correct
- `gold/` — Reference `*_gold.scnf` files for comparing against `instantiate` output

## Key APIs (in schema.lisp)

- `(parse schemas &optional observations)` — Parse Schema forms to ground clauses
- `(instantiate "file.wff")` — File-based: wff -> scnf
- `(propositionalize "file.scnf")` — File-based: scnf -> DIMACS cnf + map
- `(satisfy "file.cnf")` — Run SAT solver (default: kissat)
- `(interpret "file.satout")` — Map SAT output back to symbolic literals
- `(solve "file.wff")` — End-to-end: wff -> solution

## Running

Requires SBCL with Quicklisp. The SAT solver defaults to `kissat` (configurable via `sat-solver` variable).

```sh
./run-schema.sh
```

**Important:** SBCL on this system requires `--eval` (long form); `-e` is not recognized and silently drops all eval forms.

## Testing

Run a single test with `run-test.sh`:

```sh
bash run-test.sh <testname>   # e.g. bash run-test.sh test_all_exists
```

This runs `instantiate` on `tests/<testname>.wff`, writes `tests/<testname>.scnf`, and cats the output.

Compare output against gold:
```sh
diff tests/<testname>.scnf gold/<testname>_gold.scnf
```

Note: `#:XXnnn` gensym numbers will differ across SBCL sessions — compare clause counts and structure rather than exact text when gensyms are present.

### Known issues

- Nested `exists` with `(option compact-encoding 0)` causes exponential clause blowup (cross-product expansion). Keep domains small (≤3 values) or omit the option to use Tseitin encoding.
- `test_nested_exists_nocompact.wff` uses 3 boys / 2 girls to stay tractable with compact-encoding disabled.
- `test_nested_exists_compact.wff` uses full 4-boy / 4-girl domains with compact-encoding enabled.
