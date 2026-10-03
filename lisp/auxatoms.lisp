;;; auxatoms.lisp
;;;
;;; The atoms FiFO's clausifier mints for itself, and the guard that keeps a
;;; minted atom from being corrupted by the scnf round trip.
;;;
;;; Loaded by BOTH FiFO.lisp and reweight.lisp, because the counting chain
;;; (reweight -> maxent -> wmc -> ddnnf / mcsat / maxterm / hypotheses) is also
;;; loaded WITHOUT FiFO.lisp -- learn.sh does exactly that -- and every reader in
;;; it needs these.  Loading it twice is harmless: it only defines functions.
;;;
;;; Two kinds of auxiliary atom, both reserved by convention (like pddl2fifo's
;;; pref-violated / ObsDone atoms) and both DETERMINED by the theory's own atoms,
;;; so adding them changes neither satisfiability nor any model count:
;;;
;;;   (WEIGHTED-FORMULA n)   reify-formula: A <=> phi, carrying a weight on phi.
;;;   (TSEITIN n)            compact encoding: a selector defined as one side of
;;;                          an OR (see multiply-clauses in FiFO.lisp).
;;;
;;; An extra leading NAMESPACE argument, e.g. (TSEITIN EVIDENCE 3), marks atoms
;;; minted while clausifying evidence against an ALREADY-INSTANTIATED theory
;;; (wmc--evidence-clauses): that parse numbers from 1 again, and without the
;;; namespace its atoms would collide with the theory's own (TSEITIN 1) -- two
;;; unrelated definitions forced equal.

;; When non-nil, a symbol prepended to every auxiliary atom's arguments, e.g.
;; (TSEITIN EVIDENCE 3); see the header.  Defined HERE rather than in FiFO.lisp
;; because wmc.lisp binds it and may be loaded first: a LET of an undeclared
;; variable is lexical, so the binding would silently do nothing.
(defvar *aux-atom-namespace* nil)

(defun reified-formula-atom-p (atom)
  "True for a fresh auxiliary atom (WEIGHTED-FORMULA ...) minted by reify-formula.
Marginal reporters use this to suppress these internal atoms from the default
(all-atoms) listing; they still surface under --weighted-only, since P(that atom)
is exactly P(the reified formula)."
  (and (consp atom) (eq (car atom) 'WEIGHTED-FORMULA)))

(defun tseitin-atom-p (atom)
  "True for a selector atom (TSEITIN ...) minted by the compact encoding.  It is
an artefact of clausification, never a quantity anyone asked about, so it is
hidden from answers and from every marginal listing."
  (and (consp atom) (eq (car atom) 'TSEITIN)))

(defun auxiliary-atom-p (atom)
  "True for any atom the clausifier minted: (WEIGHTED-FORMULA ...) or (TSEITIN ...)."
  (or (reified-formula-atom-p atom) (tseitin-atom-p atom)))

(defun evidence-aux-atom-p (atom)
  "True for an auxiliary atom minted while clausifying EVIDENCE -- one carrying a
namespace, e.g. (TSEITIN EVIDENCE 3).  These are the only atoms that may
legitimately appear in evidence without being in the theory: a stray
un-namespaced (TSEITIN 9) is not, and must be reported as a stray, since given
a fresh variable it would constrain nothing.  (Users cannot write either kind:
parse-proposition reserves the names.)"
  (and (auxiliary-atom-p atom) (cddr atom) t))

(defun scnf-check-no-gensyms (form source)
  "Signal an error if FORM contains an UNINTERNED symbol; otherwise return FORM.
An scnf is written with ~S and read back with READ, and an uninterned symbol does
not survive that round trip: every occurrence of #:XX7 reads back as a DIFFERENT
symbol, so the clauses that shared one atom each get their own unconstrained copy.
The constraint silently disappears -- an UNSAT theory is reported SAT, and model
counts and marginals are those of a weaker theory.  (Before the TSEITIN atoms,
the compact encoding's selectors were gensyms and did exactly this.)  SOURCE names
the file, or the step, for the message."
  (labels ((walk (x)
             (cond ((consp x) (walk (car x)) (walk (cdr x)))
                   ((and x (symbolp x) (null (symbol-package x)))
                    (error "~A contains the uninterned symbol ~S in ~S.~@
An uninterned symbol cannot be written to an scnf and read back: each occurrence ~
reads as a different atom, so the clauses sharing it stop constraining each other ~
and SAT, MaxSAT and model-counting answers are silently wrong.  Regenerate the ~
file with a current FiFO." source x form)))))
    (walk form))
  form)
