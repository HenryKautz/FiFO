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

  function esc(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
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
    const pseudoBox = $("pseudo-goals") as HTMLInputElement;
    const u = utilityAt(p, app.domain, app.plan, app.step, pseudoBox.checked ? PSEUDO_GOAL_UTILITY : undefined);
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
      `<div class="u-item${u.pseudo ? " pseudo" : ""}" title="${esc(goalsNote)}">` +
      `<span class="u-label">Goals${u.pseudo ? " (pseudo)" : ""}</span>` +
      `<span class="u-value">${num(u.goals)}</span></div>` +
      `<div class="u-item" title="${esc(costsNote)}"><span class="u-label">Costs</span>` +
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

  /** The CLARA button: a column browser, Family / Size / Instance / Goal /
   *  Solver.  Choosing a row fills the next column (a column of one row is
   *  chosen at once); Open, a double click or Enter on a Solver row loads it.
   *  Arrow keys move within and between columns. */
  function initClara() {
    const button = $("clara-button") as HTMLButtonElement;
    const list = typeof VIZ_CLARA_EXAMPLES === "undefined" ? [] : VIZ_CLARA_EXAMPLES;
    if (list.length === 0) {
      button.hidden = true;
      return;
    }
    const dialog = $("clara-dialog") as HTMLDialogElement;
    const cols = [...dialog.querySelectorAll(".clara-col ul")] as HTMLElement[];
    const openBtn = $("clara-open") as HTMLButtonElement;
    // built on the first click, not at page load: valuing every plan parses
    // them all (about half a second for the whole of CLARA)
    let tree: ClaraNode[] = [];
    let built = false;
    const chosen: number[] = [];   // chosen[c]: the chosen row of column c
    let active = 0;                // the column the arrow keys move in

    /** the rows of column c, given the choices to its left */
    function rows(c: number): { label: string; missing?: boolean }[] {
      let nodes: ClaraNode[] = tree;
      for (let k = 0; k < c; k++) {
        const n = nodes[chosen[k]];
        if (!n) return [];
        if (k === 3) return n.leaves ?? [];
        nodes = n.children;
      }
      return nodes;
    }
    function leaf(): ClaraLeaf | undefined {
      return (rows(4) as ClaraLeaf[])[chosen[4]];
    }
    function render() {
      // a column of one row needs no choice
      for (let c = 0; c < 5; c++) {
        const r = rows(c);
        if (chosen[c] === undefined && r.length === 1) chosen[c] = 0;
      }
      cols.forEach((ul, c) => {
        ul.innerHTML = rows(c).map((r, k) =>
          `<li data-col="${c}" data-row="${k}" class="${k === chosen[c] ? "chosen" : ""}${c === active && k === chosen[c] ? " active" : ""}` +
          `${r.missing ? " missing" : ""}" title="${esc(r.label)}${r.missing ? " (no solution file)" : ""}">${esc(r.label)}</li>`).join("");
        const cur = ul.querySelector("li.chosen") as HTMLElement | null;
        if (cur) cur.scrollIntoView({ block: "nearest" });
      });
      const l = leaf();
      openBtn.disabled = !l;
      const path = $("clara-path");
      path.textContent = l
        ? list[l.example].problem.file + (l.solution !== undefined
          ? "  +  " + list[l.from ?? l.example].solutions[l.solution].file.split("/").pop()
          : l.missing ? `  (no ${l.label} plan: the problem alone)` : "") +
          (l.note ? `  -- ${l.note}` : "")
        : "Choose a family, size, instance, goal and solver.";
      path.title = path.textContent;
    }
    function choose(c: number, k: number) {
      if (k < 0 || k >= rows(c).length) return;
      if (chosen[c] === k) {
        // the same row again: move the keyboard mark without rebuilding the
        // lists, so the row clicked stays in the page and a double click on it
        // reaches the dblclick listener
        active = c;
        dialog.querySelectorAll("li.active").forEach((li) => li.classList.remove("active"));
        cols[c].querySelector("li.chosen")?.classList.add("active");
        return;
      }
      chosen.length = c;   // a new choice clears the columns to its right
      chosen[c] = k;
      active = c;
      render();
    }
    function open() {
      const l = leaf();
      if (!l) return;
      dialog.close();
      loadExample(list[l.example], l.solution, list[l.from ?? l.example]);
    }

    // the columns take the keyboard focus (tabindex in index.html): rows can't,
    // and with focus on Cancel, Enter would cancel
    const colsBox = dialog.querySelector(".clara-cols") as HTMLElement;
    button.addEventListener("click", () => {
      if (!built) {
        tree = claraTree(list, planValuer(list, typeof VIZ_DOMAINS === "undefined" ? [] : VIZ_DOMAINS));
        built = true;
      }
      render();
      dialog.showModal();
      colsBox.focus();
    });
    dialog.addEventListener("click", (ev) => {
      // the backdrop: a click outside the dialog's box (its own padding is
      // inside, though the event's target is the dialog there too)
      const r = dialog.getBoundingClientRect();
      if (ev.target === dialog &&
          (ev.clientX < r.left || ev.clientX > r.right || ev.clientY < r.top || ev.clientY > r.bottom)) {
        dialog.close();
        return;
      }
      const li = (ev.target as HTMLElement).closest("li[data-col]") as HTMLElement | null;
      if (li) {
        choose(Number(li.dataset.col), Number(li.dataset.row));
        colsBox.focus();
      }
    });
    dialog.addEventListener("dblclick", (ev) => {
      const li = (ev.target as HTMLElement).closest("li[data-col]") as HTMLElement | null;
      if (li && li.dataset.col === "4") open();
    });
    dialog.addEventListener("keydown", (ev) => {
      if ((ev.target as HTMLElement).tagName === "BUTTON" && ev.key === "Enter") return;
      const k = chosen[active] ?? -1;
      if (ev.key === "ArrowDown") choose(active, k + 1);
      else if (ev.key === "ArrowUp") choose(active, Math.max(0, k - 1));
      else if (ev.key === "ArrowRight" && active < 4 && chosen[active] !== undefined) choose(active + 1, chosen[active + 1] ?? 0);
      else if (ev.key === "ArrowLeft" && active > 0) { active--; render(); }
      else if (ev.key === "Enter") open();
      else return;
      ev.preventDefault();
    });
    openBtn.addEventListener("click", open);
    $("clara-cancel").addEventListener("click", () => dialog.close());
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
    const pseudo = $("pseudo-goals") as HTMLInputElement;
    (pseudo.parentElement as HTMLElement).title =
      `When the problem gives its goals no utility, count ${PSEUDO_GOAL_UTILITY} for each goal achieved. ` +
      `For display only: it is not the problem's utility.`;
    pseudo.addEventListener("change", () => {
      pseudo.blur();   // give the arrow keys back to stepping through the plan
      if (app.problem) renderUtility();
    });
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
