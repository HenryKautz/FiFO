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
# What is linked, from each benchmark directory and its immediate
# subdirectories (goals/, recognition/, ...):
#   - every problem .pddl (a file containing <HYPOTHESIS>, such as the AAAI
#     template.pddl, is a template, not a problem, and is skipped);
#   - every domain .pddl, one per domain name (two different files defining
#     the same domain are an error: the menu would pick one silently);
#   - every .answer/.plan whose name is a linked problem's name followed by
#     "." or "-" (the bundler's rule for which solutions go with a problem).
# A link is named after its CLARA path with "/" turned into "_"
# (TwoPackage/goals/x.pddl -> TwoPackage_goals_x.pddl), since the same file
# names recur across benchmark directories.  OldVersions/ is deliberately left
# out.
#
# Written for macOS /bin/bash 3.2 (no associative arrays).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FIFO="$(cd "$HERE/../.." && pwd -P)"
OUTDIR="$HERE/clara-examples"
ROOTS="SimpleGrid TwoPackage TwoPackageOneway ThreePackage FourPackage AAAI-2010-Benchmarks"

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

TMP="$(mktemp -d /tmp/fifo-clara-examples-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/domains"       # $TMP/domains/<name> holds the path of its domain file
: > "$TMP/wanted"          # domain names the linked problems ask for

# Line by line, assuming "(define (domain NAME" and "(:domain NAME)" each sit
# on one line, as they do throughout CLARA.  (Joining a file into one line and
# matching it with sed 's/.*(...' backtracks quadratically: minutes per file.)
# the domain a file defines (empty for a problem), lower-cased
defines_domain() {
  sed 's/;.*//' "$1" | grep -i -o -m1 -E '\([[:space:]]*define[[:space:]]*\([[:space:]]*domain[[:space:]]+[^[:space:]()]+' |
    awk '{print tolower($NF)}' | sed 's/.*(//' | head -1 || true
}
# the domain a problem asks for, lower-cased
wants_domain() {
  sed 's/;.*//' "$1" | grep -i -o -m1 -E '\([[:space:]]*:domain[[:space:]]+[^[:space:]()]+' |
    awk '{print tolower($NF)}' | head -1 || true
}

# (3) link the files
problems=0 solutions=0 domains=0 templates=0 orphans=0 conflicts=0
for r in $ROOTS; do
  if [ ! -d "$CLARA/$r" ]; then echo "  (no $r/ in CLARA: skipped)"; continue; fi
  for dir in "$CLARA/$r" "$CLARA/$r"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    rel="${dir#"$CLARA"/}"
    prefix="$(echo "$rel" | tr '/' '_')_"
    stems=""
    for f in "$dir"/*.pddl; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      case "$base" in *"conflicted copy"*) conflicts=$((conflicts + 1)); continue ;; esac
      if grep -q '<HYPOTHESIS>' "$f"; then
        templates=$((templates + 1)); continue
      fi
      dname="$(defines_domain "$f")"
      if [ -n "$dname" ]; then
        if [ -e "$TMP/domains/$dname" ]; then
          seen="$(cat "$TMP/domains/$dname")"
          if ! cmp -s "$seen" "$f"; then
            echo "build-clara-examples.sh: two different files define domain $dname:" >&2
            echo "  $seen" >&2
            echo "  $f" >&2
            exit 1
          fi
        else
          echo "$f" > "$TMP/domains/$dname"
          ln -s "$f" "$OUTDIR/$prefix$base"
          domains=$((domains + 1))
        fi
        continue
      fi
      ln -s "$f" "$OUTDIR/$prefix$base"
      problems=$((problems + 1))
      stems="$stems ${base%.pddl}"
      w="$(wants_domain "$f")"
      [ -n "$w" ] && echo "$w" >> "$TMP/wanted"
    done
    for f in "$dir"/*.answer "$dir"/*.plan; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      case "$base" in *"conflicted copy"*) conflicts=$((conflicts + 1)); continue ;; esac
      owned=0
      for s in $stems; do
        case "$base" in "$s".*|"$s"-*) owned=1; break ;; esac
      done
      if [ "$owned" = 1 ]; then
        ln -s "$f" "$OUTDIR/$prefix$base"
        solutions=$((solutions + 1))
      else
        orphans=$((orphans + 1))
      fi
    done
  done
done
echo "linked $problems problems, $solutions solutions, $domains domains into clara-examples/"
[ "$templates" = 0 ] || echo "  skipped $templates template file(s) (contain <HYPOTHESIS>)"
[ "$orphans" = 0 ] || echo "  skipped $orphans solution file(s) with no problem of that name beside them"
[ "$conflicts" = 0 ] || echo "  skipped $conflicts Dropbox \"conflicted copy\" file(s) -- CLARA needs cleaning (git clean -n)"
for w in $(sort -u "$TMP/wanted"); do
  [ -e "$TMP/domains/$w" ] ||
    echo "  warning: no domain file for (:domain $w) in CLARA; those problems load without one"
done

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
