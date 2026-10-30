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
    function goalLines(goal, warnings) {
        if (goal === undefined)
            return [];
        const conjuncts = [];
        (function flatten(g) {
            if (Viz.isList(g) && g[0] === "and")
                g.slice(1).forEach(flatten);
            else if (Viz.isList(g) && g[0] === "preference")
                return;
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
        for (const f of ((_c = section(def, ":init")) !== null && _c !== void 0 ? _c : []).slice(1)) {
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
        const goal = goalLines(goalForm === null || goalForm === void 0 ? void 0 : goalForm[1], warnings).map((line) => line.map((x) => {
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
            initAt, initIn, goal, goalLiterals, layout, rows, cols, warnings,
        };
    }
    Viz.parseProblem = parseProblem;
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
            if (head === "holds" && Viz.isList(f[1]) && f.length === 3) {
                const fl = f[1];
                const t = Number(f[2]);
                if (fl.length === 3 && !Viz.isList(fl[1]) && !Viz.isList(fl[2])) {
                    if (fl[0] === "at")
                        holdsAt(t).at.set(fl[1], fl[2]);
                    else if (fl[0] === "in")
                        holdsAt(t).inside.set(fl[1], fl[2]);
                    else
                        holdsAt(t);
                }
                else {
                    holdsAt(t);
                }
            }
            else if (head === "occurs" && Viz.isList(f[1]) && f.length === 3) {
                sawOccurs = true;
                items.push({ action: toAction(f[1]), time: Number(f[2]) });
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
// trucks, packages and goal destinations.
//
// Inside a place's square each kind has its own corner so none hides another:
// goals top left, packages top right, vehicles along the bottom.  Several of one
// kind in one place overlap, each further one offset up and to the right so its
// edge shows.  A package in a vehicle is a badge on that vehicle.  The SVG has a
// viewBox and no fixed size, so it scales with its container.
var Viz;
(function (Viz) {
    const TRUCK_COLORS = ["#2563eb", "#dc2626", "#16a34a", "#9333ea", "#0891b2", "#ca8a04", "#db2777", "#475569"];
    const PACKAGE_COLORS = ["#ea580c", "#0d9488", "#c026d3", "#65a30d", "#4f46e5", "#e11d48", "#0284c7", "#a16207",
        "#7c3aed", "#059669", "#be123c", "#1d4ed8"];
    const SPACING = 100; // grid pitch, in SVG units
    const SIDE = 64; // a place's square
    const MARGIN = 24;
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
    function esc(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }
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
    /** N boxes of width W x H stacked in REGION, each further one offset up and
     *  right by D, the stack kept inside the region (shrinking the boxes if it
     *  has to).  Returns each box's top-left corner and the size used. */
    function stack(n, region, w, h, d) {
        const scale = Math.min(1, (region.w - (n - 1) * d) / w, (region.h - (n - 1) * d) / h);
        const bw = w * Math.max(scale, 0.4);
        const bh = h * Math.max(scale, 0.4);
        const boxes = [];
        for (let k = 0; k < n; k++) {
            boxes.push({ x: region.x + k * d, y: region.y + region.h - bh - k * d });
        }
        return { boxes, w: bw, h: bh };
    }
    function renderMap(problem, state, opts = {}) {
        var _a, _b, _c, _d;
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
            if (!a || !b)
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
                out.push(`<text class="airport-mark" x="${f(c.x + SIDE / 2)}" y="${f(c.y + 9)}">✈</text>`);
            }
            const pad = 3;
            const half = SIDE / 2;
            // goals: top-left quarter
            const goals = (_b = goalsAt.get(p)) !== null && _b !== void 0 ? _b : [];
            if (goals.length > 0) {
                const s = stack(goals.length, { x: c.x + pad, y: c.y + pad, w: half - pad - 1, h: half - pad - 1 }, 22, 22, 4);
                goals.forEach((g, k) => {
                    const b = s.boxes[k];
                    const done = Viz.literalHolds(g, state) === true;
                    const col = colorOf(problem, g.args[0]);
                    out.push(`<g class="goal${done ? " achieved" : ""}">` +
                        `<rect x="${f(b.x)}" y="${f(b.y)}" width="${f(s.w)}" height="${f(s.h)}" rx="2" stroke="${col}" ` +
                        `fill="${done ? col : "var(--goal-fill)"}"/>` +
                        `<text x="${f(b.x + s.w / 2)}" y="${f(b.y + s.h / 2)}" fill="${done ? "#fff" : col}" ` +
                        `font-size="${f(s.h * 0.5)}">${esc(g.label)}</text>` +
                        `<title>${esc(g.label)}: ${esc(g.text)}${done ? " (achieved)" : ""}</title></g>`);
                });
            }
            // packages on the ground: top-right quarter
            const pkgs = (_c = packagesAt.get(p)) !== null && _c !== void 0 ? _c : [];
            if (pkgs.length > 0) {
                const s = stack(pkgs.length, { x: c.x + half + 1, y: c.y + pad, w: half - pad - 1, h: half - pad - 1 }, 22, 22, 4);
                pkgs.forEach((k, i) => {
                    const b = s.boxes[i];
                    out.push(packageBox(problem, k, b.x, b.y, s.w, s.h, `${k} at ${p}`));
                });
            }
            // vehicles: the bottom half, each with its cargo as badges
            const vs = (_d = vehiclesAt.get(p)) !== null && _d !== void 0 ? _d : [];
            if (vs.length > 0) {
                const s = stack(vs.length, { x: c.x + pad, y: c.y + half + 1, w: SIDE - 2 * pad, h: half - pad - 1 }, 56, 24, 5);
                vs.forEach((v, i) => {
                    var _a, _b;
                    const b = s.boxes[i];
                    const col = colorOf(problem, v);
                    const label = (_a = problem.labels.get(v)) !== null && _a !== void 0 ? _a : v;
                    const load = (_b = cargo.get(v)) !== null && _b !== void 0 ? _b : [];
                    const plane = problem.airplanes.includes(v);
                    const labelW = s.w * 0.4;
                    out.push(`<g class="vehicle">` +
                        `<rect x="${f(b.x)}" y="${f(b.y)}" width="${f(s.w)}" height="${f(s.h)}" rx="${plane ? f(s.h / 2) : 3}" fill="${col}"/>` +
                        `<text x="${f(b.x + labelW / 2 + 1)}" y="${f(b.y + s.h / 2)}" fill="#fff" font-size="${f(s.h * 0.5)}">${esc(label)}</text>` +
                        `<title>${esc(v)} at ${esc(p)}${load.length ? ", carrying " + load.map(esc).join(", ") : ""}</title></g>`);
                    // cargo: badges in a row right of the label, inside the vehicle; when
                    // they do not fit they overlap, each further one up and to the right
                    const room = s.w - labelW - 3;
                    const bs = Math.min(s.h - 4, 15);
                    const step = load.length > 1 ? Math.min(bs + 1, (room - bs) / (load.length - 1)) : 0;
                    const lift = step < bs ? Math.min(2, (s.h - bs) / 2) : 0;
                    load.forEach((k, j) => {
                        const bx = b.x + labelW + 1 + j * step;
                        const by = b.y + (s.h - bs) / 2 - j * lift;
                        out.push(packageBox(problem, k, bx, by, bs, bs, `${k} in ${v}`, "badge"));
                    });
                });
            }
            out.push(`</g>`);
        }
        out.push(`</g>`);
        out.push(`</svg>`);
        return out.join("\n");
    }
    Viz.renderMap = renderMap;
    function packageBox(problem, k, x, y, w, h, title, extra = "") {
        var _a;
        const col = colorOf(problem, k);
        const label = (_a = problem.labels.get(k)) !== null && _a !== void 0 ? _a : k;
        return `<g class="package${extra ? " " + extra : ""}">` +
            `<rect x="${f(x)}" y="${f(y)}" width="${f(w)}" height="${f(h)}" rx="2" fill="${col}"/>` +
            `<text x="${f(x + w / 2)}" y="${f(y + h / 2)}" fill="#fff" font-size="${f(h * 0.5)}">${esc(label)}</text>` +
            `<title>${esc(title)}</title></g>`;
    }
})(Viz || (Viz = {}));
// The page: choose a problem and optionally a solution, draw the map, list the
// goal formula and the solution, and step through the solution.
var Viz;
(function (Viz) {
    const app = { step: 0 };
    function $(id) {
        const e = document.getElementById(id);
        if (!e)
            throw new Error(`missing element #${id}`);
        return e;
    }
    function esc(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function currentState() {
        if (!app.problem)
            return undefined;
        if (app.plan)
            return app.plan.states[app.step];
        return { at: new Map(app.problem.initAt), inside: new Map(app.problem.initIn) };
    }
    function showMessages() {
        var _a, _b, _c, _d;
        const msgs = [...((_b = (_a = app.problem) === null || _a === void 0 ? void 0 : _a.warnings) !== null && _b !== void 0 ? _b : []), ...((_d = (_c = app.plan) === null || _c === void 0 ? void 0 : _c.warnings) !== null && _d !== void 0 ? _d : [])];
        const box = $("messages");
        box.hidden = msgs.length === 0;
        box.innerHTML = msgs.slice(0, 20).map((m) => `<div>⚠ ${esc(m)}</div>`).join("") +
            (msgs.length > 20 ? `<div>… and ${msgs.length - 20} more</div>` : "");
    }
    function renderGoals(state) {
        const p = app.problem;
        const box = $("goals");
        if (p.goal.length === 0) {
            box.innerHTML = `<p class="empty">The problem has no hard goal.</p>`;
            return;
        }
        const lines = p.goal.map((line, i) => {
            const lits = line.map((lit) => {
                const v = Viz.literalHolds(lit, state);
                const col = lit.args.length > 0 ? Viz.colorOf(p, lit.args[0]) : "inherit";
                const cls = v === true ? "lit true" : v === false ? "lit false" : "lit";
                return `<span class="${cls}"><b style="color:${col}">${esc(lit.label)}</b> ${esc(lit.text)}</span>`;
            });
            const vals = line.map((lit) => Viz.literalHolds(lit, state));
            const sat = vals.some((v) => v === true);
            const mark = sat ? "✓" : vals.every((v) => v === false) ? "✗" : "?";
            return `<div class="goal-line ${sat ? "sat" : "unsat"}"><span class="mark">${mark}</span>` +
                `<span class="line-no">${p.goal.length > 1 ? i + 1 + "." : ""}</span>` +
                `<span class="disj">${lits.join(`<span class="or"> ∨ </span>`)}</span></div>`;
        });
        const conj = p.goal.length > 1 ? `<p class="hint">All lines must hold (∧); each line is a disjunction (∨).</p>` : "";
        box.innerHTML = conj + lines.join("");
    }
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
                : acts.map((a) => `<span class="act">${esc(a.text)}</span>`).join("");
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
        const p = app.problem;
        if (!p)
            return;
        const state = currentState();
        const next = (_b = (_a = app.plan) === null || _a === void 0 ? void 0 : _a.steps[app.step]) !== null && _b !== void 0 ? _b : [];
        $("map").innerHTML = Viz.renderMap(p, state, { next });
        renderGoals(state);
        renderSolution();
        const counts = `${p.rows}×${p.cols} grid · ${p.trucks.length} truck${p.trucks.length === 1 ? "" : "s"}` +
            (p.airplanes.length ? ` · ${p.airplanes.length} airplane${p.airplanes.length === 1 ? "" : "s"}` : "") +
            ` · ${p.packages.length} package${p.packages.length === 1 ? "" : "s"}`;
        const sol = app.plan
            ? ` · solution ${app.planFile} (${app.plan.format}${app.plan.objective ? ", cost " + app.plan.objective : ""})`
            : "";
        $("summary").textContent = `${p.name} · ${counts}${sol}`;
        showMessages();
    }
    function go(step) {
        if (!app.plan)
            return;
        app.step = Math.max(0, Math.min(app.plan.steps.length, step));
        redraw();
    }
    function fail(where, e) {
        const box = $("messages");
        box.hidden = false;
        box.innerHTML = `<div class="error">✖ ${esc(where)}: ${esc(e instanceof Error ? e.message : String(e))}</div>`;
    }
    function loadProblem(name, text) {
        try {
            app.problem = Viz.parseProblem(text);
            app.problemFile = name;
            app.plan = undefined;
            app.planFile = undefined;
            app.step = 0;
            $("solution-file").value = "";
            document.body.classList.add("loaded");
            redraw();
        }
        catch (e) {
            fail(name, e);
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
    /** Show a problem (and a solution, at STEP) given as text: for a page that
     *  gets its files some other way than the file choosers, e.g. from a server. */
    function load(problemName, problemText, planName, planText, step = 0) {
        loadProblem(problemName, problemText);
        if (planName !== undefined && planText !== undefined) {
            loadPlan(planName, planText);
            go(step);
        }
    }
    Viz.load = load;
    function readFile(file, then) {
        const r = new FileReader();
        r.onload = () => then(file.name, String(r.result));
        r.onerror = () => fail(file.name, r.error);
        r.readAsText(file);
    }
    function init() {
        const pf = $("problem-file");
        const sf = $("solution-file");
        pf.addEventListener("change", () => { var _a; return ((_a = pf.files) === null || _a === void 0 ? void 0 : _a[0]) && readFile(pf.files[0], loadProblem); });
        sf.addEventListener("change", () => { var _a; return ((_a = sf.files) === null || _a === void 0 ? void 0 : _a[0]) && readFile(sf.files[0], loadPlan); });
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
            if (ev.target.tagName === "INPUT")
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
        // drop files anywhere: a .pddl is the problem, anything else the solution
        document.addEventListener("dragover", (ev) => ev.preventDefault());
        document.addEventListener("drop", (ev) => {
            var _a, _b;
            ev.preventDefault();
            const files = [...((_b = (_a = ev.dataTransfer) === null || _a === void 0 ? void 0 : _a.files) !== null && _b !== void 0 ? _b : [])];
            const prob = files.find((x) => /\.pddl$/i.test(x.name));
            const sol = files.find((x) => x !== prob);
            if (prob) {
                readFile(prob, (n, t) => {
                    loadProblem(n, t);
                    if (sol)
                        readFile(sol, loadPlan);
                });
            }
            else if (sol) {
                readFile(sol, loadPlan);
            }
        });
    }
    if (typeof document !== "undefined") {
        if (document.readyState === "loading")
            document.addEventListener("DOMContentLoaded", init);
        else
            init();
    }
})(Viz || (Viz = {}));
