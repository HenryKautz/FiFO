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

namespace Viz {
  export interface ColumnRow<T = unknown> {
    label: string;
    children?: ColumnRow<T>[];
    missing?: boolean;
    disabled?: boolean;
    /** the row's tooltip (default: its label) */
    title?: string;
    data?: T;
  }

  export interface ColumnBrowserOptions<T> {
    dialog: HTMLDialogElement;
    footer: HTMLElement;
    openButton: HTMLButtonElement;
    cancelButton: HTMLElement;
    /** the rows of the first column, built on the first show() */
    tree: () => ColumnRow<T>[];
    /** the footer's text for the rows chosen so far (PATH[c] in column c) */
    describe: (path: ColumnRow<T>[]) => string;
    /** load the chosen last-column row (PATH, one row per column) */
    open: (path: ColumnRow<T>[]) => void;
  }

  /** whether PATH reaches an openable row of the last column */
  function openable<T>(path: ColumnRow<T>[], ncols: number): boolean {
    return path.length === ncols && path.every((r) => !r.disabled);
  }

  export function columnBrowser<T>(o: ColumnBrowserOptions<T>): { show(): void } {
    const dialog = o.dialog;
    const cols = [...dialog.querySelectorAll(".clara-col ul")] as HTMLElement[];
    const n = cols.length;
    const colsBox = dialog.querySelector(".clara-cols") as HTMLElement;
    let tree: ColumnRow<T>[] | undefined;
    const chosen: number[] = [];   // chosen[c]: the chosen row of column c
    let active = 0;                // the column the arrow keys move in

    /** the rows of column c, given the choices to its left */
    function rows(c: number): ColumnRow<T>[] {
      let nodes = tree ?? [];
      for (let k = 0; k < c; k++) {
        const r = nodes[chosen[k]];
        if (!r) return [];
        nodes = r.children ?? [];
      }
      return nodes;
    }
    function path(): ColumnRow<T>[] {
      const out: ColumnRow<T>[] = [];
      for (let c = 0; c < n; c++) {
        const r = rows(c)[chosen[c]];
        if (!r) break;
        out.push(r);
      }
      return out;
    }
    function render() {
      for (let c = 0; c < n; c++) {
        const r = rows(c);
        if (chosen[c] === undefined && r.length === 1) chosen[c] = 0;   // nothing to choose
      }
      cols.forEach((ul, c) => {
        ul.innerHTML = rows(c).map((r, k) => {
          const cls = [k === chosen[c] ? "chosen" : "", c === active && k === chosen[c] ? "active" : "",
                       r.missing || r.disabled ? "missing" : "", r.disabled ? "disabled" : ""].filter(Boolean).join(" ");
          return `<li data-col="${c}" data-row="${k}" class="${cls}" title="${esc(r.title ?? r.label)}">` +
                 `${esc(r.label)}</li>`;
        }).join("");
        const cur = ul.querySelector("li.chosen") as HTMLElement | null;
        if (cur) cur.scrollIntoView({ block: "nearest" });
      });
      const p = path();
      o.openButton.disabled = !openable(p, n);
      o.footer.textContent = o.describe(p);
      o.footer.title = o.footer.textContent;
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
      const p = path();
      if (!openable(p, n)) return;
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
      const li = (ev.target as HTMLElement).closest("li[data-col]") as HTMLElement | null;
      if (li) {
        choose(Number(li.dataset.col), Number(li.dataset.row));
        colsBox.focus();   // the columns take the keys: rows can't, and on Cancel Enter would cancel
      }
    });
    dialog.addEventListener("dblclick", (ev) => {
      const li = (ev.target as HTMLElement).closest("li[data-col]") as HTMLElement | null;
      if (li && Number(li.dataset.col) === n - 1) open();
    });
    dialog.addEventListener("keydown", (ev) => {
      if ((ev.target as HTMLElement).tagName === "BUTTON" && ev.key === "Enter") return;
      const k = chosen[active] ?? -1;
      if (ev.key === "ArrowDown") choose(active, k + 1);
      else if (ev.key === "ArrowUp") choose(active, Math.max(0, k - 1));
      else if (ev.key === "ArrowRight" && active < n - 1 && chosen[active] !== undefined) {
        choose(active + 1, chosen[active + 1] ?? 0);
      } else if (ev.key === "ArrowLeft" && active > 0) {
        active--;
        render();
      } else if (ev.key === "Enter") open();
      else return;
      ev.preventDefault();
    });
    o.openButton.addEventListener("click", open);
    o.cancelButton.addEventListener("click", () => dialog.close());

    return {
      show() {
        if (!tree) tree = o.tree();
        render();
        dialog.showModal();
        colsBox.focus();
      },
    };
  }
}
