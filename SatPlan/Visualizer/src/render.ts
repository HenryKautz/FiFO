// The map as SVG markup: places as squares on the grid, roads as lines with an
// arrowhead at each end they can be driven towards, and in each square its
// trucks, airplanes, packages and goal destinations.
//
// A square's contents fill it: one kind alone (say, a truck) gets the whole
// square; vehicles share it with the others by taking the bottom part; goals
// and packages split what is left side by side.  Several of one kind overlap,
// each further one offset up and to the right so its edge shows, and they shrink
// as there are more.  A package in a vehicle is a small badge on that vehicle.
// The SVG has a viewBox and no fixed size, so it scales with its container.
//
// Icons: Material Design Icons (https://pictogrammers.com/library/mdi/),
// Apache License 2.0 -- "truck", "airplane", "package-variant-closed".

namespace Viz {
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
  const SIDE = 68;     // a place's square
  const MARGIN = 24;
  const PAD = 2;       // between a square's edge and its contents
  const OFFSET = 0.2;  // a stacked item's offset, as a fraction of its size

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

  interface Box { x: number; y: number; w: number; h: number }

  /** N square items stacked in REGION as large as fits, each further one offset
   *  up and to the right by OFFSET of its size; the stack is centered across the
   *  region and sits on its bottom.  Each item's top-left corner and the size. */
  export function stack(n: number, region: Box): { boxes: { x: number; y: number }[]; size: number } {
    const k = 1 + OFFSET * (n - 1);
    const size = Math.min(region.w, region.h) / k;
    const d = size * OFFSET;
    const span = size * k;
    const x0 = region.x + (region.w - span) / 2;
    const y0 = region.y + region.h - size;
    const boxes: { x: number; y: number }[] = [];
    for (let i = 0; i < n; i++) boxes.push({ x: x0 + i * d, y: y0 - i * d });
    return { boxes, size };
  }

  /** The parts of a square's inner area given to each kind present. */
  export function regions(inner: Box, goals: boolean, packages: boolean, vehicles: boolean) {
    const out: { goals?: Box; packages?: Box; vehicles?: Box } = {};
    const top = goals || packages;
    const topH = vehicles && top ? inner.h * 0.45 : inner.h;
    const topBox: Box = { x: inner.x, y: inner.y, w: inner.w, h: topH };
    if (vehicles) out.vehicles = top ? { x: inner.x, y: inner.y + topH, w: inner.w, h: inner.h - topH } : inner;
    if (goals && packages) {
      out.goals = { x: topBox.x, y: topBox.y, w: topBox.w / 2, h: topBox.h };
      out.packages = { x: topBox.x + topBox.w / 2, y: topBox.y, w: topBox.w / 2, h: topBox.h };
    } else if (goals) {
      out.goals = topBox;
    } else if (packages) {
      out.packages = topBox;
    }
    return out;
  }

  /** An icon of KIND at (X, Y), SIZE square, in COLOR, with a haloed label. */
  function icon(kind: keyof typeof ICONS, cls: string, x: number, y: number, size: number, color: string,
                label: string, title: string, extra = ""): string {
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
      // a road from a place to itself (or two places drawn in one cell) has no
      // line to draw
      if (!a || !b || (a.x === b.x && a.y === b.y)) continue;
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
        out.push(`<text class="airport-mark" x="${f(c.x + SIDE - 7)}" y="${f(c.y + 8)}">✈</text>`);
      }
      const goals = goalsAt.get(p) ?? [];
      const pkgs = packagesAt.get(p) ?? [];
      const vs = vehiclesAt.get(p) ?? [];
      const inner: Box = { x: c.x + PAD, y: c.y + PAD, w: SIDE - 2 * PAD, h: SIDE - 2 * PAD };
      const reg = regions(inner, goals.length > 0, pkgs.length > 0, vs.length > 0);

      if (reg.goals) {
        const s = stack(goals.length, reg.goals);
        const g = s.size * 0.86; // a goal box sits inside its slot, its dashes clear of the next
        goals.forEach((lit, k) => {
          const b = s.boxes[k];
          const x = b.x + (s.size - g) / 2;
          const y = b.y + (s.size - g) / 2;
          const done = literalHolds(lit, state) === true;
          const col = colorOf(problem, lit.args[0]);
          const fs = Math.max(g * 0.36, 5);
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
          const b = s.boxes[i];
          out.push(icon("package", "package", b.x, b.y, s.size, colorOf(problem, k),
                        problem.labels.get(k) ?? k, `${k} at ${p}`));
        });
      }

      if (reg.vehicles) {
        const s = stack(vs.length, reg.vehicles);
        vs.forEach((v, i) => {
          const b = s.boxes[i];
          const load = cargo.get(v) ?? [];
          // cargo badges over the vehicle's top right, overlapping up and right
          let badges = "";
          if (load.length > 0) {
            const bs = s.size * 0.42;
            const step = bs * OFFSET * 1.5;
            load.forEach((k, j) => {
              badges += icon("package", "package badge", b.x + s.size * 0.56 + j * step, b.y - bs * 0.05 - j * step,
                             bs, colorOf(problem, k), problem.labels.get(k) ?? k, `${k} in ${v}`);
            });
          }
          const kind = problem.airplanes.includes(v) ? "airplane" : "truck";
          out.push(icon(kind, "vehicle", b.x, b.y, s.size, colorOf(problem, v), problem.labels.get(v) ?? v,
                        `${v} at ${p}${load.length ? ", carrying " + load.join(", ") : ""}`, badges));
        });
      }
      out.push(`</g>`);
    }
    out.push(`</g>`);
    out.push(`</svg>`);
    return out.join("\n");
  }
}
