#!/bin/bash
# Run from inside tests/.  Loads FiFO from the source checkout's lisp/ by default
# (../lisp); set FIFO_LISP to test an installed copy instead.
FIFO_LISP="${FIFO_LISP:-../lisp}"
sbcl --eval "(load \"$FIFO_LISP/FiFO.lisp\")" --eval "(solve \"tests_solve/$1.wff\" :solnfile \"tests_solve/$1.answer\")" --eval "(quit)"
cat "tests_solve/$1.answer"

