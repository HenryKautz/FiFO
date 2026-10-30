// A grid planning problem as the visualizer needs it: places laid out on the
// grid, roads, vehicles, packages, where everything starts, and the hard goal.
//
// Places named p<row>-<col> (ppgen's grid style) are drawn at that cell, row 1
// at the top.  Any other place names get a square layout in the order they are
// declared.  Object kinds come from their PDDL types (truck, airplane, package,
// place, airport); an untyped object is classified by its name.

namespace Viz {
  export type Kind = "truck" | "airplane" | "package" | "place" | "other";

  export interface Literal {
    pred: string;
    args: string[];
    negated: boolean;
    /** "G1", "G2", ... in order of first appearance; one per distinct literal. */
    label: string;
    text: string;
  }

  export interface Road {
    a: string;
    b: string;
    /** true when there is a road both ways; else the road runs a -> b only. */
    both: boolean;
  }

  /** A soft goal: (preference NAME GD WEIGHT) in the goal (FiFO and ppgen's
   *  form), or (preference NAME GD) weighted by the metric's (* W (is-violated
   *  NAME)).  Its weight is the utility of achieving it. */
  export interface Preference {
    name: string;
    formula: SExpr;
    weight: number;
  }

  export interface Problem {
    name: string;
    domain: string;
    kinds: Map<string, Kind>;
    places: string[];
    airports: Set<string>;
    trucks: string[];
    airplanes: string[];
    packages: string[];
    /** Every vehicle (trucks, then airplanes) and package with its display label. */
    labels: Map<string, string>;
    roads: Road[];
    initAt: Map<string, string>;
    initIn: Map<string, string>;
    /** The hard goal as a conjunction of lines, each line a disjunction. */
    goal: Literal[][];
    /** Every distinct goal literal, in label order. */
    goalLiterals: Literal[];
    /** Weighted preferences; those with no weight anywhere are left out. */
    preferences: Preference[];
    /** Numeric fluents from :init, (= (drive-cost) 2), keyed by the term as
     *  written: "(drive-cost)". */
    numbers: Map<string, number>;
    layout: Map<string, { row: number; col: number }>;
    rows: number;
    cols: number;
    warnings: string[];
  }

  function section(def: SExpr[], key: string): SExpr[] | undefined {
    for (const x of def) if (isList(x) && x[0] === key) return x;
    return undefined;
  }

  function kindOfType(t: string): Kind {
    if (t === "truck") return "truck";
    if (t === "airplane" || t === "plane") return "airplane";
    if (t === "package" || t === "obj") return "package";
    if (t === "place" || t === "location" || t === "airport" || t === "city-location") return "place";
    return "other";
  }

  function kindOfName(n: string): Kind {
    if (/^truck/.test(n)) return "truck";
    if (/^(air)?plane/.test(n)) return "airplane";
    if (/^(pkg|package|obj)/.test(n)) return "package";
    return "other";
  }

  /** The hard goal's lines: preferences dropped, nested ANDs flattened, each
   *  conjunct an OR (one line of disjuncts) or a single literal (a line of one). */
  function goalLines(goal: SExpr | undefined, warnings: string[], prefs: SExpr[][]): SExpr[][] {
    if (goal === undefined) return [];
    const conjuncts: SExpr[] = [];
    (function flatten(g: SExpr) {
      if (isList(g) && g[0] === "and") g.slice(1).forEach(flatten);
      else if (isList(g) && g[0] === "preference") prefs.push(g);
      else conjuncts.push(g);
    })(goal);
    const lines: SExpr[][] = [];
    for (const c of conjuncts) {
      if (isList(c) && c[0] === "or") {
        const disjuncts: SExpr[] = [];
        for (const d of c.slice(1)) {
          if (isList(d) && (d[0] === "and" || d[0] === "or")) {
            warnings.push(`goal: nested ${d[0]} inside OR shown as one literal: ${show(d)}`);
          }
          disjuncts.push(d);
        }
        lines.push(disjuncts);
      } else {
        lines.push([c]);
      }
    }
    return lines;
  }

  export function parseProblem(text: string): Problem {
    const forms = readAll(text);
    const def = forms.find((f) => isList(f) && f[0] === "define") as SExpr[] | undefined;
    if (!def) throw new Error("no (define (problem ...)) form: is this a PDDL problem file?");
    const head = def[1];
    if (!isList(head) || head[0] !== "problem") {
      throw new Error("this is a PDDL domain, not a problem: choose the problem file");
    }
    const warnings: string[] = [];
    const name = String(head[1] ?? "problem");
    const domainForm = section(def, ":domain");
    const domain = domainForm ? String(domainForm[1]) : "";

    // objects: names, then "- type"
    const kinds = new Map<string, Kind>();
    const declared: string[] = [];
    const airports = new Set<string>();
    const objs = section(def, ":objects") ?? [];
    let pending: string[] = [];
    for (let i = 1; i < objs.length; i++) {
      const x = objs[i];
      if (x === "-") {
        const t = String(objs[++i]);
        for (const o of pending) {
          kinds.set(o, kindOfType(t));
          if (t === "airport") airports.add(o);
        }
        pending = [];
      } else if (!isList(x)) {
        pending.push(x);
        declared.push(x);
      }
    }
    for (const o of pending) kinds.set(o, kindOfName(o));

    // init
    const initAt = new Map<string, string>();
    const initIn = new Map<string, string>();
    const roadSet = new Set<string>();
    const roadPairs: [string, string][] = [];
    const numbers = new Map<string, number>();
    for (const f of (section(def, ":init") ?? []).slice(1)) {
      if (isList(f) && f[0] === "=" && isList(f[1]) && f.length === 3 && !Number.isNaN(Number(f[2]))) {
        numbers.set(show(f[1]), Number(f[2]));
        continue;
      }
      if (!isList(f) || f.length !== 3 || isList(f[1]) || isList(f[2])) continue;
      const [p, a, b] = f as string[];
      if (p === "at") initAt.set(a, b);
      else if (p === "in") initIn.set(a, b);
      else if (p === "road") {
        if (!roadSet.has(a + " " + b)) roadPairs.push([a, b]);
        roadSet.add(a + " " + b);
      }
    }
    // an object of unknown kind that something is "at" is a place
    for (const p of initAt.values()) if ((kinds.get(p) ?? "other") === "other") kinds.set(p, "place");
    for (const [a, b] of roadPairs) {
      for (const p of [a, b]) if ((kinds.get(p) ?? "other") === "other") kinds.set(p, "place");
    }

    const ofKind = (k: Kind) => declared.filter((o) => kinds.get(o) === k);
    const places = ofKind("place");
    for (const [a, b] of roadPairs) for (const p of [a, b]) if (!places.includes(p)) places.push(p);
    const trucks = ofKind("truck");
    const airplanes = ofKind("airplane");
    const packages = ofKind("package");
    const labels = new Map<string, string>();
    trucks.forEach((t, i) => labels.set(t, `T${i + 1}`));
    airplanes.forEach((a, i) => labels.set(a, `A${i + 1}`));
    packages.forEach((p, i) => labels.set(p, `P${i + 1}`));

    // roads: one per unordered pair, two-way when both directions exist
    const roads: Road[] = [];
    const seenPair = new Set<string>();
    for (const [a, b] of roadPairs) {
      const key = a < b ? a + " " + b : b + " " + a;
      if (seenPair.has(key)) continue;
      seenPair.add(key);
      roads.push({ a, b, both: roadSet.has(b + " " + a) });
    }

    // goal
    const goalForm = section(def, ":goal");
    const literalByText = new Map<string, Literal>();
    const goalLiterals: Literal[] = [];
    const prefForms: SExpr[][] = [];
    const goal = goalLines(goalForm?.[1], warnings, prefForms).map((line) =>
      line.map((x) => {
        let negated = false;
        let atom = x;
        if (isList(atom) && atom[0] === "not") {
          negated = true;
          atom = atom[1];
        }
        const text = show(x);
        let lit = literalByText.get(text);
        if (!lit) {
          const parts = isList(atom) ? atom.map((y) => (isList(y) ? show(y) : y)) : [atom];
          lit = { pred: parts[0], args: parts.slice(1), negated, label: `G${goalLiterals.length + 1}`, text };
          literalByText.set(text, lit);
          goalLiterals.push(lit);
        }
        return lit;
      }),
    );

    // preferences: a weight written in the preference, else from the metric.
    // A violation's coefficient in a metric to MINIMIZE is the utility of
    // achieving the preference; in one to MAXIMIZE, minus it.
    const metricWeights = new Map<string, number>();
    const metric = section(def, ":metric");
    const direction = metric?.[1] === "maximize" ? -1 : 1;
    (function walk(x: SExpr | undefined, scale: number) {
      if (!isList(x)) return;
      if (x[0] === "is-violated" && !isList(x[1])) {
        metricWeights.set(x[1] as string, (metricWeights.get(x[1] as string) ?? 0) + direction * scale);
      } else if (x[0] === "*" && x.length === 3) {
        const [a, b] = [x[1], x[2]];
        if (!isList(a) && !Number.isNaN(Number(a))) walk(b, scale * Number(a));
        else if (!isList(b) && !Number.isNaN(Number(b))) walk(a, scale * Number(b));
      } else if (x[0] === "+") {
        x.slice(1).forEach((y) => walk(y, scale));
      } else if (x[0] === "-") {
        if (x.length === 2) walk(x[1], -scale);
        else x.slice(1).forEach((y, i) => walk(y, i === 0 ? scale : -scale));
      }
    })(metric?.[2], 1);
    const preferences: Preference[] = [];
    for (const pf of prefForms) {
      // (preference NAME GD [WEIGHT]) or (preference GD [WEIGHT]) unnamed
      const named = pf.length >= 3 && !isList(pf[1]);
      const name = named ? (pf[1] as string) : "";
      const formula = named ? pf[2] : pf[1];
      const w = named ? pf[3] : pf[2];
      const weight = w !== undefined && !isList(w) && !Number.isNaN(Number(w)) ? Number(w) : metricWeights.get(name);
      if (formula !== undefined && weight !== undefined) preferences.push({ name, formula, weight });
    }

    // layout
    const layout = new Map<string, { row: number; col: number }>();
    const cell = /^p(\d+)-(\d+)$/;
    let rows = 0;
    let cols = 0;
    if (places.length > 0 && places.every((p) => cell.test(p))) {
      for (const p of places) {
        const m = cell.exec(p)!;
        const row = Number(m[1]);
        const col = Number(m[2]);
        layout.set(p, { row, col });
        rows = Math.max(rows, row);
        cols = Math.max(cols, col);
      }
    } else {
      if (places.length > 0) {
        warnings.push("places are not named p<row>-<col>: laid out in declaration order");
      }
      cols = Math.max(1, Math.ceil(Math.sqrt(places.length)));
      rows = Math.max(1, Math.ceil(places.length / cols));
      places.forEach((p, i) => layout.set(p, { row: Math.floor(i / cols) + 1, col: (i % cols) + 1 }));
    }

    for (const [o, p] of initAt) {
      if (!layout.has(p)) warnings.push(`init: ${o} is at ${p}, which is not a place`);
    }
    return {
      name, domain, kinds, places, airports, trucks, airplanes, packages, labels, roads,
      initAt, initIn, goal, goalLiterals, preferences, numbers, layout, rows, cols, warnings,
    };
  }
}
