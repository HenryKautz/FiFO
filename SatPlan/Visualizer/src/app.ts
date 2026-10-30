// The page: choose a problem and optionally a solution, draw the map, list the
// goal formula and the solution, and step through the solution.

namespace Viz {
  interface AppState {
    problem?: Problem;
    problemFile?: string;
    plan?: Plan;
    planFile?: string;
    step: number;
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

  function showMessages() {
    const msgs = [...(app.problem?.warnings ?? []), ...(app.plan?.warnings ?? [])];
    const box = $("messages");
    box.hidden = msgs.length === 0;
    box.innerHTML = msgs.slice(0, 20).map((m) => `<div>⚠ ${esc(m)}</div>`).join("") +
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
        const cls = v === true ? "lit true" : v === false ? "lit false" : "lit";
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
    const p = app.problem;
    if (!p) return;
    const state = currentState()!;
    const next = app.plan?.steps[app.step] ?? [];
    $("map").innerHTML = renderMap(p, state, { next });
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

  function go(step: number) {
    if (!app.plan) return;
    app.step = Math.max(0, Math.min(app.plan.steps.length, step));
    redraw();
  }

  function fail(where: string, e: unknown) {
    const box = $("messages");
    box.hidden = false;
    box.innerHTML = `<div class="error">✖ ${esc(where)}: ${esc(e instanceof Error ? e.message : String(e))}</div>`;
  }

  function loadProblem(name: string, text: string) {
    try {
      app.problem = parseProblem(text);
      app.problemFile = name;
      app.plan = undefined;
      app.planFile = undefined;
      app.step = 0;
      ($("solution-file") as HTMLInputElement).value = "";
      document.body.classList.add("loaded");
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
      redraw();
    } catch (e) {
      fail(name, e);
    }
  }

  /** Show a problem (and a solution, at STEP) given as text: for a page that
   *  gets its files some other way than the file choosers, e.g. from a server. */
  export function load(problemName: string, problemText: string, planName?: string, planText?: string, step = 0) {
    loadProblem(problemName, problemText);
    if (planName !== undefined && planText !== undefined) {
      loadPlan(planName, planText);
      go(step);
    }
  }

  function readFile(file: File, then: (name: string, text: string) => void) {
    const r = new FileReader();
    r.onload = () => then(file.name, String(r.result));
    r.onerror = () => fail(file.name, r.error);
    r.readAsText(file);
  }

  function init() {
    const pf = $("problem-file") as HTMLInputElement;
    const sf = $("solution-file") as HTMLInputElement;
    pf.addEventListener("change", () => pf.files?.[0] && readFile(pf.files[0], loadProblem));
    sf.addEventListener("change", () => sf.files?.[0] && readFile(sf.files[0], loadPlan));
    $("first").addEventListener("click", () => go(0));
    $("prev").addEventListener("click", () => go(app.step - 1));
    $("next").addEventListener("click", () => go(app.step + 1));
    $("last").addEventListener("click", () => go(Infinity));
    $("solution").addEventListener("click", (ev) => {
      const li = (ev.target as HTMLElement).closest("li[data-step]") as HTMLElement | null;
      if (li) go(Number(li.dataset.step));
    });
    document.addEventListener("keydown", (ev) => {
      if ((ev.target as HTMLElement).tagName === "INPUT") return;
      if (ev.key === "ArrowRight") go(app.step + 1);
      else if (ev.key === "ArrowLeft") go(app.step - 1);
      else if (ev.key === "Home") go(0);
      else if (ev.key === "End") go(Infinity);
      else return;
      ev.preventDefault();
    });
    // drop files anywhere: a .pddl is the problem, anything else the solution
    document.addEventListener("dragover", (ev) => ev.preventDefault());
    document.addEventListener("drop", (ev) => {
      ev.preventDefault();
      const files = [...(ev.dataTransfer?.files ?? [])];
      const prob = files.find((x) => /\.pddl$/i.test(x.name));
      const sol = files.find((x) => x !== prob);
      if (prob) {
        readFile(prob, (n, t) => {
          loadProblem(n, t);
          if (sol) readFile(sol, loadPlan);
        });
      } else if (sol) {
        readFile(sol, loadPlan);
      }
    });
  }

  if (typeof document !== "undefined") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }
}
