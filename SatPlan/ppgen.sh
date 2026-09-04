#!/bin/bash
#
# ppgen.sh -- generate a planning problem for the clara-logistics domain.
#
# Two topologies:
#
#   --style clique   NUMBER-CLIQUES groups of CLIQUE-SIZE places, each group
#                    fully connected by two-way roads, one airport per group.
#                    Packages, airplanes and trucks are spread evenly over the
#                    groups (any two differ by at most one), at a random place
#                    within the group.
#
#   --style grid     an M x N grid of places with two-way roads between
#                    orthogonally adjacent cells.  Airports are placed to
#                    maximize their minimum pairwise distance; trucks and
#                    packages go anywhere at random; airplanes are spread
#                    evenly over the airports.
#
# Every pair of airports is joined by a two-way route in both styles.  Goals
# place each package somewhere other than where it started.
#
# The problem is written to stdout unless --output names a file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PPGEN="$SCRIPT_DIR/ppgen.lisp"

print_usage() {
  cat <<'EOF'
usage: ppgen.sh --style <grid|clique> [options]

  --style <grid|clique>     which topology to generate (required)

clique style:
  --clique-size <N>         places in each clique of roads (required)
  --number-cliques <N>      number of cliques (required)
  --trucks <N>              default: number of cliques
  --airplanes <N>           default: number of cliques
  --packages <N>            default: number of cliques

grid style:
  --dimensions <M> <N>      grid size (required)
  --airports <N>            default 2
  --airplanes <N>           default: number of airports
  --trucks <N>              default: number of airports
  --packages <N>            default: number of airports

both styles:
  --drive-cost <R>          cost of one drive, default 1
  --fly-cost <R>            cost of one flight, default 3
  --preferences none        conjunctive goal: every package must be delivered
  --preferences <L> <H>     disjunctive goal instead -- ONE delivery is required,
                            and each is preferred by a weight, equally spaced
                            from L to H and handed out in random order
  --goals-per-package <N> <M>
                            N destinations per package (default 1) instead of one,
                            any of which delivers it; only one can ever hold, since
                            a package is at one place.  M (0 or 1, default 0) is the
                            minimum number of HARD goals per package: 0 leaves the
                            usual single disjunction over every goal, 1 requires
                            each package to reach one of its own destinations
                            regardless of cost.  N > 1 or M = 1 REQUIRES
                            --preferences
  --maxgoals <N>            require at most N deliveries in the goal state.
                            At most 3.  REQUIRES --preferences: the default goal
                            demands every delivery, so a cap on the number
                            delivered would be contradictory or vacuous.
                            Default: the number of packages, i.e. no limit
  --seed <N>                seed the generator, so a run is reproducible.  With
                            no --seed the clock supplies one, and the value used
                            is recorded in the generated file
  --name <name>             problem name, default <style>-problem
  --domain <name>           domain named in (:domain ...), default clara-logistics
  --output <file>, -o       write here instead of stdout
  --help, -h                this message

examples:
  ppgen.sh --style clique --clique-size 4 --number-cliques 3 --seed 1
  ppgen.sh --style grid --dimensions 5 5 --airports 3 --packages 4 -o pb2.pddl
  ppgen.sh --style grid --dimensions 4 4 --packages 3 --preferences 1 5
  ppgen.sh --style grid --dimensions 5 5 --packages 6 --preferences 1 9 --maxgoals 2
  ppgen.sh --style grid --dimensions 5 5 --packages 3 --preferences 1 9 \
           --goals-per-package 3 1

Every generated file records the settings it was made with -- defaults and the
seed included -- as comment lines, so it can be regenerated exactly.
EOF
}

STYLE="" CLIQUE_SIZE="" NUMBER_CLIQUES="" ROWS="" COLS="" AIRPORTS=""
TRUCKS="" AIRPLANES="" PACKAGES="" DRIVE_COST="1" FLY_COST="3"
SEED="" NAME="" DOMAIN="clara-logistics" OUTPUT="" PREF_L="" PREF_H="" MAXGOALS=""
GOALS_PER_PACKAGE="" MIN_HARD_GOALS=""

die() { echo "ppgen.sh: $1" >&2; exit 2; }

# want_int <flag> <value> : accept a non-negative integer
want_int() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 expects a non-negative integer, got '$2'"
}
# want_num <flag> <value> : accept a real (the costs may be fractional)
want_num() {
  [[ "$2" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "$1 expects a number, got '$2'"
}
need() { [[ $# -ge 2 ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --style)          need "$@"; STYLE="$2"; shift 2 ;;
    --clique-size)    need "$@"; want_int "$1" "$2"; CLIQUE_SIZE="$2"; shift 2 ;;
    --number-cliques) need "$@"; want_int "$1" "$2"; NUMBER_CLIQUES="$2"; shift 2 ;;
    --dimensions)
      [[ $# -ge 3 ]] || die "--dimensions needs two values, e.g. --dimensions 5 5"
      want_int "$1" "$2"; want_int "$1" "$3"; ROWS="$2"; COLS="$3"; shift 3 ;;
    --airports)       need "$@"; want_int "$1" "$2"; AIRPORTS="$2"; shift 2 ;;
    --trucks)         need "$@"; want_int "$1" "$2"; TRUCKS="$2"; shift 2 ;;
    --airplanes)      need "$@"; want_int "$1" "$2"; AIRPLANES="$2"; shift 2 ;;
    --packages)       need "$@"; want_int "$1" "$2"; PACKAGES="$2"; shift 2 ;;
    --drive-cost)     need "$@"; want_num "$1" "$2"; DRIVE_COST="$2"; shift 2 ;;
    --fly-cost)       need "$@"; want_num "$1" "$2"; FLY_COST="$2"; shift 2 ;;
    --preferences)
      need "$@"
      if [[ "$2" == "none" ]]; then
        PREF_L="" PREF_H=""; shift 2
      else
        [[ $# -ge 3 ]] || die "--preferences takes 'none' or two numbers, e.g. --preferences 1 5"
        want_num "$1" "$2"; want_num "$1" "$3"
        PREF_L="$2"; PREF_H="$3"; shift 3
      fi ;;
    --goals-per-package)
      [[ $# -ge 3 ]] || die "--goals-per-package needs two values, e.g. --goals-per-package 3 1"
      want_int "$1" "$2"; want_int "$1" "$3"
      GOALS_PER_PACKAGE="$2"; MIN_HARD_GOALS="$3"; shift 3 ;;
    --maxgoals)       need "$@"; want_int "$1" "$2"; MAXGOALS="$2"; shift 2 ;;
    --seed)           need "$@"; want_int "$1" "$2"; SEED="$2"; shift 2 ;;
    --name)           need "$@"; NAME="$2"; shift 2 ;;
    --domain)         need "$@"; DOMAIN="$2"; shift 2 ;;
    -o|--output)      need "$@"; OUTPUT="$2"; shift 2 ;;
    -h|--help)        print_usage; exit 0 ;;
    *)                die "unknown option '$1' (try --help)" ;;
  esac
done

if [[ -n "$MAXGOALS" && "$MAXGOALS" -gt 3 ]]; then
  die "--maxgoals is capped at 3, got $MAXGOALS"
fi
if [[ -n "$MAXGOALS" && -z "$PREF_L" ]]; then
  die "--maxgoals needs --preferences: the default goal requires every package to be delivered, so a cap on how many are delivered is either contradictory or vacuous"
fi
if [[ -n "$MIN_HARD_GOALS" && "$MIN_HARD_GOALS" != "0" && "$MIN_HARD_GOALS" != "1" ]]; then
  die "--goals-per-package's second value is the minimum number of hard goals per package, and must be 0 or 1, got $MIN_HARD_GOALS"
fi
if [[ -n "$GOALS_PER_PACKAGE" && "$GOALS_PER_PACKAGE" -lt 1 ]]; then
  die "--goals-per-package must be at least 1, got $GOALS_PER_PACKAGE"
fi
if [[ -n "$GOALS_PER_PACKAGE" && "$GOALS_PER_PACKAGE" -gt 1 && -z "$PREF_L" ]]; then
  die "--goals-per-package $GOALS_PER_PACKAGE needs --preferences: the default goal is a conjunction of every delivery, so several destinations for one package would require it to be in several places at once"
fi
if [[ "${MIN_HARD_GOALS:-0}" == "1" && -z "$PREF_L" ]]; then
  die "--goals-per-package's hard-goal minimum needs --preferences: without preferences every delivery is already required, so demanding one per package says nothing"
fi
[[ -n "$STYLE" ]] || { print_usage >&2; exit 2; }
command -v sbcl >/dev/null 2>&1 || die "sbcl not found on PATH"
[[ -f "$PPGEN" ]] || die "generator not found: $PPGEN"

# Per-style required arguments, checked here so the message names the flag.
case "$STYLE" in
  clique)
    [[ -n "$CLIQUE_SIZE"    ]] || die "clique style needs --clique-size <N>"
    [[ -n "$NUMBER_CLIQUES" ]] || die "clique style needs --number-cliques <N>"
    if [[ -n "$ROWS" ]]; then die "--dimensions applies to grid style, not clique"; fi
    if [[ -n "$AIRPORTS" ]]; then
      die "--airports applies to grid style; clique style has one airport per clique"
    fi
    ;;
  grid)
    [[ -n "$ROWS" ]] || die "grid style needs --dimensions <M> <N>"
    if [[ -n "$CLIQUE_SIZE" ]]; then die "--clique-size applies to clique style, not grid"; fi
    if [[ -n "$NUMBER_CLIQUES" ]]; then die "--number-cliques applies to clique style, not grid"; fi
    ;;
  *) die "--style must be 'grid' or 'clique', got '$STYLE'" ;;
esac

# Build the keyword arguments for (ppgen ...).  Unset ones are simply omitted,
# so the Lisp defaults apply.
kw() { if [[ -n "$2" ]]; then printf ' %s %s' "$1" "$2"; fi; }

ARGS=":style :$STYLE"
ARGS+="$(kw :clique-size "$CLIQUE_SIZE")"
ARGS+="$(kw :number-cliques "$NUMBER_CLIQUES")"
ARGS+="$(kw :rows "$ROWS")"
ARGS+="$(kw :cols "$COLS")"
ARGS+="$(kw :airports "$AIRPORTS")"
ARGS+="$(kw :trucks "$TRUCKS")"
ARGS+="$(kw :airplanes "$AIRPLANES")"
ARGS+="$(kw :packages "$PACKAGES")"
ARGS+="$(kw :drive-cost "$DRIVE_COST")"
ARGS+="$(kw :fly-cost "$FLY_COST")"
ARGS+="$(kw :maxgoals "$MAXGOALS")"
ARGS+="$(kw :goals-per-package "$GOALS_PER_PACKAGE")"
ARGS+="$(kw :min-hard-goals "$MIN_HARD_GOALS")"
ARGS+="$(kw :pref-low "$PREF_L")"
ARGS+="$(kw :pref-high "$PREF_H")"
ARGS+="$(kw :seed "$SEED")"
if [[ -n "$NAME" ]]; then ARGS+=" :name \"$NAME\""; fi
ARGS+=" :domain \"$DOMAIN\""

run() {
  sbcl --noinform --disable-debugger \
       --eval "(load \"$PPGEN\")" \
       --eval "(handler-case (ppgen:ppgen $ARGS)
                 (error (e) (format *error-output* \"ppgen.sh: ~a~%\" e)
                            (sb-ext:exit :code 2)))" \
       --quit
}

if [[ -n "$OUTPUT" ]]; then
  # write via a temp file so a failure leaves no half-written problem behind
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  run > "$tmp"
  mv "$tmp" "$OUTPUT"
  trap - EXIT
  echo "Wrote $OUTPUT" >&2
else
  run
fi
