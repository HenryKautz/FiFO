// Tests for the visualizer's parsing, plan simulation and rendering, run under
// Node by tests/run-test-visualizer.sh (FiFO's tests directory).
//
// The main oracle is FiFO's own answer file: its HOLDS facts give the true state
// at every slice, independently of the visualizer's action semantics.  The same
// plan written as actions only (the "@" and plain-list formats, HOLDS removed)
// must reproduce those states by simulation.  Counts on the problem side are
// taken with regular expressions over the PDDL text, not from the parser.

declare const require: any;
declare const process: any;

namespace VizTest {
  const fs = require("fs");
  const path = require("path");
  const EX = path.join(process.argv[2], "examples");
  const read = (f: string) => fs.readFileSync(path.join(EX, f), "utf8");

  let passed = 0;
  let failed = 0;
  function check(name: string, ok: boolean, detail = "") {
    const dots = ".".repeat(Math.max(3, 70 - name.length));
    if (ok) {
      passed++;
      console.log(`  ${name} ${dots} PASS`);
    } else {
      failed++;
      console.log(`  ${name} ${dots} FAIL${detail ? "\n      " + detail : ""}`);
    }
  }
  function throws(f: () => unknown, re: RegExp): boolean {
    try {
      f();
      return false;
    } catch (e) {
      return re.test(String(e instanceof Error ? e.message : e));
    }
  }
  function where(s: Viz.State, o: string): string {
    return s.inside.has(o) ? "in " + s.inside.get(o) : "at " + (s.at.get(o) ?? "-");
  }
  function sameStates(p: Viz.Problem, a: Viz.State[], b: Viz.State[]): string {
    if (a.length !== b.length) return `${a.length} states vs ${b.length}`;
    const objs = [...p.trucks, ...p.airplanes, ...p.packages];
    for (let k = 0; k < a.length; k++) {
      for (const o of objs) {
        if (where(a[k], o) !== where(b[k], o)) return `step ${k}: ${o} ${where(a[k], o)} vs ${where(b[k], o)}`;
      }
    }
    return "";
  }
  const count = (s: string, re: RegExp) => (s.match(re) ?? []).length;

  console.log("=== s-expressions ===");
  {
    const f = Viz.readAll("(A (b C)) ; comment (x\n d @ 3");
    check("lists, atoms, comments, lowercasing", JSON.stringify(f) === JSON.stringify([["a", ["b", "c"]], "d", "@", "3"]),
          JSON.stringify(f));
    check("an unclosed list is an error", throws(() => Viz.readAll("(a (b)"), /never closed/));
    check("an extra ) is an error", throws(() => Viz.readAll("(a))"), /extra/));
  }

  console.log("=== problems ===");
  const t6 = read("grid6x6-1.pddl");
  const p6 = Viz.parseProblem(t6);
  {
    const roadFacts = count(t6, /\(road \S+ \S+\)/g);
    check("6x6: 6 rows x 6 cols, 36 places laid out", p6.rows === 6 && p6.cols === 6 && p6.layout.size === 36);
    check(`6x6: ${roadFacts} road facts -> ${roadFacts / 2} two-way roads`,
          p6.roads.length === roadFacts / 2 && p6.roads.every((r) => r.both), `${p6.roads.length} roads`);
    check("6x6: trucks T1 T2, packages P1..P4",
          p6.trucks.join() === "truck1,truck2" && p6.packages.join() === "pkg1,pkg2,pkg3,pkg4" &&
          p6.labels.get("truck2") === "T2" && p6.labels.get("pkg4") === "P4");
    const disj = /\(:goal \(and\s+\(or ([^\n]*)\)\n/.exec(t6)![1];
    const n = count(disj, /\(at /g);
    check(`6x6: the hard goal is one line of ${n} disjuncts; the ${count(t6, /\(preference /g)} preferences are dropped`,
          p6.goal.length === 1 && p6.goal[0].length === n && p6.goalLiterals.length === n);
    check("6x6: goal labels G1.. in order", p6.goal[0][0].label === "G1" && p6.goal[0][0].text === "(at pkg1 p1-4)" &&
          p6.goal[0][n - 1].label === `G${n}`);
    check("6x6: initial positions", p6.initAt.get("truck1") === "p3-1" && p6.initAt.get("pkg3") === "p1-6");
  }
  const t5 = read("grid5x5-air.pddl");
  const p5 = Viz.parseProblem(t5);
  {
    check("5x5: airports are places, marked as airports",
          p5.places.length === 25 && p5.airports.has("p5-1") && p5.airports.has("p1-5") && p5.layout.has("p1-5"));
    check("5x5: one airplane, labelled A1", p5.airplanes.join() === "plane1" && p5.labels.get("plane1") === "A1");
    check("5x5: the goal is a conjunction of 3 lines of 2 disjuncts",
          p5.goal.length === 3 && p5.goal.every((l) => l.length === 2) && p5.goalLiterals.length === 6);
    check("a domain file is refused", throws(() => Viz.parseProblem("(define (domain d) (:requirements :strips))"), /domain/));
    check("a non-PDDL file is refused", throws(() => Viz.parseProblem("SAT\n(HOLDS (AT A B) 1)"), /define/));
  }
  {
    const one = Viz.parseProblem(`(define (problem tiny) (:domain clara-logistics)
      (:objects a b c - place t - truck k - package)
      (:init (at t a) (at k b) (road a b) (road b a) (road b c))
      (:goal (and (at k c) (or (at t a) (at t c)))))`);
    const ab = one.roads.find((r) => r.a === "a" && r.b === "b");
    const bc = one.roads.find((r) => r.a === "b" && r.b === "c");
    check("a road listed both ways is two-way, once each way only one-way",
          one.roads.length === 2 && !!ab && ab.both && !!bc && !bc.both);
    check("non-grid place names get a square layout, with a warning",
          one.layout.size === 3 && one.warnings.some((w) => /p<row>-<col>/.test(w)));
    check("a single-literal conjunct is a line of its own",
          one.goal.length === 2 && one.goal[0].length === 1 && one.goal[1].length === 2);
    const svg = Viz.renderMap(one, { at: new Map(one.initAt), inside: new Map() });
    check("the one-way road has an arrow at one end only",
          count(svg, /marker-start=/g) === 1 && count(svg, /marker-end=/g) === 2 && count(svg, /class="road one-way"/g) === 1);
  }

  console.log("=== solutions ===");
  const ans = read("grid5x5-air.answer");
  const planA = Viz.parsePlan(ans, p5);
  const lastSlice = Math.max(...(ans.match(/^\(HOLDS .* (\d+)\)$/gm) ?? []).map((l: string) => Number(/(\d+)\)$/.exec(l)![1])));
  const firstSlice = Math.min(...(ans.match(/^\(HOLDS .* (\d+)\)$/gm) ?? []).map((l: string) => Number(/(\d+)\)$/.exec(l)![1])));
  {
    check("answer: recognized as FiFO's format, cost read", planA.format === "answer" && planA.objective === "17");
    check(`answer: one state per slice ${firstSlice}..${lastSlice}`,
          planA.states.length === lastSlice - firstSlice + 1 && planA.steps.length === lastSlice - firstSlice &&
          planA.firstStep === firstSlice);
    check(`answer: ${count(ans, /^\(OCCURS /gm)} actions in their slices`,
          planA.steps.reduce((n, s) => n + s.length, 0) === count(ans, /^\(OCCURS /gm) &&
          planA.steps[0].map((a) => a.text).join() === "(drive truck1 p2-1 p3-1),(drive truck2 p3-2 p2-2)");
    check("answer: applying the actions reproduces every HOLDS state (no warnings)",
          planA.warnings.length === 0, planA.warnings.join("; "));
    const end = planA.states[planA.states.length - 1];
    check("answer: the goal holds at the end, not at the start",
          p5.goal.every((l) => l.some((g) => Viz.literalHolds(g, end) === true)) &&
          !p5.goal.every((l) => l.some((g) => Viz.literalHolds(g, planA.states[0]) === true)));
    check("answer: a loaded package is in its truck", where(planA.states[2], "pkg3") === "in truck1");
  }
  {
    const at = Viz.parsePlan(read("grid5x5-air-at.answer"), p5);
    check("@ format with HOLDS: recognized, same states and steps as the answer",
          at.format === "at" && sameStates(p5, at.states, planA.states) === "" && at.warnings.length === 0,
          sameStates(p5, at.states, planA.states) + at.warnings.join("; "));
    const bare = read("grid5x5-air-at.answer").split("\n").filter((l: string) => !/^\(HOLDS /.test(l)).join("\n");
    const sim = Viz.parsePlan(bare, p5);
    const d = sameStates(p5, sim.states, planA.states);
    check("@ format without HOLDS: simulation alone gives the answer's HOLDS states", sim.format === "at" && d === "", d);
  }
  {
    const list = Viz.parsePlan(read("grid5x5-air.plan"), p5);
    const n = count(read("grid5x5-air.plan"), /^\(/gm);
    const endA = planA.states[planA.states.length - 1];
    const endL = list.states[list.states.length - 1];
    check(`plain list: ${n} actions, one per step`, list.format === "list" && list.steps.length === n &&
          list.steps.every((s) => s.length === 1));
    check("plain list: ends in the answer's final state",
          sameStates(p5, [endL], [endA]) === "" && list.warnings.length === 0,
          sameStates(p5, [endL], [endA]) + list.warnings.join("; "));
    const timed = Viz.parsePlan("0: (drive truck1 p2-1 p3-1) [2]\n0: (drive truck2 p3-2 p2-2) [2]\n1: (load pkg3 truck1 p3-1) [1]\n", p5);
    check("numbered list: 't:' groups actions into steps, '[cost]' ignored",
          timed.steps.length === 2 && timed.steps[0].length === 2 && timed.steps[1].length === 1 &&
          where(timed.states[2], "pkg3") === "in truck1");
    const atStart: Viz.Literal = { pred: "at", args: ["pkg3", "p3-1"], negated: false, label: "G", text: "(at pkg3 p3-1)" };
    check("a loaded package is no longer at the place it was loaded from",
          Viz.literalHolds(atStart, timed.states[1]) === true && Viz.literalHolds(atStart, timed.states[2]) === false);
  }
  {
    const wrong = Viz.parsePlan(read("grid6x6-1.answer"), p5);
    check("a solution for another problem is reported, not silently drawn",
          wrong.warnings.some((w) => /does not have|in the problem's init/.test(w)));
    const odd = Viz.parsePlan("(teleport truck1 p5-5)\n", p5);
    check("an action it cannot apply is reported", odd.warnings.some((w) => /don't know how to apply/.test(w)));
  }

  console.log("=== rendering ===");
  {
    const svg = Viz.renderMap(p6, { at: new Map(p6.initAt), inside: new Map() });
    check("6x6 map: 36 squares, 36 two-way roads", count(svg, /class="square/g) === 36 &&
          count(svg, /class="road"/g) === 36 && count(svg, /marker-start=/g) === 36);
    check("6x6 map: 2 trucks, 4 packages, 12 goal tokens",
          count(svg, /class="vehicle"/g) === 2 && count(svg, /class="package"/g) === 4 && count(svg, /class="goal/g) === 12);
    check("6x6 map: scales with its container (viewBox, no fixed size)",
          /viewBox="0 0 \d+ \d+"/.test(svg) && !/<svg[^>]* width=/.test(svg));
    // two trucks in one place: both drawn, the second offset up and right
    const both: Viz.State = { at: new Map([["truck1", "p1-1"], ["truck2", "p1-1"]]), inside: new Map([["pkg1", "truck2"]]) };
    const s2 = Viz.renderMap(p6, both);
    const place = /<g class="place" data-place="p1-1">([\s\S]*?)<\/g>\n<g class="place"/.exec(s2)![1];
    const rects = [...place.matchAll(/<g class="vehicle"><rect x="([\d.]+)" y="([\d.]+)"/g)].map((m) => [Number(m[1]), Number(m[2])]);
    check("two trucks in one place overlap, the second up and to the right",
          rects.length === 2 && rects[1][0] > rects[0][0] && rects[1][1] < rects[0][1], JSON.stringify(rects));
    check("a package in a truck is a badge, not on the ground",
          count(s2, /class="package badge"/g) === 1 && /<title>pkg1 in truck2<\/title>/.test(s2));
    const end = planA.states[planA.states.length - 1];
    const s5 = Viz.renderMap(p5, end);
    check("goals achieved at the end are drawn as achieved", count(s5, /class="goal achieved"/g) === 3);
    const moves = Viz.renderMap(p5, planA.states[0], { next: planA.steps[0] });
    check("the next step's drives are highlighted in their trucks' colors",
          count(moves, /class="move"/g) === 2 && moves.includes(`stroke="${Viz.colorOf(p5, "truck1")}"`));
    check("trucks get different colors; a goal shares its package's color",
          Viz.colorOf(p6, "truck1") !== Viz.colorOf(p6, "truck2") &&
          new RegExp(`stroke="${Viz.colorOf(p6, "pkg2")}"[^>]*/><text[^>]*>G4<`).test(
            Viz.renderMap(p6, { at: new Map(p6.initAt), inside: new Map() })));
  }

  console.log(`\n=== summary: ${passed} passed, ${failed} failed ===`);
  process.exit(failed === 0 ? 0 : 1);
}
