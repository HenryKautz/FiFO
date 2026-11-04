# Regenerate everything still built on an old clara-logistics domain

**Goal.** FiFO must use exactly one logistics domain, `pddl/clara-logistics.pddl`:
`load` and `unload` cost `(handle-cost)` each, `drive` costs `(drive-cost)`, `fly`
costs `(fly-cost)`, and there is **no `transfer` action**. CLARA was regenerated with
it; FiFO's own fixtures, examples and two test suites were not. The old domain
`pddl/clara-logistics-old.pddl` has been **deleted** (in the same commit as this
file) so that anything still using it fails instead of quietly working. Your job:
regenerate or recalibrate everything below against `clara-logistics`, until no file
names `clara-logistics-old` or `clara-logistics-handling` (outside history notes) and
every suite passes.

Read the repo's `CLAUDE.md` first (rules and traps), and `design-notes.md` for the
component you touch. Follow its suite conventions: compare against an INDEPENDENT
oracle, refuse to pass vacuously, mutation-check every case you add or recalibrate.

## 0. Before starting

- `git pull` FiFO and CLARA (the CLARA checkout beside FiFO: `<FiFO>/../CLARA`).
- Delete any installed copy of the old domain, or the installed scripts will still
  resolve it by name: `rm -f ~/lib/fifo/pddl/clara-logistics-old.pddl`, then
  `make install` from the checkout.
- Confirm the inventory: `grep -rn -E 'clara-logistics-(old|handling)' . --exclude-dir=.git`.
  Expected hits are listed below; history notes (`TO-DO.md` §3, `software-components.md`
  near line 574, `satplan.md` near line 412, CLARA's README near line 104) are to be
  reworded, not left claiming the old file exists.

## 1. `tests/run-test-evidence.sh` -- 18 of 42 fail now (loud, good)

The "occur-in-order as a windowed trajectory constraint" block (from about line 404)
copies `pddl/clara-logistics-old.pddl` (line ~411) and hard-codes observed actions,
slices and costs from a fixed-seed ppgen problem's optimal plan under the OLD domain.

- Make the fixture use `pddl/clara-logistics.pddl` (ppgen writes `(:domain
  clara-logistics)` and the `(= (handle-cost) 1)` line already).
- Re-derive every hard-coded action, slice and cost from a fresh optimal plan under
  the new domain, proved optimal by an EXACT solver (`EvalMaxSAT_bin` or
  `rc2-maxsat.py`, per CLAUDE.md; not tt-open-wbo). Keep each case's MEANING: e.g.
  "strict ordering serializes parallel observations" needs a plan that really does
  two observed actions in one slice -- if the new plan has none, pick another
  seed/fixture that does, and say so in a comment.
- Each recalibrated case must still fail when the feature it tests is broken
  (mutation-check: e.g. drop the window bound, make strict non-strict).

## 2. `tests/run-test-evgen.sh` -- SKIPS everything now (silent, bad)

`DOMAIN=` at line ~31 names the deleted file. The suite then cannot solve its fixture
and prints "skipping: could not solve the fixture problem -- no MaxSAT solver
'EvalMaxSAT_bin'?" and exits 0: a missing DOMAIN reported as a missing SOLVER.

- First fix the skip: skip only when the solver is really absent (check it with
  `bin/fifo-solvers.sh`, as the other suites do); any other failure to solve the
  fixture is a FAIL with the planner's message.
- Then point it at `pddl/clara-logistics.pddl` and recalibrate the cases TO-DO.md §3
  lists (the `fly,in` mix ~line 117, "the evidence binds" ~287, "recognize.sh's
  negation" ~384, "the not-comply case is the more expensive" ~389, "a window
  excluding an observation breaks it" ~837, "the order matters" ~1004) from fresh
  exact-optimal plans, as in step 1. Expect others to move too; run it all.

## 3. The circuit visualizer's bundled example -- `SatPlan/Visualizer/circuit-examples/`

It is CLARA TwoPackage `grid3x3-1` as it was BEFORE the regeneration:
`grid3x3-1.pddl` says `(:domain clara-logistics-old)`; `grid3x3-1.dnnf`,
`grid3x3-1.wff` (+ `satplan.wff`) and the evidence files (`-obs1`, `-obs5`,
`-ord1`, evgen-style names: obsK = the first K observations) were made under the old
domain. `tests/run-test-circuit-viz.sh` still passes, because nothing there looks the
domain up -- but it is old-domain data.

- Rebuild it from CURRENT CLARA `TwoPackage/grid3x3-1`: its `grid3x3-1.pddl`
  (`:domain clara-logistics`), `recognition/grid3x3-1.pddl`, `circuits/grid3x3-1.dnnf`
  (projected d4 circuit, ~100 KB) and the plans in `goals/`.
- The suite's oracle counts the theory with SharpSAT-TD, independently of the
  circuit: today it instantiates `grid3x3-1.wff` + `satplan.wff`. Provide a theory
  whose model count equals the circuit's Z exactly (the suite asserts it): either a
  self-contained `.wff` that instantiates to CLARA's `scnf/grid3x3-1.scnf` (planner.sh
  / recognize.sh `--stop-after wff` at the recognition horizon), or bundle that
  `.scnf` and change the suite to read it. Either way the circuit and the oracle
  theory must be the SAME theory.
- Evidence files: make obs1/obs5-style files (evgen `--recognition`) and one
  `-ord1.txt` ordering file from the new plans, so every case of the suite still has
  something to test (a 5-observation file, prefixes, an ordering-only file, files for
  several goals).
- Recalibrate every hard-coded value in `tests/run-test-circuit-viz.sh` (horizon 7,
  slices, the literal `(occurs (load pkg1 truck1 p3-3) 2)`, the 4 hypotheses' order,
  menu counts `4`/`hidden 2`, etc.) from the new files.
- **Add the missing compound-hypothesis case** (the fix it tests is in this commit:
  CLARA sessions now score `recognition/<name>.pddl`, and a hypothesis that is a
  conjunction is the atom recognize.sh created, `(HOLDS (RECHYP<i>) H)`,
  `server/circuit-server.lisp` `cv--derived-atom`): build a small recognition problem
  whose goal is `(or (and ...) (and ...) ...)` -- e.g. from the 3x3 example, two
  packages, three or four conjunctions -- make its theory with `recognize.sh
  --stop-after scnf` (as CLARA's `scripts/compile-d4.py` does), compile it
  (`marginals.sh --solver d4 --project --save-circuit`, or `--solver ddnnf` with a
  larger SBCL heap: FiFO's own compiler exhausted a 1 GB heap at horizon 9 on a 3x3),
  and assert, for several evidence sets, that the server's P(h|E) for each
  conjunction equals SharpSAT-TD's Z(E ∧ the conjunction's own `(holds (at ..) H)`
  literals) / Z(E) -- the CONJUNCTS, not the RECHYP atom, so the hypothesis-to-atom
  mapping is checked independently. Mutation-check: shift the RECHYP index by one.
- Update `SatPlan/Visualizer/README.md` and `CIRCUIT-PLAN.md` where they describe the
  example.

## 4. The plan visualizer's examples -- `SatPlan/Visualizer/examples/`

- `examples/clara-logistics.pddl` is the OLD domain under the NEW name (free load and
  unload, a `transfer` action). Replace it with a copy of `pddl/clara-logistics.pddl`.
- `examples/clara-logistics-handling.pddl` is a third variant (load/unload cost a fixed
  1, no transfer), used by `grid6x6-1.pddl`. Retire it: move `grid6x6-1` to
  `(:domain clara-logistics)` with `(= (handle-cost) 1)` in `:init` (it keeps its
  `--drive-cost 2` and its 12 weighted preferences), and delete the file (also
  `tests/fixtures/broken-domain.pddl` names it -- check what that fixture tests and
  keep its point).
- Re-plan both problems under the new domain with an exact solver and replace their
  solutions: `grid5x5-air.answer`, `grid5x5-air-at.answer` (the `@` format),
  `grid5x5-air.plan` (plain list), `grid6x6-1.answer`. Give `grid5x5-air.pddl` its
  `(= (handle-cost) 1)` line (regenerate with ppgen from the settings in its header).
- Recalibrate `SatPlan/Visualizer/tests/test.ts`: the objective values (17 for the
  5x5, 96 for the 6x6), the "a load 1 and a drive 2 in the handling domain, a load 0
  in the plain one" case (the plain domain now charges handling: rework the case to
  test pricing by `(handle-cost)`), Goals/Costs/Total, the HOLDS-state cases, the
  Examples-menu domain names. The oracle there is FiFO's own HOLDS facts and
  `*OBJECTIVE*` -- keep it that way.
- Rebuild with `bash SatPlan/Visualizer/build.sh` (examples.js, domains.js,
  visualizer.js) and update the README's description of the examples (costs, files).

## 5. Finish

- `grep -rn -E 'clara-logistics-(old|handling)' . --exclude-dir=.git` finds only
  history notes, each saying the domain is gone.
- Mark `TO-DO.md` §3 done "by way (b)" with the date, and note this file's work.
- Run everything: `bash bin/run_regression_tests.sh`, and every
  `tests/run-test-*.sh` -- report any SKIP and why (a skip must be a missing optional
  binary, never a failure in disguise).
- Delete this file, commit with a message listing what was regenerated and each
  suite's pass count, and push. Leave scratch files out.
