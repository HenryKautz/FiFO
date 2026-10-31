#!/usr/bin/env python3
"""circuit_server.py -- the circuit visualizer's server.

Serves circuit.html and its scripts, and answers the page's JSON requests by
driving one long-running SBCL process (FiFO + ddnnf.lisp + circuit-server.lisp)
that holds the loaded circuit.  Standard library only.  See CIRCUIT-PLAN.md.

    circuit_server.py --session PROBLEM.pddl CIRCUIT.dnnf[b] [EVIDENCE...]
                      [--session ...] [--clara DIR] [--port 8765] [--open]

EVIDENCE is evidence files or directories; a directory contributes the files
whose names start with the problem's name.  --clara DIR adds every problem of
CLARA's TwoPackage, SimpleGrid and ThreePackage that has a saved circuit, with
its evidence/ files.  Without any session the bundled example
(../circuit-examples/) is served.

The Lisp is FIFO_LISP if set, else ~/lib/fifo/lisp (the installed FiFO);
--sbcl names the SBCL binary, --heap-mb its heap.
"""
import argparse, glob, json, os, re, select, subprocess, sys, threading, time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
VIZ = os.path.dirname(HERE)                    # SatPlan/Visualizer
STATIC = {"circuit.html": "text/html; charset=utf-8",
          "circuit.js": "text/javascript; charset=utf-8",
          "visualizer.css": "text/css; charset=utf-8"}
REPLY = "@@REPLY "


# ------------------------------------------------------------------ s-exprs

def read_sexprs(text):
    """Every top-level s-expression of TEXT (comments stripped), as nested
    lists of lower-cased atom strings."""
    text = re.sub(r";[^\n]*", "", text)
    out, stack = [], [[]]
    for tok in re.findall(r"\(|\)|[^\s()]+", text):
        if tok == "(":
            stack.append([])
        elif tok == ")":
            if len(stack) == 1:
                raise ValueError("unbalanced ')'")
            x = stack.pop()
            stack[-1].append(x)
        else:
            stack[-1].append(tok.lower())
    if len(stack) != 1:
        raise ValueError("unbalanced '(' -- a list is never closed")
    return stack[0]


def show(x):
    return x if isinstance(x, str) else "(" + " ".join(show(y) for y in x) + ")"


def goal_literals(problem_text):
    """The hard goal's disjuncts, in order, deduplicated: every literal of every
    (or ...) conjunct, and each single-literal conjunct.  Preferences are
    ignored -- the page's hypotheses, as in the plan visualizer's Goal panel."""
    forms = read_sexprs(problem_text)
    define = next((f for f in forms if isinstance(f, list) and f and f[0] == "define"), None)
    goal = next((x for x in (define or []) if isinstance(x, list) and x and x[0] == ":goal"), None)
    if goal is None or len(goal) < 2:
        return []
    out = []

    def add(lit):
        s = show(lit)
        if s not in out:
            out.append(s)

    def walk(g):
        if isinstance(g, list) and g and g[0] == "and":
            for c in g[1:]:
                walk(c)
        elif isinstance(g, list) and g and g[0] == "preference":
            return
        elif isinstance(g, list) and g and g[0] == "or":
            for d in g[1:]:
                add(d)
        else:
            add(g)
    walk(goal[1])
    return out


def parse_evidence(text):
    """An evidence file as pinned literals in slice order.  Returns
    (items, unsupported): items [{literal, slice, positive}], unsupported the
    forms the page cannot clamp (ordering evidence, compound formulas)."""
    items, unsupported = [], []

    def literal(f):
        neg = isinstance(f, list) and f and f[0] == "not"
        atom = f[1] if neg else f
        if (isinstance(atom, list) and len(atom) == 3 and atom[0] in ("occurs", "holds")
                and re.fullmatch(r"-?\d+", atom[2] if isinstance(atom[2], str) else "")):
            items.append({"literal": show(f), "slice": int(atom[2]), "positive": not neg})
        else:
            unsupported.append(show(f))

    for f in read_sexprs(text):
        if isinstance(f, list) and f and f[0] == "and":
            for g in f[1:]:
                literal(g)
        else:
            literal(f)
    items.sort(key=lambda it: it["slice"])        # stable: file order within a slice
    return items, unsupported


# --------------------------------------------------------------------- Lisp

class LispError(Exception):
    pass


class Lisp:
    """One SBCL child running cv-serve: a command per line in, one @@REPLY line
    out.  Restarted (and the current circuit reloaded) if it dies."""

    def __init__(self, fifo_lisp, sbcl="sbcl", heap_mb=8192, log=None):
        self.fifo_lisp, self.sbcl, self.heap_mb = fifo_lisp, sbcl, heap_mb
        self.proc = None
        self.lock = threading.Lock()
        self.log = log or (lambda s: None)
        self.loaded = None                  # (circuit, goals) to reload after a restart

    def start(self):
        lisp = self.fifo_lisp
        cmd = [self.sbcl, "--dynamic-space-size", str(self.heap_mb),
               "--control-stack-size", "200MB", "--noinform", "--disable-debugger",
               "--eval", f'(load "{lisp}/FiFO.lisp")',
               "--eval", f'(load "{lisp}/ddnnf.lisp")',
               "--eval", f'(load "{os.path.join(HERE, "circuit-server.lisp")}")',
               "--eval", "(cv-serve)", "--eval", "(sb-ext:exit)"]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _call(self, command, timeout):
        if not self.alive():
            self.start()
            if self.loaded and not command.startswith("(cv-load"):
                circuit, goals = self.loaded
                self._call(load_command(circuit, goals), timeout)
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                self.proc.kill()
                raise LispError(f"no reply from Lisp within {timeout:g} s; it was stopped")
            ready, _, _ = select.select([self.proc.stdout], [], [], left)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if line == "":
                self.proc.wait()
                raise LispError(f"the Lisp process exited (code {self.proc.returncode}); "
                                "it is restarted on the next request")
            if line.startswith(REPLY):
                reply = json.loads(line[len(REPLY):])
                if "error" in reply:
                    raise LispError(reply["error"])
                return reply
            self.log(line.rstrip("\n"))

    def call(self, command, timeout=600):
        with self.lock:
            return self._call(command, timeout)

    def load(self, circuit, goals):
        with self.lock:
            reply = self._call(load_command(circuit, goals), 1800)
            self.loaded = (circuit, goals)
            return reply

    def stop(self):
        if self.alive():
            try:
                self.proc.stdin.write("(cv-quit)\n")
                self.proc.stdin.flush()
                self.proc.wait(5)
            except Exception:
                self.proc.kill()


def lisp_string(s):
    """S as a Lisp string literal: backslash and double quote escaped."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_command(circuit, goals):
    return f"(cv-load {lisp_string(circuit)} ({' '.join(lisp_string(g) for g in goals)}))"


def query_command(literals):
    for lit in literals:
        if "\n" in lit:
            raise ValueError("a literal is one line")
    return f"(cv-query ({' '.join(lisp_string(l) for l in literals)}))"


# ----------------------------------------------------------------- sessions

def best_circuit(base):
    """BASE.dnnfb if it exists (it loads much faster), else BASE.dnnf."""
    for ext in (".dnnfb", ".dnnf"):
        if os.path.exists(base + ext):
            return base + ext
    return None


def evidence_files(name, sources):
    out = []
    for src in sources:
        if os.path.isdir(src):
            out += sorted(f for f in glob.glob(os.path.join(src, name + "-*.txt")))
        elif os.path.isfile(src):
            out.append(src)
    return out


def make_session(sid, problem, circuit, evidence):
    name = os.path.splitext(os.path.basename(problem))[0]
    return {"id": sid, "name": name, "problem": os.path.abspath(problem),
            "circuit": os.path.abspath(circuit),
            "evidence": [os.path.abspath(e) for e in evidence_files(name, evidence)]}


def clara_sessions(clara, start):
    out = []
    for bench in ("TwoPackage", "SimpleGrid", "ThreePackage"):
        d = os.path.join(clara, bench)
        for pddl in sorted(glob.glob(os.path.join(d, "grid*.pddl"))):
            name = os.path.splitext(os.path.basename(pddl))[0]
            c = best_circuit(os.path.join(d, "circuits", name))
            if c:
                s = make_session(str(start + len(out)), pddl, c, [os.path.join(d, "evidence")])
                s["name"] = f"{bench}/{name}"
                out.append(s)
    return out


# --------------------------------------------------------------------- HTTP

class State:
    def __init__(self, sessions, lisp):
        self.sessions = {s["id"]: s for s in sessions}
        self.order = [s["id"] for s in sessions]
        self.lisp = lisp
        self.current = None


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "FiFOCircuitViz/1"

        def log_message(self, fmt, *args):       # quiet: one line per API call
            if self.path.startswith("/api/"):
                sys.stderr.write("%s %s\n" % (self.command, self.path))

        def send_json(self, obj, status=HTTPStatus.OK):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def fail(self, message, status=HTTPStatus.BAD_REQUEST):
            self.send_json({"error": message}, status)

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n > 10_000_000:
                raise ValueError("request too large")
            return json.loads(self.rfile.read(n) or b"{}")

        def session(self, sid):
            s = state.sessions.get(str(sid))
            if not s:
                raise KeyError(f"no session {sid!r}")
            return s

        def do_GET(self):
            url = urlparse(self.path)
            try:
                if url.path in ("/", "/index.html"):
                    return self.static("circuit.html")
                if url.path.lstrip("/") in STATIC:
                    return self.static(url.path.lstrip("/"))
                if url.path == "/api/sessions":
                    return self.send_json([{"id": i, "name": state.sessions[i]["name"],
                                            "evidence": [os.path.basename(e)
                                                         for e in state.sessions[i]["evidence"]]}
                                           for i in state.order])
                if url.path == "/api/evidence":
                    q = parse_qs(url.query)
                    s = self.session(q.get("id", [""])[0])
                    want = q.get("file", [""])[0]
                    path = next((e for e in s["evidence"] if os.path.basename(e) == want), None)
                    if not path:
                        return self.fail(f"{want!r} is not one of this session's evidence files")
                    text = open(path).read()
                    items, unsupported = parse_evidence(text)
                    return self.send_json({"file": want, "items": items,
                                           "unsupported": unsupported})
                if url.path == "/api/actions":
                    return self.send_json(state.lisp.call("(cv-actions)"))
                return self.fail("not found", HTTPStatus.NOT_FOUND)
            except (KeyError, ValueError, LispError) as e:
                return self.fail(str(e))

        def do_POST(self):
            url = urlparse(self.path)
            try:
                req = self.body()
                if url.path == "/api/load":
                    s = self.session(req.get("id"))
                    text = open(s["problem"]).read()
                    goals = goal_literals(text)
                    reply = state.lisp.load(s["circuit"], goals)
                    state.current = s["id"]
                    return self.send_json({"session": {"id": s["id"], "name": s["name"],
                                                       "circuit": os.path.basename(s["circuit"]),
                                                       "evidence": [os.path.basename(e)
                                                                    for e in s["evidence"]]},
                                           "problemName": os.path.basename(s["problem"]),
                                           "problem": text, "circuit": reply})
                if url.path == "/api/parse-evidence":
                    items, unsupported = parse_evidence(req.get("text", ""))
                    return self.send_json({"items": items, "unsupported": unsupported})
                if url.path == "/api/query":
                    lits = req.get("literals", [])
                    if not isinstance(lits, list) or not all(isinstance(l, str) for l in lits):
                        return self.fail("literals must be a list of strings")
                    return self.send_json(state.lisp.call(query_command(lits)))
                return self.fail("not found", HTTPStatus.NOT_FOUND)
            except (KeyError, ValueError, LispError) as e:
                return self.fail(str(e))

        def static(self, name):
            path = os.path.join(VIZ, name)
            data = open(path, "rb").read()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", STATIC[name])
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

    return Handler


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--session", nargs="+", action="append", default=[],
                    metavar="PROBLEM CIRCUIT [EVIDENCE]",
                    help="a problem, its saved circuit, and evidence files or directories")
    ap.add_argument("--clara", help="add every CLARA problem with a saved circuit")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--sbcl", default="sbcl")
    ap.add_argument("--heap-mb", type=int, default=8192)
    ap.add_argument("--open", action="store_true", help="open the page in a browser")
    a = ap.parse_args(argv)

    sessions = []
    for spec in a.session:
        if len(spec) < 2:
            ap.error("--session needs a problem and a circuit")
        sessions.append(make_session(str(len(sessions)), spec[0], spec[1], spec[2:]))
    if a.clara:
        sessions += clara_sessions(os.path.expanduser(a.clara), len(sessions))
    if not sessions:
        ex = os.path.join(VIZ, "circuit-examples")
        for pddl in sorted(glob.glob(os.path.join(ex, "*.pddl"))):
            name = os.path.splitext(os.path.basename(pddl))[0]
            c = best_circuit(os.path.join(ex, name))
            if c:
                sessions.append(make_session(str(len(sessions)), pddl, c, [ex]))
    if not sessions:
        ap.error("no sessions: give --session or --clara")

    fifo_lisp = os.environ.get("FIFO_LISP") or os.path.expanduser("~/lib/fifo/lisp")
    if not os.path.exists(os.path.join(fifo_lisp, "ddnnf.lisp")):
        ap.error(f"no FiFO lisp at {fifo_lisp} (set FIFO_LISP)")
    lisp = Lisp(fifo_lisp, a.sbcl, a.heap_mb,
                log=lambda s: sys.stderr.write("lisp: " + s + "\n") if s.strip() else None)
    lisp.start()
    httpd = ThreadingHTTPServer((a.host, a.port), make_handler(State(sessions, lisp)))
    url = f"http://{a.host}:{httpd.server_address[1]}/"
    print(f"circuit visualizer: {url}  ({len(sessions)} session(s))", flush=True)
    if a.open:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        lisp.stop()


if __name__ == "__main__":
    main()
