#!/bin/bash
# run-circuit-clara.sh -- the circuit visualizer on CLARA's circuits: starts
# server/circuit_server.py --clara and opens the page in a browser.
#
#   bash SatPlan/Visualizer/run-circuit-clara.sh [CLARA-DIR] [server options...]
#
# CLARA is found at the first argument if it is a directory, else $CLARA_DIR,
# else beside the FiFO checkout (<FiFO>/../CLARA), as build-clara-examples.sh
# finds it.  Further arguments go to the server, e.g. --port 8766 or
# --heap-mb 16384 (for the largest circuits).  Ctrl-C stops it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FIFO="$(cd "$HERE/../.." && pwd -P)"
if [ $# -gt 0 ] && [ -d "$1" ]; then
  CLARA="$1"
  shift
else
  CLARA="${CLARA_DIR:-$FIFO/../CLARA}"
fi
if [ ! -d "$CLARA" ]; then
  echo "run-circuit-clara.sh: no CLARA directory at $CLARA" >&2
  echo "  pass its path as the first argument, or set CLARA_DIR" >&2
  exit 1
fi
exec python3 "$HERE/server/circuit_server.py" --clara "$(cd "$CLARA" && pwd -P)" --open "$@"
