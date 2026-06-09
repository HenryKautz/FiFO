#!/bin/bash
sbcl --eval "(load \"schema.lisp\")" --eval "(solve \"tests_solve/$1.wff\" \"tests_solve/$1.answer\")" --eval "(quit)"
cat "tests_solve/$1.answer"

