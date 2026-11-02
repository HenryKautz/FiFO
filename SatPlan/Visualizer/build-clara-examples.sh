#!/bin/bash
# build-clara-examples.sh -- fill clara-examples/ with symbolic links to the
# CLARA repository's problems, domains and solutions, then run build.sh, which
# bundles them into clara-examples.js for the plan visualizer's Examples menu
# (next to the checked-in examples/, which the test suite relies on).
#
#   bash SatPlan/Visualizer/build-clara-examples.sh [CLARA-DIR]
#
# CLARA is found at the argument, else $CLARA_DIR, else beside the FiFO
# checkout (<FiFO>/../CLARA).  clara-examples/ and clara-examples.js depend on a
# local CLARA checkout, so both are git-ignored (this script makes sure).
#
# clara-examples/ mirrors CLARA's tree for these benchmark directories and
# their immediate subdirectories (goals/, recognition/, ...):
#     SimpleGrid TwoPackage TwoPackageOneway ThreePackage FourPackage
# (not AAAI-2010-Benchmarks: blocks-world and intrusion-detection problems,
# which the visualizer's grid map cannot draw).
# Each mirrored directory links that directory's .pddl, .answer and .plan
# files under their own names, except
#   - a .pddl containing <HYPOTHESIS> (a template, not a problem);
#   - a Dropbox "conflicted copy" (reported: the checkout needs cleaning).
# The bundler (tools/bundle-examples.ts) then gives each problem the domain
# beside it or in a parent directory, and the solutions beside it whose names
# start with the problem's name followed by "." or "-".
#
# Written for macOS /bin/bash 3.2.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FIFO="$(cd "$HERE/../.." && pwd -P)"
OUTDIR="$HERE/clara-examples"
ROOTS="SimpleGrid TwoPackage TwoPackageOneway ThreePackage FourPackage"

# (1) find CLARA
CLARA="${1:-${CLARA_DIR:-$FIFO/../CLARA}}"
if [ ! -d "$CLARA" ]; then
  echo "build-clara-examples.sh: no CLARA directory at $CLARA" >&2
  echo "  pass its path as the argument, or set CLARA_DIR" >&2
  exit 1
fi
CLARA="$(cd "$CLARA" && pwd -P)"
found=0
for r in $ROOTS; do [ -d "$CLARA/$r" ] && found=1; done
if [ "$found" = 0 ]; then
  echo "build-clara-examples.sh: $CLARA does not look like a CLARA checkout" >&2
  echo "  (none of: $ROOTS)" >&2
  exit 1
fi
echo "CLARA: $CLARA"

# (2) start clara-examples/ afresh
rm -rf "$OUTDIR"
mkdir "$OUTDIR"

# (3) link the files: one grep and one ln per directory, not per file
pddls=0 solutions=0 templates=0 conflicts=0
for r in $ROOTS; do
  if [ ! -d "$CLARA/$r" ]; then echo "  (no $r/ in CLARA: skipped)"; continue; fi
  for dir in "$CLARA/$r" "$CLARA/$r"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    rel="${dir#"$CLARA"/}"
    tmpl=""
    if ls "$dir"/*.pddl >/dev/null 2>&1; then
      tmpl="$(grep -l '<HYPOTHESIS>' "$dir"/*.pddl || true)"
    fi
    links=()
    for f in "$dir"/*.pddl "$dir"/*.answer "$dir"/*.plan; do
      [ -f "$f" ] || continue
      case "$f" in *"conflicted copy"*) conflicts=$((conflicts + 1)); continue ;; esac
      case "$f" in
        *.pddl)
          case "
$tmpl
" in *"
$f
"*) templates=$((templates + 1)); continue ;; esac
          pddls=$((pddls + 1)) ;;
        *) solutions=$((solutions + 1)) ;;
      esac
      links+=("$f")
    done
    [ "${#links[@]}" -gt 0 ] || continue
    mkdir -p "$OUTDIR/$rel"
    ln -s "${links[@]}" "$OUTDIR/$rel/"
  done
done
echo "linked $pddls .pddl files (problems and domains) and $solutions solution files into clara-examples/"
[ "$templates" = 0 ] || echo "  skipped $templates template file(s) (contain <HYPOTHESIS>)"
[ "$conflicts" = 0 ] || echo "  skipped $conflicts Dropbox \"conflicted copy\" file(s) -- CLARA needs cleaning (git clean -n)"

# (5) keep clara-examples/ and clara-examples.js out of git.  Appended at the
# end, after .gitignore's "!SatPlan/**" (git applies the last matching rule).
GI="$FIFO/.gitignore"
added=0
for pat in SatPlan/Visualizer/clara-examples/ SatPlan/Visualizer/clara-examples.js; do
  if ! grep -qxF "$pat" "$GI"; then
    if [ "$added" = 0 ]; then
      printf '\n# build-clara-examples.sh: links into a local CLARA checkout, and their bundle\n' >> "$GI"
      added=1
    fi
    echo "$pat" >> "$GI"
  fi
done
[ "$added" = 0 ] || echo "added clara-examples/ and clara-examples.js to .gitignore"
if ! git -C "$FIFO" check-ignore -q "$OUTDIR/" ||
   ! git -C "$FIFO" check-ignore -q "$HERE/clara-examples.js"; then
  echo "build-clara-examples.sh: .gitignore does not exclude clara-examples/ and clara-examples.js" >&2
  exit 1
fi

# bundle them for the page
bash "$HERE/build.sh"
echo "wrote $HERE/clara-examples.js"
