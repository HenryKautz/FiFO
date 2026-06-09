#!/bin/bash
sbcl --eval "(load \"FiFO.lisp\")" --eval "(instantiate \"tests_instantiate/$1.wff\" \"tests_instantiate/$1.scnf\")" --eval "(quit)"
cat "tests_instantiate/$1.scnf"


