#!/bin/bash
# Run from inside tests/.  Loads FiFO from the source checkout's lisp/ by default
# (../lisp); set FIFO_LISP to test an installed copy instead.
FIFO_LISP="${FIFO_LISP:-../lisp}"
sbcl --eval "(load \"$FIFO_LISP/FiFO.lisp\")" --eval "(instantiate \"tests_instantiate/$1.wff\" :scnfile \"tests_instantiate/$1.scnf\")" --eval "(quit)"
cat "tests_instantiate/$1.scnf"


