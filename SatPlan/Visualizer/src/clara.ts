// The CLARA browser's catalogue: the problems of clara-examples.js (bundled
// from a CLARA checkout by build-clara-examples.sh) sorted into the columns
// Family / Size / Instance / Goal / Solver, from CLARA's file names:
//
//   <Family>/gridNxM-K.pddl                  the problem: goal "original problem"
//   <Family>/recognition/gridNxM-K.pddl      its recognition version
//   <Family>/goals/gridNxM-K-<goal>.pddl     one hypothesis as the hard goal,
//       <goal> = pkg1-p2-3 or pkg1-p2-4-pkg2-p3-4-... (object, place, ...)
//   <goal>-eval.answer, <goal>-tt.answer     EvalMaxSAT's and tt-open-wbo-inc's plans
//   <goal>.answer                            a copy of one of those two (the one
//       CLARA cut its evidence files from); not listed again
//
// Every plan's row shows its value: the main page's Total at the plan's end,
// pseudo goal utility off (planValuer).  The original problem's own plans
// (gridNxM-K-eval.answer etc.) are listed if there are any.  CLARA makes none,
// so otherwise it is offered the goal plan of highest value FOR THE ORIGINAL
// PROBLEM -- its lowest-cost one when it weights no goals -- the exact
// solver's on a tie: any plan that achieves one disjunct of the goal solves
// the original problem, though not necessarily optimally (each goal plan is
// optimal only at that goal's own shortest horizon).  The recognition problem
// gets no such plan.
//
// Anything else (none since build-clara-examples.sh left out the non-grid
// AAAI-2010-Benchmarks) is placed by its directory: Size is the subdirectory,
// Instance the file name.

namespace Viz {
  /** An entry of examples.js / clara-examples.js (tools/bundle-examples.ts). */
  export interface Example {
    problem: { file: string; text: string };
    domain?: { file: string; text: string };
    solutions: { file: string; text: string }[];
  }

  /** A row of the Solver column: what Open loads -- the problem of EXAMPLE with
   *  solution SOLUTION of example FROM (default EXAMPLE itself).  MISSING: a
   *  solver CLARA ran on this goal that left no plan file (grayed; opens the
   *  problem alone).  SOLVER: the solver's name alone; VALUE: the plan's value
   *  (PlanValuer); NOTE: shown under the columns when the row is chosen. */
  export interface ClaraLeaf {
    label: string; example: number; solution?: number; from?: number; missing?: boolean;
    solver?: string; value?: number; note?: string;
  }
  /** A row of any other column; a goal is MISSING when it has no solution file
   *  at all (grayed, but it can still be opened to show the problem). */
  export interface ClaraNode { label: string; children: ClaraNode[]; leaves?: ClaraLeaf[]; missing?: boolean }

  const SOLVERS: Record<string, string> = { eval: "EvalMaxSAT - exact", tt: "tt-open-wbo - anytime" };

  /** a FiFO answer's (*OBJECTIVE* N), or undefined */
  export function answerObjective(text: string): number | undefined {
    const m = /\(\s*\*OBJECTIVE\*\s+(-?[0-9.]+(?:e-?[0-9]+)?)\s*\)/i.exec(text);
    return m ? Number(m[1]) : undefined;
  }

  /** "pkg1-p2-4-pkg2-p3-4" -> "pkg1 at p2-4, pkg2 at p3-4"; undefined if it is not that shape */
  export function claraGoalLabel(suffix: string): string | undefined {
    const parts = suffix.match(/[a-z]+\d+-p\d+-\d+/gi);
    if (!parts || parts.join("-") !== suffix) return undefined;
    return parts.map((p) => p.replace(/^([a-z]+\d+)-/i, "$1 at ")).join(", ");
  }

  interface Placed { family: string; size: string; sizeKey: number[]; instance: string; goal: string; goalRank: number }

  function place(file: string): Placed {
    const parts = file.split("/");
    const family = parts[0];
    const base = parts[parts.length - 1].replace(/\.pddl$/i, "");
    const sub = parts.slice(1, -1).join("/");
    const g = /^grid(\d+)x(\d+)-(\d+)(?:-(.+))?$/i.exec(base);
    if (g && (sub === "" || sub === "goals" || sub === "recognition")) {
      const goal = g[4] === undefined
        ? (sub === "recognition" ? "recognition problem" : "original problem")
        : (claraGoalLabel(g[4]) ?? g[4]);
      return {
        family, size: `${g[1]}×${g[2]}`, sizeKey: [Number(g[1]), Number(g[2])], instance: g[3],
        goal, goalRank: g[4] === undefined ? (sub === "recognition" ? 1 : 0) : 2,
      };
    }
    return { family, size: sub || "—", sizeKey: [], instance: base, goal: "original problem", goalRank: 0 };
  }

  /** the Solver rows of one problem: its solutions, a <goal>.answer folded into
   *  the -eval/-tt plan it copies, and last "no solution" (the problem alone).
   *  For a goals/ problem (GOAL), each of SOLVERS appears even without a plan
   *  file -- CLARA ran both on every goal -- marked missing. */
  function solverLeaves(ex: Example, i: number, goal: boolean, valueOf: PlanValuer): ClaraLeaf[] {
    const stem = ex.problem.file.replace(/\.pddl$/i, "");
    const named: { label: string; j: number; rank: number; solver?: string }[] = [];
    let chosen: number | undefined;
    ex.solutions.forEach((s, j) => {
      const rest = s.file.slice(stem.length);
      const m = /^-([a-z0-9]+)\.answer$/i.exec(rest);
      if (rest === ".answer") chosen = j;
      else if (m && SOLVERS[m[1]]) named.push({ label: SOLVERS[m[1]], j, rank: m[1] === "eval" ? 0 : 1, solver: SOLVERS[m[1]] });
      else named.push({ label: s.file.split("/").pop()!, j, rank: 2 });
    });
    if (chosen !== undefined) {
      // beside -eval/-tt plans (CLARA's goals/), <goal>.answer is a copy of one
      // of them (the one CLARA later cut its evidence files from -- no evidence
      // is in the plan): not listed again.  One that copies neither, or one
      // anywhere else, is just a solution, listed by its file name.
      const same = named.find((n) => n.rank < 2 && ex.solutions[n.j].text === ex.solutions[chosen!].text);
      if (!same) named.push({ label: ex.solutions[chosen].file.split("/").pop()!, j: chosen, rank: 2 });
    }
    const rows: { label: string; j?: number; rank: number; solver?: string }[] = named;
    if (goal) {
      for (const [key, label] of Object.entries(SOLVERS)) {
        if (!named.some((n) => n.solver === label)) rows.push({ label, rank: key === "eval" ? 0 : 1 });
      }
    }
    rows.sort((a, b) => a.rank - b.rank || a.label.localeCompare(b.label));
    return [...rows.map((n): ClaraLeaf => {
              if (n.j === undefined) return { label: n.label, example: i, missing: true };
              const value = valueOf(i, i, n.j);
              // the solver's name, then the plan's value: "EvalMaxSAT - exact (−5)"
              const v = value === undefined ? "" : ` (${showValue(value)})`;
              const label = n.solver ? n.label.replace(n.solver, n.solver + v) : n.label + v;
              return { label, example: i, solution: n.j, solver: n.solver, value };
            }),
            { label: "no solution (problem only)", example: i }];
  }

  /** The value of solution SOLUTION of example FROM shown with the problem of
   *  example PROBLEM (the same one, or an original problem borrowing a goal's
   *  plan), or undefined when it cannot be had. */
  export type PlanValuer = (problem: number, from: number, solution: number) => number | undefined;

  /** The domain the page prices problem P with when it comes with GIVEN (an
   *  example's bundled domain): GIVEN if it has P's name, else the library's of
   *  P's name, else GIVEN anyway -- the rule app.ts's adoptLibraryDomain
   *  applies to a problem loaded with its domain. */
  export function pricingDomain(p: Problem, given: Domain | undefined, library: Map<string, Domain>): Domain | undefined {
    if (given && given.name === p.domain) return given;
    return library.get(p.domain) ?? given;
  }

  /** whether every line of P's hard goal has a literal that holds in STATE */
  export function hardGoalHolds(p: Problem, state: State): boolean {
    return p.goal.every((line) => line.some((lit) => literalHolds(lit, state) === true));
  }

  /** a plan's value as the main page's Total shows it at the plan's end, with
   *  pseudo goal utility off: the achieved preference weights minus the cost
   *  -- the same utilityAt the page uses, priced with the domain the page will
   *  use (pricingDomain, LIBRARY being FiFO's pddl/), against the problem the
   *  plan is shown WITH (for a borrowed plan, the original problem's
   *  utilities, not the goal problem's).  Undefined when the plan does not
   *  parse, when the problem has neither costs nor goal utilities (no value to
   *  rank by), or for a borrowed plan that does not achieve the original
   *  problem's hard goal.  Parsed on demand. */
  export function planValuer(examples: Example[], library: { name: string; text: string }[] = []): PlanValuer {
    const problems = new Map<number, Problem | null>();
    const domains = new Map<string, Domain | undefined>();
    const lib = new Map<string, Domain>();
    for (const d of library) {
      try { lib.set(d.name, parseDomain(d.text)); } catch { /* a broken library domain prices nothing */ }
    }
    const problemOf = (i: number) => {
      if (!problems.has(i)) {
        try { problems.set(i, parseProblem(examples[i].problem.text)); } catch { problems.set(i, null); }
      }
      return problems.get(i) ?? undefined;
    };
    const givenDomain = (i: number) => {
      const d = examples[i].domain;
      if (!d) return undefined;
      if (!domains.has(d.file)) {
        try { domains.set(d.file, parseDomain(d.text)); } catch { domains.set(d.file, undefined); }
      }
      return domains.get(d.file);
    };
    return (problem, from, solution) => {
      const p = problemOf(problem);
      if (!p) return undefined;
      try {
        const plan = parsePlan(examples[from].solutions[solution].text, p);
        const end = plan.steps.length;
        if (from !== problem && !hardGoalHolds(p, plan.states[end])) return undefined;
        const u = utilityAt(p, pricingDomain(p, givenDomain(problem), lib), plan, end);
        return u.goals === undefined && u.costs === undefined ? undefined : u.total;
      } catch {
        return undefined;
      }
    };
  }

  /** a number as the page shows it: "−5", "3", "2.5" (rounded to 1/1000) */
  export function showValue(v: number): string {
    const r = Math.round(v * 1000) / 1000;
    return r < 0 ? "−" + Math.abs(r) : String(r);
  }

  /** the original problem's row when it has no plan of its own: the goal plan
   *  of highest value for the ORIGINAL problem (GOALS: label -> rows) -- the
   *  lowest-cost one when it weights no goals -- the exact solver's on a tie,
   *  then the first goal's; undefined when no goal plan has a value */
  function bestGoalPlan(orig: number, goals: Map<string, { rank: number; leaves: ClaraLeaf[] }>,
                        valueOf: PlanValuer): ClaraLeaf | undefined {
    let best: { l: ClaraLeaf; goal: string; v: number } | undefined;
    const order = [...goals.keys()].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    for (const g of order) {
      const e = goals.get(g)!;
      if (e.rank !== 2) continue;
      for (const l of e.leaves) {
        if (l.solution === undefined || l.solver === undefined) continue;
        const v = valueOf(orig, l.example, l.solution);
        if (v === undefined) continue;
        if (!best || v > best.v || (v === best.v && l.solver === SOLVERS.eval && best.l.solver !== SOLVERS.eval)) {
          best = { l, goal: g, v };
        }
      }
    }
    if (!best) return undefined;
    return {
      label: `${best.l.solver} (${showValue(best.v)})`, example: orig,
      from: best.l.example, solution: best.l.solution, solver: best.l.solver, value: best.v,
      note: `the plan found for goal "${best.goal}", the best (${showValue(best.v)}) of the plans for this ` +
            `problem's goals -- what solving it directly would usually find, though a goal plan is optimal only ` +
            `at its own goal's shortest horizon`,
    };
  }

  /** for tests only: a plan's value as minus its *OBJECTIVE* -- right only
   *  when no problem involved weights a goal, and it checks no goal; never the
   *  page's valuer (that is planValuer) */
  export function objectiveValuer(examples: Example[]): PlanValuer {
    return (_problem, from, solution) => {
      const o = answerObjective(examples[from].solutions[solution].text);
      return o === undefined ? undefined : -o;
    };
  }

  function cmpKey(a: number[], b: number[]): number {
    for (let k = 0; k < Math.max(a.length, b.length); k++) {
      const d = (a[k] ?? -1) - (b[k] ?? -1);
      if (d !== 0) return d;
    }
    return 0;
  }

  /** the catalogue as a tree: families, then sizes, instances, goals; each goal
   *  node's leaves are the Solver column.  VALUEOF values the plans: the page
   *  passes planValuer (required, so no caller gets a stand-in by default). */
  export function claraTree(examples: Example[], valueOf: PlanValuer): ClaraNode[] {
    const families = new Map<string, Map<string, { key: number[]; inst: Map<string, Map<string, { rank: number; leaves: ClaraLeaf[] }>> }>>();
    examples.forEach((ex, i) => {
      const p = place(ex.problem.file);
      if (!families.has(p.family)) families.set(p.family, new Map());
      const sizes = families.get(p.family)!;
      if (!sizes.has(p.size)) sizes.set(p.size, { key: p.sizeKey, inst: new Map() });
      const insts = sizes.get(p.size)!.inst;
      if (!insts.has(p.instance)) insts.set(p.instance, new Map());
      const goals = insts.get(p.instance)!;
      // two problems with one goal label (should not happen) stay apart
      let label = p.goal;
      for (let n = 2; goals.has(label); n++) label = `${p.goal} (${n})`;
      goals.set(label, { rank: p.goalRank, leaves: solverLeaves(ex, i, p.goalRank === 2, valueOf) });
    });
    // an original problem with no plan of its own borrows its best goal plan
    // (highest value for the original problem; the cheapest when it weights no goal)
    for (const sizes of families.values()) for (const { inst } of sizes.values()) for (const goals of inst.values()) {
      const orig = goals.get("original problem");
      if (!orig || orig.rank !== 0 || orig.leaves.some((l) => l.solution !== undefined)) continue;
      const best = bestGoalPlan(orig.leaves[0].example, goals, valueOf);
      if (best) orig.leaves.unshift(best);
    }
    const byName = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true });
    return [...families.keys()].sort(byName).map((fam) => {
      const sizes = families.get(fam)!;
      return {
        label: fam,
        children: [...sizes.keys()].sort((a, b) => cmpKey(sizes.get(a)!.key, sizes.get(b)!.key) || byName(a, b)).map((sz) => {
          const insts = sizes.get(sz)!.inst;
          return {
            label: sz,
            children: [...insts.keys()].sort(byName).map((k) => {
              const goals = insts.get(k)!;
              return {
                label: k,
                children: [...goals.keys()].sort((a, b) => goals.get(a)!.rank - goals.get(b)!.rank || byName(a, b))
                  .map((gl) => {
                    const leaves = goals.get(gl)!.leaves;
                    return { label: gl, children: [], leaves, missing: leaves.every((l) => l.solution === undefined) };
                  }),
              };
            }),
          };
        }),
      };
    });
  }
}
