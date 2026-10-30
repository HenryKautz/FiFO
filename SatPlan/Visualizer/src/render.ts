// The map as SVG markup: places as squares on the grid, roads as lines with an
// arrowhead at each end they can be driven towards, and in each square its
// trucks, packages and goal destinations.
//
// Inside a place's square each kind has its own corner so none hides another:
// goals top left, packages top right, vehicles along the bottom.  Several of one
// kind in one place overlap, each further one offset up and to the right so its
// edge shows.  A package in a vehicle is a badge on that vehicle.  The SVG has a
// viewBox and no fixed size, so it scales with its container.

namespace Viz {
  const TRUCK_COLORS = ["#2563eb", "#dc2626", "#16a34a", "#9333ea", "#0891b2", "#ca8a04", "#db2777", "#475569"];
  const PACKAGE_COLORS = ["#ea580c", "#0d9488", "#c026d3", "#65a30d", "#4f46e5", "#e11d48", "#0284c7", "#a16207",
                          "#7c3aed", "#059669", "#be123c", "#1d4ed8"];

  const SPACING = 100; // grid pitch, in SVG units
  const SIDE = 64;     // a place's square
  const MARGIN = 24;

  export function colorOf(problem: Problem, obj: string): string {
    let i = problem.trucks.indexOf(obj);
    if (i >= 0) return TRUCK_COLORS[i % TRUCK_COLORS.length];
    i = problem.airplanes.indexOf(obj);
    if (i >= 0) return TRUCK_COLORS[(problem.trucks.length + i) % TRUCK_COLORS.length];
    i = problem.packages.indexOf(obj);
    if (i >= 0) return PACKAGE_COLORS[i % PACKAGE_COLORS.length];
    return "#6b7280";
  }

  function esc(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function f(x: number): string {
    return (Math.round(x * 100) / 100).toString();
  }

  /** The top-left corner of place P's square. */
  function corner(problem: Problem, p: string): { x: number; y: number } | undefined {
    const c = problem.layout.get(p);
    if (!c) return undefined;
    return {
      x: MARGIN + (c.col - 1) * SPACING + (SPACING - SIDE) / 2,
      y: MARGIN + (c.row - 1) * SPACING + (SPACING - SIDE) / 2,
    };
  }

  function center(problem: Problem, p: string): { x: number; y: number } | undefined {
    const c = corner(problem, p);
    return c && { x: c.x + SIDE / 2, y: c.y + SIDE / 2 };
  }

  /** Where the segment from the center of a square towards (dx, dy) leaves it. */
  function exitPoint(cx: number, cy: number, dx: number, dy: number, gap: number) {
    const half = SIDE / 2 + gap;
    const t = half / Math.max(Math.abs(dx), Math.abs(dy));
    return { x: cx + dx * t, y: cy + dy * t };
  }

  /** N boxes of width W x H stacked in REGION, each further one offset up and
   *  right by D, the stack kept inside the region (shrinking the boxes if it
   *  has to).  Returns each box's top-left corner and the size used. */
  function stack(n: number, region: { x: number; y: number; w: number; h: number }, w: number, h: number, d: number) {
    const scale = Math.min(1, (region.w - (n - 1) * d) / w, (region.h - (n - 1) * d) / h);
    const bw = w * Math.max(scale, 0.4);
    const bh = h * Math.max(scale, 0.4);
    const boxes: { x: number; y: number }[] = [];
    for (let k = 0; k < n; k++) {
      boxes.push({ x: region.x + k * d, y: region.y + region.h - bh - k * d });
    }
    return { boxes, w: bw, h: bh };
  }

  export interface RenderOptions {
    /** the actions about to be taken; their roads are highlighted */
    next?: Action[];
  }

  export function renderMap(problem: Problem, state: State, opts: RenderOptions = {}): string {
    const W = MARGIN * 2 + problem.cols * SPACING;
    const H = MARGIN * 2 + problem.rows * SPACING;
    const out: string[] = [];
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
      if (!a || !b) continue;
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
    for (const a of opts.next ?? []) {
      const vehicle = a.args.find((o) => problem.trucks.includes(o) || problem.airplanes.includes(o));
      const places = a.args.filter((o) => problem.layout.has(o));
      if (!vehicle || places.length < 2 || a.name.startsWith("load") || a.name.startsWith("unload")) continue;
      const from = center(problem, places[0]);
      const to = center(problem, places[1]);
      if (!from || !to || (from.x === to.x && from.y === to.y)) continue;
      const p = exitPoint(from.x, from.y, to.x - from.x, to.y - from.y, 2);
      const q = exitPoint(to.x, to.y, from.x - to.x, from.y - to.y, 2);
      out.push(`<line class="move" stroke="${colorOf(problem, vehicle)}" x1="${f(p.x)}" y1="${f(p.y)}" ` +
               `x2="${f(q.x)}" y2="${f(q.y)}"><title>next: ${esc(a.text)}</title></line>`);
    }
    out.push(`</g>`);

    // what is where
    const vehiclesAt = new Map<string, string[]>();
    const packagesAt = new Map<string, string[]>();
    const goalsAt = new Map<string, Literal[]>();
    const push = <T>(m: Map<string, T[]>, k: string, v: T) => {
      const l = m.get(k);
      if (l) l.push(v);
      else m.set(k, [v]);
    };
    for (const v of [...problem.trucks, ...problem.airplanes]) {
      const p = state.at.get(v);
      if (p) push(vehiclesAt, p, v);
    }
    for (const k of problem.packages) {
      const p = state.at.get(k);
      if (p && !state.inside.has(k)) push(packagesAt, p, k);
    }
    for (const g of problem.goalLiterals) {
      if (g.pred === "at" && g.args.length === 2 && !g.negated && problem.layout.has(g.args[1])) {
        push(goalsAt, g.args[1], g);
      }
    }
    const cargo = new Map<string, string[]>();
    for (const [k, v] of state.inside) push(cargo, v, k);

    out.push(`<g class="places">`);
    for (const p of problem.places) {
      const c = corner(problem, p);
      if (!c) continue;
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
      const goals = goalsAt.get(p) ?? [];
      if (goals.length > 0) {
        const s = stack(goals.length, { x: c.x + pad, y: c.y + pad, w: half - pad - 1, h: half - pad - 1 }, 22, 22, 4);
        goals.forEach((g, k) => {
          const b = s.boxes[k];
          const done = literalHolds(g, state) === true;
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
      const pkgs = packagesAt.get(p) ?? [];
      if (pkgs.length > 0) {
        const s = stack(pkgs.length, { x: c.x + half + 1, y: c.y + pad, w: half - pad - 1, h: half - pad - 1 }, 22, 22, 4);
        pkgs.forEach((k, i) => {
          const b = s.boxes[i];
          out.push(packageBox(problem, k, b.x, b.y, s.w, s.h, `${k} at ${p}`));
        });
      }

      // vehicles: the bottom half, each with its cargo as badges
      const vs = vehiclesAt.get(p) ?? [];
      if (vs.length > 0) {
        const s = stack(vs.length, { x: c.x + pad, y: c.y + half + 1, w: SIDE - 2 * pad, h: half - pad - 1 }, 56, 24, 5);
        vs.forEach((v, i) => {
          const b = s.boxes[i];
          const col = colorOf(problem, v);
          const label = problem.labels.get(v) ?? v;
          const load = cargo.get(v) ?? [];
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

  function packageBox(problem: Problem, k: string, x: number, y: number, w: number, h: number,
                      title: string, extra = ""): string {
    const col = colorOf(problem, k);
    const label = problem.labels.get(k) ?? k;
    return `<g class="package${extra ? " " + extra : ""}">` +
      `<rect x="${f(x)}" y="${f(y)}" width="${f(w)}" height="${f(h)}" rx="2" fill="${col}"/>` +
      `<text x="${f(x + w / 2)}" y="${f(y + h / 2)}" fill="#fff" font-size="${f(h * 0.5)}">${esc(label)}</text>` +
      `<title>${esc(title)}</title></g>`;
  }
}
