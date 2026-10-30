// The page: choose a problem and optionally a domain and a solution, draw the
// map, show the goal formula, the running utility and the solution, and step
// through the solution.

namespace Viz {
  interface AppState {
    problem?: Problem;
    problemFile?: string;
    domain?: Domain;
    domainFile?: string;
    plan?: Plan;
    planFile?: string;
    step: number;
    /** an error from the last file loaded, shown until the next load */
    error?: string;
  }

  const app: AppState = { step: 0 };

  function $(id: string): HTMLElement {
    const e = document.getElementById(id);
    if (!e) throw new Error(`missing element #${id}`);
    return e;
  }

  function esc(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
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
    const err = app.error ? `<div class="error">✖ ${esc(app.error)}</div>` : "";
    box.hidden = msgs.length === 0 && !err;
    box.innerHTML = err + msgs.slice(0, 20).map((m) => `<div>⚠ ${esc(m)}</div>`).join("") +
      (msgs.length > 20 ? `<div>… and ${msgs.length - 20} more</div>` : "");
  }

  function renderGoals(state: State) {
    const p = app.problem!;
    const box = $("goals");
    if (p.goal.length === 0) {
      box.innerHTML = `<p class="empty">The problem has no hard goal.</p>`;
      return;
    }
    const lines = p.goal.map((line, i) => {
      const lits = line.map((lit) => {
        const v = literalHolds(lit, state);
        const col = lit.args.length > 0 ? colorOf(p, lit.args[0]) : "inherit";
        // an achieved goal is highlighted in its package's color, as on the map
        if (v === true) {
          return `<span class="lit true" style="background:${col}" title="achieved"><b>${esc(lit.label)}</b> ${esc(lit.text)}</span>`;
        }
        const cls = v === false ? "lit false" : "lit";
        return `<span class="${cls}"><b style="color:${col}">${esc(lit.label)}</b> ${esc(lit.text)}</span>`;
      });
      const vals = line.map((lit) => literalHolds(lit, state));
      const sat = vals.some((v) => v === true);
      const mark = sat ? "✓" : vals.every((v) => v === false) ? "✗" : "?";
      return `<div class="goal-line ${sat ? "sat" : "unsat"}"><span class="mark">${mark}</span>` +
        `<span class="line-no">${p.goal.length > 1 ? i + 1 + "." : ""}</span>` +
        `<span class="disj">${lits.join(`<span class="or"> ∨ </span>`)}</span></div>`;
    });
    const conj = p.goal.length > 1 ? `<p class="hint">All lines must hold (∧); each line is a disjunction (∨).</p>` : "";
    box.innerHTML = conj + lines.join("");
  }

  function num(x: number | undefined): string {
    if (x === undefined) return "–";
    const r = Math.round(x * 1000) / 1000;
    return (r < 0 ? "−" + Math.abs(r) : String(r));
  }

  function renderUtility() {
    const p = app.problem!;
    const u = utilityAt(p, app.domain, app.plan, app.step);
    const goalsNote = u.goals === undefined
      ? "the problem gives its goals no utility"
      : `${p.preferences.length} weighted preference${p.preferences.length === 1 ? "" : "s"}` +
        (u.undecided ? `; ${u.undecided} not tracked` : "");
    const costsNote = u.costs === undefined
      ? "the problem has no action costs"
      : !app.plan
        ? "no solution loaded"
        : u.costsExact ? `from the domain${app.domainFile ? " " + app.domainFile : ""}`
          : app.domain ? "some costs unknown (counted as 0)"
            : "estimated: load the domain for exact costs";
    $("utility").innerHTML =
      `<div class="u-item"><span class="u-label">Goals</span><span class="u-value">${num(u.goals)}</span>` +
      `<span class="u-note">${esc(goalsNote)}</span></div>` +
      `<div class="u-item"><span class="u-label">Costs</span>` +
      `<span class="u-value${u.costs !== undefined && !u.costsExact ? " estimated" : ""}">${num(u.costs === undefined ? undefined : -u.costs)}</span>` +
      `<span class="u-note">${esc(costsNote)}</span></div>` +
      `<div class="u-item total"><span class="u-label">Total</span><span class="u-value">${num(u.total)}</span>` +
      `<span class="u-note">Goals + Costs</span></div>`;
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
    const sol = app.plan
      ? ` · solution ${app.planFile} (${app.plan.format}${app.plan.objective ? ", objective " + app.plan.objective : ""})`
      : "";
    $("summary").textContent = `${p.name} · ${counts}${dom}${sol}`;
  }

  function go(step: number) {
    if (!app.plan) return;
    app.step = Math.max(0, Math.min(app.plan.steps.length, step));
    redraw();
  }

  function fail(where: string, e: unknown) {
    app.error = `${where}: ${e instanceof Error ? e.message : String(e)}`;
    showMessages();
  }

  function loadProblem(name: string, text: string): boolean {
    try {
      const problem = parseProblem(text);
      app.problem = problem;
      app.problemFile = name;
      app.plan = undefined;
      app.planFile = undefined;
      app.step = 0;
      app.error = undefined;
      ($("solution-file") as HTMLInputElement).value = "";
      redraw();
      return true;
    } catch (e) {
      fail(name, e);
      return false;
    }
  }

  function loadDomain(name: string, text: string) {
    try {
      app.domain = parseDomain(text);
      app.domainFile = name;
      app.error = undefined;
      redraw();
    } catch (e) {
      fail(name, e);
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
      app.error = undefined;
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
    readText(file).then((f) => then(f.name, f.text), (e) => fail(file.name, e));
  }

  /** examples.js (written by build.sh from examples/) defines this: each
   *  example problem, its domain if examples/ has it, and the solutions whose
   *  file names start with the problem's name. */
  interface Example {
    problem: { file: string; text: string };
    domain?: { file: string; text: string };
    solutions: { file: string; text: string }[];
  }
  declare const VIZ_EXAMPLES: Example[] | undefined;

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
      const ex = list[i];
      const s = j === undefined ? undefined : ex.solutions[j];
      for (const id of ["problem-file", "domain-file", "solution-file"]) ($(id) as HTMLInputElement).value = "";
      app.domain = undefined;
      app.domainFile = undefined;
      load(ex.problem.file, ex.problem.text, s?.file, s?.text, 0, ex.domain?.file, ex.domain?.text);
      sel.value = "";
      sel.blur();
    });
  }

  function init() {
    initExamples();
    const pf = $("problem-file") as HTMLInputElement;
    const df = $("domain-file") as HTMLInputElement;
    const sf = $("solution-file") as HTMLInputElement;
    pf.addEventListener("change", () => readInto(pf, loadProblem));
    df.addEventListener("change", () => readInto(df, loadDomain));
    sf.addEventListener("change", () => readInto(sf, loadPlan));
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
      Promise.all(files.map(readText)).then((texts) => {
        const isPddl = (t: { name: string; text: string }) =>
          /\.pddl$/i.test(t.name) || /\(\s*define\s*\(/i.test(t.text);
        const dom = texts.find((t) => isPddl(t) && isDomainText(t.text));
        const prob = texts.find((t) => isPddl(t) && t !== dom);
        const sol = texts.find((t) => t !== dom && t !== prob);
        if (dom) loadDomain(dom.name, dom.text);
        if (prob && !loadProblem(prob.name, prob.text)) return;
        if (sol) loadPlan(sol.name, sol.text);
      }, (e) => fail("dropped files", e));
    });
  }

  if (typeof document !== "undefined") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }
}
