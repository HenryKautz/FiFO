// What the visualizer needs from a PDDL domain: each action's parameters and
// the amount its effect adds to (total-cost), so a solution's running cost can
// be shown.  The amount is a number or a function term such as (drive-cost) or
// (road-length ?from ?to), whose value the problem's :init gives.

namespace Viz {
  export interface DomainAction {
    name: string;
    params: string[];
    /** the unconditional (increase (total-cost) X) amounts of the effect,
     *  summed; [] if none */
    costs: SExpr[];
    /** true when a cost sits under when/forall: it depends on the state or on
     *  how many objects match, which the visualizer does not evaluate */
    conditionalCosts: boolean;
  }

  export interface Domain {
    name: string;
    actions: Map<string, DomainAction>;
  }

  /** Parameter names of a typed list "?a ?b - t ?c - u". */
  function paramNames(list: SExpr | undefined): string[] {
    if (!isList(list)) return [];
    return list.filter((x): x is string => !isList(x) && x.startsWith("?"));
  }

  /** The (increase (total-cost) X) amounts of EFFECT: those under plain ANDs in
   *  COSTS, and whether any sits under a when or forall. */
  function costTerms(effect: SExpr | undefined, acc = { costs: [] as SExpr[], conditional: false }, under = false) {
    if (!isList(effect)) return acc;
    if (effect[0] === "increase" && isList(effect[1]) && effect[1][0] === "total-cost" && effect[2] !== undefined) {
      if (under) acc.conditional = true;
      else acc.costs.push(effect[2]);
      return acc;
    }
    const cond = under || effect[0] === "when" || effect[0] === "forall";
    for (const x of effect) costTerms(x, acc, cond);
    return acc;
  }

  export function isDomainText(text: string): boolean {
    return /\(\s*define\s*\(\s*domain\b/i.test(text.replace(/;[^\n]*/g, ""));
  }

  export function parseDomain(text: string): Domain {
    const forms = readAll(text);
    const def = forms.find((f) => isList(f) && f[0] === "define") as SExpr[] | undefined;
    if (!def || !isList(def[1]) || def[1][0] !== "domain") {
      throw new Error("no (define (domain ...)) form: is this a PDDL domain file?");
    }
    const actions = new Map<string, DomainAction>();
    for (const x of def.slice(2)) {
      if (!isList(x) || x[0] !== ":action") continue;
      const name = String(x[1]);
      let params: string[] = [];
      let effect: SExpr | undefined;
      for (let i = 2; i < x.length - 1; i++) {
        if (x[i] === ":parameters") params = paramNames(x[i + 1]);
        if (x[i] === ":effect") effect = x[i + 1];
      }
      const c = costTerms(effect);
      actions.set(name, { name, params, costs: c.costs, conditionalCosts: c.conditional });
    }
    return { name: String(def[1][1]), actions };
  }

  export interface ActionCost {
    cost: number;
    /** false when the cost had to be guessed (no domain, or a term with no value) */
    exact: boolean;
  }

  /** The cost of ACTION: from DOMAIN when given; otherwise guessed from the
   *  problem's cost functions by name (drive-cost for a drive, fly-cost for a
   *  fly, nothing for anything else). */
  export function actionCost(problem: Problem, domain: Domain | undefined, action: Action): ActionCost {
    if (!domain) {
      for (const [fn, v] of problem.numbers) {
        const m = /^\(([a-z0-9_-]+)-cost\)$/.exec(fn);
        if (m && action.name.includes(m[1])) return { cost: v, exact: false };
      }
      return { cost: 0, exact: false };
    }
    const da = domain.actions.get(action.name);
    if (!da) return { cost: 0, exact: false };
    const bind = new Map(da.params.map((p, i) => [p, action.args[i]] as [string, string]));
    let cost = 0;
    let exact = !da.conditionalCosts;   // conditional costs are not counted
    for (const term of da.costs) {
      if (!isList(term)) {
        const n = Number(term);
        if (Number.isNaN(n)) exact = false;
        else cost += n;
        continue;
      }
      const key = show(term.map((x) => (!isList(x) && bind.has(x) ? bind.get(x)! : x)));
      const v = problem.numbers.get(key);
      if (v === undefined) exact = false;
      else cost += v;
    }
    return { cost, exact };
  }
}
