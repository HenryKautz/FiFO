#!/usr/bin/env python3
"""circuit_server.py -- the circuit visualizer's server.

Serves circuit.html and its scripts, and answers the page's JSON requests by
driving one long-running SBCL process (FiFO + ddnnf.lisp + recognition-goal.lisp
+ circuit-server.lisp) that holds the loaded circuit.  Standard library only.
See CIRCUIT-PLAN.md.

    circuit_server.py --session PROBLEM.pddl CIRCUIT.dnnf[b] [EVIDENCE...]
                      [--session ...] [--clara DIR] [--port 8765] [--open]

EVIDENCE is evidence files or directories; a directory contributes the files
whose names start with the problem's name.  Offered are only the files with a
literal the page can clamp, and not those a longer file for the same solution
extends (the page steps through the longer one): see useful_evidence.  Every
file stays available by name (the page's ?evidence=FILE), and files named one
by one are always offered.  --clara DIR adds every problem of
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
LOAD_TIMEOUT = 1800        # seconds: loading a big circuit, also after a restart
QUERY_TIMEOUT = 600


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


def parse_evidence(text):
    """An evidence file as pinned literals in slice order.  Returns
    (items, unsupported): items [{literal, slice, positive}], unsupported the
    forms the page cannot clamp (ordering evidence, compound formulas).

    As everywhere in FiFO, an evidence file is ONE form -- (and ...) of
    literals, or a single literal: a file of several forms is refused (FiFO
    reads only the first), and so is (not A B) (it reads as (not A))."""
    forms = read_sexprs(text)
    if len(forms) > 1:
        raise ValueError(f"the evidence file has {len(forms)} top-level forms; FiFO reads "
                         "only the first.  Wrap the literals in one (and ...).")
    items, unsupported = [], []

    def literal(f):
        if isinstance(f, list) and f and f[0] == "not" and len(f) != 2:
            unsupported.append(show(f) + "  -- (not ...) takes one argument")
            return
        neg = isinstance(f, list) and f and f[0] == "not"
        atom = f[1] if neg else f
        if (isinstance(atom, list) and len(atom) == 3 and atom[0] in ("occurs", "holds")
                and isinstance(atom[2], str) and re.fullmatch(r"\d+", atom[2])):
            items.append({"literal": show(f), "slice": int(atom[2]), "positive": not neg})
        else:
            unsupported.append(show(f))

    for f in forms:
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


def lisp_string(s):
    """S as a Lisp string literal: backslash and double quote escaped."""
    if "\n" in s:
        raise ValueError("a string sent to Lisp is one line")
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_command(circuit, problem):
    return f"(cv-load {lisp_string(circuit)} {lisp_string(problem)})"


def query_command(literals):
    return f"(cv-query ({' '.join(lisp_string(l) for l in literals)}))"


class Lisp:
    """One SBCL child running cv-serve: a command per line in, one @@REPLY line
    out.  Restarted (and the current circuit reloaded) if it dies.

    Replies are read straight from the pipe's file descriptor into our own
    buffer: select() on the fd and readline() on a buffered text wrapper do not
    mix -- a log line and the reply arriving in one chunk would leave the reply
    in the wrapper's buffer while select() waits on an empty pipe."""

    def __init__(self, fifo_lisp, sbcl="sbcl", heap_mb=8192, log=None):
        self.fifo_lisp, self.sbcl, self.heap_mb = fifo_lisp, sbcl, heap_mb
        self.proc = None
        self.buf = b""
        self.lock = threading.Lock()
        self.log = log or (lambda s: None)
        self.loaded = None                  # (circuit, problem) to reload after a restart

    def start(self):
        lisp = self.fifo_lisp
        cmd = [self.sbcl, "--dynamic-space-size", str(self.heap_mb),
               "--control-stack-size", "200MB", "--noinform", "--disable-debugger",
               "--eval", f'(load "{lisp}/FiFO.lisp")',
               "--eval", f'(load "{lisp}/ddnnf.lisp")',
               "--eval", f'(load "{lisp}/recognition-goal.lisp")',
               "--eval", f'(load "{os.path.join(HERE, "circuit-server.lisp")}")',
               "--eval", "(cv-serve)", "--eval", "(sb-ext:exit)"]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, bufsize=0)
        self.buf = b""

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _readline(self, deadline):
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                self.proc.kill()
                raise LispError("no reply from Lisp in time; it was stopped "
                                "(it restarts on the next request)")
            ready, _, _ = select.select([fd], [], [], left)
            if not ready:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                self.proc.wait()
                raise LispError(f"the Lisp process exited (code {self.proc.returncode}); "
                                "it restarts on the next request")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", "replace")

    def _send(self, command, timeout):
        try:
            self.proc.stdin.write((command + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            self.proc.kill()
            raise LispError(f"the Lisp process is gone ({e}); it restarts on the next request")
        deadline = time.monotonic() + timeout
        while True:
            line = self._readline(deadline)
            if line.startswith(REPLY):
                reply = json.loads(line[len(REPLY):])
                if "error" in reply:
                    raise LispError(reply["error"])
                return reply
            if line.strip():
                self.log(line)

    def _call(self, command, timeout):
        if not self.alive():
            self.start()
            if self.loaded and not command.startswith("(cv-load"):
                self._send(load_command(*self.loaded), LOAD_TIMEOUT)
        return self._send(command, timeout)

    def call(self, command, timeout=QUERY_TIMEOUT):
        with self.lock:
            return self._call(command, timeout)

    def load(self, circuit, problem):
        with self.lock:
            reply = self._call(load_command(circuit, problem), LOAD_TIMEOUT)
            self.loaded = (circuit, problem)
            return reply

    def stop(self):
        if self.alive():
            try:
                self.proc.stdin.write(b"(cv-quit)\n")
                self.proc.stdin.flush()
                self.proc.wait(5)
            except Exception:
                self.proc.kill()


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
            out += sorted(glob.glob(os.path.join(src, name + "-*.txt")))
        elif os.path.isfile(src):
            out.append(src)
        else:
            raise ValueError(f"evidence {src!r} is neither a file nor a directory")
    return out


def evidence_stem(path):
    """The solution an evidence file observes: its name without -obsK.txt
    (evgen's NAME-obsK.txt holds the first K observations of one solution);
    any other file is its own."""
    m = re.fullmatch(r"(.*)-obs\d+\.txt", os.path.basename(path))
    return m.group(1) if m else path


def useful_evidence(paths):
    """The evidence files worth offering: PATHS minus those the page could do
    nothing with -- no literal it can clamp (an -ordK.txt file is one ordering
    form) -- and those whose literals are a prefix of a longer file's for the
    SAME solution (obs1 and obs2 when obs3 extends them: the page steps through
    obs3 anyway).  Files for different solutions are all kept, even when one
    starts like another.  A file that does not parse is kept, so choosing it
    shows why.  Returns (kept, hidden count)."""
    parsed = {}
    by_stem = {}
    for p in paths:
        try:
            items, _ = parse_evidence(open(p).read())
            parsed[p] = [(it["literal"], it["slice"]) for it in items]
        except (OSError, ValueError, UnicodeDecodeError):
            parsed[p] = None
        by_stem.setdefault(evidence_stem(p), []).append(p)
    kept = []
    for p in paths:
        mine = parsed[p]
        if mine is None:
            kept.append(p)
            continue
        if not mine:
            continue
        if any(q != p and parsed[q] is not None and len(parsed[q]) > len(mine)
               and parsed[q][:len(mine)] == mine
               for q in by_stem[evidence_stem(p)]):
            continue
        kept.append(p)
    return kept, len(paths) - len(kept)


def make_session(sid, problem, circuit, evidence):
    """A session: the problem, its circuit, and its evidence files -- ALL of
    them, any of which the page may open by name; the menu's list (menu_files)
    is worked out when the session is first loaded.  Files named one by one
    (not found in a directory) are always offered."""
    for what, path in (("problem", problem), ("circuit", circuit)):
        if not os.path.isfile(path):
            raise ValueError(f"the {what} {path!r} does not exist")
    name = os.path.splitext(os.path.basename(problem))[0]
    named = [os.path.abspath(e) for e in evidence if os.path.isfile(e)]
    return {"id": sid, "name": name, "problem": os.path.abspath(problem),
            "circuit": os.path.abspath(circuit),
            # once each, though a file be named and also in a directory given
            "evidence": list(dict.fromkeys(os.path.abspath(e) for e in evidence_files(name, evidence))),
            "named": named, "menu": None}


def menu_files(s):
    """The evidence files the session's menu offers (useful_evidence, the
    files named one by one kept regardless), and how many it leaves out;
    computed once, on first use, so startup does not read every file."""
    if s["menu"] is None:
        kept, _ = useful_evidence(s["evidence"])
        kept = set(kept) | set(s["named"])
        menu = [e for e in s["evidence"] if e in kept]
        s["menu"] = (menu, len(s["evidence"]) - len(menu))
    return s["menu"]


def clara_sessions(clara, start):
    out = []
    for bench in ("TwoPackage", "SimpleGrid", "ThreePackage"):
        d = os.path.join(clara, bench)
        for pddl in sorted(glob.glob(os.path.join(d, "grid*.pddl"))):
            name = os.path.splitext(os.path.basename(pddl))[0]
            c = best_circuit(os.path.join(d, "circuits", name))
            if c:
                ev = os.path.join(d, "evidence")
                s = make_session(str(start + len(out)), pddl, c, [ev] if os.path.isdir(ev) else [])
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
        self.lock = threading.Lock()    # a load and the queries that follow it

    def session(self, sid):
        s = self.sessions.get(str(sid))
        if not s:
            raise KeyError(f"no session {sid!r}")
        return s

    def load(self, sid):
        s = self.session(sid)
        reply = self.lisp.load(s["circuit"], s["problem"])
        self.current = s["id"]
        return s, reply

    def ensure(self, sid):
        """Make SID the loaded session (reloading it if another tab loaded a
        different one meanwhile): a query must run on the circuit its page shows."""
        if str(sid) != self.current:
            self.load(sid)


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

        def guarded(self, fn):
            try:
                fn()
            except (KeyError, ValueError, LispError) as e:
                self.fail(str(e).strip("'\""))
            except Exception as e:                # never leave the page without a reply
                self.fail(f"server error: {type(e).__name__}: {e}", HTTPStatus.INTERNAL_SERVER_ERROR)

        def do_GET(self):
            self.guarded(self.get)

        def do_POST(self):
            self.guarded(self.post)

        def get(self):
            url = urlparse(self.path)
            q = parse_qs(url.query)
            if url.path in ("/", "/index.html"):
                return self.static("circuit.html")
            if url.path.lstrip("/") in STATIC:
                return self.static(url.path.lstrip("/"))
            if url.path == "/api/sessions":
                # the evidence menu comes with /api/load (menu_files)
                return self.send_json([{"id": i, "name": state.sessions[i]["name"]}
                                       for i in state.order])
            if url.path == "/api/evidence":
                s = state.session(q.get("id", [""])[0])
                want = q.get("file", [""])[0]
                path = next((e for e in s["evidence"] if os.path.basename(e) == want), None)
                if not path:
                    return self.fail(f"{want!r} is not one of this session's evidence files")
                items, unsupported = parse_evidence(open(path).read())
                return self.send_json({"file": want, "items": items, "unsupported": unsupported})
            if url.path == "/api/actions":
                with state.lock:
                    state.ensure(q.get("id", [""])[0])
                    return self.send_json(state.lisp.call("(cv-actions)"))
            return self.fail("not found", HTTPStatus.NOT_FOUND)

        def post(self):
            url = urlparse(self.path)
            req = self.body()
            if url.path == "/api/load":
                with state.lock:
                    s, reply = state.load(req.get("id"))
                menu, hidden = menu_files(s)
                return self.send_json({"session": {"id": s["id"], "name": s["name"],
                                                   "circuit": os.path.basename(s["circuit"]),
                                                   "evidence": [os.path.basename(e) for e in menu],
                                                   "hidden": hidden},
                                       "problemName": os.path.basename(s["problem"]),
                                       "problem": open(s["problem"]).read(), "circuit": reply})
            if url.path == "/api/parse-evidence":
                items, unsupported = parse_evidence(req.get("text", ""))
                return self.send_json({"items": items, "unsupported": unsupported})
            if url.path == "/api/query":
                lits = req.get("literals", [])
                if not isinstance(lits, list) or not all(isinstance(l, str) for l in lits):
                    return self.fail("literals must be a list of strings")
                if "id" not in req:
                    return self.fail("a query names its session (id)")
                with state.lock:
                    state.ensure(req["id"])
                    return self.send_json(state.lisp.call(query_command(lits)))
            return self.fail("not found", HTTPStatus.NOT_FOUND)

        def static(self, name):
            data = open(os.path.join(VIZ, name), "rb").read()
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
    try:
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
    except ValueError as e:
        ap.error(str(e))
    if not sessions:
        ap.error("no sessions: give --session or --clara")

    fifo_lisp = os.environ.get("FIFO_LISP") or os.path.expanduser("~/lib/fifo/lisp")
    for f in ("FiFO.lisp", "ddnnf.lisp", "recognition-goal.lisp"):
        if not os.path.exists(os.path.join(fifo_lisp, f)):
            ap.error(f"no {f} in {fifo_lisp} (set FIFO_LISP)")
    lisp = Lisp(fifo_lisp, a.sbcl, a.heap_mb,
                log=lambda s: sys.stderr.write("lisp: " + s + "\n"))
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
