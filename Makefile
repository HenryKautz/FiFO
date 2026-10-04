# FiFO installation.
#
#   make install
#
# copies the shell scripts in bin/ into BINDIR and the lisp library in lisp/ into
# LISPDIR, creating the directories as needed.  Defaults install the scripts to
# ~/bin and the lisp (FiFO.lisp, pddl2fifo.lisp, planner.lisp, reweight.lisp,
# maxent.lisp, hypotheses.lisp, ..., plus the data files satplan.wff and
# solvers.dat) to ~/lib/fifo/lisp -- the location planner.sh looks in by default.
# Both data files are runtime dependencies: solvers.dat is the solver/counter
# table that bin/fifo-solvers.sh and lisp/FiFO.lisp both read.
#
# The SatPlan generators are installed too: ppgen.sh (clara-logistics problems)
# and evgen.sh (plan-recognition evidence) go to BINDIR, and their ppgen.lisp and
# evgen.lisp to LISPDIR, where an installed script looks for them when there is
# no copy beside it.  In the checkout they stay under SatPlan/.
#
# The PDDL domain library, pddl/ (clara-logistics.pddl, which ppgen's problems
# name), goes to LISPDIR/../pddl -- ~/lib/fifo/pddl by default.  A problem whose
# (:domain <name>) file is neither beside it nor in the current directory is
# looked up there, so a generated problem plans from any directory.
# Override either at install time, e.g.:
#
#   make install BINDIR=/usr/local/bin LISPDIR=/usr/local/lib/fifo/lisp
#
# If you install the lisp somewhere other than ~/lib/fifo/lisp, set FIFO_LISP to
# that directory when running the scripts.

BINDIR  ?= $(HOME)/bin
LISPDIR ?= $(HOME)/lib/fifo/lisp
# Not separately settable: the Lisp finds the domain library as ../pddl from where
# it was loaded, and the scripts as $FIFO_LISP/../pddl.
PDDLDIR := $(LISPDIR)/../pddl

.PHONY: install
install:
	mkdir -p $(BINDIR) $(LISPDIR)
	cp bin/*  $(BINDIR)/
	cp lisp/* $(LISPDIR)/
	cp SatPlan/ppgen.sh SatPlan/evgen.sh     $(BINDIR)/
	cp SatPlan/ppgen.lisp SatPlan/evgen.lisp $(LISPDIR)/
	mkdir -p $(PDDLDIR)
	cp pddl/*.pddl $(PDDLDIR)/
	chmod +x $(BINDIR)/*.sh
	@echo "Installed scripts -> $(BINDIR)"
	@echo "Installed lisp    -> $(LISPDIR)"
	@echo "Installed domains -> $(PDDLDIR)"
	@echo "Make sure $(BINDIR) is on your PATH."
ifneq ($(LISPDIR),$(HOME)/lib/fifo/lisp)
	@echo "NOTE: lisp is not at the default ~/lib/fifo/lisp; run the scripts with"
	@echo "      FIFO_LISP=$(LISPDIR)"
endif
