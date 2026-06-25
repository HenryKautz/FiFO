# FiFO installation.
#
#   make install
#
# copies the shell scripts in bin/ into BINDIR and the lisp library in lisp/ into
# LISPDIR, creating the directories as needed.  Defaults install the scripts to
# ~/bin and the lisp (FiFO.lisp, pddl2fifo.lisp, planner.lisp, reweight.lisp,
# maxent.lisp, satplan.wff) to ~/lib/fifo/lisp -- the location planner.sh looks in
# by default.  Override either at install time, e.g.:
#
#   make install BINDIR=/usr/local/bin LISPDIR=/usr/local/lib/fifo/lisp
#
# If you install the lisp somewhere other than ~/lib/fifo/lisp, set FIFO_LISP to
# that directory when running the scripts.

BINDIR  ?= $(HOME)/bin
LISPDIR ?= $(HOME)/lib/fifo/lisp

.PHONY: install
install:
	mkdir -p $(BINDIR) $(LISPDIR)
	cp bin/*  $(BINDIR)/
	cp lisp/* $(LISPDIR)/
	chmod +x $(BINDIR)/*.sh
	@echo "Installed scripts -> $(BINDIR)"
	@echo "Installed lisp    -> $(LISPDIR)"
	@echo "Make sure $(BINDIR) is on your PATH."
ifneq ($(LISPDIR),$(HOME)/lib/fifo/lisp)
	@echo "NOTE: lisp is not at the default ~/lib/fifo/lisp; run the scripts with"
	@echo "      FIFO_LISP=$(LISPDIR)"
endif
