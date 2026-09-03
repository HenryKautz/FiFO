#!/bin/bash
#
# install-solvers.sh -- clone, build, and install the external solvers FiFO uses.
#
# For each solver: if a usable copy is already on PATH it is left alone (pass
# --all to rebuild it anyway); otherwise the repository is cloned into
# <FiFO>/Solvers/, built, and the resulting binary is copied into ~/bin.
#
# A failure in one solver never stops the others -- each is attempted in turn and
# a summary of what was installed, skipped, and what failed is printed at the end.
# Build output goes to <FiFO>/Solvers/logs/<solver>.log.
#
# See software-components.md for what each solver does and why FiFO needs it.

# NOTE: deliberately no `set -e` -- this script must survive a failed build and
# carry on to the next solver.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIFO_ROOT="$(cd "$SELF/.." && pwd)"
# Checkouts live in <FiFO>/Solvers by default.  FIFO_SOLVERS moves them, which
# is worth doing if the FiFO directory is inside a synced folder (Dropbox, etc.):
# these build trees run to hundreds of megabytes and are entirely regenerable.
# When this script is run from an INSTALLED copy (make install puts it in ~/bin)
# there is no FiFO directory above it, so fall back to ~/Solvers.
if [[ -f "$FIFO_ROOT/lisp/FiFO.lisp" ]]; then
  DEFAULT_SRC="$FIFO_ROOT/Solvers"
else
  DEFAULT_SRC="$HOME/Solvers"
fi
SRC_ROOT="${FIFO_SOLVERS:-$DEFAULT_SRC}"
LOG_DIR="$SRC_ROOT/logs"
BINDIR="$HOME/bin"

ALL_SOLVERS=(kissat tt-open-wbo-inc nuwls-c evalmaxsat wmaxcdcl rc2 addmc d4 walksat maxpre)

FORCE=0
DRY=0
SELECTED=()

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s%s%s\n' "$Y" "$*" "$N" >&2; }

print_usage() {
  cat <<EOF
usage: install-solvers.sh [--all] [--only <solver>]... [--bindir <dir>] [--dry-run] [--list]

Clone, build, and install the external solvers FiFO can use.  Repositories are
cloned into $SRC_ROOT and binaries installed into
$BINDIR.  Solvers already available are skipped unless --all is given, and a
failed build is reported but does not stop the remaining solvers.

  --all             (re)install every solver even if it is already available
  --only <solver>   install just this one; repeatable.  Names: ${ALL_SOLVERS[*]}
  --bindir <dir>    install binaries here instead of $BINDIR
  --dry-run         print what would be done without cloning or building
  --list            list the solvers, their repositories, and their status
  -h, --help        show this help

Set FIFO_SOLVERS to clone somewhere other than <FiFO>/Solvers -- worth doing when
the FiFO directory is inside a synced folder, since these build trees are large
and entirely regenerable.

Prerequisites: git, make, and a C/C++ compiler for all of them; cmake for addmc
and d4.  On macOS, d4 additionally needs Homebrew with 'brew install gcc gmp
boost cmake' -- its build uses the GNU toolchain, not Apple clang.

Most entries are a git clone plus a build; 'rc2' is instead 'pip install
python-sat', since bin/rc2-maxsat.py ships with FiFO and only the library it
wraps can be missing.  It is included because it is the DEFAULT solver for
marginals.sh --solver max-term.

Not covered here: the alternative solvers listed in software-components.md that
FiFO does not drive directly (Mallob, Painless, MaxHS, CP-SAT via
'pip install ortools').
EOF
}

die() { printf 'install-solvers.sh: %s\n\n' "$1" >&2; print_usage >&2; exit 2; }

# --- per-solver definitions -------------------------------------------------
# Each accessor is a case statement rather than an associative array so the
# script runs under the bash 3.2 that ships with macOS.

solver_desc() {
  case "$1" in
    kissat)           echo "CDCL SAT solver -- feasibility for solve/ and the planner's horizon search" ;;
    tt-open-wbo-inc)  echo "anytime weighted MaxSAT -- cost minimization (MAP inference)" ;;
    nuwls-c)          echo "anytime weighted MaxSAT -- NuWLS local search over tt-open-wbo-inc" ;;
    evalmaxsat)       echo "EXACT weighted MaxSAT -- core-guided, terminates with a proof of optimality" ;;
    wmaxcdcl)         echo "EXACT weighted MaxSAT -- branch-and-bound with clause learning (MSE 2023)" ;;
    rc2)              echo "EXACT weighted MaxSAT -- PySAT's RC2, the DEFAULT for --solver max-term" ;;
    maxpre)           echo "MaxPre 2 -- WCNF preprocessor (run in front of any MaxSAT solver)" ;;
    addmc)            echo "ADD-based weighted model counter -- exact marginals and Z" ;;
    d4)               echo "d4v2 decision-DNNF compiler -- exact marginals on structured instances" ;;
    walksat)          echo "WalkSAT v58 -mcsat -- approximate marginals by MC-SAT sampling" ;;
  esac
}

solver_repo() {
  case "$1" in
    kissat)           echo "https://github.com/arminbiere/kissat.git" ;;
    tt-open-wbo-inc)  echo "https://github.com/HenryKautz/tt-open-wbo-inc.git" ;;
    nuwls-c)          echo "https://github.com/shaowei-cai-group/NuWLS-c.git" ;;
    evalmaxsat)       echo "https://github.com/FlorentAvellaneda/EvalMaxSAT.git" ;;
    wmaxcdcl)         echo "https://github.com/jordicollcaballero/WMaxCDCL_Paper.git" ;;
    rc2)              echo "(pip) python-sat" ;;
    maxpre)           echo "https://bitbucket.org/coreo-group/maxpre2.git" ;;
    addmc)            echo "https://github.com/HenryKautz/ADDMC.git" ;;
    d4)               echo "https://github.com/HenryKautz/d4v2.git" ;;
    walksat)          echo "https://gitlab.com/HenryKautz/Walksat.git" ;;
  esac
}

# Branch to check out.  Empty means "whatever the repository's default is".
solver_branch() {
  case "$1" in
    # main carries the macOS work AND (since 5c31942) the <functional> include
    # that MaxSAT.h needs for std::function.  Named explicitly rather than left
    # empty so that a checkout made by an earlier version of this script -- which
    # briefly used the older macos-support branch -- gets re-pointed at main
    # instead of being pulled forward on the stale branch forever.
    tt-open-wbo-inc)  echo "main" ;;
    *)                echo "" ;;
  esac
}

# Directory name under Solvers/ for the checkout.
solver_dir() {
  case "$1" in
    kissat)           echo "kissat" ;;
    tt-open-wbo-inc)  echo "tt-open-wbo-inc" ;;
    nuwls-c)          echo "NuWLS-c" ;;
    evalmaxsat)       echo "EvalMaxSAT" ;;
    wmaxcdcl)         echo "WMaxCDCL" ;;
    rc2)              echo "" ;;
    maxpre)           echo "maxpre2" ;;
    addmc)            echo "ADDMC" ;;
    d4)               echo "d4v2" ;;
    walksat)          echo "Walksat" ;;
  esac
}

# The binaries this solver installs into BINDIR.
solver_bins() {
  case "$1" in
    kissat)           echo "kissat" ;;
    tt-open-wbo-inc)  echo "tt-open-wbo-inc-Glucose4_1 tt-open-wbo-inc-IntelSATSolver" ;;
    nuwls-c)          echo "nuwls-c" ;;
    evalmaxsat)       echo "EvalMaxSAT_bin" ;;
    wmaxcdcl)         echo "wmaxcdcl" ;;
    rc2)              echo "" ;;
    maxpre)           echo "maxpre" ;;
    addmc)            echo "addmc" ;;
    d4)               echo "d4" ;;
    walksat)          echo "walksat" ;;
  esac
}

# 0 when a USABLE copy is already available.  Presence on PATH is not always
# enough: an old walksat has no -mcsat, and FiFO locates d4 by path, not PATH.
solver_have() {
  local bin
  case "$1" in
    walksat)
      bin="$(command -v walksat 2>/dev/null)" || return 1
      # v57 and earlier print their help and ignore -mcsat, so probe for it.
      # Capture the help text rather than piping it: walksat exits non-zero after
      # printing help, and `grep -q` closes the pipe on its first match, so under
      # `set -o pipefail` a piped probe reports failure even when -mcsat IS there.
      local help
      help="$("$bin" -help </dev/null 2>&1 || true)"
      case "$help" in *-mcsat*) return 0 ;; esac
      HAVE_NOTE="$bin has no -mcsat (v57 or earlier)"
      return 1 ;;
    rc2)
      # bin/rc2-maxsat.py ships with FiFO; what can be missing is the library it
      # wraps.  This is the default solver for --solver max-term, so a plain
      # "install all the solvers" run has to cover it or that back end is broken
      # out of the box.
      python3 -c "import pysat.examples.rc2" >/dev/null 2>&1 && return 0
      HAVE_NOTE="python-sat is not installed (bin/rc2-maxsat.py cannot run)"
      return 1 ;;
    *)
      for bin in $(solver_bins "$1"); do
        command -v "$bin" >/dev/null 2>&1 || return 1
      done
      return 0 ;;
  esac
}

# Print any missing build prerequisites; empty output means we are good to go.
solver_prereq() {
  local missing=""
  for t in git make; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  case "$1" in
    kissat|walksat)
      command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || missing="$missing cc/gcc" ;;
    tt-open-wbo-inc|nuwls-c|maxpre)
      command -v g++ >/dev/null 2>&1 || missing="$missing g++" ;;
    evalmaxsat)
      command -v cmake >/dev/null 2>&1 || missing="$missing cmake"
      command -v g++   >/dev/null 2>&1 || missing="$missing g++" ;;
    wmaxcdcl)
      command -v g++ >/dev/null 2>&1 || missing="$missing g++" ;;
    rc2)
      command -v python3 >/dev/null 2>&1 || missing="$missing python3"
      command -v pip3 >/dev/null 2>&1 || python3 -m pip --version >/dev/null 2>&1 \
        || missing="$missing pip3" ;;
    addmc)
      command -v cmake >/dev/null 2>&1 || missing="$missing cmake"
      command -v g++   >/dev/null 2>&1 || missing="$missing g++" ;;
    d4)
      command -v cmake >/dev/null 2>&1 || missing="$missing cmake"
      if [[ "$(uname)" == "Darwin" ]]; then
        # d4's macOS build hard-codes the Homebrew GNU toolchain (build.sh sets
        # CC/CXX itself), so Apple clang will not do and the version matters.
        # A different Homebrew major version means editing d4's build files --
        # see its README.
        command -v brew   >/dev/null 2>&1 || missing="$missing brew"
        command -v g++-16 >/dev/null 2>&1 || missing="$missing g++-16(brew install gcc)"
      else
        command -v ninja >/dev/null 2>&1 || missing="$missing ninja"
      fi ;;
  esac
  printf '%s' "${missing# }"
}

# Build in $2 (the checkout) and install into BINDIR.  Return non-zero on failure.
# Everything here runs with stdout/stderr already redirected to the build log.
solver_build() {
  local name="$1" dir="$2"
  case "$name" in
    kissat)
      ( cd "$dir" && ./configure && make -j ) || return 1
      install_bin "$dir/build/kissat" kissat ;;

    tt-open-wbo-inc)
      # Mirror the fork's own `make install` target, which builds each SAT-solver
      # backend in turn (the choice is a Makefile variable, so it takes two
      # passes with a clean in between).  No -j: these Makefiles are not
      # parallel-safe.
      ( cd "$dir/code" \
        && make clean \
        && make \
        && make clean SOLVERDIR=glucose4.1 SOLVERNAME='"Glucose4_1"' NSPACE=Glucose \
        && make SOLVERDIR=glucose4.1 SOLVERNAME='"Glucose4_1"' NSPACE=Glucose ) || return 1
      install_bin "$dir/bin/tt-open-wbo-inc-Glucose4_1"     tt-open-wbo-inc-Glucose4_1 || return 1
      install_bin "$dir/bin/tt-open-wbo-inc-IntelSATSolver" tt-open-wbo-inc-IntelSATSolver ;;

    nuwls-c)
      # Needs gmpxx.h / libgmpxx, which on macOS live under the Homebrew prefix
      # that Apple clang does not search.  CPATH/LIBRARY_PATH add them without
      # overriding the Makefile's own CFLAGS/LFLAGS (a command-line CFLAGS= would
      # wipe the flags it needs).  Both are no-ops where the paths are standard.
      ( cd "$dir/code" && brew_env make ) || return 1
      # The Makefile already writes to ../bin/nuwls-c.
      install_bin "$dir/bin/nuwls-c" nuwls-c ;;

    evalmaxsat)
      # All dependencies (CaDiCaL, MCQD, CLI11) are vendored, so this is a plain
      # out-of-source cmake build with nothing to fetch.
      ( cd "$dir" && mkdir -p build && cd build && brew_env cmake .. && brew_env make -j ) || return 1
      install_bin "$dir/build/main/EvalMaxSAT_bin" EvalMaxSAT_bin ;;

    rc2)
      # A pip package rather than a build; nothing is cloned.
      ( python3 -m pip install --quiet python-sat ) || return 1
      python3 -c "import pysat.examples.rc2" >/dev/null 2>&1 \
        || { echo "python-sat installed but pysat.examples.rc2 will not import" >&2; return 1; } ;;

    wmaxcdcl)
      # Build the MaxSAT-Evaluation-2023 submission under WMaxCDCL/code, not the
      # WMaxCDCL-flags tree, which is the same solver with ablation switches for
      # the paper's experiments.
      #
      # The README says "make rs".  That is the STATIC target, and macOS ships no
      # static libc, so it cannot link there -- use the dynamic release target
      # instead and rename the result.  On Linux either works; "r" is used on both
      # so the build is the same everywhere.
      ( cd "$dir/WMaxCDCL/code/simp" && brew_env make r ) || return 1
      install_bin "$dir/WMaxCDCL/code/simp/wmaxcdcl_release" wmaxcdcl ;;

    maxpre)
      # Same treatment: main.cpp includes boost/iostreams/filter/gzip.hpp.
      ( cd "$dir" && brew_env make ) || return 1
      # src/Makefile ends with `mv src/maxpre maxpre`, so it lands at the root.
      install_bin "$dir/maxpre" maxpre ;;

    addmc)
      # INSTALL.sh untars the bundled CUDD/cxxopts, cmakes, and leaves ./addmc.
      # CMAKE_POLICY_VERSION_MINIMUM: ADDMC asks for cmake_minimum_required 2.8.9,
      # and CMake 4 removed compatibility with anything below 3.5, so a modern
      # cmake refuses to configure without it.
      ( cd "$dir" && CMAKE_POLICY_VERSION_MINIMUM=3.5 bash INSTALL.sh ) || return 1
      install_bin "$dir/addmc" addmc ;;

    d4)
      if [[ "$(uname)" == "Darwin" ]]; then
        # PaToH and a g++-built boost::program_options are not bundled.
        ( cd "$dir" && ./setup-macos-deps.sh ) || return 1
      fi
      ( cd "$dir" && ./build.sh ) || return 1
      ( cd "$dir/demo/compiler" && make c -j ) || return 1
      # FiFO wants the demo compiler executable; install it under the name d4.
      install_bin "$dir/demo/compiler/build/compiler" d4 ;;

    walksat)
      # The repo holds several versions; MC-SAT lives in v58.
      ( cd "$dir/Walksat_v58_MC-SAT" && make walksat ) || return 1
      install_bin "$dir/Walksat_v58_MC-SAT/walksat" walksat ;;
  esac
}

# --- plumbing ---------------------------------------------------------------

run() {  # echo and execute, honoring --dry-run
  if [[ "$DRY" -eq 1 ]]; then info "would run: $*"; return 0; fi
  "$@"
}

install_bin() {  # install_bin <built-path> <installed-name>
  local src="$1" name="$2"
  if [[ "$DRY" -eq 1 ]]; then info "would install $src -> $BINDIR/$name"; return 0; fi
  if [[ ! -x "$src" ]]; then
    echo "build finished but produced no executable at $src" >&2
    return 1
  fi
  mkdir -p "$BINDIR" && cp -f "$src" "$BINDIR/$name" && chmod +x "$BINDIR/$name"
}

brew_env() {  # brew_env <cmd>... : run CMD with the Homebrew prefix on the header
              # and library search paths.  Apple clang does not look there by
              # default, and several of these builds expect system-wide gmp /
              # boost.  A no-op when Homebrew is absent (e.g. Linux).
  local prefix
  if prefix="$(brew --prefix 2>/dev/null)" && [[ -n "$prefix" ]]; then
    CPATH="${CPATH:+$CPATH:}$prefix/include" \
    LIBRARY_PATH="${LIBRARY_PATH:+$LIBRARY_PATH:}$prefix/lib" "$@"
  else
    "$@"
  fi
}

clone_or_update() {  # clone_or_update <repo-url> <dir> [branch]
  local url="$1" dir="$2" branch="${3:-}"
  if [[ -d "$dir/.git" ]]; then
    info "updating existing checkout $dir"
    # An existing checkout may sit on the wrong branch (or predate our learning
    # that a non-default branch is the one we want), so re-point it first.
    if [[ -n "$branch" ]]; then
      run git -C "$dir" checkout "$branch" >/dev/null 2>&1 || \
        warn "could not switch $dir to branch $branch"
    fi
    # A pull failure (local edits, no network) is not fatal -- build what we have.
    run git -C "$dir" pull --ff-only >/dev/null 2>&1 || \
      warn "could not update $dir; building the existing checkout"
    return 0
  fi
  if [[ -e "$dir" ]]; then
    echo "$dir exists but is not a git checkout" >&2
    return 1
  fi
  if [[ -n "$branch" ]]; then
    info "cloning $url (branch $branch)"
    run git clone --branch "$branch" "$url" "$dir"
  else
    info "cloning $url"
    run git clone "$url" "$dir"
  fi
}

# Results, kept in parallel arrays (bash 3.2 has no associative arrays).
R_NAME=(); R_STATUS=(); R_NOTE=()
record() { R_NAME+=("$1"); R_STATUS+=("$2"); R_NOTE+=("$3"); }

# --- argument parsing -------------------------------------------------------
LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)      FORCE=1; shift ;;
    --only)     [[ $# -ge 2 ]] || die "--only needs a solver name"; SELECTED+=("$2"); shift 2 ;;
    --bindir)   [[ $# -ge 2 ]] || die "--bindir needs a directory"; BINDIR="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --list)     LIST=1; shift ;;
    -h|--help)  print_usage; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          die "unexpected argument: $1" ;;
  esac
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  SELECTED=("${ALL_SOLVERS[@]}")
else
  for s in "${SELECTED[@]}"; do
    found=0
    for k in "${ALL_SOLVERS[@]}"; do [[ "$s" == "$k" ]] && found=1; done
    [[ "$found" -eq 1 ]] || die "unknown solver: $s (known: ${ALL_SOLVERS[*]})"
  done
fi

if [[ "$LIST" -eq 1 ]]; then
  printf '%-18s %-9s %s\n' "SOLVER" "STATUS" "REPOSITORY"
  for s in "${ALL_SOLVERS[@]}"; do
    HAVE_NOTE=""
    if solver_have "$s"; then st="present"; else st="missing"; fi
    printf '%-18s %-9s %s\n' "$s" "$st" "$(solver_repo "$s")"
    printf '%-18s %-9s %s\n' "" "" "$(solver_desc "$s")"
    [[ -n "$HAVE_NOTE" ]] && printf '%-18s %-9s %s\n' "" "" "note: $HAVE_NOTE"
  done
  exit 0
fi

# --- run --------------------------------------------------------------------
say "FiFO solver installer"
say "  sources -> $SRC_ROOT"
say "  binaries -> $BINDIR"
[[ "$DRY" -eq 1 ]] && say "  (dry run -- nothing will be cloned, built, or installed)"
say ""

if [[ "$DRY" -eq 0 ]]; then
  mkdir -p "$SRC_ROOT" "$LOG_DIR" || { echo "cannot create $SRC_ROOT" >&2; exit 1; }
fi

# Every solver here but rc2 is a C++ build, so check the toolchain once rather
# than letting each one fail the same way.  The failure worth naming is a stale
# libc++ header directory: a Command Line Tools upgrade can leave a nearly empty
# /Library/Developer/CommandLineTools/usr/include/c++/v1 behind, and because
# clang searches that path before the SDK's, the directory EXISTING is enough to
# shadow the real headers.  Every build then dies on "'vector' file not found",
# which reads like a missing dependency rather than a broken install.
check_cxx() {
  local t out
  [[ "$DRY" -eq 1 ]] && return 0
  t="$(mktemp -d)"; printf '#include <vector>\nint main(){return 0;}\n' > "$t/probe.cpp"
  if out="$( (cd "$t" && brew_env "${CXX:-g++}" -std=c++11 -c probe.cpp -o probe.o) 2>&1 )"; then
    rm -rf "$t"; return 0
  fi
  rm -rf "$t"
  warn "the C++ toolchain cannot compile a program that includes <vector>:"
  printf '    %s\n' "$(printf '%s' "$out" | head -3)" >&2
  local stale=/Library/Developer/CommandLineTools/usr/include/c++/v1
  if [[ -d "$stale" && ! -e "$stale/vector" ]]; then
    warn "cause: $stale exists but is empty of headers -- a leftover from an older"
    warn "Command Line Tools.  clang searches it before the SDK, so it shadows the real"
    warn "libc++.  Move it aside (reversible) and every C++ build here starts working:"
    warn "    sudo mv $stale ${stale}.stale"
  else
    warn "try:  xcode-select --install   (or reinstall the Command Line Tools)"
  fi
  warn "continuing anyway -- the C++ builds below will very likely fail."
  say ""
  return 1
}
check_cxx || true

for s in "${SELECTED[@]}"; do
  step "$s -- $(solver_desc "$s")"

  HAVE_NOTE=""
  if [[ "$FORCE" -eq 0 ]] && solver_have "$s"; then
    where="$(command -v $(solver_bins "$s" | awk '{print $1}') 2>/dev/null)"
    info "already installed at ${where:-(found)} -- skipping (use --all to rebuild)"
    record "$s" skipped "${where:-already available}"
    continue
  fi
  [[ -n "$HAVE_NOTE" ]] && warn "$HAVE_NOTE -- replacing it"

  missing="$(solver_prereq "$s")"
  if [[ -n "$missing" ]]; then
    warn "missing build prerequisites: $missing"
    record "$s" failed "missing: $missing"
    continue
  fi

  dir="$SRC_ROOT/$(solver_dir "$s")"
  if [[ -z "$(solver_dir "$s")" ]]; then
    dir=""                      # pip package: nothing to clone
  elif ! clone_or_update "$(solver_repo "$s")" "$dir" "$(solver_branch "$s")"; then
    warn "clone failed"
    record "$s" failed "clone failed"
    continue
  fi

  if [[ "$DRY" -eq 1 ]]; then
    info "would build in $dir and install: $(solver_bins "$s")"
    record "$s" "would-install" "$dir"
    continue
  fi

  log="$LOG_DIR/$s.log"
  info "building (log: $log)"
  if solver_build "$s" "$dir" >"$log" 2>&1; then
    installed=""
    for b in $(solver_bins "$s"); do installed="$installed $BINDIR/$b"; done
    # A pip entry installs no binary of its own -- name the package instead of
    # printing an empty list.
    [[ -z "$installed" ]] && installed=" $(solver_repo "$s")"
    info "${G}installed:${N}${installed}"
    record "$s" installed "${installed# }"
  else
    warn "build failed -- last lines of $log:"
    tail -n 15 "$log" 2>/dev/null | sed 's/^/      /' >&2
    record "$s" failed "see $log"
  fi
done

# --- summary ----------------------------------------------------------------
say ""
say "${B}Summary${N}"
say "-------"
n_ok=0; n_skip=0; n_fail=0
for i in "${!R_NAME[@]}"; do
  case "${R_STATUS[$i]}" in
    installed)     c="$G"; n_ok=$((n_ok+1)) ;;
    skipped)       c="$Y"; n_skip=$((n_skip+1)) ;;
    would-install) c="$Y" ;;
    *)             c="$R"; n_fail=$((n_fail+1)) ;;
  esac
  printf '  %-18s %s%-13s%s %s\n' "${R_NAME[$i]}" "$c" "${R_STATUS[$i]}" "$N" "${R_NOTE[$i]}"
done
say ""
say "  $n_ok installed, $n_skip already present, $n_fail failed"

# Post-install notes that are easy to miss.
notes=()
case ":$PATH:" in *":$BINDIR:"*) ;; *) notes+=("$BINDIR is not on your PATH -- add it.") ;; esac
if [[ ${#notes[@]} -gt 0 ]]; then
  say ""
  say "${B}Notes${N}"
  for n in "${notes[@]}"; do say "  - $n"; done
fi

[[ "$n_fail" -eq 0 ]]
