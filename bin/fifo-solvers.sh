#!/bin/bash
#
# fifo-solvers.sh -- shared solver/counter validation for the FiFO CLIs.
#
# This file is meant to be *sourced*, not executed.  Every place a CLI accepts a
# solver, counter or preprocessor NAME goes through here, so the checking and the
# accepted spellings are the same everywhere:
#
#   _fifo_require_solver <name> <sat|maxsat> <script>   validate, then print the
#                                                       resolved binary name
#   _fifo_require_counter <name> <marginals|planner> <script>
#   _fifo_require_preprocessor <name> <script>
#   _fifo_resolve_solver <name>                         abbreviation -> binary
#   _fifo_solver_kind <name>                            sat | maxsat | unknown
#
# The names, their abbreviations and their kinds all come from lisp/solvers.dat,
# which lisp/FiFO.lisp reads too -- so the shell and the Lisp cannot drift.  This
# file used to carry its own copy of the abbreviation table with a comment asking
# that the two be kept in step; that was a request, not a mechanism.
#
# Why the kind check matters: the two solver families read different files.  A
# plain SAT solver expects a DIMACS "p cnf" header and will choke on -- or
# silently misread -- a weighted CNF, while a MaxSAT solver needs the weighted
# format and has nothing to optimize without it.  Getting it wrong is QUIET
# rather than loud: weights written into a plain .cnf become `cw` comment lines,
# which a SAT solver ignores while happily returning a non-optimal model.
#
# An unrecognised name is refused, and the message says how to add one.  A name
# containing "/" is exempt: it is an explicit path the caller pointed at, so it
# is checked for existence and classified by its basename, but needs no entry.
# (marginals.sh's own default, bin/rc2-maxsat.py, is such a path.)
#
# bash 3.2 compatible -- /bin/bash on macOS, which the test suites exercise --
# so no associative arrays and no ${var,,}.

_FIFO_SOLVERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fallback classification for binaries the table does not name (a path, or a
# local build).  Only used to give a better error; the table is authoritative.
_FIFO_SAT_PATTERNS='kissat cadical minisat glucose lingeling cryptominisat picosat mallob painless march plingeling treengeling'
_FIFO_MAXSAT_PATTERNS='tt-open-wbo open-wbo tt-glucose tt-intelsat nuwls spb-maxsat maxhs uwrmaxsat evalmaxsat wmaxcdcl maxcdcl cashwmaxsat loandra rc2 maxino qmaxsat'

_fifo_lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# --- the shared table -------------------------------------------------------

# When FIFO_LISP is set it is AUTHORITATIVE: the table must come from the same
# directory as the FiFO.lisp that will be loaded.  Falling back to another
# directory's table would reintroduce exactly the drift this file exists to stop
# -- the shell resolving names from one table while the Lisp reads another.
# The search list applies only when FIFO_LISP is unset.
_fifo_table_path() {
  local d
  if [[ -n "${FIFO_LISP:-}" ]]; then
    [[ -f "$FIFO_LISP/solvers.dat" ]] && { printf '%s' "$FIFO_LISP/solvers.dat"; return 0; }
    return 1
  fi
  for d in "$_FIFO_SOLVERS_DIR/../lisp" "$HOME/lib/fifo/lisp"; do
    [[ -f "$d/solvers.dat" ]] && { printf '%s' "$d/solvers.dat"; return 0; }
  done
  return 1
}

# Read solvers.dat once per process into _FIFO_TABLE (comments and blanks
# stripped).  A missing table is a hard error naming the path: falling back to an
# empty one would make every name "unrecognised", which is a confusing way to say
# that a file of the library is missing.
_fifo_load_solver_table() {
  [[ -n "${_FIFO_TABLE:-}" ]] && return 0
  local path
  if ! path="$(_fifo_table_path)"; then
    if [[ -n "${FIFO_LISP:-}" ]]; then
      cat >&2 <<EOF
fifo: solvers.dat not found in \$FIFO_LISP ($FIFO_LISP).

  It is part of the FiFO library and lists the solvers and counters the scripts
  accept.  FIFO_LISP is authoritative -- the table has to come from the same
  directory as the FiFO.lisp being loaded, or the two could disagree -- so no
  other location is tried.

  Run 'make install', or point FIFO_LISP at a checkout's lisp/ directory.
EOF
    else
      cat >&2 <<EOF
fifo: solvers.dat not found.

  It is part of the FiFO library and lists the solvers and counters the scripts
  accept.  Looked in:
      $_FIFO_SOLVERS_DIR/../lisp
      $HOME/lib/fifo/lisp

  Run 'make install', or set FIFO_LISP to a checkout's lisp/ directory.
EOF
    fi
    return 1
  fi
  _FIFO_TABLE_PATH="$path"
  _FIFO_TABLE="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$path")"
  if [[ -z "$_FIFO_TABLE" ]]; then
    echo "fifo: $path contains no entries" >&2
    return 1
  fi
  return 0
}

# _fifo_lookup <type> <name> -> the whole matching line, matching the canonical
# name or any of its abbreviations, case-insensitively.
_fifo_lookup() {
  _fifo_load_solver_table || return 1
  printf '%s\n' "$_FIFO_TABLE" | awk -v t="$1" -v n="$2" '
    function lc(s) { return tolower(s) }
    lc($1) != lc(t) { next }
    lc($2) == lc(n) { print; exit }
    $5 != "-" {
      m = split($5, a, ",")
      for (i = 1; i <= m; i++) if (lc(a[i]) == lc(n)) { print; exit }
    }'
}

_fifo_field() { printf '%s' "$1" | awk -v i="$2" '{print $i; exit}'; }

# _fifo_names <type> [<kind>] -> "canonical (abbrev), canonical, ..." for messages
_fifo_names() {
  _fifo_load_solver_table || return 1
  printf '%s\n' "$_FIFO_TABLE" | awk -v t="$1" -v k="${2:-}" '
    tolower($1) != tolower(t) { next }
    k != "" && tolower($3) != tolower(k) { next }
    { if ($5 != "-") printf "%s%s (%s)", sep, $2, $5; else printf "%s%s", sep, $2; sep = ", " }
    END { print "" }'
}

_fifo_is_path() { case "${1:-}" in */*) return 0 ;; *) return 1 ;; esac; }

# --- solvers ----------------------------------------------------------------

# Abbreviation (or exact name) -> the executable actually invoked.  A path and an
# unknown name are returned unchanged; validation is _fifo_require_solver's job.
_fifo_resolve_solver() {
  local line
  _fifo_is_path "${1:-}" && { printf '%s' "$1"; return 0; }
  line="$(_fifo_lookup solver "${1:-}")"
  if [[ -n "$line" ]]; then _fifo_field "$line" 2; else printf '%s' "${1:-}"; fi
}

# sat | maxsat | unknown.  The table first; then the name patterns, so a path or
# a local build still classifies well enough to warn about.
_fifo_solver_kind() {
  local line name lower p
  line="$(_fifo_lookup solver "${1:-}")"
  if [[ -n "$line" ]]; then _fifo_field "$line" 3; return 0; fi
  name="${1:-}"; name="${name##*/}"
  lower="$(_fifo_lower "$name")"
  # MaxSAT first: "tt-open-wbo-inc-Glucose4_1" contains "glucose", and it is a
  # MaxSAT solver that happens to be built on the Glucose SAT engine.
  for p in $_FIFO_MAXSAT_PATTERNS; do
    case "$lower" in *"$p"*) echo maxsat; return 0 ;; esac
  done
  for p in $_FIFO_SAT_PATTERNS; do
    case "$lower" in *"$p"*) echo sat; return 0 ;; esac
  done
  echo unknown
}

_fifo_kind_word() { [[ "$1" == "sat" ]] && echo "SAT" || echo "MaxSAT"; }

# _fifo_require_solver <name> <sat|maxsat> <script>
# On success prints the resolved binary name and returns 0; otherwise explains
# and returns 1.
_fifo_require_solver() {
  local name="$1" want="$2" self="$3" line bin kind want_word got_word install
  _fifo_load_solver_table || return 1
  want_word="$(_fifo_kind_word "$want")"

  if _fifo_is_path "$name"; then
    # An explicit path: the caller means this file, so no table entry is needed.
    if ! command -v "$name" >/dev/null 2>&1 && [[ ! -x "$name" ]]; then
      echo "$self: no such solver: '$name'" >&2
      return 1
    fi
    kind="$(_fifo_solver_kind "$name")"
    if [[ "$kind" != "unknown" && "$kind" != "$want" ]]; then
      _fifo_explain_kind "$name" "$kind" "$want" "$self"; return 1
    fi
    printf '%s' "$name"; return 0
  fi

  line="$(_fifo_lookup solver "$name")"
  if [[ -z "$line" ]]; then
    got_word="$(_fifo_solver_kind "$name")"
    {
      echo "$self: unknown solver '$name'."
      [[ "$got_word" != "unknown" ]] && echo "  (it looks like a $got_word solver, but it is not in FiFO's table)"
      echo
      echo "  Known $want_word solvers: $(_fifo_names solver "$want")"
      echo
      echo "  To use another, add a line to"
      echo "      $_FIFO_TABLE_PATH"
      echo "  following the format documented in its header, e.g."
      echo "      solver  <binary-name>  $want  exact  <abbrev>  <installer-name>"
      echo "  or give a path (./my-solver, /opt/bin/my-solver), which is used as given."
    } >&2
    return 1
  fi

  kind="$(_fifo_field "$line" 3)"
  if [[ "$kind" != "$want" ]]; then
    _fifo_explain_kind "$name" "$kind" "$want" "$self"; return 1
  fi

  bin="$(_fifo_field "$line" 2)"
  install="$(_fifo_field "$line" 6)"
  # A "bundled" solver ships in bin/ rather than being installed on PATH, so
  # look for it beside this file before deciding it is missing.  rc2-maxsat.py
  # is one, and it is max-term's default.
  if [[ "$(_fifo_field "$line" 4)" == *bundled* ]] \
     && ! command -v "$bin" >/dev/null 2>&1 && [[ -x "$_FIFO_SOLVERS_DIR/$bin" ]]; then
    printf '%s' "$_FIFO_SOLVERS_DIR/$bin"; return 0
  fi
  if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -x "$bin" ]]; then
    {
      echo "$self: $want_word solver '$bin' is not installed."
      [[ "$name" != "$bin" ]] && echo "  ('$name' is an abbreviation for it.)"
      if [[ "$install" != "-" ]]; then
        echo "  Install it with:"
        echo "      bin/install-solvers.sh --only $install"
      fi
    } >&2
    return 1
  fi
  printf '%s' "$bin"
}

# The wording here is load-bearing: tests/run-test-cli.sh greps for
# "is a MaxSAT solver" and "is a plain SAT solver".
_fifo_explain_kind() {
  local name="$1" kind="$2" want="$3" self="$4"
  if [[ "$want" == "sat" ]]; then
    cat >&2 <<EOF
$self: '$name' is a MaxSAT solver, but a plain SAT solver is needed here.

  This step writes a plain DIMACS "p cnf" file, which has no weights to minimize
  -- a MaxSAT solver has nothing to optimize there, and may not accept the file
  at all.

  Known SAT solvers: $(_fifo_names solver sat)
EOF
  else
    cat >&2 <<EOF
$self: '$name' is a plain SAT solver, but a MaxSAT solver is needed here.

  This step writes a weighted CNF (hard clauses prefixed 'h', soft clauses
  prefixed by their weight).  A SAT solver cannot read that format, and even
  where it can it has no notion of an objective to minimize.

  Known MaxSAT solvers: $(_fifo_names solver maxsat)
EOF
  fi
}

# --- counters ---------------------------------------------------------------

# _fifo_require_counter <name> <marginals|planner> <script>
# Prints the canonical counter name on success.  CONTEXT "planner" excludes the
# counters flagged no-planner.
_fifo_require_counter() {
  local name="$1" context="$2" self="$3" line flags bin install
  _fifo_load_solver_table || return 1
  line="$(_fifo_lookup counter "$name")"
  flags=""
  [[ -n "$line" ]] && flags="$(_fifo_field "$line" 4)"

  if [[ -z "$line" ]] || { [[ "$context" == "planner" ]] && [[ "$flags" == *no-planner* ]]; }; then
    {
      if [[ -n "$line" ]]; then
        echo "$self: counter '$name' is not available here."
        echo "  It is a marginals.sh counter: it needs a named query, while this reports"
        echo "  every atom -- which for max-term would be 1+n MaxSAT solves."
      else
        echo "$self: unknown counter '$name'."
      fi
      echo
      echo "  Available counters: $(_fifo_counter_names "$context")"
      echo
      echo "  A counter is NAMED, never a path.  To add one, edit"
      echo "      $_FIFO_TABLE_PATH"
    } >&2
    return 1
  fi

  bin="$(_fifo_field "$line" 2)"
  install="$(_fifo_field "$line" 6)"
  # Which binary a counter needs is in the table (needs:BIN), not hardcoded here:
  # it is not always the counter's own name -- mc-sat runs walksat.
  local prog
  prog="$(printf '%s' "$flags" | tr ',' '\n' | sed -n 's/^needs://p' | head -1)"
  if [[ -n "$prog" ]]; then
    if ! command -v "$prog" >/dev/null 2>&1; then
      {
        echo "$self: counter '$bin' needs '$prog', which is not on PATH."
        echo "  Install it with:"
        echo "      bin/install-solvers.sh --only $install"
      } >&2
      return 1
    fi
  fi
  printf '%s' "$bin"
}

_fifo_counter_names() {
  _fifo_load_solver_table || return 1
  printf '%s\n' "$_FIFO_TABLE" | awk -v ctx="${1:-marginals}" '
    tolower($1) != "counter" { next }
    ctx == "planner" && $4 ~ /no-planner/ { next }
    { if ($5 != "-") printf "%s%s (%s)", sep, $2, $5; else printf "%s%s", sep, $2; sep = ", " }
    END { print "" }'
}

# --- preprocessors ----------------------------------------------------------

_fifo_require_preprocessor() {
  local name="$1" self="$2" line bin install
  _fifo_load_solver_table || return 1
  if _fifo_is_path "$name"; then
    if ! command -v "$name" >/dev/null 2>&1 && [[ ! -x "$name" ]]; then
      echo "$self: no such preprocessor: '$name'" >&2; return 1
    fi
    printf '%s' "$name"; return 0
  fi
  line="$(_fifo_lookup preproc "$name")"
  if [[ -z "$line" ]]; then
    {
      echo "$self: unknown preprocessor '$name'."
      echo "  Known: $(_fifo_names preproc)"
      echo "  To add one, edit $_FIFO_TABLE_PATH; or give a path, used as given."
    } >&2
    return 1
  fi
  bin="$(_fifo_field "$line" 2)"; install="$(_fifo_field "$line" 6)"
  if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -x "$bin" ]]; then
    {
      echo "$self: preprocessor '$bin' is not installed."
      [[ "$install" != "-" ]] && echo "  Install it with:  bin/install-solvers.sh --only $install"
    } >&2
    return 1
  fi
  printf '%s' "$bin"
}
