# SatPlan Visualizer

A web page that draws a grid planning problem and steps through a solution.
It runs entirely in the browser: open `index.html` (double-click it, or
`open SatPlan/Visualizer/index.html`), choose a problem and optionally a
solution, or drop the files anywhere on the page. Nothing is uploaded and no
server is needed. It does not run a planner (yet).

![The 5x5 example at step 8](screenshot.png)

## What it shows

- **Map.** Each place is a square at its grid cell: ppgen's grid problems name
  places `p<row>-<col>`, row 1 at the top. (Other place names are laid out in
  a square in declaration order, with a warning.) Roads are lines with an
  arrowhead at each end that can be driven *to*: two arrowheads for a two-way
  road, one (and a dashed line) for a one-way road. Airports are tinted and
  marked ✈; flight routes between airports are not drawn.
- **Inside a square**, each kind has its own corner:
  - goal destinations (**G1**, **G2**, …) top left, a dashed outline in the
    color of the package they are for, filled once achieved;
  - packages on the ground (**P1**, …) top right;
  - trucks (**T1**, …) and airplanes (**A1**, …, rounded) along the bottom, each
    vehicle in its own color, with the packages it carries as badges on it.

  Several of one kind in one place overlap, each further one offset up and to
  the right so its edge shows. Hover over anything for its full name.
- **Goal.** The hard goal, as one line per conjunct; each line is a
  disjunction. Preferences are ignored. Literals true in the displayed state
  are highlighted, and each line is marked ✓ when one of its literals holds.
- **Solution.** The actions by step. ◀ ▶ (or the arrow keys, Home and End)
  step through it; clicking a step jumps there. The map shows the state at the
  current step, and the drives about to be taken are drawn in their vehicle's
  color.

## Solution formats

| Format | Example | Notes |
|---|---|---|
| FiFO `.answer` | `(OCCURS (DRIVE TRUCK1 P2-1 P3-1) 1)` | `HOLDS` facts give the state at each slice |
| action `@` step | `(drive truck1 p2-1 p3-1) @ 1` | `.answer` with each `OCCURS` rewritten; `HOLDS` lines optional |
| plain list | `(drive truck1 p2-1 p3-1)` | one action per step; `t: (action)` groups by step, a trailing `[cost]` is ignored |

Where the file has `HOLDS` facts for a step, the state is read from them;
otherwise it is computed by applying the actions (load, unload, transfer,
drive, fly, and the classic logistics names load-truck, drive-truck, …). When
both exist they are compared, and any disagreement is shown as a warning, as
are actions naming objects the problem does not have.

`examples/` has a 6×6 problem (two trucks, four packages, a 12-way disjunctive
goal) with its FiFO answer, and a 5×5 problem with two airports and an
airplane, whose goal is a conjunction of three disjunctions, with its solution
in all three formats.

## Code

TypeScript in `src/`, compiled to the single script `visualizer.js` (checked in,
so the page works without building):

| File | Contents |
|---|---|
| `src/sexpr.ts` | s-expression reader (PDDL and answer files) |
| `src/problem.ts` | the problem: objects, roads, initial state, goal lines, grid layout |
| `src/plan.ts` | the three solution formats, plan simulation, goal evaluation |
| `src/render.ts` | the map as SVG |
| `src/app.ts` | the page: file loading, panels, stepping; `Viz.load(...)` for programmatic use |

After changing anything in `src/`, rebuild and test:

```sh
tsc -p SatPlan/Visualizer             # writes SatPlan/Visualizer/visualizer.js
bash tests/run-test-visualizer.sh     # also fails if visualizer.js is stale
```

The tests (`tests/test.ts`, run under Node) check the plan simulation against
FiFO's own `HOLDS` states: the same plan with the `HOLDS` lines removed must
reproduce every one of them.
