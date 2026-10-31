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
# place each package somewhere other than where it started -- or, with
# --packages 0, send each truck somewhere.  --destinations, --require and
# --preferences shape the goal independently.  --knockout N
# deletes N percent of each road network's roads, keeping it connected;
# --oneway N then makes N percent of the remaining roads one-way, keeping every
# place reachable from every other.
# --mindist N and --maxdist M (grid) start the goal objects at p1-1 and put every
# destination at least N and at most M steps away.
#
# The problem is written to stdout unless --output names a file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FIFO_LISP by the rule every script shares: fifo-lisp.sh is beside an installed
# copy, and in a checkout it is in ../bin (this script lives in SatPlan/).
if [[ -f "$SCRIPT_DIR/fifo-lisp.sh" ]]; then source "$SCRIPT_DIR/fifo-lisp.sh"
else source "$SCRIPT_DIR/../bin/fifo-lisp.sh"; fi
# ppgen.lisp: beside this script in a checkout; `make install` puts the script in
# BINDIR and the lisp in FIFO_LISP.  When FIFO_LISP points at a CHECKOUT's lisp/,
# ppgen.lisp is in that checkout's SatPlan/ instead -- looked for last.
PPGEN="$SCRIPT_DIR/ppgen.lisp"
[[ -f "$PPGEN" ]] || PPGEN="$FIFO_LISP/ppgen.lisp"
[[ -f "$PPGEN" ]] || PPGEN="$FIFO_LISP/../SatPlan/ppgen.lisp"

print_usage() {
  cat <<'EOF'
usage: ppgen.sh --style <grid|clique> [options]

  --style <grid|clique>     which topology to generate (required)

clique style:
  --clique-size <N>         places in each clique of roads (required)
  --number-cliques <N>      number of cliques (required)

grid style:
  --dimensions <M> <N>      grid size (required)
  --airports <N>            default 2
  --mindist <N>             every goal object (package, or truck with
                               --packages 0) starts at the origin p1-1, and its
                               destinations are all at least N steps away -- the
                               shortest path over roads, plus airport routes
                               for a package when there are airplanes.  Refused
                               when too few places qualify for the distinct
                               destinations
  --maxdist <M>             likewise, with every destination at most M steps
                               away.  Either or both; --mindist N --maxdist N
                               puts every destination at exactly N steps

both styles:
  --trucks <N>              default: number of cliques, or of airports (grid)
  --airplanes <N>           default: number of cliques, or of airports (grid);
                               0 with --packages 0
  --packages <N>            default: number of cliques, or of airports (grid).
                               0 is the simpler problem: no packages, and the
                               goals send each TRUCK to a destination instead
                               (within its own clique in clique style -- roads
                               never leave one).  Every goal option below then
                               applies per truck
  --drive-cost <R>          cost of one drive, default 1
  --fly-cost <R>            cost of one flight, default 3
  --handle-cost <R>         cost of one load or unload, default 1
  --knockout <N>            delete N percent (0-100) of the roads of each road
                               network -- each clique, or the whole grid --
                               keeping it connected: a random spanning tree is
                               kept and random other roads added back.  Refused
                               when the tree alone exceeds (100-N)% of the
                               roads.  Default 0
  --oneway <N>              make N percent (0-100) of each road network's
                               two-way roads (after --knockout) one-way, each
                               in a random direction, keeping every place
                               reachable from every other.  A road whose loss
                               of either direction would cut a place off stays
                               two-way; if too few can be turned, all that can
                               are, with a warning.  Default 0
  --seed <N>                seed the generator, so a run is reproducible.
                               With no --seed the clock supplies one, and the
                               value used is recorded in the generated file
  --name <name>             problem name, default <style>-problem
  --domain <name>           domain named in (:domain ...), default
                               clara-logistics
  --output <file>, -o       write here instead of stdout
  --help, -h                this message

goals -- three independent options; "object" is a package, or a truck with
--packages 0:
  --destinations <N>        N distinct destinations per object, any one of
                               which counts as reaching it (only one can hold:
                               an object is at one place).  Default 1
  --require all             every object must reach a destination (default)
  --require some            at least one object must reach a destination
  --preferences <L> <H>     every goal is also a preference, weighted equally
                               spaced from L to H in random order and charged
                               when the goal does not hold.  Refused with
                               --require all and one destination, where every
                               goal is forced
  --preferences none        no weights (the default)

examples:
  ppgen.sh --style clique --clique-size 4 --number-cliques 3 --seed 1
  ppgen.sh --style grid --dimensions 5 5 --airports 3 --packages 4 -o pb2.pddl
  ppgen.sh --style grid --dimensions 4 4 --packages 3 --require some \
           --preferences 1 5
  ppgen.sh --style grid --dimensions 5 5 --packages 3 --destinations 3
  ppgen.sh --style clique --clique-size 4 --number-cliques 2 --packages 0
  ppgen.sh --style grid --dimensions 6 6 --knockout 25
  ppgen.sh --style grid --dimensions 6 6 --packages 3 --mindist 6 --maxdist 6

Every generated file records the settings it was made with -- defaults and the
seed included -- as comment lines, so it can be regenerated exactly.
EOF
}

STYLE="" CLIQUE_SIZE="" NUMBER_CLIQUES="" ROWS="" COLS="" AIRPORTS=""
TRUCKS="" AIRPLANES="" PACKAGES="" DRIVE_COST="1" FLY_COST="3" HANDLE_COST="1"
SEED="" NAME="" DOMAIN="clara-logistics" OUTPUT="" PREF_L="" PREF_H=""
DESTINATIONS="" REQUIRE="" KNOCKOUT="" ONEWAY="" MINDIST="" MAXDIST=""

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
    --handle-cost)    need "$@"; want_num "$1" "$2"; HANDLE_COST="$2"; shift 2 ;;
    --preferences)
      need "$@"
      if [[ "$2" == "none" ]]; then
        PREF_L="" PREF_H=""; shift 2
      else
        [[ $# -ge 3 ]] || die "--preferences takes 'none' or two numbers, e.g. --preferences 1 5"
        want_num "$1" "$2"; want_num "$1" "$3"
        PREF_L="$2"; PREF_H="$3"; shift 3
      fi ;;
    --destinations)   need "$@"; want_int "$1" "$2"; DESTINATIONS="$2"; shift 2 ;;
    --require)
      need "$@"
      [[ "$2" == all || "$2" == some ]] || die "--require takes all or some, got '$2'"
      REQUIRE="$2"; shift 2 ;;
    --knockout)       need "$@"; want_int "$1" "$2"; KNOCKOUT="$2"; shift 2 ;;
    --oneway)         need "$@"; want_int "$1" "$2"; ONEWAY="$2"; shift 2 ;;
    --mindist)        need "$@"; want_int "$1" "$2"; MINDIST="$2"; shift 2 ;;
    --maxdist)        need "$@"; want_int "$1" "$2"; MAXDIST="$2"; shift 2 ;;
    --seed)           need "$@"; want_int "$1" "$2"; SEED="$2"; shift 2 ;;
    --name)           need "$@"; NAME="$2"; shift 2 ;;
    --domain)         need "$@"; DOMAIN="$2"; shift 2 ;;
    -o|--output)      need "$@"; OUTPUT="$2"; shift 2 ;;
    -h|--help)        print_usage; exit 0 ;;
    *)                die "unknown option '$1' (try --help)" ;;
  esac
done

if [[ -n "$KNOCKOUT" && "$KNOCKOUT" -gt 100 ]]; then
  die "--knockout is a percentage, 0 to 100, got $KNOCKOUT"
fi
if [[ -n "$ONEWAY" && "$ONEWAY" -gt 100 ]]; then
  die "--oneway is a percentage, 0 to 100, got $ONEWAY"
fi
if [[ -n "$MINDIST" && "$MINDIST" -lt 1 ]]; then
  die "--mindist must be at least 1, got $MINDIST"
fi
if [[ -n "$MAXDIST" && "$MAXDIST" -lt 1 ]]; then
  die "--maxdist must be at least 1, got $MAXDIST"
fi
if [[ -n "$MINDIST" && -n "$MAXDIST" && "$MAXDIST" -lt "$MINDIST" ]]; then
  die "--maxdist $MAXDIST is below --mindist $MINDIST: no place is that far and that near"
fi
if [[ -n "$DESTINATIONS" && "$DESTINATIONS" -lt 1 ]]; then
  die "--destinations must be at least 1, got $DESTINATIONS"
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
    if [[ -n "$MINDIST" ]]; then
      die "--mindist applies to grid style only: it measures from the grid's origin p1-1"
    fi
    if [[ -n "$MAXDIST" ]]; then
      die "--maxdist applies to grid style only: it measures from the grid's origin p1-1"
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
ARGS+="$(kw :handle-cost "$HANDLE_COST")"
ARGS+="$(kw :destinations "$DESTINATIONS")"
if [[ -n "$REQUIRE" ]]; then ARGS+=" :require \"$REQUIRE\""; fi
ARGS+="$(kw :pref-low "$PREF_L")"
ARGS+="$(kw :pref-high "$PREF_H")"
ARGS+="$(kw :knockout "$KNOCKOUT")"
ARGS+="$(kw :oneway "$ONEWAY")"
ARGS+="$(kw :mindist "$MINDIST")"
ARGS+="$(kw :maxdist "$MAXDIST")"
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
