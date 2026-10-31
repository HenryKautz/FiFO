// The circuit visualizer page: choose a session (a problem and its compiled
// circuit) from the server, add observations -- stepping through an evidence
// file, or by hand -- and show each hypothesis's probability given them.
// The probabilities come from circuit_server.py, which evaluates the circuit in
// FiFO's Lisp.  Reuses the plan visualizer's problem parser and map renderer.

namespace Viz {
  interface Observation {
    literal: string;          // "(occurs (drive truck1 p2-3 p3-3) 1)" or "(not ...)"
    slice: number;
    positive: boolean;
    action?: Action;          // the action, for drawing it on the map
  }

  interface Hypothesis { goal: string; atom: string | null; present: boolean }

  interface QueryReply {
    ok: boolean; unsat?: boolean; z?: number; z0?: number; pe?: number;
    marginal?: (number | null)[]; likelihood?: (number | null)[]; posterior?: (number | null)[];
    unknown?: string[]; refused?: { literal: string; reason: string }[]; ms?: number;
  }

  interface CircuitState {
    sessions: { id: string; name: string; evidence: string[] }[];
    sessionId?: string;
    problem?: Problem;
    circuit?: { nvars: number; nodes: number; projected: number | null; horizon: number | null;
                actions: number; hypotheses: Hypothesis[]; path: string };
    evidenceName?: string;
    observations: Observation[];
    step: number;             // how many observations are applied
    actions?: string[];       // kept action atoms, for the entry box
    reply?: QueryReply;
    messages: string[];
    errors: string[];
    busy: boolean;
    pending: boolean;         // a query was asked for while another ran
  }

  const cs: CircuitState = { sessions: [], observations: [], step: 0, messages: [], errors: [],
                             busy: false, pending: false };

  function $(id: string): HTMLElement {
    const e = document.getElementById(id);
    if (!e) throw new Error(`missing element #${id}`);
    return e;
  }

  function esc(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  async function api(path: string, body?: unknown): Promise<any> {
    const r = await fetch(path, body === undefined ? {} : {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    let data: any;
    try {
      data = await r.json();
    } catch {
      throw new Error(`${path}: the server sent no JSON (HTTP ${r.status})`);
    }
    if (!r.ok || (data && data.error)) throw new Error(data && data.error ? data.error : `HTTP ${r.status}`);
    return data;
  }

  /** "(occurs (drive truck1 a b) 3)" -> its action, for the map. */
  function observationOf(literal: string, slice: number, positive: boolean): Observation {
    let action: Action | undefined;
    try {
      const f = readAll(literal)[0];
      const atom = isList(f) && f[0] === "not" ? f[1] : f;
      if (positive && isList(atom) && atom[0] === "occurs" && isList(atom[1])) {
        const parts = (atom[1] as SExpr[]).map((x) => (isList(x) ? show(x) : x));
        action = { name: parts[0], args: parts.slice(1), text: show(atom[1]) };
      }
    } catch {
      /* drawn without the map highlight */
    }
    return { literal, slice, positive, action };
  }

  function fmt(p: number | null | undefined, digits = 3): string {
    return p === null || p === undefined ? "–" : p.toFixed(digits);
  }

  // ------------------------------------------------------------------ views

  function showMessages() {
    const box = $("messages");
    const html = cs.errors.map((e) => `<div class="error">✖ ${esc(e)}</div>`).join("") +
      cs.messages.map((m) => `<div>⚠ ${esc(m)}</div>`).join("");
    box.hidden = html === "";
    box.innerHTML = html;
  }

  function hypothesisLabel(i: number): string {
    // the goal literal's label in the problem (G1, G2, ...) when it has one
    const p = cs.problem;
    const h = cs.circuit!.hypotheses[i];
    const lit = p?.goalLiterals.find((g) => g.text === h.goal);
    return lit ? lit.label : `H${i + 1}`;
  }

  function renderHypotheses() {
    const box = $("hypotheses");
    const c = cs.circuit;
    if (!c) {
      box.innerHTML = `<p class="empty">No circuit loaded.</p>`;
      return;
    }
    const r = cs.reply;
    if (r && r.unsat) {
      box.innerHTML = `<p class="unsat">✖ The evidence is inconsistent: no plan of the circuit fits it ` +
        `(Z = 0).  Remove or step back an observation.</p>`;
      return;
    }
    const rows = c.hypotheses.map((h, i) => ({ h, i,
      m: r?.marginal?.[i] ?? null, post: r?.posterior?.[i] ?? null }));
    const best = rows.reduce((b, x) => ((x.m ?? -1) > (b?.m ?? -1) ? x : b), rows[0]);
    rows.sort((a, b) => (b.m ?? -1) - (a.m ?? -1));
    const p = cs.problem!;
    box.innerHTML =
      `<table class="hyp"><thead><tr><th></th><th>Hypothesis</th>` +
      `<th title="P(h | evidence): the marginal">P(h | E)</th>` +
      `<th title="P(E | h) normalized over the hypotheses: the posterior with a uniform prior (Ramírez–Geffner)">posterior</th>` +
      `</tr></thead><tbody>` +
      rows.map(({ h, i, m, post }) => {
        const lit = p.goalLiterals.find((g) => g.text === h.goal);
        const col = lit && lit.args.length ? colorOf(p, lit.args[0]) : "#6b7280";
        if (!h.present) {
          return `<tr class="missing"><td><b style="color:${col}">${esc(hypothesisLabel(i))}</b></td>` +
            `<td class="lit">${esc(h.goal)}</td><td colspan="2">not in the circuit</td></tr>`;
        }
        return `<tr class="${best && best.i === i ? "best" : ""}">` +
          `<td><b style="color:${col}">${esc(hypothesisLabel(i))}</b></td>` +
          `<td class="lit">${esc(h.goal)}</td>` +
          `<td class="prob"><span class="bar" style="width:${Math.round((m ?? 0) * 100)}%;background:${col}"></span>` +
          `<span class="num">${fmt(m)}</span></td>` +
          `<td class="prob"><span class="bar post" style="width:${Math.round((post ?? 0) * 100)}%;background:${col}"></span>` +
          `<span class="num">${fmt(post)}</span></td></tr>`;
      }).join("") +
      `</tbody></table>` +
      `<p class="hint">P(h | E) is each goal atom's marginal; hypotheses can hold together, so these ` +
      `need not sum to 1.  The posterior divides out each goal's prior weight and assumes a uniform ` +
      `prior.  P(E) = ${fmt(r?.pe, 4)}${r?.ms !== undefined ? ` · ${r.ms} ms` : ""}</p>`;
  }

  function renderEvidence() {
    const box = $("evidence");
    const n = cs.observations.length;
    ($("controls") as HTMLElement).hidden = n === 0;
    if (n === 0) {
      box.innerHTML = `<p class="empty">No observations.  Choose an evidence file, or add one below.</p>`;
    } else {
      box.innerHTML = `<ol>` + cs.observations.map((o, k) => {
        const cls = k < cs.step ? "done" : "todo";
        return `<li class="${cls}" data-step="${k + 1}"><span class="t">${o.slice}</span>` +
          `<span class="act">${esc(o.literal)}</span>` +
          `<button class="remove" data-remove="${k}" title="Remove">✕</button></li>`;
      }).join("") + `</ol>`;
    }
    $("step-label").textContent = `${cs.step} of ${n} observations applied` +
      (cs.evidenceName ? ` · ${cs.evidenceName}` : "");
    ($("prev") as HTMLButtonElement).disabled = cs.step === 0;
    ($("first") as HTMLButtonElement).disabled = cs.step === 0;
    ($("next") as HTMLButtonElement).disabled = cs.step >= n;
    ($("last") as HTMLButtonElement).disabled = cs.step >= n;
  }

  function renderMapView() {
    const p = cs.problem;
    if (!p) return;
    const applied = cs.observations.slice(0, cs.step);
    const moves = applied.filter((o) => o.action).map((o) => ({ action: o.action!, label: String(o.slice) }));
    const goalProb = new Map<string, number>();
    const c = cs.circuit;
    if (c && cs.reply && !cs.reply.unsat && cs.reply.marginal) {
      c.hypotheses.forEach((h, i) => {
        const lit = p.goalLiterals.find((g) => g.text === h.goal);
        const m = cs.reply!.marginal![i];
        if (lit && m !== null && m !== undefined) goalProb.set(lit.label, m);
      });
    }
    const state: State = { at: new Map(p.initAt), inside: new Map(p.initIn) };
    $("map").innerHTML = renderMap(p, state, { observed: moves, goalProb });
  }

  function renderAll() {
    renderMapView();
    renderHypotheses();
    renderEvidence();
    showMessages();
    const c = cs.circuit;
    $("summary").textContent = c && cs.problem
      ? `${cs.problem.name} · circuit ${c.path.split("/").pop()} · ${c.nodes.toLocaleString()} nodes · ` +
        `${c.projected !== null ? `projected onto ${c.projected} of ${c.nvars} atoms` : `${c.nvars} atoms`} · ` +
        `horizon ${c.horizon ?? "?"}` + (cs.busy ? " · computing…" : "")
      : "Choose a session.";
  }

  // ---------------------------------------------------------------- actions

  async function query(): Promise<void> {
    if (!cs.circuit) return;
    if (cs.busy) {
      cs.pending = true;
      return;
    }
    cs.busy = true;
    renderAll();
    try {
      const literals = cs.observations.slice(0, cs.step).map((o) => o.literal);
      const r: QueryReply = await api("/api/query", { literals });
      if (!r.ok) {
        const parts = [
          ...(r.unknown ?? []).map((u) => `${u}: not an atom of this circuit (check the spelling and the slice)`),
          ...(r.refused ?? []).map((x) => `${x.literal} ${x.reason}`),
        ];
        cs.errors = parts;
      } else {
        cs.errors = [];
        cs.reply = r;
      }
    } catch (e) {
      cs.errors = [String(e instanceof Error ? e.message : e)];
    } finally {
      cs.busy = false;
    }
    if (cs.pending) {
      cs.pending = false;
      return query();
    }
    renderAll();
  }

  function setStep(k: number) {
    cs.step = Math.max(0, Math.min(cs.observations.length, k));
    renderAll();
    void query();
  }

  async function loadSession(id: string) {
    cs.errors = [];
    cs.messages = [];
    cs.busy = true;
    $("summary").textContent = "Loading the circuit…";
    try {
      const r = await api("/api/load", { id });
      cs.sessionId = id;
      cs.problem = parseProblem(r.problem);
      cs.circuit = r.circuit;
      cs.observations = [];
      cs.step = 0;
      cs.reply = undefined;
      cs.evidenceName = undefined;
      cs.messages = [...cs.problem.warnings];
      const missing = r.circuit.hypotheses.filter((h: Hypothesis) => !h.present);
      if (missing.length) {
        cs.messages.push(`${missing.length} goal literal(s) have no atom in the circuit at its last slice`);
      }
      const sel = $("evidence-file") as HTMLSelectElement;
      sel.innerHTML = `<option value="">Choose an evidence file…</option>` +
        r.session.evidence.map((f: string) => `<option value="${esc(f)}">${esc(f)}</option>`).join("");
      const a = await api("/api/actions");
      cs.actions = a.actions;
      ($("action-list") as HTMLElement).innerHTML =
        a.actions.map((x: string) => `<option value="${esc(x.replace(/^\(occurs /, "").replace(/ \d+\)$/, ""))}">`).join("");
    } catch (e) {
      cs.errors = [String(e instanceof Error ? e.message : e)];
    } finally {
      cs.busy = false;
    }
    renderAll();
    if (cs.circuit) void query();
  }

  function useEvidence(name: string, items: { literal: string; slice: number; positive: boolean }[],
                       unsupported: string[]) {
    cs.evidenceName = name;
    cs.observations = items.map((it) => observationOf(it.literal, it.slice, it.positive));
    cs.step = cs.observations.length;
    cs.messages = unsupported.length
      ? [`${name}: ${unsupported.length} form(s) cannot be used here (ordering evidence and compound ` +
         `formulas need the circuit recompiled): ${unsupported.join(" ")}`]
      : [];
    renderAll();
    void query();
  }

  async function chooseEvidence(file: string) {
    if (!file || !cs.sessionId) return;
    ($("evidence-file") as HTMLSelectElement).value = file;
    try {
      const r = await api(`/api/evidence?id=${encodeURIComponent(cs.sessionId)}&file=${encodeURIComponent(file)}`);
      useEvidence(file, r.items, r.unsupported);
    } catch (e) {
      cs.errors = [String(e instanceof Error ? e.message : e)];
      renderAll();
    }
  }

  async function uploadEvidence(file: File) {
    try {
      const text = await file.text();
      const r = await api("/api/parse-evidence", { text });
      useEvidence(file.name, r.items, r.unsupported);
    } catch (e) {
      cs.errors = [`${file.name}: ${e instanceof Error ? e.message : e}`];
      renderAll();
    }
  }

  function addObservation() {
    const actionBox = $("add-action") as HTMLInputElement;
    const sliceBox = $("add-slice") as HTMLInputElement;
    const neg = ($("add-negated") as HTMLInputElement).checked;
    let act = actionBox.value.trim().toLowerCase();
    const slice = Number(sliceBox.value);
    if (!act) return;
    if (!Number.isInteger(slice) || slice < 1) {
      cs.errors = ["the slice must be a whole number, 1 or more"];
      return renderAll();
    }
    if (!act.startsWith("(")) act = `(${act})`;
    const atom = `(occurs ${act} ${slice})`;
    const literal = neg ? `(not ${atom})` : atom;
    // insert in slice order (after any others at the same slice); the new
    // observation is applied, with everything before it
    const obs = observationOf(literal, slice, !neg);
    const at = cs.observations.findIndex((o) => o.slice > slice);
    const idx = at < 0 ? cs.observations.length : at;
    cs.observations.splice(idx, 0, obs);
    cs.step = Math.max(cs.step + (idx < cs.step ? 1 : 0), idx + 1);
    actionBox.value = "";
    renderAll();
    void query();
  }

  function init() {
    $("session").addEventListener("change", (ev) => {
      const v = (ev.target as HTMLSelectElement).value;
      if (v) void loadSession(v);
    });
    $("evidence-file").addEventListener("change", (ev) => {
      void chooseEvidence((ev.target as HTMLSelectElement).value);
    });
    $("evidence-upload").addEventListener("change", (ev) => {
      const f = (ev.target as HTMLInputElement).files?.[0];
      if (f) void uploadEvidence(f);
    });
    $("first").addEventListener("click", () => setStep(0));
    $("prev").addEventListener("click", () => setStep(cs.step - 1));
    $("next").addEventListener("click", () => setStep(cs.step + 1));
    $("last").addEventListener("click", () => setStep(Infinity));
    $("clear").addEventListener("click", () => {
      cs.observations = [];
      cs.step = 0;
      cs.evidenceName = undefined;
      renderAll();
      void query();
    });
    $("add").addEventListener("click", addObservation);
    $("add-action").addEventListener("keydown", (ev) => {
      if ((ev as KeyboardEvent).key === "Enter") addObservation();
    });
    $("evidence").addEventListener("click", (ev) => {
      const t = ev.target as HTMLElement;
      const rm = t.closest("[data-remove]") as HTMLElement | null;
      if (rm) {
        const k = Number(rm.dataset.remove);
        cs.observations.splice(k, 1);
        if (k < cs.step) cs.step--;
        renderAll();
        void query();
        return;
      }
      const li = t.closest("li[data-step]") as HTMLElement | null;
      if (li) setStep(Number(li.dataset.step));
    });
    document.addEventListener("keydown", (ev) => {
      const tag = (ev.target as HTMLElement).tagName;
      if (tag === "INPUT" || tag === "SELECT" || !cs.circuit) return;
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
      if (ev.key === "ArrowRight") setStep(cs.step + 1);
      else if (ev.key === "ArrowLeft") setStep(cs.step - 1);
      else return;
      ev.preventDefault();
    });
    api("/api/sessions").then((s) => {
      cs.sessions = s;
      ($("session") as HTMLSelectElement).innerHTML = `<option value="">Choose a session…</option>` +
        s.map((x: { id: string; name: string }) => `<option value="${esc(x.id)}">${esc(x.name)}</option>`).join("");
      // ?session=<id or name>&evidence=<file>&step=<k> opens a view directly
      const q = new URLSearchParams(location.search);
      const want = q.get("session");
      const pick = s.find((x: { id: string; name: string }) => x.id === want || x.name === want) ??
                   (s.length === 1 ? s[0] : undefined);
      if (pick) {
        ($("session") as HTMLSelectElement).value = pick.id;
        void loadSession(pick.id).then(async () => {
          const ev = q.get("evidence");
          if (ev && cs.circuit) {
            await chooseEvidence(ev);
            const k = q.get("step");
            if (k !== null && Number.isFinite(Number(k))) setStep(Number(k));
          }
        });
      }
      renderAll();
    }, (e) => {
      cs.errors = [`cannot reach the server: ${e instanceof Error ? e.message : e}`];
      showMessages();
    });
  }

  if (typeof document !== "undefined" && document.getElementById("hypotheses")) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }
}
