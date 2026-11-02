// The CLARA browser's catalogue: the problems of clara-examples.js (bundled
// from a CLARA checkout by build-clara-examples.sh) sorted into the columns
// Family / Size / Instance / Goal / Solver, from CLARA's file names:
//
//   <Family>/gridNxM-K.pddl                  the problem: goal "original problem"
//   <Family>/recognition/gridNxM-K.pddl      its recognition version
//   <Family>/goals/gridNxM-K-<goal>.pddl     one hypothesis as the hard goal,
//       <goal> = pkg1-p2-3 or pkg1-p2-4-pkg2-p3-4-... (object, place, ...)
//   <goal>-eval.answer, <goal>-tt.answer     EvalMaxSAT's and tt-open-wbo-inc's plans
//   <goal>.answer                            the plan the evidence was cut from: a
//       copy of one of those two, so it is shown as that one's "evidence plan"
//
// Anything else (the AAAI-2010 benchmarks) is placed by its directory: Size is
// the subdirectory, Instance the file name.

namespace Viz {
  /** An entry of examples.js / clara-examples.js (tools/bundle-examples.ts). */
  export interface Example {
    problem: { file: string; text: string };
    domain?: { file: string; text: string };
    solutions: { file: string; text: string }[];
  }

  /** A row of the Solver column: what Open loads.  MISSING: a solver CLARA ran
   *  on this goal that left no plan file (grayed; opens the problem alone). */
  export interface ClaraLeaf { label: string; example: number; solution?: number; missing?: boolean }
  /** A row of any other column; a goal is MISSING when it has no solution file
   *  at all (grayed, but it can still be opened to show the problem). */
  export interface ClaraNode { label: string; children: ClaraNode[]; leaves?: ClaraLeaf[]; missing?: boolean }

  const SOLVERS: Record<string, string> = { eval: "EvalMaxSAT", tt: "tt-open-wbo-inc" };

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
  function solverLeaves(ex: Example, i: number, goal: boolean): ClaraLeaf[] {
    const stem = ex.problem.file.replace(/\.pddl$/i, "");
    const named: { label: string; j: number; rank: number }[] = [];
    let chosen: number | undefined;
    ex.solutions.forEach((s, j) => {
      const rest = s.file.slice(stem.length);
      const m = /^-([a-z0-9]+)\.answer$/i.exec(rest);
      if (rest === ".answer") chosen = j;
      else if (m && SOLVERS[m[1]]) named.push({ label: SOLVERS[m[1]], j, rank: m[1] === "eval" ? 0 : 1 });
      else named.push({ label: s.file.split("/").pop()!, j, rank: 2 });
    });
    if (chosen !== undefined) {
      // beside -eval/-tt plans (CLARA's goals/), <goal>.answer is the evidence
      // plan; anywhere else (AAAI) it is just a solution, listed by name
      const same = named.find((n) => n.rank < 2 && ex.solutions[n.j].text === ex.solutions[chosen!].text);
      if (same) same.label += " · evidence plan";
      else if (named.some((n) => n.rank < 2)) named.push({ label: "evidence plan", j: chosen, rank: -1 });
      else named.push({ label: ex.solutions[chosen].file.split("/").pop()!, j: chosen, rank: 2 });
    }
    const rows: { label: string; j?: number; rank: number }[] = named;
    if (goal) {
      for (const [key, label] of Object.entries(SOLVERS)) {
        if (!named.some((n) => n.label.startsWith(label))) rows.push({ label, rank: key === "eval" ? 0 : 1 });
      }
    }
    rows.sort((a, b) => a.rank - b.rank || a.label.localeCompare(b.label));
    return [...rows.map((n): ClaraLeaf => n.j === undefined ? { label: n.label, example: i, missing: true }
                                                             : { label: n.label, example: i, solution: n.j }),
            { label: "no solution (problem only)", example: i }];
  }

  function cmpKey(a: number[], b: number[]): number {
    for (let k = 0; k < Math.max(a.length, b.length); k++) {
      const d = (a[k] ?? -1) - (b[k] ?? -1);
      if (d !== 0) return d;
    }
    return 0;
  }

  /** the catalogue as a tree: families, then sizes, instances, goals; each goal
   *  node's leaves are the Solver column */
  export function claraTree(examples: Example[]): ClaraNode[] {
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
      goals.set(label, { rank: p.goalRank, leaves: solverLeaves(ex, i, p.goalRank === 2) });
    });
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
