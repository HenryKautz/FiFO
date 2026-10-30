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
    // FiFO writes a 0-ary fluent or action bare: (HOLDS DONE 1), (OCCURS NOOP 2)
    const bare = Viz.parsePlan("SAT\n(HOLDS (AT TRUCK1 P2-1) 1)\n(HOLDS DONE 1)\n(OCCURS (DRIVE TRUCK1 P2-1 P3-1) 1)\n" +
                               "(HOLDS (AT TRUCK1 P3-1) 2)\n(OCCURS NOOP 2)\n(HOLDS (AT TRUCK1 P3-1) 3)\n", p5);
    check("0-ary HOLDS and OCCURS keep their slices (no extra step, no action named holds)",
          bare.steps.length === 2 && bare.steps[1].map((a) => a.name).join() === "noop" &&
          !bare.steps.flat().some((a) => a.name === "holds" || a.name === "occurs"),
          JSON.stringify(bare.steps.map((s) => s.map((a) => a.text))));
    const badT = Viz.parsePlan("(HOLDS (AT TRUCK1 P2-1) 1)\n(HOLDS (AT TRUCK1 P1-1) X)\n(OCCURS (DRIVE TRUCK1 P2-1 P3-1) 1)\n", p5);
    check("a HOLDS with a non-numeric slice is reported and skipped, not a NaN step",
          badT.firstStep === 1 && badT.steps.length === 1 && badT.warnings.some((w) => /not a number/.test(w)),
          `${badT.firstStep} ${badT.steps.length} ${badT.warnings}`);
  }

  console.log("=== rendering ===");
  {
    const svg = Viz.renderMap(p6, { at: new Map(p6.initAt), inside: new Map() });
    check("6x6 map: 36 squares, 36 two-way roads", count(svg, /class="square/g) === 36 &&
          count(svg, /class="road"/g) === 36 && count(svg, /marker-start=/g) === 36);
    check("6x6 map: 2 trucks, 4 packages, 12 goal tokens",
          count(svg, /class="vehicle"/g) === 2 && count(svg, /class="package"/g) === 4 && count(svg, /class="goal/g) === 12);
    check("6x6 map: scales with its container (viewBox, no fixed size)",
          /^<svg [^>]*viewBox="0 0 \d+ \d+"/.test(svg) && !/^<svg [^>]* width=/.test(svg));
    // what a place's square holds: [kind, x, y, size] of each item, in order
    const items = (svg: string, place: string) => {
      const m = new RegExp(`<g class="place" data-place="${place}">([\\s\\S]*?)\\n</g>`).exec(svg);
      return [...(m ? m[1] : "").matchAll(/<g class="([a-z ]+)" data-box="([\d.]+) ([\d.]+) ([\d.]+)"/g)]
        .map((x) => ({ kind: x[1], x: Number(x[2]), y: Number(x[3]), size: Number(x[4]) }));
    };
    const at = (pairs: [string, string][], inside: [string, string][] = []): Viz.State =>
      ({ at: new Map(pairs), inside: new Map(inside) });
    // two trucks in one place: both drawn, the second offset up and right
    const s2 = Viz.renderMap(p6, at([["truck1", "p1-1"], ["truck2", "p1-1"]], [["pkg1", "truck2"]]));
    const vs = items(s2, "p1-1").filter((i) => i.kind === "vehicle");
    check("two trucks in one place overlap, the second up and to the right",
          vs.length === 2 && vs[1].x > vs[0].x && vs[1].y < vs[0].y && vs[1].x < vs[0].x + vs[0].size,
          JSON.stringify(vs));
    check("a package in a truck is a badge, not on the ground",
          count(s2, /class="package badge"/g) === 1 && /<title>pkg1 in truck2<\/title>/.test(s2) &&
          count(s2, /class="package"/g) === 0);
    // icon sizes: alone a truck nearly fills the square; it shrinks to share it
    const side = Number(/<rect class="square" x="[\d.]+" y="[\d.]+" width="([\d.]+)"/.exec(s2)![1]);
    const alone = items(Viz.renderMap(p6, at([["truck1", "p1-1"]])), "p1-1");
    const shared = items(Viz.renderMap(p6, at([["truck1", "p2-4"], ["pkg1", "p2-4"]])), "p2-4");
    check("a truck alone in its square nearly fills it",
          alone.length === 1 && alone[0].size >= 0.9 * side, `${alone[0]?.size} of ${side}`);
    check("with a package there, the truck shrinks and the package fits beside it",
          shared.length === 2 && shared.every((i) => i.size < alone[0].size) &&
          shared.every((i) => i.size >= 0.35 * side), JSON.stringify(shared));
    check("two trucks are each smaller than one", vs.every((v) => v.size < alone[0].size));
    const inside = (i: { x: number; y: number; size: number }, sq: { x: number; y: number }) =>
      i.x >= sq.x - 0.01 && i.y >= sq.y - 0.01 && i.x + i.size <= sq.x + side + 0.01 && i.y + i.size <= sq.y + side + 0.01;
    const crowd = Viz.renderMap(p6, at([["truck1", "p4-5"], ["truck2", "p4-5"], ["pkg1", "p4-5"], ["pkg2", "p4-5"], ["pkg3", "p4-5"]]));
    const sq = /data-place="p4-5">\n<rect class="square" x="([\d.]+)" y="([\d.]+)"/.exec(crowd)!;
    const all = items(crowd, "p4-5");
    check("a crowded square (2 goals, 3 packages, 2 trucks) keeps every item inside it",
          all.length === 7 && all.every((i) => inside(i, { x: Number(sq[1]), y: Number(sq[2]) })), JSON.stringify(all));
    const end = planA.states[planA.states.length - 1];
    const s5 = Viz.renderMap(p5, end);
    check("goals achieved at the end are drawn as achieved", count(s5, /class="goal achieved"/g) === 3);
    const loop = Viz.parseProblem(t6.replace("(road p2-1 p1-1)", "(road p1-1 p1-1) (road p2-1 p1-1)"));
    check("a road from a place to itself draws nothing, and no NaN",
          !/NaN/.test(Viz.renderMap(loop, { at: new Map(loop.initAt), inside: new Map() })));
    const moves = Viz.renderMap(p5, planA.states[0], { next: planA.steps[0] });
    check("the next step's drives are highlighted in their trucks' colors",
          count(moves, /class="move"/g) === 2 && moves.includes(`stroke="${Viz.colorOf(p5, "truck1")}"`));
    check("trucks get different colors; a goal shares its package's color",
          Viz.colorOf(p6, "truck1") !== Viz.colorOf(p6, "truck2") &&
          new RegExp(`stroke="${Viz.colorOf(p6, "pkg2")}"[^>]*/><text[^>]*>G4<`).test(
            Viz.renderMap(p6, { at: new Map(p6.initAt), inside: new Map() })));
  }

  console.log("=== utility ===");
  {
    // The oracle: FiFO's MaxSAT objective is the weight of the violated
    // preferences plus the plan's total cost, and the answer lists the violated
    // ones (PREF-VIOLATED).
    const objective = (t: string) => Number(/\(\*OBJECTIVE\* (\d+)\)/.exec(t)![1]);
    const violated = (t: string) => new Set((t.match(/^\(PREF-VIOLATED (\S+)\)$/gm) ?? [])
      .map((l: string) => /\(PREF-VIOLATED (\S+)\)/.exec(l)![1].toLowerCase()));
    const handling = Viz.parseDomain(read("clara-logistics-handling.pddl"));
    const plain = Viz.parseDomain(read("clara-logistics.pddl"));
    const a6text = read("grid6x6-1.answer");
    const a6 = Viz.parsePlan(a6text, p6);
    const end6 = a6.steps.length;
    const u6 = Viz.utilityAt(p6, handling, a6, end6);
    const totalW = p6.preferences.reduce((s, p) => s + p.weight, 0);
    const v6 = violated(a6text);
    const achievedW = p6.preferences.filter((p) => !v6.has(p.name)).reduce((s, p) => s + p.weight, 0);
    check(`6x6: ${p6.preferences.length} preferences read with their weights (${count(t6, /\(preference /g)} in the file)`,
          p6.preferences.length === count(t6, /\(preference /g) && p6.preferences.every((p) => p.weight === 8));
    check("6x6: Goals at the end = the weight of the preferences FiFO did not report violated",
          u6.goals === achievedW && v6.size > 0, `${u6.goals} vs ${achievedW}`);
    check(`6x6: unachieved weight + Costs = FiFO's objective (${objective(a6text)})`,
          totalW - (u6.goals ?? NaN) + (u6.costs ?? NaN) === objective(a6text) && u6.costsExact,
          `${totalW} - ${u6.goals} + ${u6.costs}`);
    check("6x6: Total = Goals - Costs", u6.total === (u6.goals ?? 0) - (u6.costs ?? 0));
    const run = a6.states.map((_, k) => Viz.utilityAt(p6, handling, a6, k).costs ?? NaN);
    check("costs run from 0 at step 0 and never fall",
          run[0] === 0 && run.every((c, k) => k === 0 || c >= run[k - 1]), JSON.stringify(run));
    const load = { name: "load", args: ["pkg1", "truck2", "p2-4"], text: "(load pkg1 truck2 p2-4)" };
    const drive = { name: "drive", args: ["truck2", "p2-3", "p2-4"], text: "(drive truck2 p2-3 p2-4)" };
    check("the domain prices actions: a load 1 and a drive (drive-cost) = 2 in the handling domain, a load 0 in the plain one",
          Viz.actionCost(p6, handling, load).cost === 1 && Viz.actionCost(p6, handling, drive).cost === 2 &&
          Viz.actionCost(p6, plain, load).cost === 0 && Viz.actionCost(p6, plain, load).exact);
    const est = Viz.utilityAt(p6, undefined, a6, end6);
    check("without a domain, costs are estimated from the problem's drive-cost (and say so)",
          est.costs === 2 * a6.steps.flat().filter((a) => a.name === "drive").length && !est.costsExact);

    const a5text = read("grid5x5-air.answer");
    const u5 = Viz.utilityAt(p5, plain, planA, planA.steps.length);
    check(`5x5: no preferences, so no Goals utility; Costs = FiFO's objective (${objective(a5text)})`,
          u5.goals === undefined && u5.costs === objective(a5text) && u5.total === -objective(a5text),
          `${u5.goals} ${u5.costs}`);
    const plainList = Viz.parsePlan(read("grid5x5-air.plan"), p5);
    check("the same plan as a plain list has the same cost",
          Viz.utilityAt(p5, plain, plainList, plainList.steps.length).costs === u5.costs);

    // the standard PDDL3 forms: a weight in the metric, a cost from a function of the action's arguments
    const pm = Viz.parseProblem(`(define (problem m) (:domain d)
      (:objects a b c - place t - truck k - package)
      (:init (at t a) (at k a) (road a b) (road b a) (road b c) (= (len a b) 7) (= (len b c) 3))
      (:goal (and (at k c) (preference p1 (at k c)) (preference p2 (at t b))))
      (:metric minimize (+ (total-cost) (* 5 (is-violated p1)) (* (is-violated p2) 2))))`);
    const dm = Viz.parseDomain(`(define (domain d) (:requirements :action-costs)
      (:action drive :parameters (?t - truck ?from ?to - place)
         :effect (and (at ?t ?to) (increase (total-cost) (len ?from ?to)))))`);
    const pmPlan = Viz.parsePlan("(drive t a b)\n(drive t b c)\n", pm);
    const um = Viz.utilityAt(pm, dm, pmPlan, 1);
    check("weights from the metric's (* w (is-violated p)); a cost (len ?from ?to) from :init",
          pm.preferences.map((p) => `${p.name}=${p.weight}`).join() === "p1=5,p2=2" &&
          um.goals === 2 && um.costs === 7 && Viz.utilityAt(pm, dm, pmPlan, 2).costs === 10,
          `${pm.preferences.map((p) => p.name + "=" + p.weight)} ${um.goals} ${um.costs}`);
    const metricOf = (m: string) => Viz.parseProblem(`(define (problem m) (:domain d) (:objects a - place k - package)
      (:init (at k a)) (:goal (and (preference p1 (at k a)) (preference p2 (at k a)))) (:metric ${m}))`)
      .preferences.map((p) => `${p.name}=${p.weight}`).join();
    check("a maximize metric, and (- ...), give violation penalties as positive utilities",
          metricOf("maximize (- 0 (* 5 (is-violated p1)) (* 2 (is-violated p2)))") === "p1=5,p2=2" &&
          metricOf("minimize (- (total-cost) (* -3 (is-violated p1)) (- (* 4 (is-violated p2))))") === "p1=3,p2=4",
          metricOf("maximize (- 0 (* 5 (is-violated p1)) (* 2 (is-violated p2)))") + " | " +
          metricOf("minimize (- (total-cost) (* -3 (is-violated p1)) (- (* 4 (is-violated p2))))"));
    const dc = Viz.parseDomain(`(define (domain d) (:action move :parameters (?t - truck ?from ?to - place)
      :effect (and (at ?t ?to) (increase (total-cost) 2) (when (at ?t ?from) (increase (total-cost) 5)))))`);
    const cc = Viz.actionCost(pm, dc, { name: "move", args: ["t", "a", "b"], text: "(move t a b)" });
    check("a cost under when (or forall) is not counted, and the cost is marked inexact",
          cc.cost === 2 && !cc.exact, JSON.stringify(cc));
  }

  console.log("=== the Examples menu (examples.js) ===");
  {
    const js = fs.readFileSync(path.join(process.argv[2], "examples.js"), "utf8");
    const exs = new Function(js + "\nreturn VIZ_EXAMPLES;")() as
      { problem: { file: string; text: string }; domain?: { file: string };
        solutions: { file: string; text: string }[] }[];
    const pddl = fs.readdirSync(EX).filter((f: string) => f.endsWith(".pddl") && !Viz.isDomainText(read(f))).sort();
    check(`one entry per example problem (${pddl.length}), domains left out`,
          exs.map((e) => e.problem.file).join() === pddl.join());
    check("each example has the domain its problem names",
          exs.find((e) => e.problem.file === "grid6x6-1.pddl")!.domain?.file === "clara-logistics-handling.pddl" &&
          exs.find((e) => e.problem.file === "grid5x5-air.pddl")!.domain?.file === "clara-logistics.pddl");
    const air = exs.find((e) => e.problem.file === "grid5x5-air.pddl");
    check("grid5x5-air has its three solutions; grid6x6-1 its one",
          !!air && air.solutions.map((s) => s.file).join() === "grid5x5-air-at.answer,grid5x5-air.answer,grid5x5-air.plan" &&
          exs.find((e) => e.problem.file === "grid6x6-1.pddl")!.solutions.map((s) => s.file).join() === "grid6x6-1.answer");
    check("each bundled file is the file's exact text",
          exs.every((e) => e.problem.text === read(e.problem.file) && e.solutions.every((s) => s.text === read(s.file))));
  }

  console.log(`\n=== summary: ${passed} passed, ${failed} failed ===`);
  process.exit(failed === 0 ? 0 : 1);
}
