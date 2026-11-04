// The page: choose a problem and optionally a domain and a solution, draw the
// map, show the goal formula, the running utility and the solution, and step
// through the solution.

namespace Viz {
  interface AppState {
    problem?: Problem;
    problemFile?: string;
    domain?: Domain;
    domainFile?: string;
    /** where the domain (or a failed attempt at one) came from: the user's
     *  chooser or a drop, the caller with the problem, or FiFO's library */
    domainSource?: "user" | "given" | "library";
    plan?: Plan;
    planFile?: string;
    step: number;
    /** errors from the files of the last load (one chooser, or one drop of
     *  several files), shown until the next load begins */
    errors: string[];
  }

  const app: AppState = { step: 0, errors: [] };

  function $(id: string): HTMLElement {
    const e = document.getElementById(id);
    if (!e) throw new Error(`missing element #${id}`);
    return e;
  }

  function currentState(): State | undefined {
    if (!app.problem) return undefined;
    if (app.plan) return app.plan.states[app.step];
    return { at: new Map(app.problem.initAt), inside: new Map(app.problem.initIn) };
  }

  function domainWarnings(): string[] {
    const p = app.problem;
    const d = app.domain;
    if (!p || !d || !p.domain || p.domain === d.name) return [];
    return [`the domain file ${app.domainFile} is "${d.name}", but the problem names "${p.domain}"`];
  }

  function showMessages() {
    const msgs = [...(app.problem?.warnings ?? []), ...domainWarnings(), ...(app.plan?.warnings ?? [])];
    const box = $("messages");
    const err = app.errors.map((e) => `<div class="error">✖ ${esc(e)}</div>`).join("");
    box.hidden = msgs.length === 0 && !err;
    box.innerHTML = err + msgs.slice(0, 20).map((m) => `<div>⚠ ${esc(m)}</div>`).join("") +
      (msgs.length > 20 ? `<div>… and ${msgs.length - 20} more</div>` : "");
  }

  function renderGoals(state: State) {
    $("goals").innerHTML = goalHtml(app.problem!, state);
  }

  function num(x: number | undefined): string {
    return x === undefined ? "–" : showValue(x);   // one format for the page and the CLARA browser
  }

  function renderUtility() {
    const p = app.problem!;
    const per = pseudoGoalUtility();
    const u = utilityAt(p, app.domain, app.plan, app.step, per !== 0 ? per : undefined);
    const goalsNote = u.goals === undefined
      ? "the problem gives its goals no utility"
      : u.pseudo
        ? `pseudo: ${per} per goal achieved, for display only` +
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
      `<div class="u-item${u.pseudo ? " pseudo" : ""}" title="${esc(goalsNote)}">` +
      `<span class="u-label">Goals${u.pseudo ? " (pseudo)" : ""}</span>` +
      `<span class="u-value">${num(u.goals)}</span></div>` +
      `<div class="u-item" title="${esc(costsNote)}"><span class="u-label">Costs</span>` +
      `<span class="u-value${u.costs !== undefined && !u.costsExact ? " estimated" : ""}">${num(u.costs === undefined ? undefined : -u.costs)}</span></div>` +
      `<div class="u-item total${u.pseudo ? " pseudo" : ""}" title="Goals + Costs${u.pseudo ? ", with pseudo goal utility" : ""}">` +
      `<span class="u-label">Total</span><span class="u-value">${num(u.total)}</span></div>`;
  }

  /** The "Pseudo Goal Utility" box: what each achieved goal of a problem that
   *  weights none counts, a whole number; 0 (the default) is off.  Anything
   *  typed that is not a number reads as 0, a fraction as the nearest integer. */
  function pseudoGoalUtility(): number {
    const v = Math.round(Number(($("pseudo-goals") as HTMLInputElement).value));
    return Number.isFinite(v) ? v : 0;
  }

  function renderSolution() {
    const box = $("solution");
    const plan = app.plan;
    const controls = $("controls") as HTMLElement;
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
    const cur = box.querySelector("li.current") as HTMLElement | null;
    if (cur) cur.scrollIntoView({ block: "nearest" });
    $("step-label").textContent = `Step ${app.step} of ${plan.steps.length} · time ${app.step + plan.firstStep}`;
    ($("prev") as HTMLButtonElement).disabled = app.step === 0;
    ($("first") as HTMLButtonElement).disabled = app.step === 0;
    ($("next") as HTMLButtonElement).disabled = app.step >= plan.steps.length;
    ($("last") as HTMLButtonElement).disabled = app.step >= plan.steps.length;
  }

  function redraw() {
    showMessages();
    const p = app.problem;
    if (!p) return;
    const state = currentState()!;
    const next = app.plan?.steps[app.step] ?? [];
    $("map").innerHTML = renderMap(p, state, { next });
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
      const end = utilityAt(p, app.domain, app.plan, app.plan.steps.length);
      const known = end.goals !== undefined || end.costs !== undefined;
      const approx = (end.costs !== undefined && !end.costsExact) || end.undecided > 0;
      sol = ` · solution ${app.planFile}` + (known ? ` (value ${approx ? "≈" : ""}${num(end.total)})` : "");
    }
    $("summary").textContent = `${p.name} · ${counts}${dom}${sol}`;
  }

  function go(step: number) {
    if (!app.plan) return;
    app.step = Math.max(0, Math.min(app.plan.steps.length, step));
    redraw();
  }

  function fail(where: string, e: unknown) {
    app.errors.push(`${where}: ${e instanceof Error ? e.message : String(e)}`);
    showMessages();
  }

  /** domains.js (written by build.sh from FiFO's pddl/) defines this: the
   *  domain library, by name. */
  declare const VIZ_DOMAINS: { name: string; file: string; text: string }[] | undefined;

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
  function adoptLibraryDomain(problem: Problem, manual: boolean) {
    if (!problem.domain || app.domainSource === "user" || typeof VIZ_DOMAINS === "undefined") return;
    if (app.domain?.name === problem.domain && (app.domainSource === "library" || !manual)) return;
    const lib = VIZ_DOMAINS.find((d) => d.name === problem.domain);
    if (!lib) return;
    try {
      app.domain = parseDomain(lib.text);
      app.domainFile = `${lib.file} (FiFO's library)`;
      app.domainSource = "library";
      ($("domain-file") as HTMLInputElement).value = "";
    } catch (e) {
      fail(lib.file, e);
    }
  }

  /** MANUAL: the user chose or dropped this problem (see adoptLibraryDomain) */
  function loadProblem(name: string, text: string, manual = false): boolean {
    try {
      const problem = parseProblem(text);
      adoptLibraryDomain(problem, manual);
      app.problem = problem;
      app.problemFile = name;
      app.plan = undefined;
      app.planFile = undefined;
      app.step = 0;
      ($("solution-file") as HTMLInputElement).value = "";
      redraw();
      return true;
    } catch (e) {
      fail(name, e);
      return false;
    }
  }

  /** SOURCE: "user" when chosen or dropped, "given" when it comes with the
   *  problem (an example, or load()'s caller) -- see adoptLibraryDomain */
  function loadDomain(name: string, text: string, source: "user" | "given" = "given") {
    app.domainSource = source;
    try {
      app.domain = parseDomain(text);
      app.domainFile = name;
      redraw();
    } catch (e) {
      // drop the old domain too: costs from a domain the user just replaced
      // would be silently wrong; without one they are marked estimated
      app.domain = undefined;
      app.domainFile = undefined;
      fail(name, e);
      redraw();
    }
  }

  function loadPlan(name: string, text: string) {
    if (!app.problem) {
      fail(name, new Error("choose a problem file first"));
      return;
    }
    try {
      app.plan = parsePlan(text, app.problem);
      app.planFile = name;
      app.step = 0;
      redraw();
    } catch (e) {
      fail(name, e);
    }
  }

  /** Show a problem (and a solution, at STEP; and a domain, for costs) given as
   *  text: for a page that gets its files some other way than the file
   *  choosers, e.g. from a server. */
  export function load(problemName: string, problemText: string, planName?: string, planText?: string, step = 0,
                       domainName?: string, domainText?: string) {
    app.errors = [];
    if (domainName !== undefined && domainText !== undefined) loadDomain(domainName, domainText);
    if (!loadProblem(problemName, problemText)) return;
    if (planName !== undefined && planText !== undefined) {
      loadPlan(planName, planText);
      go(step);
    }
  }

  function readText(file: File): Promise<{ name: string; text: string }> {
    return new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve({ name: file.name, text: String(r.result) });
      r.onerror = () => reject(r.error);
      r.readAsText(file);
    });
  }

  function readInto(input: HTMLInputElement, then: (name: string, text: string) => void) {
    const file = input.files?.[0];
    if (!file) return;
    app.errors = [];
    readText(file).then((f) => then(f.name, f.text), (e) => fail(file.name, e));
  }

  /** examples.js (written by build.sh from examples/) defines this: each
   *  example problem, its domain if examples/ has it, and the solutions whose
   *  file names start with the problem's name. */
  declare const VIZ_EXAMPLES: Example[] | undefined;
  /** clara-examples.js (git-ignored; build-clara-examples.sh) defines this
   *  when there is a local CLARA checkout: the CLARA button's browser. */
  declare const VIZ_CLARA_EXAMPLES: Example[] | undefined;

  /** load example EX with its solution J (none if undefined) -- or solution J
   *  of example FROM, for a plan borrowed from another problem -- clearing the
   *  file choosers and any domain loaded before */
  function loadExample(ex: Example, j: number | undefined, from: Example = ex) {
    const s = j === undefined ? undefined : from.solutions[j];
    for (const id of ["problem-file", "domain-file", "solution-file"]) ($(id) as HTMLInputElement).value = "";
    app.domain = undefined;
    app.domainSource = undefined;
    app.domainFile = undefined;
    load(ex.problem.file, ex.problem.text, s?.file, s?.text, 0, ex.domain?.file, ex.domain?.text);
  }

  /** The CLARA button: a column browser (columns.ts), Family / Size /
   *  Instance / Goal / Solver; a Solver row loads its problem and plan. */
  function initClara() {
    const button = $("clara-button") as HTMLButtonElement;
    const list = typeof VIZ_CLARA_EXAMPLES === "undefined" ? [] : VIZ_CLARA_EXAMPLES;
    if (list.length === 0) {
      button.hidden = true;
      return;
    }
    /** claraTree's nodes as the browser's rows: a goal's leaves are its
     *  Solver column */
    const toRows = (ns: ClaraNode[]): ColumnRow<ClaraLeaf>[] => ns.map((nd) => ({
      label: nd.label, missing: nd.missing,
      children: nd.leaves
        ? nd.leaves.map((l) => ({ label: l.label, missing: l.missing, data: l,
                                  title: l.label + (l.missing ? " (no solution file)" : "") }))
        : toRows(nd.children),
    }));
    const browser = columnBrowser<ClaraLeaf>({
      dialog: $("clara-dialog") as HTMLDialogElement,
      footer: $("clara-path"),
      openButton: $("clara-open") as HTMLButtonElement,
      cancelButton: $("clara-cancel"),
      // built on the first click, not at page load: valuing every plan parses
      // them all (about half a second for the whole of CLARA)
      tree: () => toRows(claraTree(list, planValuer(list, typeof VIZ_DOMAINS === "undefined" ? [] : VIZ_DOMAINS))),
      describe: (path) => {
        const l = path[4]?.data;
        if (!l) return "Choose a family, size, instance, goal and solver.";
        return list[l.example].problem.file + (l.solution !== undefined
          ? "  +  " + list[l.from ?? l.example].solutions[l.solution].file.split("/").pop()
          : l.missing ? `  (no ${l.label} plan: the problem alone)` : "") +
          (l.note ? `  -- ${l.note}` : "");
      },
      open: (path) => {
        const l = path[4].data!;
        loadExample(list[l.example], l.solution, list[l.from ?? l.example]);
      },
    });
    button.addEventListener("click", () => browser.show());
  }

  function initExamples() {
    const sel = $("examples") as HTMLSelectElement;
    const list = typeof VIZ_EXAMPLES === "undefined" ? [] : VIZ_EXAMPLES;
    if (list.length === 0) {
      (sel.parentElement as HTMLElement).hidden = true;
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
      if (!sel.value) return;
      const [i, j] = sel.value.split(":").map(Number);
      loadExample(list[i], j);
      sel.value = "";
      sel.blur();
    });
  }

  function init() {
    initExamples();
    initClara();
    const pf = $("problem-file") as HTMLInputElement;
    const df = $("domain-file") as HTMLInputElement;
    const sf = $("solution-file") as HTMLInputElement;
    pf.addEventListener("change", () => readInto(pf, (n, t) => loadProblem(n, t, true)));
    df.addEventListener("change", () => readInto(df, (n, t) => loadDomain(n, t, "user")));
    sf.addEventListener("change", () => readInto(sf, loadPlan));
    // the Pseudo Goal Utility box: typed (shown as it is typed; tidied to a
    // whole number when done), or stepped by its − and + buttons
    const pseudo = $("pseudo-goals") as HTMLInputElement;
    const showPseudo = () => { if (app.problem) renderUtility(); };
    const setPseudo = (v: number) => {
      pseudo.value = String(v);
      showPseudo();
    };
    pseudo.addEventListener("input", showPseudo);
    pseudo.addEventListener("change", () => setPseudo(pseudoGoalUtility()));
    pseudo.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") pseudo.blur();   // done: the arrow keys step the plan again
    });
    $("pseudo-minus").addEventListener("click", () => setPseudo(pseudoGoalUtility() - 1));
    $("pseudo-plus").addEventListener("click", () => setPseudo(pseudoGoalUtility() + 1));
    $("first").addEventListener("click", () => go(0));
    $("prev").addEventListener("click", () => go(app.step - 1));
    $("next").addEventListener("click", () => go(app.step + 1));
    $("last").addEventListener("click", () => go(Infinity));
    $("solution").addEventListener("click", (ev) => {
      const li = (ev.target as HTMLElement).closest("li[data-step]") as HTMLElement | null;
      if (li) go(Number(li.dataset.step));
    });
    document.addEventListener("keydown", (ev) => {
      const tag = (ev.target as HTMLElement).tagName;
      if (tag === "INPUT" || tag === "SELECT") return;
      if (document.querySelector("dialog[open]")) return;   // the CLARA browser has the keys
      // leave browser shortcuts (Cmd/Alt+arrows navigate) and, with nothing to
      // step through, ordinary scrolling alone
      if (!app.plan || ev.metaKey || ev.ctrlKey || ev.altKey) return;
      if (ev.key === "ArrowRight") go(app.step + 1);
      else if (ev.key === "ArrowLeft") go(app.step - 1);
      else if (ev.key === "Home") go(0);
      else if (ev.key === "End") go(Infinity);
      else return;
      ev.preventDefault();
    });
    // drop files anywhere: a PDDL domain, a PDDL problem, and anything else is
    // the solution -- told apart by content, then loaded in that order
    document.addEventListener("dragover", (ev) => ev.preventDefault());
    document.addEventListener("drop", (ev) => {
      ev.preventDefault();
      const files = [...(ev.dataTransfer?.files ?? [])];
      app.errors = [];
      Promise.all(files.map(readText)).then((texts) => {
        const isPddl = (t: { name: string; text: string }) =>
          /\.pddl$/i.test(t.name) || /\(\s*define\s*\(/i.test(t.text);
        const dom = texts.find((t) => isPddl(t) && isDomainText(t.text));
        const prob = texts.find((t) => isPddl(t) && t !== dom);
        const sol = texts.find((t) => t !== dom && t !== prob);
        if (dom) loadDomain(dom.name, dom.text, "user");
        if (prob && !loadProblem(prob.name, prob.text, true)) return;
        if (sol) loadPlan(sol.name, sol.text);
      }, (e) => fail("dropped files", e));
    });
  }

  if (typeof document !== "undefined") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }
}
