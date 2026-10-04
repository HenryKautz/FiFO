#!/bin/bash
#
# run-test-docs.sh -- every flag a script accepts is documented in its option
# table in software-components.md.
#
# The flags are read from the script's own argument parser (the `case` arms of its
# option loop), not from its --help text, so a flag added to the parser and to
# nothing else is caught.  Each must appear as `--flag` inside that script's
# section of software-components.md -- the reference satplan.md and the --help
# texts point readers to.
#
# Covers ppgen.sh and evgen.sh, whose reference was moved there from satplan.md.
#
# Run from anywhere:  bash tests/run-test-docs.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO/software-components.md"

PASS=0; FAIL=0
name() { printf '  %-62s ... ' "$1"; }
pass() { echo PASS; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

# parser_flags <script> : every --flag (and -x) named in a case arm, one per line.
parser_flags() {
  grep -E '^[[:space:]]+-[-a-zA-Z0-9|]+\)' "$1" | sed -E 's/^[[:space:]]+//; s/\).*//' | tr '|' '\n'
}

# documented <flag> <text> : the flag appears as a WHOLE token opening a code span
# -- `--seed <N>`, `--style clique\|grid`, `--truck-goals` -- so an undocumented
# --obs is not excused by a documented --observe.  The character after it must be
# a space, a backtick, or the backslash of an escaped |.
documented() {
  local f="$1" esc
  esc="$(printf '%s' "$f" | sed 's/[.[\*^$]/\\&/g')"
  grep -qE "\`${esc}([ \`]|\\\\)" <<<"$2"
}

# doc_section <heading> : the lines of software-components.md from "### `<heading>`"
# up to the next ------ rule.
doc_section() {
  awk -v h="### \`$1\`" '$0==h {on=1; next} on && /^------/ {exit} on' "$DOC"
}

echo "=== every parsed flag is in software-components.md ==="

for s in SatPlan/ppgen.sh SatPlan/evgen.sh; do
  base="$(basename "$s")"
  SECTION="$(doc_section "$base")"
  name "$base has a section"
  if [[ -n "$SECTION" ]]; then pass; else fail "no '### \`$base\`' section"; continue; fi

  FLAGS="$(parser_flags "$REPO/$s")"
  name "$base: the parser yields flags to check"
  # Guard against a vacuous pass if the parser's shape changes.
  [[ "$(wc -l <<<"$FLAGS" | tr -d ' ')" -ge 10 ]] && pass || fail "found only: $FLAGS"

  MISSING=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    documented "$f" "$SECTION" || MISSING+=" $f"
  done <<<"$FLAGS"
  name "$base: every flag appears in its option table"
  [[ -z "$MISSING" ]] && pass || fail "undocumented:$MISSING"
done

# The matcher itself: a prefix of a documented flag is NOT documented.  (It was a
# plain substring match, under which an undocumented --obs passed on the strength
# of --observe.)
name "a prefix of a documented flag does not count as documented"
if ! documented "--obs" '| `--observe "<names>"` | x |' \
   && documented "--observe" '| `--observe "<names>"` | x |' \
   && documented "--style" '| `--style clique\|grid` | x |' \
   && documented "--truck-goals" '| `--truck-goals` | x |'; then pass
else fail "matcher accepts a prefix, or rejects a real entry"; fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
