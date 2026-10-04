#!/bin/bash
#
# fifo-lisp.sh -- where the FiFO lisp library and PDDL domains are, for the CLIs.
#
# This file is meant to be *sourced*, not executed.  Sourcing it sets and
# EXPORTS FIFO_LISP by one rule, the same for every script:
#
#   1. FIFO_LISP, if already set (the caller's explicit choice);
#   2. otherwise <this file's directory>/../lisp, if it holds FiFO.lisp -- i.e. a
#      script run from a checkout uses that checkout's lisp;
#   3. otherwise ~/lib/fifo/lisp, where `make install` puts it.
#
# Exported so that a script calling another (recognize.sh -> planner.sh and
# marginals.sh) hands it the same library.  Every script used to carry its own
# default: most hard-coded ~/lib/fifo/lisp, so a checkout's bin/planner.sh
# silently loaded the INSTALLED lisp, while recognize.sh assumed ../lisp, which
# for an installed copy is ~/lisp -- a directory that does not exist, so the
# installed recognize.sh failed unless FIFO_LISP was set.
#
# Requiring FiFO.lisp (not merely a directory named lisp) keeps an unrelated
# ~/lisp or /usr/local/lisp from being picked up by an installed script.
#
# The PDDL domain library is the sibling directory $FIFO_LISP/../pddl (a
# checkout's pddl/, or ~/lib/fifo/pddl).  The Lisp finds it the same way, from
# where pddl2fifo.lisp was loaded; _fifo_find_domain below is the shell side, for
# an explicit domain-file argument.
#
# bash 3.2 compatible (/bin/bash on macOS).

if [[ -z "${FIFO_LISP:-}" ]]; then
  _fifo_lisp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$_fifo_lisp_here/../lisp/FiFO.lisp" ]]; then
    FIFO_LISP="$(cd "$_fifo_lisp_here/../lisp" && pwd)"
  else
    FIFO_LISP="$HOME/lib/fifo/lisp"
  fi
  unset _fifo_lisp_here
fi
export FIFO_LISP

# _fifo_find_domain <file> : print the path of an explicitly named domain file.
# A name that exists as given (relative to the current directory) is used as is.
# A BARE name -- no "/" -- that does not is looked for in the domain library
# $FIFO_LISP/../pddl, so `--domain clara-logistics.pddl` works from anywhere.  A
# name with a "/" is a path the caller meant literally and is never searched for.
# Fails (status 1, message on stderr) naming every place it looked.
_fifo_find_domain() {
  local f="$1" lib="$FIFO_LISP/../pddl"
  if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  if [[ "$f" != */* && -f "$lib/$f" ]]; then
    printf '%s' "$(cd "$lib" && pwd)/$f"; return 0
  fi
  echo "domain file not found: $f" >&2
  if [[ "$f" != */* ]]; then
    [[ -d "$lib" ]] && lib="$(cd "$lib" && pwd)"
    echo "  looked in the current directory and in the domain library $lib" >&2
  fi
  return 1
}
