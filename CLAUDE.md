# FiFO

FiFO is a finite-domain first-order logic language that compiles to propositional
CNF for SAT solving, MaxSAT (MAP) and weighted model counting. The interpreter is
Common Lisp (SBCL).

**Design history** — why things are the way they are, what was measured, what
reviews found, which mutations each suite catches — is in `design-notes.md`. Read
the relevant section there before changing a component; this file keeps only the
rules and the traps.

## Layout

- `lisp/` — the installable library. `FiFO.lisp` (parser, CNF, solving, answers),
  `auxatoms.lisp` (TSEITIN/WEIGHTED-FORMULA aux atoms + gensym guard; loaded by
  both FiFO.lisp and reweight.lisp), `pddl2fifo.lisp`, `planner.lisp`,
  `reweight.lisp`/`maxent.lisp`/`plearn.lisp` (learning; maxent also exact
  marginals), `wmc.lisp` (ADDMC, SharpSAT-TD), `ddnnf.lisp` (own d-DNNF compiler +
  d4 import, projection), `mcsat.lisp` (WalkSAT v58 MC-SAT), `maxterm.lisp`,
  `hypotheses.lisp`, `satplan.wff`, `solvers.dat`.
- `bin/` — CLIs: `solve.sh`, `map.sh`, `planner.sh`, `marginals.sh`, `wmc.sh`,
  `learn.sh`, `learn-pddl.sh`, `recognize.sh`, `cleanupfifo.sh`,
  `install-solvers.sh`, `run_regression_tests.sh`; helpers `fifo-lisp.sh`,
  `fifo-solvers.sh`, `fifo-answer.sh`; `rc2-maxsat.py`.
- `SatPlan/` — `ppgen` (problem generator) and `evgen` (evidence generator),
  `Examples/` (incl. `Plan_Recognition/`). `pddl/` — the domain library.
- `Probability/` — `probability.md` (practice), `probability-background.md`
  (theory, documents only what FiFO HAS; proposals go in `discussion.md`).
- `README.md` — language reference. `software-components.md` — every script's full
  option table, Lisp modules, external solver catalog. It is the REFERENCE for
  ppgen/evgen flags; `satplan.md` explains and links to it.
- `Makefile` — `make install`: `bin/` → `~/bin`, `lisp/` → `~/lib/fifo/lisp`,
  `pddl/` → `~/lib/fifo/pddl`, plus ppgen/evgen. `BINDIR`/`LISPDIR` overridable.

## Key APIs (lisp/FiFO.lisp)

`(parse schemas &key static-list)`, `(instantiate "f.wff")` → scnf,
`(propositionalize "f.scnf" &key cnf-format)` → DIMACS + map, `(satisfy "f.cnf")`,
`(interpret "f.satout")`, `(solve "f.wff" &key solver cnf-format preprocessor
preprocessor-techniques timeout)`.

## Running

- SBCL + Quicklisp. **Use `--eval`; `-e` is silently ignored.**
- Default SAT solver `kissat`. Optional external tools, all found on PATH (no env
  vars or `--*-bin` flags): `addmc`, `sharpSAT` (+ `flow_cutter_pace17` beside it),
  `d4`, `walksat` (v58+, needs `-mcsat`), MaxPre, python-sat for `rc2`.
  `install-solvers.sh` builds them (EvalMaxSAT on macOS needs Homebrew g++).
- **Lisp location** (`bin/fifo-lisp.sh`, sourced by every script, exports
  `FIFO_LISP`): the env var if set; else `<script dir>/../lisp` if it holds
  FiFO.lisp; else `~/lib/fifo/lisp`.
- **Domain lookup** for `(:domain name)` (`resolve-domain-file`): beside the
  problem, then the cwd, then `$FIFO_LISP/../pddl`; prints `; domain name: path`.
  Explicit `--domain` is taken as given; a bare name not in the cwd falls back to
  the library (`_fifo_find_domain`, uses `cd -P`). Leave this as is (user decision).

## Rules and traps — each of these once produced a SILENT wrong answer

**Solvers and options**
- `lisp/solvers.dat` is the single source of truth for solvers/counters, read by
  both shell and Lisp. Add a solver there and nowhere else. Every script validates
  names via `fifo-solvers.sh` (name, kind, installed) BEFORE doing work.
- Solving policy belongs to the caller. A `.wff` may set only
  `*compact-encoding*`, `*tracing*`, `*satplan-numslices*`; the policy options are
  refused. A wff's options are SCOPED to the call that read it
  (`with-wff-option-scope`, `:outer`/`:continue`) — never SETQ a global from a wff.
- `solver-verdict` reads the DIMACS `s` line first. Never scan for the substring
  `SAT` (every MaxSAT banner contains it).
- `*solver-timeout*` bounds every solver/counter run, in-process (no `timeout`
  binary on macOS); SIGTERM then SIGKILL.
- MaxPre: reconstruction is mandatory; never on the WMC path (preserves cost, not
  count); errors with plain CNF.
- Differences of MaxSAT minima (max-term, recognize.sh) need an EXACT solver
  (default `bin/rc2-maxsat.py`); anytime solvers' bounds don't cancel.

**Encoding and counting**
- Every aux atom must be DEFINED (count-neutral): compact-encoding selectors are
  `(TSEITIN n)` with S⇔D; reified weights are `(WEIGHTED-FORMULA n)` with A⇔φ;
  preferences are biconditional; ObsDone/ObsAt monitors are biconditional. A
  one-way encoding leaves a free atom and silently doubles counts.
- Tseitin definitions go to `*tseitin-definitions*` at top level, only inside
  `clauses-with-definitions`; never return them inside a formula (an enclosing OR
  switches them off). TSEITIN and WEIGHTED-FORMULA are reserved names.
- Evidence parsed separately is namespaced (`wmc--evidence-namespace`, first unused
  EVIDENCE/EVIDENCE2/…). Readers refuse gensyms (`scnf-check-no-gensyms`).
- `Weights` is a global special reset by `parse`: never bind a weight list to that
  name (use `weight-forms`).
- An evidence/hypothesis atom the theory lacks constrains NOTHING (parse mints it
  fresh). Every entry point checks against the instantiated atoms: a typo errors;
  a real term at an out-of-range slice resolves to false so the horizon can grow.
  Note scnf writes a 0-ary predicate as `P`, not `(P)`.
- `weight :odds r` = cost −ln r (a FACTOR on existing odds, not P=r/(1+r) unless
  the literal is free); in pddl2fifo a preference's `:odds` is +ln r (violation
  penalty). `:odds` and `:probability` are alternatives.
- WMC files: `:mcc-2020` (ADDMC) and `:mcc-2024` (SharpSAT-TD) are NOT
  interconvertible — 2024 writes both polarities of every variable. Parse counts as
  exact rationals; never let Z underflow to 0 (reads as UNSAT). `:fold` only for
  FiFO's own runs, never `wmc-write-wcnf`.
- SBCL threads see GLOBAL specials: `wmc--parallel-map` rebinds the timeout vars
  and `*default-pathname-defaults*`; scratch names are taken under a lock.
- d4 projection: exact only when kept atoms determine the rest — guarded by the
  Padoa check, never assumed. Never smooth over dropped vars (Z ×2 per atom,
  invisible in marginals).
- MC-SAT: check ESS AND the `mixing:` line — a frozen chain gives 0/1 marginals.
- max-term output is `MAXTERM-MARGINAL` deliberately; it is not a Gibbs marginal.

**Planning / recognition**
- `occur-in-order` windows are quantifier guards, never named slice constants (a
  slice past the horizon makes the constraint vacuous). Two identical adjacent
  observations can't share a slice even in nonstrict order.
- recognize.sh: hypotheses = nullary disjuncts of the parsed goal; priors are by
  NAME, relative weights, normalised before forwarding to marginals.sh (which
  takes probabilities); forward nothing when the user gave none.
- evgen/recognize.sh: a multi-form evidence file is refused (`(not A B)` reads as
  `(not A)`); use `--recognition 1`.
- `map.sh` scratch root must contain no `.` (FiFO derives `.satout` from the first
  dot).

**Shell**
- Scripts run under macOS `/bin/bash` 3.2: no `mapfile`, `${v,,}`, empty-array
  `"${a[@]}"` (use `${a[@]+"${a[@]}"}`).
- `planner.sh` path math must `pwd -P` both sides (symlinked `/tmp`).
- `cleanupfifo.sh` never deletes git-tracked files or touches `tests/`.
- `make-scratch-file-root` includes the pid; SBCL's default random state is
  identical across processes.

## Testing

- Full suite from the repo root: `bash bin/run_regression_tests.sh` (tests `lisp/`;
  set `FIFO_LISP` for an installed copy).
- Gold runners, run from inside `tests/`: `bash run-test-instantiate.sh <name>`
  (`tests_instantiate/` → `.scnf`, compare `gold_instantiate/<name>_gold.scnf`) and
  `bash run-test-solve.sh <name>` (`tests_solve/` → `.answer`, compare
  `gold_solve/<name>_gold.answer`). Instantiate output is deterministic.
- Behavioural suites `tests/run-test-*.sh`, runnable from anywhere: action-costs,
  cleanup, cli, docs, evgen, evidence, hypotheses, maxsat, maxterm, mcc-dialect,
  mcsat, odds, options, paths, pddl, ppgen, project, recognize, sharpsat, solvers,
  tseitin, weight-formula. Each skips cleanly (exit 0) when its optional binary is
  missing. `run-test-pddl.sh` diffs translations against checked-in wffs — update
  them when emitter output legitimately changes.
- Suite conventions: compare against an INDEPENDENT oracle, never FiFO against
  itself; refuse to pass vacuously (all marginals 0/1, no aux atom produced, a flat
  posterior); mutation-check new cases. Destructive tests run in throwaway repos.

### Known issues

- Nested `exists` with compact encoding off blows up exponentially; keep domains
  ≤3 values or leave compact on (`test_nested_exists_nocompact.wff` uses 3×2).
