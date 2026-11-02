// Built from src/ by build.sh with tsc 4.9.5 -- do not edit; rebuild instead.
"use strict";
// S-expression reader for PDDL problems and FiFO answer files.
//
// Everything is lowercased (PDDL and FiFO's answers are case-insensitive; FiFO
// prints upper case).  ";" starts a comment to the end of the line.  Besides
// lists and atoms, the reader keeps the top-level tokens a plan file may carry
// between forms -- "@", step numbers, "0:" prefixes, "[1]" costs -- as atoms,
// so the plan parser can read them in order.
var Viz;
(function (Viz) {
    function tokenize(text) {
        const tokens = [];
        let i = 0;
        const n = text.length;
        while (i < n) {
            const c = text[i];
            if (c === ";") {
                while (i < n && text[i] !== "\n")
                    i++;
            }
            else if (c === "(" || c === ")") {
                tokens.push(c);
                i++;
            }
            else if (/\s/.test(c)) {
                i++;
            }
            else {
                let j = i;
                while (j < n && !/[\s();]/.test(text[j]))
                    j++;
                tokens.push(text.slice(i, j).toLowerCase());
                i = j;
            }
        }
        return tokens;
    }
    Viz.tokenize = tokenize;
    /** Every top-level form of TEXT, atoms included, in order. */
    function readAll(text) {
        const tokens = tokenize(text);
        const out = [];
        let pos = 0;
        function read() {
            const t = tokens[pos++];
            if (t === "(") {
                const list = [];
                while (pos < tokens.length && tokens[pos] !== ")")
                    list.push(read());
                if (pos >= tokens.length)
                    throw new Error("unbalanced parentheses: a list is never closed");
                pos++; // the ")"
                return list;
            }
            if (t === ")")
                throw new Error("unbalanced parentheses: an extra ')'");
            return t;
        }
        while (pos < tokens.length)
            out.push(read());
        return out;
    }
    Viz.readAll = readAll;
    function isList(x) {
        return Array.isArray(x);
    }
    Viz.isList = isList;
    function show(x) {
        return isList(x) ? "(" + x.map(show).join(" ") + ")" : x;
    }
    Viz.show = show;
})(Viz || (Viz = {}));
// A grid planning problem as the visualizer needs it: places laid out on the
// grid, roads, vehicles, packages, where everything starts, and the hard goal.
//
// Places named p<row>-<col> (ppgen's grid style) are drawn at that cell, row 1
// at the top.  Any other place names get a square layout in the order they are
// declared.  Object kinds come from their PDDL types (truck, airplane, package,
// place, airport); an untyped object is classified by its name.
var Viz;
(function (Viz) {
    function section(def, key) {
        for (const x of def)
            if (Viz.isList(x) && x[0] === key)
                return x;
        return undefined;
    }
    function kindOfType(t) {
        if (t === "truck")
            return "truck";
        if (t === "airplane" || t === "plane")
            return "airplane";
        if (t === "package" || t === "obj")
            return "package";
        if (t === "place" || t === "location" || t === "airport" || t === "city-location")
            return "place";
        return "other";
    }
    function kindOfName(n) {
        if (/^truck/.test(n))
            return "truck";
        if (/^(air)?plane/.test(n))
            return "airplane";
        if (/^(pkg|package|obj)/.test(n))
            return "package";
        return "other";
    }
    /** The hard goal's lines: preferences dropped, nested ANDs flattened, each
     *  conjunct an OR (one line of disjuncts) or a single literal (a line of one). */
    function goalLines(goal, warnings, prefs) {
        if (goal === undefined)
            return [];
        const conjuncts = [];
        (function flatten(g) {
            if (Viz.isList(g) && g[0] === "and")
                g.slice(1).forEach(flatten);
            else if (Viz.isList(g) && g[0] === "preference")
                prefs.push(g);
            else
                conjuncts.push(g);
        })(goal);
        const lines = [];
        for (const c of conjuncts) {
            if (Viz.isList(c) && c[0] === "or") {
                const disjuncts = [];
                for (const d of c.slice(1)) {
                    if (Viz.isList(d) && (d[0] === "and" || d[0] === "or")) {
                        warnings.push(`goal: nested ${d[0]} inside OR shown as one literal: ${Viz.show(d)}`);
                    }
                    disjuncts.push(d);
                }
                lines.push(disjuncts);
            }
            else {
                lines.push([c]);
            }
        }
        return lines;
    }
    function parseProblem(text) {
        var _a, _b, _c, _d, _e;
        const forms = Viz.readAll(text);
        const def = forms.find((f) => Viz.isList(f) && f[0] === "define");
        if (!def)
            throw new Error("no (define (problem ...)) form: is this a PDDL problem file?");
        const head = def[1];
        if (!Viz.isList(head) || head[0] !== "problem") {
            throw new Error("this is a PDDL domain, not a problem: choose the problem file");
        }
        const warnings = [];
        const name = String((_a = head[1]) !== null && _a !== void 0 ? _a : "problem");
        const domainForm = section(def, ":domain");
        const domain = domainForm ? String(domainForm[1]) : "";
        // objects: names, then "- type"
        const kinds = new Map();
        const declared = [];
        const airports = new Set();
        const objs = (_b = section(def, ":objects")) !== null && _b !== void 0 ? _b : [];
        let pending = [];
        for (let i = 1; i < objs.length; i++) {
            const x = objs[i];
            if (x === "-") {
                const t = String(objs[++i]);
                for (const o of pending) {
                    kinds.set(o, kindOfType(t));
                    if (t === "airport")
                        airports.add(o);
                }
                pending = [];
            }
            else if (!Viz.isList(x)) {
                pending.push(x);
                declared.push(x);
            }
        }
        for (const o of pending)
            kinds.set(o, kindOfName(o));
        // init
        const initAt = new Map();
        const initIn = new Map();
        const roadSet = new Set();
        const roadPairs = [];
        const numbers = new Map();
        for (const f of ((_c = section(def, ":init")) !== null && _c !== void 0 ? _c : []).slice(1)) {
            if (Viz.isList(f) && f[0] === "=" && Viz.isList(f[1]) && f.length === 3 && !Number.isNaN(Number(f[2]))) {
                numbers.set(Viz.show(f[1]), Number(f[2]));
                continue;
            }
            if (!Viz.isList(f) || f.length !== 3 || Viz.isList(f[1]) || Viz.isList(f[2]))
                continue;
            const [p, a, b] = f;
            if (p === "at")
                initAt.set(a, b);
            else if (p === "in")
                initIn.set(a, b);
            else if (p === "road") {
                if (!roadSet.has(a + " " + b))
                    roadPairs.push([a, b]);
                roadSet.add(a + " " + b);
            }
        }
        // an object of unknown kind that something is "at" is a place
        for (const p of initAt.values())
            if (((_d = kinds.get(p)) !== null && _d !== void 0 ? _d : "other") === "other")
                kinds.set(p, "place");
        for (const [a, b] of roadPairs) {
            for (const p of [a, b])
                if (((_e = kinds.get(p)) !== null && _e !== void 0 ? _e : "other") === "other")
                    kinds.set(p, "place");
        }
        const ofKind = (k) => declared.filter((o) => kinds.get(o) === k);
        const places = ofKind("place");
        for (const [a, b] of roadPairs)
            for (const p of [a, b])
                if (!places.includes(p))
                    places.push(p);
        const trucks = ofKind("truck");
        const airplanes = ofKind("airplane");
        const packages = ofKind("package");
        const labels = new Map();
        trucks.forEach((t, i) => labels.set(t, `T${i + 1}`));
        airplanes.forEach((a, i) => labels.set(a, `A${i + 1}`));
        packages.forEach((p, i) => labels.set(p, `P${i + 1}`));
        // roads: one per unordered pair, two-way when both directions exist
        const roads = [];
        const seenPair = new Set();
        for (const [a, b] of roadPairs) {
            const key = a < b ? a + " " + b : b + " " + a;
            if (seenPair.has(key))
                continue;
            seenPair.add(key);
            roads.push({ a, b, both: roadSet.has(b + " " + a) });
        }
        // goal
        const goalForm = section(def, ":goal");
        const literalByText = new Map();
        const goalLiterals = [];
        const prefForms = [];
        const goal = goalLines(goalForm === null || goalForm === void 0 ? void 0 : goalForm[1], warnings, prefForms).map((line) => line.map((x) => {
            let negated = false;
            let atom = x;
            if (Viz.isList(atom) && atom[0] === "not") {
                negated = true;
                atom = atom[1];
            }
            const text = Viz.show(x);
            let lit = literalByText.get(text);
            if (!lit) {
                const parts = Viz.isList(atom) ? atom.map((y) => (Viz.isList(y) ? Viz.show(y) : y)) : [atom];
                lit = { pred: parts[0], args: parts.slice(1), negated, label: `G${goalLiterals.length + 1}`, text };
                literalByText.set(text, lit);
                goalLiterals.push(lit);
            }
            return lit;
        }));
        // preferences: a weight written in the preference, else from the metric.
        // A violation's coefficient in a metric to MINIMIZE is the utility of
        // achieving the preference; in one to MAXIMIZE, minus it.
        const metricWeights = new Map();
        const metric = section(def, ":metric");
        const direction = (metric === null || metric === void 0 ? void 0 : metric[1]) === "maximize" ? -1 : 1;
        (function walk(x, scale) {
            var _a;
            if (!Viz.isList(x))
                return;
            if (x[0] === "is-violated" && !Viz.isList(x[1])) {
                metricWeights.set(x[1], ((_a = metricWeights.get(x[1])) !== null && _a !== void 0 ? _a : 0) + direction * scale);
            }
            else if (x[0] === "*" && x.length === 3) {
                const [a, b] = [x[1], x[2]];
                if (!Viz.isList(a) && !Number.isNaN(Number(a)))
                    walk(b, scale * Number(a));
                else if (!Viz.isList(b) && !Number.isNaN(Number(b)))
                    walk(a, scale * Number(b));
            }
            else if (x[0] === "+") {
                x.slice(1).forEach((y) => walk(y, scale));
            }
            else if (x[0] === "-") {
                if (x.length === 2)
                    walk(x[1], -scale);
                else
                    x.slice(1).forEach((y, i) => walk(y, i === 0 ? scale : -scale));
            }
        })(metric === null || metric === void 0 ? void 0 : metric[2], 1);
        const preferences = [];
        for (const pf of prefForms) {
            // (preference NAME GD [WEIGHT]) or (preference GD [WEIGHT]) unnamed
            const named = pf.length >= 3 && !Viz.isList(pf[1]);
            const name = named ? pf[1] : "";
            const formula = named ? pf[2] : pf[1];
            const w = named ? pf[3] : pf[2];
            const weight = w !== undefined && !Viz.isList(w) && !Number.isNaN(Number(w)) ? Number(w) : metricWeights.get(name);
            if (formula !== undefined && weight !== undefined)
                preferences.push({ name, formula, weight });
        }
        // layout
        const layout = new Map();
        const cell = /^p(\d+)-(\d+)$/;
        let rows = 0;
        let cols = 0;
        if (places.length > 0 && places.every((p) => cell.test(p))) {
            for (const p of places) {
                const m = cell.exec(p);
                const row = Number(m[1]);
                const col = Number(m[2]);
                layout.set(p, { row, col });
                rows = Math.max(rows, row);
                cols = Math.max(cols, col);
            }
        }
        else {
            if (places.length > 0) {
                warnings.push("places are not named p<row>-<col>: laid out in declaration order");
            }
            cols = Math.max(1, Math.ceil(Math.sqrt(places.length)));
            rows = Math.max(1, Math.ceil(places.length / cols));
            places.forEach((p, i) => layout.set(p, { row: Math.floor(i / cols) + 1, col: (i % cols) + 1 }));
        }
        for (const [o, p] of initAt) {
            if (!layout.has(p))
                warnings.push(`init: ${o} is at ${p}, which is not a place`);
        }
        return {
            name, domain, kinds, places, airports, trucks, airplanes, packages, labels, roads,
            initAt, initIn, goal, goalLiterals, preferences, numbers, layout, rows, cols, warnings,
        };
    }
    Viz.parseProblem = parseProblem;
})(Viz || (Viz = {}));
// What the visualizer needs from a PDDL domain: each action's parameters and
// the amount its effect adds to (total-cost), so a solution's running cost can
// be shown.  The amount is a number or a function term such as (drive-cost) or
// (road-length ?from ?to), whose value the problem's :init gives.
var Viz;
(function (Viz) {
    /** Parameter names of a typed list "?a ?b - t ?c - u". */
    function paramNames(list) {
        if (!Viz.isList(list))
            return [];
        return list.filter((x) => !Viz.isList(x) && x.startsWith("?"));
    }
    /** The (increase (total-cost) X) amounts of EFFECT: those under plain ANDs in
     *  COSTS, and whether any sits under a when or forall. */
    function costTerms(effect, acc = { costs: [], conditional: false }, under = false) {
        if (!Viz.isList(effect))
            return acc;
        if (effect[0] === "increase" && Viz.isList(effect[1]) && effect[1][0] === "total-cost" && effect[2] !== undefined) {
            if (under)
                acc.conditional = true;
            else
                acc.costs.push(effect[2]);
            return acc;
        }
        const cond = under || effect[0] === "when" || effect[0] === "forall";
        for (const x of effect)
            costTerms(x, acc, cond);
        return acc;
    }
    function isDomainText(text) {
        return /\(\s*define\s*\(\s*domain\b/i.test(text.replace(/;[^\n]*/g, ""));
    }
    Viz.isDomainText = isDomainText;
    function parseDomain(text) {
        const forms = Viz.readAll(text);
        const def = forms.find((f) => Viz.isList(f) && f[0] === "define");
        if (!def || !Viz.isList(def[1]) || def[1][0] !== "domain") {
            throw new Error("no (define (domain ...)) form: is this a PDDL domain file?");
        }
        const actions = new Map();
        for (const x of def.slice(2)) {
            if (!Viz.isList(x) || x[0] !== ":action")
                continue;
            const name = String(x[1]);
            let params = [];
            let effect;
            for (let i = 2; i < x.length - 1; i++) {
                if (x[i] === ":parameters")
                    params = paramNames(x[i + 1]);
                if (x[i] === ":effect")
                    effect = x[i + 1];
            }
            const c = costTerms(effect);
            actions.set(name, { name, params, costs: c.costs, conditionalCosts: c.conditional });
        }
        return { name: String(def[1][1]), actions };
    }
    Viz.parseDomain = parseDomain;
    /** The cost of ACTION: from DOMAIN when given; otherwise guessed from the
     *  problem's cost functions by name (drive-cost for a drive, fly-cost for a
     *  fly, nothing for anything else). */
    function actionCost(problem, domain, action) {
        if (!domain) {
            for (const [fn, v] of problem.numbers) {
                const m = /^\(([a-z0-9_-]+)-cost\)$/.exec(fn);
                if (m && action.name.includes(m[1]))
                    return { cost: v, exact: false };
            }
            return { cost: 0, exact: false };
        }
        const da = domain.actions.get(action.name);
        if (!da)
            return { cost: 0, exact: false };
        const bind = new Map(da.params.map((p, i) => [p, action.args[i]]));
        let cost = 0;
        let exact = !da.conditionalCosts; // conditional costs are not counted
        for (const term of da.costs) {
            if (!Viz.isList(term)) {
                const n = Number(term);
                if (Number.isNaN(n))
                    exact = false;
                else
                    cost += n;
                continue;
            }
            const key = Viz.show(term.map((x) => (!Viz.isList(x) && bind.has(x) ? bind.get(x) : x)));
            const v = problem.numbers.get(key);
            if (v === undefined)
                exact = false;
            else
                cost += v;
        }
        return { cost, exact };
    }
    Viz.actionCost = actionCost;
})(Viz || (Viz = {}));
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
var Viz;
(function (Viz) {
    function cloneState(s) {
        return { at: new Map(s.at), inside: new Map(s.inside) };
    }
    Viz.cloneState = cloneState;
    function sameState(a, b, objects) {
        var _a, _b;
        for (const o of objects) {
            const wa = a.inside.has(o) ? "in " + a.inside.get(o) : "at " + ((_a = a.at.get(o)) !== null && _a !== void 0 ? _a : "nowhere");
            const wb = b.inside.has(o) ? "in " + b.inside.get(o) : "at " + ((_b = b.at.get(o)) !== null && _b !== void 0 ? _b : "nowhere");
            if (wa !== wb)
                return `${o} is ${wb} in the file but ${wa} by applying the actions`;
        }
        return undefined;
    }
    function toAction(form) {
        const parts = form.map((x) => (Viz.isList(x) ? Viz.show(x) : x));
        return { name: parts[0], args: parts.slice(1), text: Viz.show(form) };
    }
    /** The state after applying ACTIONS (taken together) to STATE. */
    function applyActions(problem, state, actions, warnings) {
        var _a;
        const next = cloneState(state);
        const kind = (o) => { var _a; return (_a = problem.kinds.get(o)) !== null && _a !== void 0 ? _a : "other"; };
        const isVehicle = (o) => kind(o) === "truck" || kind(o) === "airplane";
        for (const a of actions) {
            const pkg = a.args.find((o) => kind(o) === "package");
            const vehicles = a.args.filter(isVehicle);
            const places = a.args.filter((o) => kind(o) === "place");
            const n = a.name;
            if (n.startsWith("unload") && pkg && vehicles.length >= 1) {
                const where = (_a = places[0]) !== null && _a !== void 0 ? _a : state.at.get(vehicles[0]);
                next.inside.delete(pkg);
                if (where)
                    next.at.set(pkg, where);
            }
            else if (n.startsWith("load") && pkg && vehicles.length >= 1) {
                next.at.delete(pkg);
                next.inside.set(pkg, vehicles[0]);
            }
            else if (n.startsWith("transfer") && pkg && vehicles.length >= 2) {
                next.inside.set(pkg, vehicles[1]);
            }
            else if ((n.includes("drive") || n.includes("fly") || n.includes("move")) &&
                vehicles.length >= 1 && places.length >= 1) {
                next.at.set(vehicles[0], places.length >= 2 ? places[1] : places[0]);
            }
            else {
                warnings.push(`don't know how to apply ${a.text}; the state is left unchanged`);
            }
        }
        return next;
    }
    Viz.applyActions = applyActions;
    function parsePlan(text, problem) {
        const forms = Viz.readAll(text);
        const warnings = [];
        const items = [];
        const holds = new Map();
        let objective;
        let sawOccurs = false;
        let sawAt = false;
        let prefixTime;
        const holdsAt = (t) => {
            let s = holds.get(t);
            if (!s) {
                s = { at: new Map(), inside: new Map() };
                holds.set(t, s);
            }
            return s;
        };
        for (let i = 0; i < forms.length; i++) {
            const f = forms[i];
            if (!Viz.isList(f)) {
                const m = /^(\d+(?:\.\d+)?):$/.exec(f);
                if (m)
                    prefixTime = Math.round(Number(m[1]));
                // SAT, UNSAT, "[1]" costs and other stray atoms carry nothing to show
                continue;
            }
            if (f.length === 0)
                continue;
            const head = f[0];
            // (HOLDS fluent t) and (OCCURS action t); FiFO writes a 0-ary one bare: (HOLDS P t)
            if ((head === "holds" || head === "occurs") && f.length === 3 && f[1] !== undefined) {
                const t = Viz.isList(f[2]) ? NaN : Number(f[2]);
                if (!Number.isInteger(t)) {
                    warnings.push(`ignored ${Viz.show(f)}: its time step is not a number`);
                    continue;
                }
                const body = Viz.isList(f[1]) ? f[1] : [f[1]];
                if (head === "occurs") {
                    sawOccurs = true;
                    items.push({ action: toAction(body), time: t });
                }
                else if (body.length === 3 && !Viz.isList(body[1]) && !Viz.isList(body[2]) && (body[0] === "at" || body[0] === "in")) {
                    if (body[0] === "at")
                        holdsAt(t).at.set(body[1], body[2]);
                    else
                        holdsAt(t).inside.set(body[1], body[2]);
                }
                else {
                    holdsAt(t);
                }
            }
            else if (head === "*objective*") {
                objective = String(f[1]);
            }
            else if (head === "pref-violated" || head === "not") {
                continue;
            }
            else if (Viz.isList(head)) {
                warnings.push(`ignored ${Viz.show(f)}`);
            }
            else {
                // a bare action, possibly followed by "@ t"
                let time;
                if (forms[i + 1] === "@" && forms[i + 2] !== undefined && !Viz.isList(forms[i + 2])) {
                    time = Number(forms[i + 2]);
                    if (!Number.isInteger(time)) {
                        warnings.push(`${Viz.show(f)} @ ${forms[i + 2]}: the step is not a number`);
                        time = undefined;
                    }
                    sawAt = true;
                    i += 2;
                }
                else if (prefixTime !== undefined) {
                    time = prefixTime;
                }
                prefixTime = undefined;
                items.push({ action: toAction(f), time });
            }
        }
        const format = sawOccurs ? "answer" : sawAt ? "at" : "list";
        const timed = items.filter((it) => it.time !== undefined && !Number.isNaN(it.time));
        if (timed.length > 0 && timed.length < items.length) {
            warnings.push(`${items.length - timed.length} action(s) have no step number; they are put after the rest, one per step`);
        }
        // step numbering: the first slice of the file (HOLDS or action) is step 0
        const times = [...timed.map((it) => it.time), ...holds.keys()];
        const first = times.length > 0 ? Math.min(...times) : 0;
        const steps = [];
        const put = (k, a) => {
            while (steps.length <= k)
                steps.push([]);
            steps[k].push(a);
        };
        for (const it of timed)
            put(it.time - first, it.action);
        let k = steps.length;
        for (const it of items)
            if (it.time === undefined || Number.isNaN(it.time))
                put(k++, it.action);
        const lastHolds = holds.size > 0 ? Math.max(...holds.keys()) - first : 0;
        const nStates = Math.max(steps.length + 1, lastHolds + 1);
        while (steps.length < nStates - 1)
            steps.push([]);
        // states: HOLDS where the file has them, else the actions applied
        const objects = [...problem.trucks, ...problem.airplanes, ...problem.packages];
        const states = [];
        const initial = { at: new Map(problem.initAt), inside: new Map(problem.initIn) };
        const h0 = holds.get(first);
        states.push(h0 ? h0 : initial);
        if (h0) {
            const diff = sameState(initial, h0, objects);
            if (diff)
                warnings.push(`step 0: ${diff.replace("by applying the actions", "in the problem's init")}`);
        }
        for (let s = 0; s < nStates - 1; s++) {
            const applied = applyActions(problem, states[s], steps[s], warnings);
            const h = holds.get(first + s + 1);
            if (h) {
                const diff = sameState(applied, h, objects);
                if (diff)
                    warnings.push(`step ${s + 1}: ${diff}`);
                states.push(h);
            }
            else {
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
        if (items.length === 0 && holds.size === 0)
            warnings.push("no actions found in the solution file");
        return { format, steps, states, firstStep: first, objective, warnings: dedupe(warnings) };
    }
    Viz.parsePlan = parsePlan;
    function dedupe(xs) {
        return [...new Set(xs)];
    }
    /** Whether formula F (at/in literals under and/or/not) holds in STATE;
     *  undefined when it mentions anything the visualizer does not track. */
    function formulaHolds(f, state) {
        if (!Viz.isList(f))
            return undefined;
        const parts = f.slice(1);
        if (f[0] === "and" || f[0] === "or") {
            const vs = parts.map((g) => formulaHolds(g, state));
            if (f[0] === "and")
                return vs.includes(false) ? false : vs.includes(undefined) ? undefined : true;
            return vs.includes(true) ? true : vs.includes(undefined) ? undefined : false;
        }
        if (f[0] === "not") {
            const v = formulaHolds(f[1], state);
            return v === undefined ? undefined : !v;
        }
        if ((f[0] === "at" || f[0] === "in") && f.length === 3 && !Viz.isList(f[1]) && !Viz.isList(f[2])) {
            return f[0] === "at" ? state.at.get(f[1]) === f[2] : state.inside.get(f[1]) === f[2];
        }
        return undefined;
    }
    Viz.formulaHolds = formulaHolds;
    /** The running utility at STEP: achieved preference weights, minus the cost
     *  of the actions taken before STEP.  With PSEUDO (a number) and a problem
     *  that gives its goals no utility, each distinct hard-goal literal that
     *  holds counts PSEUDO instead -- a display aid, not the problem's utility. */
    function utilityAt(problem, domain, plan, step, pseudo) {
        const state = plan ? plan.states[step] : { at: new Map(problem.initAt), inside: new Map(problem.initIn) };
        let goals;
        let undecided = 0;
        let isPseudo = false;
        if (problem.preferences.length > 0) {
            goals = 0;
            for (const p of problem.preferences) {
                const v = formulaHolds(p.formula, state);
                if (v === true)
                    goals += p.weight;
                else if (v === undefined)
                    undecided++;
            }
        }
        else if (pseudo !== undefined && problem.goalLiterals.length > 0) {
            isPseudo = true;
            goals = 0;
            for (const lit of problem.goalLiterals) {
                const v = literalHolds(lit, state);
                if (v === true)
                    goals += pseudo;
                else if (v === undefined)
                    undecided++;
            }
        }
        const hasCosts = domain ? [...domain.actions.values()].some((a) => a.costs.length > 0 || a.conditionalCosts)
            : [...problem.numbers.keys()].some((k) => /-cost\)$/.test(k) && k !== "(total-cost)");
        let costs;
        let costsExact = !!domain;
        if (hasCosts) {
            costs = 0;
            for (let k = 0; plan && k < step; k++) {
                for (const a of plan.steps[k]) {
                    const c = Viz.actionCost(problem, domain, a);
                    costs += c.cost;
                    if (!c.exact)
                        costsExact = false;
                }
            }
        }
        return { goals, costs, costsExact, total: (goals !== null && goals !== void 0 ? goals : 0) - (costs !== null && costs !== void 0 ? costs : 0), undecided, pseudo: isPseudo };
    }
    Viz.utilityAt = utilityAt;
    /** Whether goal literal LIT holds in STATE; undefined for a predicate the
     *  visualizer does not track. */
    function literalHolds(lit, state) {
        let v;
        if (lit.pred === "at" && lit.args.length === 2)
            v = state.at.get(lit.args[0]) === lit.args[1];
        else if (lit.pred === "in" && lit.args.length === 2)
            v = state.inside.get(lit.args[0]) === lit.args[1];
        if (v === undefined)
            return undefined;
        return lit.negated ? !v : v;
    }
    Viz.literalHolds = literalHolds;
})(Viz || (Viz = {}));
// The map as SVG markup: places as squares on the grid, roads as lines with an
// arrowhead at each end they can be driven towards, and in each square its
// trucks, airplanes, packages and goal destinations.
//
// A square's contents fill it: one kind alone (say, a truck) gets the whole
// square; vehicles share it with the others by taking the bottom part; goals
// and packages split what is left side by side.  Several vehicles or packages
// overlap, each further one offset up and to the right so its edge shows, and
// they shrink as there are more; several goals are tiled side by side, shrunk to
// fit, so every label stays readable.  A package in a vehicle is a small badge
// on that vehicle.
// The SVG has a viewBox and no fixed size, so it scales with its container.
//
// Icons: Material Design Icons (https://pictogrammers.com/library/mdi/),
// Apache License 2.0 -- "truck", "airplane", "package-variant-closed".
var Viz;
(function (Viz) {
    const TRUCK_COLORS = ["#2563eb", "#dc2626", "#16a34a", "#9333ea", "#0891b2", "#ca8a04", "#db2777", "#475569"];
    const PACKAGE_COLORS = ["#ea580c", "#0d9488", "#c026d3", "#65a30d", "#4f46e5", "#e11d48", "#0284c7", "#a16207",
        "#7c3aed", "#059669", "#be123c", "#1d4ed8"];
    /** Icon paths in a 24 x 24 box, and where on the icon its label sits. */
    const ICONS = {
        truck: {
            d: "M18,18.5A1.5,1.5 0 0,1 16.5,17A1.5,1.5 0 0,1 18,15.5A1.5,1.5 0 0,1 19.5,17A1.5,1.5 0 0,1 18,18.5M19.5,9.5L21.46,12H17V9.5M6,18.5A1.5,1.5 0 0,1 4.5,17A1.5,1.5 0 0,1 6,15.5A1.5,1.5 0 0,1 7.5,17A1.5,1.5 0 0,1 6,18.5M20,8H17V4H3C1.89,4 1,4.89 1,6V17H3A3,3 0 0,0 6,20A3,3 0 0,0 9,17H15A3,3 0 0,0 18,20A3,3 0 0,0 21,17H23V12L20,8Z",
            label: { x: 8.5, y: 10.5 },
        },
        airplane: {
            d: "M20.56 3.91C21.15 4.5 21.15 5.45 20.56 6.03L16.67 9.92L18.79 19.11L17.38 20.53L13.5 13.1L9.6 17L9.96 19.47L8.89 20.53L7.13 17.35L3.94 15.58L5 14.5L7.5 14.87L11.37 11L3.94 7.09L5.36 5.68L14.55 7.8L18.44 3.91C19 3.33 20 3.33 20.56 3.91Z",
            label: { x: 12, y: 12.5 },
        },
        package: {
            d: "M21,16.5C21,16.88 20.79,17.21 20.47,17.38L12.57,21.82C12.41,21.94 12.21,22 12,22C11.79,22 11.59,21.94 11.43,21.82L3.53,17.38C3.21,17.21 3,16.88 3,16.5V7.5C3,7.12 3.21,6.79 3.53,6.62L11.43,2.18C11.59,2.06 11.79,2 12,2C12.21,2 12.41,2.06 12.57,2.18L20.47,6.62C20.79,6.79 21,7.12 21,7.5V16.5M12,4.15L10.11,5.22L16,8.61L17.96,7.5L12,4.15M6.04,7.5L12,10.85L13.96,9.75L8.08,6.35L6.04,7.5M5,15.91L11,19.29V12.58L5,9.21V15.91M19,15.91V9.21L13,12.58V19.29L19,15.91Z",
            label: { x: 12, y: 13.5 },
        },
    };
    const SPACING = 100; // grid pitch, in SVG units
    const SIDE = 68; // a place's square
    const MARGIN = 24;
    const PAD = 2; // between a square's edge and its contents
    const OFFSET = 0.2; // a stacked item's offset, as a fraction of its size
    function colorOf(problem, obj) {
        let i = problem.trucks.indexOf(obj);
        if (i >= 0)
            return TRUCK_COLORS[i % TRUCK_COLORS.length];
        i = problem.airplanes.indexOf(obj);
        if (i >= 0)
            return TRUCK_COLORS[(problem.trucks.length + i) % TRUCK_COLORS.length];
        i = problem.packages.indexOf(obj);
        if (i >= 0)
            return PACKAGE_COLORS[i % PACKAGE_COLORS.length];
        return "#6b7280";
    }
    Viz.colorOf = colorOf;
    /** S escaped for HTML text and double-quoted attributes: the one copy, for
     *  every page (render.ts comes first in each build) */
    function esc(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }
    Viz.esc = esc;
    function f(x) {
        return (Math.round(x * 100) / 100).toString();
    }
    /** The top-left corner of place P's square. */
    function corner(problem, p) {
        const c = problem.layout.get(p);
        if (!c)
            return undefined;
        return {
            x: MARGIN + (c.col - 1) * SPACING + (SPACING - SIDE) / 2,
            y: MARGIN + (c.row - 1) * SPACING + (SPACING - SIDE) / 2,
        };
    }
    function center(problem, p) {
        const c = corner(problem, p);
        return c && { x: c.x + SIDE / 2, y: c.y + SIDE / 2 };
    }
    /** Where the segment from the center of a square towards (dx, dy) leaves it. */
    function exitPoint(cx, cy, dx, dy, gap) {
        const half = SIDE / 2 + gap;
        const t = half / Math.max(Math.abs(dx), Math.abs(dy));
        return { x: cx + dx * t, y: cy + dy * t };
    }
    /** N square items stacked in REGION as large as fits, each further one offset
     *  up and to the right by OFFSET of its size; the stack is centered across the
     *  region and sits on its bottom.  Each item's top-left corner and the size. */
    function stack(n, region) {
        const k = 1 + OFFSET * (n - 1);
        const size = Math.min(region.w, region.h) / k;
        const d = size * OFFSET;
        const span = size * k;
        const x0 = region.x + (region.w - span) / 2;
        const y0 = region.y + region.h - size;
        const boxes = [];
        for (let i = 0; i < n; i++)
            boxes.push({ x: x0 + i * d, y: y0 - i * d });
        return { boxes, size };
    }
    Viz.stack = stack;
    /** N square items tiled in REGION without overlapping: the grid of columns
     *  and rows that gives the largest items, centered in the region.  Each
     *  item's top-left corner (row by row) and the size. */
    function tile(n, region) {
        let best = { cols: 1, rows: n, size: 0 };
        for (let cols = 1; cols <= n; cols++) {
            const rows = Math.ceil(n / cols);
            const size = Math.min(region.w / cols, region.h / rows);
            if (size > best.size)
                best = { cols, rows, size };
        }
        const { cols, rows, size } = best;
        const x0 = region.x + (region.w - cols * size) / 2;
        const y0 = region.y + (region.h - rows * size) / 2;
        const boxes = [];
        for (let i = 0; i < n; i++)
            boxes.push({ x: x0 + (i % cols) * size, y: y0 + Math.floor(i / cols) * size });
        return { boxes, size };
    }
    Viz.tile = tile;
    /** The parts of a square's inner area given to each kind present. */
    function regions(inner, goals, packages, vehicles) {
        const out = {};
        const top = goals || packages;
        const topH = vehicles && top ? inner.h * 0.45 : inner.h;
        const topBox = { x: inner.x, y: inner.y, w: inner.w, h: topH };
        if (vehicles)
            out.vehicles = top ? { x: inner.x, y: inner.y + topH, w: inner.w, h: inner.h - topH } : inner;
        if (goals && packages) {
            out.goals = { x: topBox.x, y: topBox.y, w: topBox.w / 2, h: topBox.h };
            out.packages = { x: topBox.x + topBox.w / 2, y: topBox.y, w: topBox.w / 2, h: topBox.h };
        }
        else if (goals) {
            out.goals = topBox;
        }
        else if (packages) {
            out.packages = topBox;
        }
        return out;
    }
    Viz.regions = regions;
    /** An icon of KIND at (X, Y), SIZE square, in COLOR, with a haloed label. */
    function icon(kind, cls, x, y, size, color, label, title, extra = "") {
        const ic = ICONS[kind];
        const u = size / 24;
        const fs = Math.max(size * 0.3, 5);
        const lx = x + ic.label.x * u;
        const ly = y + ic.label.y * u;
        // the package icon is line art, so its label sits on a solid tag; the
        // vehicles' labels sit on their solid bodies, haloed in their color
        const tag = kind === "package"
            ? `<rect class="tag" x="${f(lx - fs * 0.62 * label.length / 2 - fs * 0.25)}" y="${f(ly - fs * 0.62)}" ` +
                `width="${f(fs * 0.62 * label.length + fs * 0.5)}" height="${f(fs * 1.24)}" rx="${f(fs * 0.3)}" fill="${color}"/>`
            : "";
        return `<g class="${cls}" data-box="${f(x)} ${f(y)} ${f(size)}">` +
            `<svg x="${f(x)}" y="${f(y)}" width="${f(size)}" height="${f(size)}" viewBox="0 0 24 24">` +
            `<path d="${ic.d}" fill="${color}"/></svg>` + tag +
            `<text class="label" x="${f(lx)}" y="${f(ly)}" font-size="${f(fs)}" ` +
            `stroke="${color}" stroke-width="${f(fs * 0.28)}">${esc(label)}</text>` +
            extra +
            `<title>${esc(title)}</title></g>`;
    }
    /** The hard goal as HTML, one line per conjunct, each a disjunction of its
     *  labelled literals; a literal true in STATE is highlighted in its package's
     *  color, as on the map, and a line is marked ✓ when one of its literals
     *  holds.  PROB, when given, adds each literal's probability (by label). */
    function goalHtml(p, state, prob) {
        if (p.goal.length === 0)
            return `<p class="empty">The problem has no hard goal.</p>`;
        const lines = p.goal.map((line, i) => {
            const lits = line.map((lit) => {
                const v = Viz.literalHolds(lit, state);
                const col = lit.args.length > 0 ? colorOf(p, lit.args[0]) : "inherit";
                const pr = prob === null || prob === void 0 ? void 0 : prob.get(lit.label);
                const num = pr === undefined ? "" : ` <span class="lit-p">${pr.toFixed(3)}</span>`;
                if (v === true) {
                    return `<span class="lit true" style="background:${col}" title="achieved"><b>${esc(lit.label)}</b> ${esc(lit.text)}${num}</span>`;
                }
                const cls = v === false ? "lit false" : "lit";
                return `<span class="${cls}"><b style="color:${col}">${esc(lit.label)}</b> ${esc(lit.text)}${num}</span>`;
            });
            const vals = line.map((lit) => Viz.literalHolds(lit, state));
            const sat = vals.some((v) => v === true);
            const mark = sat ? "✓" : vals.every((v) => v === false) ? "✗" : "?";
            return `<div class="goal-line ${sat ? "sat" : "unsat"}"><span class="mark">${mark}</span>` +
                `<span class="line-no">${p.goal.length > 1 ? i + 1 + "." : ""}</span>` +
                `<span class="disj">${lits.join(`<span class="or"> ∨ </span>`)}</span></div>`;
        });
        const conj = p.goal.length > 1 ? `<p class="hint">All lines must hold (∧); each line is a disjunction (∨).</p>` : "";
        return conj + lines.join("");
    }
    Viz.goalHtml = goalHtml;
    function renderMap(problem, state, opts = {}) {
        var _a, _b, _c, _d, _e, _f;
        const W = MARGIN * 2 + problem.cols * SPACING;
        const H = MARGIN * 2 + problem.rows * SPACING;
        const out = [];
        out.push(`<svg xmlns="http://www.w3.org/2000/svg" class="map" viewBox="0 0 ${W} ${H}" ` +
            `preserveAspectRatio="xMidYMid meet" role="img" aria-label="${esc(problem.name)}">`);
        out.push(`<defs>` +
            `<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">` +
            `<path d="M0,0 L10,5 L0,10 z" class="arrowhead"/></marker>` +
            `</defs>`);
        // roads
        out.push(`<g class="roads">`);
        for (const r of problem.roads) {
            const a = center(problem, r.a);
            const b = center(problem, r.b);
            // a road from a place to itself (or two places drawn in one cell) has no
            // line to draw
            if (!a || !b || (a.x === b.x && a.y === b.y))
                continue;
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const p = exitPoint(a.x, a.y, dx, dy, 2);
            const q = exitPoint(b.x, b.y, -dx, -dy, 2);
            const start = r.both ? ` marker-start="url(#arrow)"` : "";
            out.push(`<line class="road${r.both ? "" : " one-way"}" x1="${f(p.x)}" y1="${f(p.y)}" x2="${f(q.x)}" y2="${f(q.y)}"` +
                `${start} marker-end="url(#arrow)"><title>${esc(r.a)} ${r.both ? "↔" : "→"} ${esc(r.b)}</title></line>`);
        }
        out.push(`</g>`);
        // the moves about to be made, in their vehicle's color
        out.push(`<g class="moves">`);
        for (const a of (_a = opts.next) !== null && _a !== void 0 ? _a : []) {
            const vehicle = a.args.find((o) => problem.trucks.includes(o) || problem.airplanes.includes(o));
            const places = a.args.filter((o) => problem.layout.has(o));
            if (!vehicle || places.length < 2 || a.name.startsWith("load") || a.name.startsWith("unload"))
                continue;
            const from = center(problem, places[0]);
            const to = center(problem, places[1]);
            if (!from || !to || (from.x === to.x && from.y === to.y))
                continue;
            const p = exitPoint(from.x, from.y, to.x - from.x, to.y - from.y, 2);
            const q = exitPoint(to.x, to.y, from.x - to.x, from.y - to.y, 2);
            out.push(`<line class="move" stroke="${colorOf(problem, vehicle)}" x1="${f(p.x)}" y1="${f(p.y)}" ` +
                `x2="${f(q.x)}" y2="${f(q.y)}"><title>next: ${esc(a.text)}</title></line>`);
        }
        out.push(`</g>`);
        // observed actions: drives as arrows labelled with their slice; loads,
        // unloads and the rest as a tag on their place
        const tags = new Map();
        out.push(`<g class="observed">`);
        for (const { action: a, label } of (_b = opts.observed) !== null && _b !== void 0 ? _b : []) {
            const vehicle = a.args.find((o) => problem.trucks.includes(o) || problem.airplanes.includes(o));
            const places = a.args.filter((o) => problem.layout.has(o));
            const isMove = !!vehicle && places.length >= 2 && !a.name.startsWith("load") && !a.name.startsWith("unload");
            const from = isMove ? center(problem, places[0]) : undefined;
            const to = isMove ? center(problem, places[1]) : undefined;
            if (from && to && (from.x !== to.x || from.y !== to.y)) {
                // offset to the right of the direction of travel, so the two
                // directions of one road (a drive out and back) do not overlap
                const len = Math.hypot(to.x - from.x, to.y - from.y);
                const ox = (-(to.y - from.y) / len) * 6;
                const oy = ((to.x - from.x) / len) * 6;
                const p0 = exitPoint(from.x, from.y, to.x - from.x, to.y - from.y, 2);
                const q0 = exitPoint(to.x, to.y, from.x - to.x, from.y - to.y, 2);
                const p = { x: p0.x + ox, y: p0.y + oy };
                const q = { x: q0.x + ox, y: q0.y + oy };
                const col = colorOf(problem, vehicle);
                out.push(`<g class="obs-move"><line stroke="${col}" x1="${f(p.x)}" y1="${f(p.y)}" ` +
                    `x2="${f(q.x)}" y2="${f(q.y)}" marker-end="url(#arrow)"/>` +
                    `<circle cx="${f((p.x + q.x) / 2)}" cy="${f((p.y + q.y) / 2)}" r="7" fill="${col}"/>` +
                    `<text x="${f((p.x + q.x) / 2)}" y="${f((p.y + q.y) / 2)}" fill="#fff" font-size="8">${esc(label)}</text>` +
                    `<title>observed at ${esc(label)}: ${esc(a.text)}</title></g>`);
            }
            else if (places.length >= 1) {
                const verb = a.name.startsWith("unload") ? "U" : a.name.startsWith("load") ? "L" : a.name[0].toUpperCase();
                const l = (_c = tags.get(places[0])) !== null && _c !== void 0 ? _c : [];
                l.push(`${verb}${label}`);
                tags.set(places[0], l);
            }
        }
        out.push(`</g>`);
        // the tags go on top of the squares, after them
        const tagOut = [];
        for (const [place, ls] of tags) {
            const c = corner(problem, place);
            if (!c)
                continue;
            const text = ls.join(" ");
            const w = 6 + text.length * 5;
            tagOut.push(`<g class="obs-tag"><rect x="${f(c.x - 2)}" y="${f(c.y - 8)}" width="${f(w)}" height="11" rx="3"/>` +
                `<text x="${f(c.x - 2 + w / 2)}" y="${f(c.y - 2.5)}" font-size="8">${esc(text)}</text>` +
                `<title>observed: ${esc(text)} (L load, U unload, then the slice)</title></g>`);
        }
        // what is where
        const vehiclesAt = new Map();
        const packagesAt = new Map();
        const goalsAt = new Map();
        const push = (m, k, v) => {
            const l = m.get(k);
            if (l)
                l.push(v);
            else
                m.set(k, [v]);
        };
        for (const v of [...problem.trucks, ...problem.airplanes]) {
            const p = state.at.get(v);
            if (p)
                push(vehiclesAt, p, v);
        }
        for (const k of problem.packages) {
            const p = state.at.get(k);
            if (p && !state.inside.has(k))
                push(packagesAt, p, k);
        }
        for (const g of problem.goalLiterals) {
            if (g.pred === "at" && g.args.length === 2 && !g.negated && problem.layout.has(g.args[1])) {
                push(goalsAt, g.args[1], g);
            }
        }
        const cargo = new Map();
        for (const [k, v] of state.inside)
            push(cargo, v, k);
        out.push(`<g class="places">`);
        for (const p of problem.places) {
            const c = corner(problem, p);
            if (!c)
                continue;
            const airport = problem.airports.has(p);
            out.push(`<g class="place" data-place="${esc(p)}">`);
            out.push(`<rect class="square${airport ? " airport" : ""}" x="${f(c.x)}" y="${f(c.y)}" width="${SIDE}" height="${SIDE}">` +
                `<title>${esc(p)}${airport ? " (airport)" : ""}</title></rect>`);
            if (airport) {
                out.push(`<text class="airport-mark" x="${f(c.x + SIDE - 7)}" y="${f(c.y + 8)}">✈</text>`);
            }
            const goals = (_d = goalsAt.get(p)) !== null && _d !== void 0 ? _d : [];
            const pkgs = (_e = packagesAt.get(p)) !== null && _e !== void 0 ? _e : [];
            const vs = (_f = vehiclesAt.get(p)) !== null && _f !== void 0 ? _f : [];
            const inner = { x: c.x + PAD, y: c.y + PAD, w: SIDE - 2 * PAD, h: SIDE - 2 * PAD };
            const reg = regions(inner, goals.length > 0, pkgs.length > 0, vs.length > 0);
            if (reg.goals) {
                // goals are tiled, not stacked: each one's label (and probability)
                // stays readable however many share the place
                const s = tile(goals.length, reg.goals);
                const g = s.size * 0.86; // a goal box sits inside its slot, its dashes clear of the next
                goals.forEach((lit, k) => {
                    var _a;
                    const b = s.boxes[k];
                    const x = b.x + (s.size - g) / 2;
                    const y = b.y + (s.size - g) / 2;
                    const col = colorOf(problem, lit.args[0]);
                    const fs = Math.max(g * 0.36, 5);
                    const prob = (_a = opts.goalProb) === null || _a === void 0 ? void 0 : _a.get(lit.label);
                    if (prob !== undefined) {
                        // shaded by probability; the number under the label
                        const strong = prob >= 0.5;
                        out.push(`<g class="goal prob" data-box="${f(x)} ${f(y)} ${f(g)}" data-prob="${f(prob)}">` +
                            `<rect x="${f(x)}" y="${f(y)}" width="${f(g)}" height="${f(g)}" rx="${f(g * 0.12)}" stroke="${col}" ` +
                            `stroke-width="${f(Math.max(g * 0.06, 1))}" fill="${col}" fill-opacity="${f(0.08 + 0.92 * prob)}"/>` +
                            `<text x="${f(x + g / 2)}" y="${f(y + g * 0.38)}" fill="${strong ? "#fff" : col}" ` +
                            `font-size="${f(fs * 0.9)}">${esc(lit.label)}</text>` +
                            `<text class="pnum" x="${f(x + g / 2)}" y="${f(y + g * 0.72)}" fill="${strong ? "#fff" : col}" ` +
                            `font-size="${f(fs * 0.75)}">${prob.toFixed(2)}</text>` +
                            `<title>${esc(lit.label)}: ${esc(lit.text)} -- P = ${prob.toFixed(4)}</title></g>`);
                        return;
                    }
                    const done = Viz.literalHolds(lit, state) === true;
                    out.push(`<g class="goal${done ? " achieved" : ""}" data-box="${f(x)} ${f(y)} ${f(g)}">` +
                        `<rect x="${f(x)}" y="${f(y)}" width="${f(g)}" height="${f(g)}" rx="${f(g * 0.12)}" stroke="${col}" ` +
                        `stroke-width="${f(Math.max(g * 0.06, 1))}" fill="${done ? col : "var(--goal-fill)"}"/>` +
                        `<text x="${f(x + g / 2)}" y="${f(y + g / 2)}" fill="${done ? "#fff" : col}" ` +
                        `font-size="${f(fs)}">${esc(lit.label)}</text>` +
                        `<title>${esc(lit.label)}: ${esc(lit.text)}${done ? " (achieved)" : ""}</title></g>`);
                });
            }
            if (reg.packages) {
                const s = stack(pkgs.length, reg.packages);
                pkgs.forEach((k, i) => {
                    var _a;
                    const b = s.boxes[i];
                    out.push(icon("package", "package", b.x, b.y, s.size, colorOf(problem, k), (_a = problem.labels.get(k)) !== null && _a !== void 0 ? _a : k, `${k} at ${p}`));
                });
            }
            if (reg.vehicles) {
                const s = stack(vs.length, reg.vehicles);
                vs.forEach((v, i) => {
                    var _a, _b;
                    const b = s.boxes[i];
                    const load = (_a = cargo.get(v)) !== null && _a !== void 0 ? _a : [];
                    // cargo badges over the vehicle's top right, overlapping up and right
                    let badges = "";
                    if (load.length > 0) {
                        const bs = s.size * 0.42;
                        const step = bs * OFFSET * 1.5;
                        load.forEach((k, j) => {
                            var _a;
                            badges += icon("package", "package badge", b.x + s.size * 0.56 + j * step, b.y - bs * 0.05 - j * step, bs, colorOf(problem, k), (_a = problem.labels.get(k)) !== null && _a !== void 0 ? _a : k, `${k} in ${v}`);
                        });
                    }
                    const kind = problem.airplanes.includes(v) ? "airplane" : "truck";
                    out.push(icon(kind, "vehicle", b.x, b.y, s.size, colorOf(problem, v), (_b = problem.labels.get(v)) !== null && _b !== void 0 ? _b : v, `${v} at ${p}${load.length ? ", carrying " + load.join(", ") : ""}`, badges));
                });
            }
            out.push(`</g>`);
        }
        out.push(`</g>`);
        if (tagOut.length)
            out.push(`<g class="observed-tags">`, ...tagOut, `</g>`);
        out.push(`</svg>`);
        return out.join("\n");
    }
    Viz.renderMap = renderMap;
})(Viz || (Viz = {}));
// A column browser in a <dialog>, as the CLARA buttons of both pages use it
// (Finder's column view): each column lists the rows under the row chosen in
// the column to its left; a row of the last column is what Open loads.
//
// The dialog holds one ".clara-col ul" per column, a ".clara-cols" box that
// takes the keyboard focus (tabindex), a footer element (FOOTER), and the
// OPEN and CANCEL buttons.  Choosing a row fills the next column (a column of
// one row is chosen at once); Open, a double click or Enter on a last-column
// row loads it.  The arrow keys move within and between columns.
//
// A row marked MISSING is grayed but can still be opened (the plan page: a
// solver that left no plan opens the problem alone); one marked DISABLED is
// grayed and cannot be opened, nor anything under it (the circuit page: a
// circuit that failed to compile).
var Viz;
(function (Viz) {
    /** whether PATH reaches an openable row of the last column */
    function openable(path, ncols) {
        return path.length === ncols && path.every((r) => !r.disabled);
    }
    function columnBrowser(o) {
        const dialog = o.dialog;
        const cols = [...dialog.querySelectorAll(".clara-col ul")];
        const n = cols.length;
        const colsBox = dialog.querySelector(".clara-cols");
        let tree;
        const chosen = []; // chosen[c]: the chosen row of column c
        let active = 0; // the column the arrow keys move in
        /** the rows of column c, given the choices to its left */
        function rows(c) {
            var _a;
            let nodes = tree !== null && tree !== void 0 ? tree : [];
            for (let k = 0; k < c; k++) {
                const r = nodes[chosen[k]];
                if (!r)
                    return [];
                nodes = (_a = r.children) !== null && _a !== void 0 ? _a : [];
            }
            return nodes;
        }
        function path() {
            const out = [];
            for (let c = 0; c < n; c++) {
                const r = rows(c)[chosen[c]];
                if (!r)
                    break;
                out.push(r);
            }
            return out;
        }
        function render() {
            for (let c = 0; c < n; c++) {
                const r = rows(c);
                if (chosen[c] === undefined && r.length === 1)
                    chosen[c] = 0; // nothing to choose
            }
            cols.forEach((ul, c) => {
                ul.innerHTML = rows(c).map((r, k) => {
                    var _a;
                    const cls = [k === chosen[c] ? "chosen" : "", c === active && k === chosen[c] ? "active" : "",
                        r.missing || r.disabled ? "missing" : "", r.disabled ? "disabled" : ""].filter(Boolean).join(" ");
                    return `<li data-col="${c}" data-row="${k}" class="${cls}" title="${Viz.esc((_a = r.title) !== null && _a !== void 0 ? _a : r.label)}">` +
                        `${Viz.esc(r.label)}</li>`;
                }).join("");
                const cur = ul.querySelector("li.chosen");
                if (cur)
                    cur.scrollIntoView({ block: "nearest" });
            });
            const p = path();
            o.openButton.disabled = !openable(p, n);
            o.footer.textContent = o.describe(p);
            o.footer.title = o.footer.textContent;
        }
        function choose(c, k) {
            var _a;
            if (k < 0 || k >= rows(c).length)
                return;
            if (chosen[c] === k) {
                // the same row again: move the keyboard mark without rebuilding the
                // lists, so the row clicked stays in the page and a double click on it
                // reaches the dblclick listener
                active = c;
                dialog.querySelectorAll("li.active").forEach((li) => li.classList.remove("active"));
                (_a = cols[c].querySelector("li.chosen")) === null || _a === void 0 ? void 0 : _a.classList.add("active");
                return;
            }
            chosen.length = c; // a new choice clears the columns to its right
            chosen[c] = k;
            active = c;
            render();
        }
        function open() {
            const p = path();
            if (!openable(p, n))
                return;
            dialog.close();
            o.open(p);
        }
        dialog.addEventListener("click", (ev) => {
            // the backdrop: a click outside the dialog's box (its own padding is
            // inside, though the event's target is the dialog there too)
            const r = dialog.getBoundingClientRect();
            if (ev.target === dialog &&
                (ev.clientX < r.left || ev.clientX > r.right || ev.clientY < r.top || ev.clientY > r.bottom)) {
                dialog.close();
                return;
            }
            const li = ev.target.closest("li[data-col]");
            if (li) {
                choose(Number(li.dataset.col), Number(li.dataset.row));
                colsBox.focus(); // the columns take the keys: rows can't, and on Cancel Enter would cancel
            }
        });
        dialog.addEventListener("dblclick", (ev) => {
            const li = ev.target.closest("li[data-col]");
            if (li && Number(li.dataset.col) === n - 1)
                open();
        });
        dialog.addEventListener("keydown", (ev) => {
            var _a, _b;
            if (ev.target.tagName === "BUTTON" && ev.key === "Enter")
                return;
            const k = (_a = chosen[active]) !== null && _a !== void 0 ? _a : -1;
            if (ev.key === "ArrowDown")
                choose(active, k + 1);
            else if (ev.key === "ArrowUp")
                choose(active, Math.max(0, k - 1));
            else if (ev.key === "ArrowRight" && active < n - 1 && chosen[active] !== undefined) {
                choose(active + 1, (_b = chosen[active + 1]) !== null && _b !== void 0 ? _b : 0);
            }
            else if (ev.key === "ArrowLeft" && active > 0) {
                active--;
                render();
            }
            else if (ev.key === "Enter")
                open();
            else
                return;
            ev.preventDefault();
        });
        o.openButton.addEventListener("click", open);
        o.cancelButton.addEventListener("click", () => dialog.close());
        return {
            show() {
                if (!tree)
                    tree = o.tree();
                render();
                dialog.showModal();
                colsBox.focus();
            },
        };
    }
    Viz.columnBrowser = columnBrowser;
})(Viz || (Viz = {}));
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
var Viz;
(function (Viz) {
    const SOLVERS = { eval: "EvalMaxSAT - exact", tt: "tt-open-wbo - anytime" };
    /** a FiFO answer's (*OBJECTIVE* N), or undefined */
    function answerObjective(text) {
        const m = /\(\s*\*OBJECTIVE\*\s+(-?[0-9.]+(?:e-?[0-9]+)?)\s*\)/i.exec(text);
        return m ? Number(m[1]) : undefined;
    }
    Viz.answerObjective = answerObjective;
    /** "pkg1-p2-4-pkg2-p3-4" -> "pkg1 at p2-4, pkg2 at p3-4"; undefined if it is not that shape */
    function claraGoalLabel(suffix) {
        const parts = suffix.match(/[a-z]+\d+-p\d+-\d+/gi);
        if (!parts || parts.join("-") !== suffix)
            return undefined;
        return parts.map((p) => p.replace(/^([a-z]+\d+)-/i, "$1 at ")).join(", ");
    }
    Viz.claraGoalLabel = claraGoalLabel;
    function place(file) {
        var _a;
        const parts = file.split("/");
        const family = parts[0];
        const base = parts[parts.length - 1].replace(/\.pddl$/i, "");
        const sub = parts.slice(1, -1).join("/");
        const g = /^grid(\d+)x(\d+)-(\d+)(?:-(.+))?$/i.exec(base);
        if (g && (sub === "" || sub === "goals" || sub === "recognition")) {
            const goal = g[4] === undefined
                ? (sub === "recognition" ? "recognition problem" : "original problem")
                : ((_a = claraGoalLabel(g[4])) !== null && _a !== void 0 ? _a : g[4]);
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
    function solverLeaves(ex, i, goal, valueOf) {
        const stem = ex.problem.file.replace(/\.pddl$/i, "");
        const named = [];
        let chosen;
        ex.solutions.forEach((s, j) => {
            const rest = s.file.slice(stem.length);
            const m = /^-([a-z0-9]+)\.answer$/i.exec(rest);
            if (rest === ".answer")
                chosen = j;
            else if (m && SOLVERS[m[1]])
                named.push({ label: SOLVERS[m[1]], j, rank: m[1] === "eval" ? 0 : 1, solver: SOLVERS[m[1]] });
            else
                named.push({ label: s.file.split("/").pop(), j, rank: 2 });
        });
        if (chosen !== undefined) {
            // beside -eval/-tt plans (CLARA's goals/), <goal>.answer is a copy of one
            // of them (the one CLARA later cut its evidence files from -- no evidence
            // is in the plan): not listed again.  One that copies neither, or one
            // anywhere else, is just a solution, listed by its file name.
            const same = named.find((n) => n.rank < 2 && ex.solutions[n.j].text === ex.solutions[chosen].text);
            if (!same)
                named.push({ label: ex.solutions[chosen].file.split("/").pop(), j: chosen, rank: 2 });
        }
        const rows = named;
        if (goal) {
            for (const [key, label] of Object.entries(SOLVERS)) {
                if (!named.some((n) => n.solver === label))
                    rows.push({ label, rank: key === "eval" ? 0 : 1 });
            }
        }
        rows.sort((a, b) => a.rank - b.rank || a.label.localeCompare(b.label));
        return [...rows.map((n) => {
                if (n.j === undefined)
                    return { label: n.label, example: i, missing: true };
                const value = valueOf(i, i, n.j);
                // the solver's name, then the plan's value: "EvalMaxSAT - exact (−5)"
                const v = value === undefined ? "" : ` (${showValue(value)})`;
                const label = n.solver ? n.label.replace(n.solver, n.solver + v) : n.label + v;
                return { label, example: i, solution: n.j, solver: n.solver, value };
            }),
            { label: "no solution (problem only)", example: i }];
    }
    /** The domain the page prices problem P with when it comes with GIVEN (an
     *  example's bundled domain): GIVEN if it has P's name, else the library's of
     *  P's name, else GIVEN anyway -- the rule app.ts's adoptLibraryDomain
     *  applies to a problem loaded with its domain. */
    function pricingDomain(p, given, library) {
        var _a;
        if (given && given.name === p.domain)
            return given;
        return (_a = library.get(p.domain)) !== null && _a !== void 0 ? _a : given;
    }
    Viz.pricingDomain = pricingDomain;
    /** whether every line of P's hard goal has a literal that holds in STATE */
    function hardGoalHolds(p, state) {
        return p.goal.every((line) => line.some((lit) => Viz.literalHolds(lit, state) === true));
    }
    Viz.hardGoalHolds = hardGoalHolds;
    /** a plan's value as the main page's Total shows it at the plan's end, with
     *  pseudo goal utility off: the achieved preference weights minus the cost
     *  -- the same utilityAt the page uses, priced with the domain the page will
     *  use (pricingDomain, LIBRARY being FiFO's pddl/), against the problem the
     *  plan is shown WITH (for a borrowed plan, the original problem's
     *  utilities, not the goal problem's).  Undefined when the plan does not
     *  parse, when the problem has neither costs nor goal utilities (no value to
     *  rank by), or for a borrowed plan that does not achieve the original
     *  problem's hard goal.  Parsed on demand. */
    function planValuer(examples, library = []) {
        const problems = new Map();
        const domains = new Map();
        const lib = new Map();
        for (const d of library) {
            try {
                lib.set(d.name, Viz.parseDomain(d.text));
            }
            catch { /* a broken library domain prices nothing */ }
        }
        const problemOf = (i) => {
            var _a;
            if (!problems.has(i)) {
                try {
                    problems.set(i, Viz.parseProblem(examples[i].problem.text));
                }
                catch {
                    problems.set(i, null);
                }
            }
            return (_a = problems.get(i)) !== null && _a !== void 0 ? _a : undefined;
        };
        const givenDomain = (i) => {
            const d = examples[i].domain;
            if (!d)
                return undefined;
            if (!domains.has(d.file)) {
                try {
                    domains.set(d.file, Viz.parseDomain(d.text));
                }
                catch {
                    domains.set(d.file, undefined);
                }
            }
            return domains.get(d.file);
        };
        return (problem, from, solution) => {
            const p = problemOf(problem);
            if (!p)
                return undefined;
            try {
                const plan = Viz.parsePlan(examples[from].solutions[solution].text, p);
                const end = plan.steps.length;
                if (from !== problem && !hardGoalHolds(p, plan.states[end]))
                    return undefined;
                const u = Viz.utilityAt(p, pricingDomain(p, givenDomain(problem), lib), plan, end);
                return u.goals === undefined && u.costs === undefined ? undefined : u.total;
            }
            catch {
                return undefined;
            }
        };
    }
    Viz.planValuer = planValuer;
    /** a number as the page shows it: "−5", "3", "2.5" (rounded to 1/1000) */
    function showValue(v) {
        const r = Math.round(v * 1000) / 1000;
        return r < 0 ? "−" + Math.abs(r) : String(r);
    }
    Viz.showValue = showValue;
    /** the original problem's row when it has no plan of its own: the goal plan
     *  of highest value for the ORIGINAL problem (GOALS: label -> rows) -- the
     *  lowest-cost one when it weights no goals -- the exact solver's on a tie,
     *  then the first goal's; undefined when no goal plan has a value */
    function bestGoalPlan(orig, goals, valueOf) {
        let best;
        const order = [...goals.keys()].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
        for (const g of order) {
            const e = goals.get(g);
            if (e.rank !== 2)
                continue;
            for (const l of e.leaves) {
                if (l.solution === undefined || l.solver === undefined)
                    continue;
                const v = valueOf(orig, l.example, l.solution);
                if (v === undefined)
                    continue;
                if (!best || v > best.v || (v === best.v && l.solver === SOLVERS.eval && best.l.solver !== SOLVERS.eval)) {
                    best = { l, goal: g, v };
                }
            }
        }
        if (!best)
            return undefined;
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
    function objectiveValuer(examples) {
        return (_problem, from, solution) => {
            const o = answerObjective(examples[from].solutions[solution].text);
            return o === undefined ? undefined : -o;
        };
    }
    Viz.objectiveValuer = objectiveValuer;
    function cmpKey(a, b) {
        var _a, _b;
        for (let k = 0; k < Math.max(a.length, b.length); k++) {
            const d = ((_a = a[k]) !== null && _a !== void 0 ? _a : -1) - ((_b = b[k]) !== null && _b !== void 0 ? _b : -1);
            if (d !== 0)
                return d;
        }
        return 0;
    }
    /** the catalogue as a tree: families, then sizes, instances, goals; each goal
     *  node's leaves are the Solver column.  VALUEOF values the plans: the page
     *  passes planValuer (required, so no caller gets a stand-in by default). */
    function claraTree(examples, valueOf) {
        const families = new Map();
        examples.forEach((ex, i) => {
            const p = place(ex.problem.file);
            if (!families.has(p.family))
                families.set(p.family, new Map());
            const sizes = families.get(p.family);
            if (!sizes.has(p.size))
                sizes.set(p.size, { key: p.sizeKey, inst: new Map() });
            const insts = sizes.get(p.size).inst;
            if (!insts.has(p.instance))
                insts.set(p.instance, new Map());
            const goals = insts.get(p.instance);
            // two problems with one goal label (should not happen) stay apart
            let label = p.goal;
            for (let n = 2; goals.has(label); n++)
                label = `${p.goal} (${n})`;
            goals.set(label, { rank: p.goalRank, leaves: solverLeaves(ex, i, p.goalRank === 2, valueOf) });
        });
        // an original problem with no plan of its own borrows its best goal plan
        // (highest value for the original problem; the cheapest when it weights no goal)
        for (const sizes of families.values())
            for (const { inst } of sizes.values())
                for (const goals of inst.values()) {
                    const orig = goals.get("original problem");
                    if (!orig || orig.rank !== 0 || orig.leaves.some((l) => l.solution !== undefined))
                        continue;
                    const best = bestGoalPlan(orig.leaves[0].example, goals, valueOf);
                    if (best)
                        orig.leaves.unshift(best);
                }
        const byName = (a, b) => a.localeCompare(b, undefined, { numeric: true });
        return [...families.keys()].sort(byName).map((fam) => {
            const sizes = families.get(fam);
            return {
                label: fam,
                children: [...sizes.keys()].sort((a, b) => cmpKey(sizes.get(a).key, sizes.get(b).key) || byName(a, b)).map((sz) => {
                    const insts = sizes.get(sz).inst;
                    return {
                        label: sz,
                        children: [...insts.keys()].sort(byName).map((k) => {
                            const goals = insts.get(k);
                            return {
                                label: k,
                                children: [...goals.keys()].sort((a, b) => goals.get(a).rank - goals.get(b).rank || byName(a, b))
                                    .map((gl) => {
                                    const leaves = goals.get(gl).leaves;
                                    return { label: gl, children: [], leaves, missing: leaves.every((l) => l.solution === undefined) };
                                }),
                            };
                        }),
                    };
                }),
            };
        });
    }
    Viz.claraTree = claraTree;
})(Viz || (Viz = {}));
// The page: choose a problem and optionally a domain and a solution, draw the
// map, show the goal formula, the running utility and the solution, and step
// through the solution.
var Viz;
(function (Viz) {
    const app = { step: 0, errors: [] };
    function $(id) {
        const e = document.getElementById(id);
        if (!e)
            throw new Error(`missing element #${id}`);
        return e;
    }
    function currentState() {
        if (!app.problem)
            return undefined;
        if (app.plan)
            return app.plan.states[app.step];
        return { at: new Map(app.problem.initAt), inside: new Map(app.problem.initIn) };
    }
    function domainWarnings() {
        const p = app.problem;
        const d = app.domain;
        if (!p || !d || !p.domain || p.domain === d.name)
            return [];
        return [`the domain file ${app.domainFile} is "${d.name}", but the problem names "${p.domain}"`];
    }
    function showMessages() {
        var _a, _b, _c, _d;
        const msgs = [...((_b = (_a = app.problem) === null || _a === void 0 ? void 0 : _a.warnings) !== null && _b !== void 0 ? _b : []), ...domainWarnings(), ...((_d = (_c = app.plan) === null || _c === void 0 ? void 0 : _c.warnings) !== null && _d !== void 0 ? _d : [])];
        const box = $("messages");
        const err = app.errors.map((e) => `<div class="error">✖ ${Viz.esc(e)}</div>`).join("");
        box.hidden = msgs.length === 0 && !err;
        box.innerHTML = err + msgs.slice(0, 20).map((m) => `<div>⚠ ${Viz.esc(m)}</div>`).join("") +
            (msgs.length > 20 ? `<div>… and ${msgs.length - 20} more</div>` : "");
    }
    function renderGoals(state) {
        $("goals").innerHTML = Viz.goalHtml(app.problem, state);
    }
    function num(x) {
        return x === undefined ? "–" : Viz.showValue(x); // one format for the page and the CLARA browser
    }
    function renderUtility() {
        const p = app.problem;
        const pseudoBox = $("pseudo-goals");
        const u = Viz.utilityAt(p, app.domain, app.plan, app.step, pseudoBox.checked ? PSEUDO_GOAL_UTILITY : undefined);
        const goalsNote = u.goals === undefined
            ? "the problem gives its goals no utility"
            : u.pseudo
                ? `pseudo: ${PSEUDO_GOAL_UTILITY} per goal achieved, for display only` +
                    (u.undecided ? `; ${u.undecided} not tracked` : "")
                : `${p.preferences.length} weighted preference${p.preferences.length === 1 ? "" : "s"}` +
                    (u.undecided ? `; ${u.undecided} not tracked` : "");
        const costsNote = u.costs === undefined
            ? "the problem has no action costs"
            : !app.plan
                ? "no solution loaded"
                : u.costsExact ? `from the domain${app.domainFile ? " " + app.domainFile : ""}`
                    : app.domain ? "some costs unknown or conditional (not counted)"
                        : "estimated: load the domain for exact costs";
        $("utility").innerHTML =
            // no captions under the numbers: what each one means is its tooltip
            `<div class="u-item${u.pseudo ? " pseudo" : ""}" title="${Viz.esc(goalsNote)}">` +
                `<span class="u-label">Goals${u.pseudo ? " (pseudo)" : ""}</span>` +
                `<span class="u-value">${num(u.goals)}</span></div>` +
                `<div class="u-item" title="${Viz.esc(costsNote)}"><span class="u-label">Costs</span>` +
                `<span class="u-value${u.costs !== undefined && !u.costsExact ? " estimated" : ""}">${num(u.costs === undefined ? undefined : -u.costs)}</span></div>` +
                `<div class="u-item total${u.pseudo ? " pseudo" : ""}" title="Goals + Costs${u.pseudo ? ", with pseudo goal utility" : ""}">` +
                `<span class="u-label">Total</span><span class="u-value">${num(u.total)}</span></div>`;
    }
    /** what the "Pseudo Goal Utility" box gives each achieved goal of a problem
     *  that weights none */
    const PSEUDO_GOAL_UTILITY = 20;
    function renderSolution() {
        const box = $("solution");
        const plan = app.plan;
        const controls = $("controls");
        if (!plan) {
            box.innerHTML = `<p class="empty">No solution loaded.</p>`;
            controls.hidden = true;
            return;
        }
        controls.hidden = false;
        const rows = plan.steps.map((acts, k) => {
            const cls = k < app.step ? "done" : k === app.step ? "current" : "todo";
            const items = acts.length === 0
                ? `<span class="noop">(no action)</span>`
                : acts.map((a) => `<span class="act">${Viz.esc(a.text)}</span>`).join("");
            return `<li class="${cls}" data-step="${k}"><span class="t">${k + plan.firstStep}</span>${items}</li>`;
        });
        rows.push(`<li class="${app.step === plan.steps.length ? "current" : "todo"}" data-step="${plan.steps.length}">` +
            `<span class="t">${plan.steps.length + plan.firstStep}</span><span class="noop">end</span></li>`);
        box.innerHTML = `<ol>${rows.join("")}</ol>`;
        const cur = box.querySelector("li.current");
        if (cur)
            cur.scrollIntoView({ block: "nearest" });
        $("step-label").textContent = `Step ${app.step} of ${plan.steps.length} · time ${app.step + plan.firstStep}`;
        $("prev").disabled = app.step === 0;
        $("first").disabled = app.step === 0;
        $("next").disabled = app.step >= plan.steps.length;
        $("last").disabled = app.step >= plan.steps.length;
    }
    function redraw() {
        var _a, _b;
        showMessages();
        const p = app.problem;
        if (!p)
            return;
        const state = currentState();
        const next = (_b = (_a = app.plan) === null || _a === void 0 ? void 0 : _a.steps[app.step]) !== null && _b !== void 0 ? _b : [];
        $("map").innerHTML = Viz.renderMap(p, state, { next });
        renderGoals(state);
        renderUtility();
        renderSolution();
        const counts = `${p.rows}×${p.cols} grid · ${p.trucks.length} truck${p.trucks.length === 1 ? "" : "s"}` +
            (p.airplanes.length ? ` · ${p.airplanes.length} airplane${p.airplanes.length === 1 ? "" : "s"}` : "") +
            ` · ${p.packages.length} package${p.packages.length === 1 ? "" : "s"}`;
        const dom = app.domain ? ` · domain ${app.domainFile}` : "";
        // the plan's value: the Total at its last step, pseudo goal utility off --
        // not FiFO's *OBJECTIVE*, which is minimized (the cost plus the weights of
        // unachieved preferences) and so is minus the value only when no goal is
        // weighted.  ≈ when some cost was estimated or a preference not tracked;
        // none when the problem has neither costs nor goal utilities.
        let sol = "";
        if (app.plan) {
            const end = Viz.utilityAt(p, app.domain, app.plan, app.plan.steps.length);
            const known = end.goals !== undefined || end.costs !== undefined;
            const approx = (end.costs !== undefined && !end.costsExact) || end.undecided > 0;
            sol = ` · solution ${app.planFile}` + (known ? ` (value ${approx ? "≈" : ""}${num(end.total)})` : "");
        }
        $("summary").textContent = `${p.name} · ${counts}${dom}${sol}`;
    }
    function go(step) {
        if (!app.plan)
            return;
        app.step = Math.max(0, Math.min(app.plan.steps.length, step));
        redraw();
    }
    function fail(where, e) {
        app.errors.push(`${where}: ${e instanceof Error ? e.message : String(e)}`);
        showMessages();
    }
    /** a problem loaded without the domain it names gets the library's, as FiFO
     *  falls back to its pddl/.  Kept instead:
     *   - ANY domain the user chose or dropped (even one of another name, which is
     *     then warned about, or one that failed to parse): never replaced behind
     *     their back;
     *   - the domain loaded WITH the problem (an example's, or load()'s caller's)
     *     or the library's own, when it has the problem's name.
     *  A domain left over from an earlier example gives way when the user then
     *  loads a problem (MANUAL): examples/ has its own copies of some library
     *  domains, older ones, and their costs would be silently wrong. */
    function adoptLibraryDomain(problem, manual) {
        var _a;
        if (!problem.domain || app.domainSource === "user" || typeof VIZ_DOMAINS === "undefined")
            return;
        if (((_a = app.domain) === null || _a === void 0 ? void 0 : _a.name) === problem.domain && (app.domainSource === "library" || !manual))
            return;
        const lib = VIZ_DOMAINS.find((d) => d.name === problem.domain);
        if (!lib)
            return;
        try {
            app.domain = Viz.parseDomain(lib.text);
            app.domainFile = `${lib.file} (FiFO's library)`;
            app.domainSource = "library";
            $("domain-file").value = "";
        }
        catch (e) {
            fail(lib.file, e);
        }
    }
    /** MANUAL: the user chose or dropped this problem (see adoptLibraryDomain) */
    function loadProblem(name, text, manual = false) {
        try {
            const problem = Viz.parseProblem(text);
            adoptLibraryDomain(problem, manual);
            app.problem = problem;
            app.problemFile = name;
            app.plan = undefined;
            app.planFile = undefined;
            app.step = 0;
            $("solution-file").value = "";
            redraw();
            return true;
        }
        catch (e) {
            fail(name, e);
            return false;
        }
    }
    /** SOURCE: "user" when chosen or dropped, "given" when it comes with the
     *  problem (an example, or load()'s caller) -- see adoptLibraryDomain */
    function loadDomain(name, text, source = "given") {
        app.domainSource = source;
        try {
            app.domain = Viz.parseDomain(text);
            app.domainFile = name;
            redraw();
        }
        catch (e) {
            // drop the old domain too: costs from a domain the user just replaced
            // would be silently wrong; without one they are marked estimated
            app.domain = undefined;
            app.domainFile = undefined;
            fail(name, e);
            redraw();
        }
    }
    function loadPlan(name, text) {
        if (!app.problem) {
            fail(name, new Error("choose a problem file first"));
            return;
        }
        try {
            app.plan = Viz.parsePlan(text, app.problem);
            app.planFile = name;
            app.step = 0;
            redraw();
        }
        catch (e) {
            fail(name, e);
        }
    }
    /** Show a problem (and a solution, at STEP; and a domain, for costs) given as
     *  text: for a page that gets its files some other way than the file
     *  choosers, e.g. from a server. */
    function load(problemName, problemText, planName, planText, step = 0, domainName, domainText) {
        app.errors = [];
        if (domainName !== undefined && domainText !== undefined)
            loadDomain(domainName, domainText);
        if (!loadProblem(problemName, problemText))
            return;
        if (planName !== undefined && planText !== undefined) {
            loadPlan(planName, planText);
            go(step);
        }
    }
    Viz.load = load;
    function readText(file) {
        return new Promise((resolve, reject) => {
            const r = new FileReader();
            r.onload = () => resolve({ name: file.name, text: String(r.result) });
            r.onerror = () => reject(r.error);
            r.readAsText(file);
        });
    }
    function readInto(input, then) {
        var _a;
        const file = (_a = input.files) === null || _a === void 0 ? void 0 : _a[0];
        if (!file)
            return;
        app.errors = [];
        readText(file).then((f) => then(f.name, f.text), (e) => fail(file.name, e));
    }
    /** load example EX with its solution J (none if undefined) -- or solution J
     *  of example FROM, for a plan borrowed from another problem -- clearing the
     *  file choosers and any domain loaded before */
    function loadExample(ex, j, from = ex) {
        var _a, _b;
        const s = j === undefined ? undefined : from.solutions[j];
        for (const id of ["problem-file", "domain-file", "solution-file"])
            $(id).value = "";
        app.domain = undefined;
        app.domainSource = undefined;
        app.domainFile = undefined;
        load(ex.problem.file, ex.problem.text, s === null || s === void 0 ? void 0 : s.file, s === null || s === void 0 ? void 0 : s.text, 0, (_a = ex.domain) === null || _a === void 0 ? void 0 : _a.file, (_b = ex.domain) === null || _b === void 0 ? void 0 : _b.text);
    }
    /** The CLARA button: a column browser (columns.ts), Family / Size /
     *  Instance / Goal / Solver; a Solver row loads its problem and plan. */
    function initClara() {
        const button = $("clara-button");
        const list = typeof VIZ_CLARA_EXAMPLES === "undefined" ? [] : VIZ_CLARA_EXAMPLES;
        if (list.length === 0) {
            button.hidden = true;
            return;
        }
        /** claraTree's nodes as the browser's rows: a goal's leaves are its
         *  Solver column */
        const toRows = (ns) => ns.map((nd) => ({
            label: nd.label, missing: nd.missing,
            children: nd.leaves
                ? nd.leaves.map((l) => ({ label: l.label, missing: l.missing, data: l,
                    title: l.label + (l.missing ? " (no solution file)" : "") }))
                : toRows(nd.children),
        }));
        const browser = Viz.columnBrowser({
            dialog: $("clara-dialog"),
            footer: $("clara-path"),
            openButton: $("clara-open"),
            cancelButton: $("clara-cancel"),
            // built on the first click, not at page load: valuing every plan parses
            // them all (about half a second for the whole of CLARA)
            tree: () => toRows(Viz.claraTree(list, Viz.planValuer(list, typeof VIZ_DOMAINS === "undefined" ? [] : VIZ_DOMAINS))),
            describe: (path) => {
                var _a, _b;
                const l = (_a = path[4]) === null || _a === void 0 ? void 0 : _a.data;
                if (!l)
                    return "Choose a family, size, instance, goal and solver.";
                return list[l.example].problem.file + (l.solution !== undefined
                    ? "  +  " + list[(_b = l.from) !== null && _b !== void 0 ? _b : l.example].solutions[l.solution].file.split("/").pop()
                    : l.missing ? `  (no ${l.label} plan: the problem alone)` : "") +
                    (l.note ? `  -- ${l.note}` : "");
            },
            open: (path) => {
                var _a;
                const l = path[4].data;
                loadExample(list[l.example], l.solution, list[(_a = l.from) !== null && _a !== void 0 ? _a : l.example]);
            },
        });
        button.addEventListener("click", () => browser.show());
    }
    function initExamples() {
        const sel = $("examples");
        const list = typeof VIZ_EXAMPLES === "undefined" ? [] : VIZ_EXAMPLES;
        if (list.length === 0) {
            sel.parentElement.hidden = true;
            return;
        }
        list.forEach((ex, i) => {
            const group = document.createElement("optgroup");
            group.label = ex.problem.file;
            const only = document.createElement("option");
            only.value = `${i}`;
            only.textContent = `${ex.problem.file} (no solution)`;
            group.appendChild(only);
            ex.solutions.forEach((s, j) => {
                const o = document.createElement("option");
                o.value = `${i}:${j}`;
                o.textContent = `${ex.problem.file} + ${s.file}`;
                group.appendChild(o);
            });
            sel.appendChild(group);
        });
        sel.addEventListener("change", () => {
            if (!sel.value)
                return;
            const [i, j] = sel.value.split(":").map(Number);
            loadExample(list[i], j);
            sel.value = "";
            sel.blur();
        });
    }
    function init() {
        initExamples();
        initClara();
        const pf = $("problem-file");
        const df = $("domain-file");
        const sf = $("solution-file");
        pf.addEventListener("change", () => readInto(pf, (n, t) => loadProblem(n, t, true)));
        df.addEventListener("change", () => readInto(df, (n, t) => loadDomain(n, t, "user")));
        sf.addEventListener("change", () => readInto(sf, loadPlan));
        const pseudo = $("pseudo-goals");
        pseudo.parentElement.title =
            `When the problem gives its goals no utility, count ${PSEUDO_GOAL_UTILITY} for each goal achieved. ` +
                `For display only: it is not the problem's utility.`;
        pseudo.addEventListener("change", () => {
            pseudo.blur(); // give the arrow keys back to stepping through the plan
            if (app.problem)
                renderUtility();
        });
        $("first").addEventListener("click", () => go(0));
        $("prev").addEventListener("click", () => go(app.step - 1));
        $("next").addEventListener("click", () => go(app.step + 1));
        $("last").addEventListener("click", () => go(Infinity));
        $("solution").addEventListener("click", (ev) => {
            const li = ev.target.closest("li[data-step]");
            if (li)
                go(Number(li.dataset.step));
        });
        document.addEventListener("keydown", (ev) => {
            const tag = ev.target.tagName;
            if (tag === "INPUT" || tag === "SELECT")
                return;
            if (document.querySelector("dialog[open]"))
                return; // the CLARA browser has the keys
            // leave browser shortcuts (Cmd/Alt+arrows navigate) and, with nothing to
            // step through, ordinary scrolling alone
            if (!app.plan || ev.metaKey || ev.ctrlKey || ev.altKey)
                return;
            if (ev.key === "ArrowRight")
                go(app.step + 1);
            else if (ev.key === "ArrowLeft")
                go(app.step - 1);
            else if (ev.key === "Home")
                go(0);
            else if (ev.key === "End")
                go(Infinity);
            else
                return;
            ev.preventDefault();
        });
        // drop files anywhere: a PDDL domain, a PDDL problem, and anything else is
        // the solution -- told apart by content, then loaded in that order
        document.addEventListener("dragover", (ev) => ev.preventDefault());
        document.addEventListener("drop", (ev) => {
            var _a, _b;
            ev.preventDefault();
            const files = [...((_b = (_a = ev.dataTransfer) === null || _a === void 0 ? void 0 : _a.files) !== null && _b !== void 0 ? _b : [])];
            app.errors = [];
            Promise.all(files.map(readText)).then((texts) => {
                const isPddl = (t) => /\.pddl$/i.test(t.name) || /\(\s*define\s*\(/i.test(t.text);
                const dom = texts.find((t) => isPddl(t) && Viz.isDomainText(t.text));
                const prob = texts.find((t) => isPddl(t) && t !== dom);
                const sol = texts.find((t) => t !== dom && t !== prob);
                if (dom)
                    loadDomain(dom.name, dom.text, "user");
                if (prob && !loadProblem(prob.name, prob.text, true))
                    return;
                if (sol)
                    loadPlan(sol.name, sol.text);
            }, (e) => fail("dropped files", e));
        });
    }
    if (typeof document !== "undefined") {
        if (document.readyState === "loading")
            document.addEventListener("DOMContentLoaded", init);
        else
            init();
    }
})(Viz || (Viz = {}));
