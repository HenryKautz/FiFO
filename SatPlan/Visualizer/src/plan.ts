// Solutions, in three formats, turned into one state per time step.
//
//   answer   FiFO's .answer: (HOLDS fluent t) for every true fluent at slice t,
//            (OCCURS action t) for every action taken at slice t.
//   at       the same with each OCCURS written as the bare action followed by
//            "@ t":  (drive truck2 p2-3 p2-4) @ 1.  HOLDS lines may be kept.
//   list     a plain list of actions, one per step in order; an optional "t:"
//            prefix gives the step (several actions may share one) and a
//            trailing "[cost]" is ignored, as in IPC plan files.
//
// Step k shows state k and the actions taken at step k, which lead to state
// k+1.  When the file has HOLDS facts for a slice, that slice's state is read
// from them; otherwise it is computed from the previous state by applying the
// actions (load, unload, transfer, drive, fly, and their logistics-domain
// variants load-truck, drive-truck, ...).  Where both exist they are compared
// and a disagreement is reported.

namespace Viz {
  export interface Action {
    name: string;
    args: string[];
    text: string;
  }

  export interface State {
    /** object -> place, for vehicles and packages on the ground */
    at: Map<string, string>;
    /** package -> vehicle it is in */
    inside: Map<string, string>;
  }

  export type PlanFormat = "answer" | "at" | "list";

  export interface Plan {
    format: PlanFormat;
    /** steps[k]: the actions taken at step k, from states[k] to states[k+1] */
    steps: Action[][];
    states: State[];
    /** The first step's number as written in the file (1 for FiFO answers). */
    firstStep: number;
    objective?: string;
    warnings: string[];
  }

  export function cloneState(s: State): State {
    return { at: new Map(s.at), inside: new Map(s.inside) };
  }

  function sameState(a: State, b: State, objects: string[]): string | undefined {
    for (const o of objects) {
      const wa = a.inside.has(o) ? "in " + a.inside.get(o) : "at " + (a.at.get(o) ?? "nowhere");
      const wb = b.inside.has(o) ? "in " + b.inside.get(o) : "at " + (b.at.get(o) ?? "nowhere");
      if (wa !== wb) return `${o} is ${wb} in the file but ${wa} by applying the actions`;
    }
    return undefined;
  }

  function toAction(form: SExpr[]): Action {
    const parts = form.map((x) => (isList(x) ? show(x) : x));
    return { name: parts[0], args: parts.slice(1), text: show(form) };
  }

  /** The state after applying ACTIONS (taken together) to STATE. */
  export function applyActions(problem: Problem, state: State, actions: Action[], warnings: string[]): State {
    const next = cloneState(state);
    const kind = (o: string) => problem.kinds.get(o) ?? "other";
    const isVehicle = (o: string) => kind(o) === "truck" || kind(o) === "airplane";
    for (const a of actions) {
      const pkg = a.args.find((o) => kind(o) === "package");
      const vehicles = a.args.filter(isVehicle);
      const places = a.args.filter((o) => kind(o) === "place");
      const n = a.name;
      if (n.startsWith("unload") && pkg && vehicles.length >= 1) {
        const where = places[0] ?? state.at.get(vehicles[0]);
        next.inside.delete(pkg);
        if (where) next.at.set(pkg, where);
      } else if (n.startsWith("load") && pkg && vehicles.length >= 1) {
        next.at.delete(pkg);
        next.inside.set(pkg, vehicles[0]);
      } else if (n.startsWith("transfer") && pkg && vehicles.length >= 2) {
        next.inside.set(pkg, vehicles[1]);
      } else if ((n.includes("drive") || n.includes("fly") || n.includes("move")) &&
                 vehicles.length >= 1 && places.length >= 1) {
        next.at.set(vehicles[0], places.length >= 2 ? places[1] : places[0]);
      } else {
        warnings.push(`don't know how to apply ${a.text}; the state is left unchanged`);
      }
    }
    return next;
  }

  /** The source of a parsed plan item: where it came from in the file. */
  interface Item {
    action: Action;
    time?: number;
  }

  export function parsePlan(text: string, problem: Problem): Plan {
    const forms = readAll(text);
    const warnings: string[] = [];
    const items: Item[] = [];
    const holds = new Map<number, State>();
    let objective: string | undefined;
    let sawOccurs = false;
    let sawAt = false;
    let prefixTime: number | undefined;

    const holdsAt = (t: number) => {
      let s = holds.get(t);
      if (!s) {
        s = { at: new Map(), inside: new Map() };
        holds.set(t, s);
      }
      return s;
    };

    for (let i = 0; i < forms.length; i++) {
      const f = forms[i];
      if (!isList(f)) {
        const m = /^(\d+(?:\.\d+)?):$/.exec(f);
        if (m) prefixTime = Math.round(Number(m[1]));
        // SAT, UNSAT, "[1]" costs and other stray atoms carry nothing to show
        continue;
      }
      if (f.length === 0) continue;
      const head = f[0];
      // (HOLDS fluent t) and (OCCURS action t); FiFO writes a 0-ary one bare: (HOLDS P t)
      if ((head === "holds" || head === "occurs") && f.length === 3 && f[1] !== undefined) {
        const t = isList(f[2]) ? NaN : Number(f[2]);
        if (!Number.isInteger(t)) {
          warnings.push(`ignored ${show(f)}: its time step is not a number`);
          continue;
        }
        const body = isList(f[1]) ? f[1] : [f[1]];
        if (head === "occurs") {
          sawOccurs = true;
          items.push({ action: toAction(body), time: t });
        } else if (body.length === 3 && !isList(body[1]) && !isList(body[2]) && (body[0] === "at" || body[0] === "in")) {
          if (body[0] === "at") holdsAt(t).at.set(body[1] as string, body[2] as string);
          else holdsAt(t).inside.set(body[1] as string, body[2] as string);
        } else {
          holdsAt(t);
        }
      } else if (head === "*objective*") {
        objective = String(f[1]);
      } else if (head === "pref-violated" || head === "not") {
        continue;
      } else if (isList(head)) {
        warnings.push(`ignored ${show(f)}`);
      } else {
        // a bare action, possibly followed by "@ t"
        let time: number | undefined;
        if (forms[i + 1] === "@" && forms[i + 2] !== undefined && !isList(forms[i + 2])) {
          time = Number(forms[i + 2]);
          if (!Number.isInteger(time)) {
            warnings.push(`${show(f)} @ ${forms[i + 2]}: the step is not a number`);
            time = undefined;
          }
          sawAt = true;
          i += 2;
        } else if (prefixTime !== undefined) {
          time = prefixTime;
        }
        prefixTime = undefined;
        items.push({ action: toAction(f), time });
      }
    }

    const format: PlanFormat = sawOccurs ? "answer" : sawAt ? "at" : "list";
    const timed = items.filter((it) => it.time !== undefined && !Number.isNaN(it.time));
    if (timed.length > 0 && timed.length < items.length) {
      warnings.push(`${items.length - timed.length} action(s) have no step number; they are put after the rest, one per step`);
    }

    // step numbering: the first slice of the file (HOLDS or action) is step 0
    const times = [...timed.map((it) => it.time as number), ...holds.keys()];
    const first = times.length > 0 ? Math.min(...times) : 0;
    const steps: Action[][] = [];
    const put = (k: number, a: Action) => {
      while (steps.length <= k) steps.push([]);
      steps[k].push(a);
    };
    for (const it of timed) put((it.time as number) - first, it.action);
    let k = steps.length;
    for (const it of items) if (it.time === undefined || Number.isNaN(it.time)) put(k++, it.action);

    const lastHolds = holds.size > 0 ? Math.max(...holds.keys()) - first : 0;
    const nStates = Math.max(steps.length + 1, lastHolds + 1);
    while (steps.length < nStates - 1) steps.push([]);

    // states: HOLDS where the file has them, else the actions applied
    const objects = [...problem.trucks, ...problem.airplanes, ...problem.packages];
    const states: State[] = [];
    const initial: State = { at: new Map(problem.initAt), inside: new Map(problem.initIn) };
    const h0 = holds.get(first);
    states.push(h0 ? h0 : initial);
    if (h0) {
      const diff = sameState(initial, h0, objects);
      if (diff) warnings.push(`step 0: ${diff.replace("by applying the actions", "in the problem's init")}`);
    }
    for (let s = 0; s < nStates - 1; s++) {
      const applied = applyActions(problem, states[s], steps[s], warnings);
      const h = holds.get(first + s + 1);
      if (h) {
        const diff = sameState(applied, h, objects);
        if (diff) warnings.push(`step ${s + 1}: ${diff}`);
        states.push(h);
      } else {
        states.push(applied);
      }
    }

    for (const st of steps) {
      for (const a of st) {
        for (const o of a.args) {
          if (!problem.kinds.has(o) && !problem.layout.has(o)) {
            warnings.push(`${a.text} names ${o}, which the problem does not have`);
          }
        }
      }
    }
    if (items.length === 0 && holds.size === 0) warnings.push("no actions found in the solution file");
    return { format, steps, states, firstStep: first, objective, warnings: dedupe(warnings) };
  }

  function dedupe(xs: string[]): string[] {
    return [...new Set(xs)];
  }

  /** Whether formula F (at/in literals under and/or/not) holds in STATE;
   *  undefined when it mentions anything the visualizer does not track. */
  export function formulaHolds(f: SExpr, state: State): boolean | undefined {
    if (!isList(f)) return undefined;
    const parts = f.slice(1);
    if (f[0] === "and" || f[0] === "or") {
      const vs = parts.map((g) => formulaHolds(g, state));
      if (f[0] === "and") return vs.includes(false) ? false : vs.includes(undefined) ? undefined : true;
      return vs.includes(true) ? true : vs.includes(undefined) ? undefined : false;
    }
    if (f[0] === "not") {
      const v = formulaHolds(f[1], state);
      return v === undefined ? undefined : !v;
    }
    if ((f[0] === "at" || f[0] === "in") && f.length === 3 && !isList(f[1]) && !isList(f[2])) {
      return f[0] === "at" ? state.at.get(f[1] as string) === f[2] : state.inside.get(f[1] as string) === f[2];
    }
    return undefined;
  }

  export interface Utility {
    /** utility of the preferences achieved in the displayed state; undefined
     *  when the problem weights none */
    goals?: number;
    /** cost of the actions taken so far; undefined when the problem has no costs */
    costs?: number;
    /** false when some cost was guessed (no domain, or a cost term without a value) */
    costsExact: boolean;
    total: number;
    /** preferences whose truth could not be decided (not counted) */
    undecided: number;
  }

  /** The running utility at STEP: achieved preference weights, minus the cost
   *  of the actions taken before STEP. */
  export function utilityAt(problem: Problem, domain: Domain | undefined, plan: Plan | undefined, step: number): Utility {
    const state = plan ? plan.states[step] : { at: new Map(problem.initAt), inside: new Map(problem.initIn) };
    let goals: number | undefined;
    let undecided = 0;
    if (problem.preferences.length > 0) {
      goals = 0;
      for (const p of problem.preferences) {
        const v = formulaHolds(p.formula, state);
        if (v === true) goals += p.weight;
        else if (v === undefined) undecided++;
      }
    }
    const hasCosts = domain ? [...domain.actions.values()].some((a) => a.costs.length > 0 || a.conditionalCosts)
                            : [...problem.numbers.keys()].some((k) => /-cost\)$/.test(k) && k !== "(total-cost)");
    let costs: number | undefined;
    let costsExact = !!domain;
    if (hasCosts) {
      costs = 0;
      for (let k = 0; plan && k < step; k++) {
        for (const a of plan.steps[k]) {
          const c = actionCost(problem, domain, a);
          costs += c.cost;
          if (!c.exact) costsExact = false;
        }
      }
    }
    return { goals, costs, costsExact, total: (goals ?? 0) - (costs ?? 0), undecided };
  }

  /** Whether goal literal LIT holds in STATE; undefined for a predicate the
   *  visualizer does not track. */
  export function literalHolds(lit: Literal, state: State): boolean | undefined {
    let v: boolean | undefined;
    if (lit.pred === "at" && lit.args.length === 2) v = state.at.get(lit.args[0]) === lit.args[1];
    else if (lit.pred === "in" && lit.args.length === 2) v = state.inside.get(lit.args[0]) === lit.args[1];
    if (v === undefined) return undefined;
    return lit.negated ? !v : v;
  }
}
