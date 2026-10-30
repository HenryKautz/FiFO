// S-expression reader for PDDL problems and FiFO answer files.
//
// Everything is lowercased (PDDL and FiFO's answers are case-insensitive; FiFO
// prints upper case).  ";" starts a comment to the end of the line.  Besides
// lists and atoms, the reader keeps the top-level tokens a plan file may carry
// between forms -- "@", step numbers, "0:" prefixes, "[1]" costs -- as atoms,
// so the plan parser can read them in order.

namespace Viz {
  export type SExpr = string | SExpr[];

  export function tokenize(text: string): string[] {
    const tokens: string[] = [];
    let i = 0;
    const n = text.length;
    while (i < n) {
      const c = text[i];
      if (c === ";") {
        while (i < n && text[i] !== "\n") i++;
      } else if (c === "(" || c === ")") {
        tokens.push(c);
        i++;
      } else if (/\s/.test(c)) {
        i++;
      } else {
        let j = i;
        while (j < n && !/[\s();]/.test(text[j])) j++;
        tokens.push(text.slice(i, j).toLowerCase());
        i = j;
      }
    }
    return tokens;
  }

  /** Every top-level form of TEXT, atoms included, in order. */
  export function readAll(text: string): SExpr[] {
    const tokens = tokenize(text);
    const out: SExpr[] = [];
    let pos = 0;
    function read(): SExpr {
      const t = tokens[pos++];
      if (t === "(") {
        const list: SExpr[] = [];
        while (pos < tokens.length && tokens[pos] !== ")") list.push(read());
        if (pos >= tokens.length) throw new Error("unbalanced parentheses: a list is never closed");
        pos++; // the ")"
        return list;
      }
      if (t === ")") throw new Error("unbalanced parentheses: an extra ')'");
      return t;
    }
    while (pos < tokens.length) out.push(read());
    return out;
  }

  export function isList(x: SExpr | undefined): x is SExpr[] {
    return Array.isArray(x);
  }

  export function show(x: SExpr): string {
    return isList(x) ? "(" + x.map(show).join(" ") + ")" : x;
  }
}
