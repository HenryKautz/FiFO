;;; reweight.lisp
;;;
;;; FiFO weight-learning, Case 4 (beliefs about marginals), independent /
;;; clause-ignoring estimator -- the "warm start" of fifo-weight-learning.md S8.
;;;
;;; Input:  an instantiated .scnf file whose (WEIGHT <literal> p) lines carry a
;;;         TARGET MARGINAL PROBABILITY p in [0.0, 1.0] -- the probability that
;;;         <literal> is true that we want the weighted theory to have.
;;;
;;; Output: <root>_reweighted.scnf, identical to the input except that every
;;;         marginal-bearing WEIGHT line is replaced by an integer-weighted
;;;         literal (or, for the degenerate p=0 / p=1 cases, a hard unit clause).
;;;
;;; Model.  FiFO compiles to hard clauses plus weighted literals; a WEIGHT w on
;;; literal L is the COST of making L true (README, "Weighted CNF output
;;; formats"), and the MaxSAT objective is the sum of the weights of the true
;;; literals.  Ignoring the clauses, each atom is then an independent logistic
;;; variable: with cost theta charged when the atom is true,
;;;
;;;     P(atom = 1) = e^-theta / (1 + e^-theta) = 1 / (1 + e^theta) = sigma(-theta).
;;;
;;; Inverting for a target marginal p gives the log-odds warm start
;;;
;;;     theta = log((1 - p) / p)        (cost charged when the atom is TRUE).
;;;
;;; theta is positive when p < 0.5 and negative when p > 0.5.  A negative cost on
;;; the positive literal is, up to an additive constant on the objective (which
;;; changes neither the argmin nor the distribution), a positive cost on the
;;; negative literal.  So we apply the README "shift" rule directly:
;;;
;;;     p < 0.5 :  (WEIGHT atom        log((1-p)/p))     -- cost to turn it on
;;;     p > 0.5 :  (WEIGHT (NOT atom)  log(p/(1-p)))     -- cost to turn it off
;;;     p = 0.5 :  no weight (theta = 0)
;;;     p = 0   :  hard clause (OR (NOT atom))           -- atom forced false
;;;     p = 1   :  hard clause (OR atom)                 -- atom forced true
;;;
;;; Exactly one polarity ever carries a weight; the other is implicitly zero.
;;;
;;; Integer weights.  MaxSAT / WCNF requires positive integers, but theta is
;;; real.  We multiply every theta by a common SCALE (default 100) and round.
;;; The common factor preserves the log-odds RATIOS between atoms exactly; it
;;; also uniformly sharpens the distribution (it divides the temperature), so the
;;; recovered real-valued weight of any emitted line is (integer weight / SCALE).
;;; A weight that rounds to 0 (a target within 1/(2*SCALE) log-odds of 0.5) is
;;; dropped.  The chosen scale is recorded in a comment header; the Lisp reader
;;; skips ';' comments, so the file remains valid input to propositionalize.
;;;
;;; NOTE: this is the independent approximation -- exact only when the hard
;;; clauses do not couple the weighted atoms.  When they do, these weights are
;;; the starting point for the iterative MaxEnt fit (S8/S9), not the fixed point.

(ql:quickload :cl-ppcre :silent t)

(defun rw--literal-atom-and-sign (literal)
  "Split LITERAL into its underlying atom and a flag for whether it is positive.
Returns (values atom positive-p).  A literal is either (PRED args...) or
(NOT (PRED args...))."
  (if (and (consp literal) (eq (car literal) 'not))
      (progn
        (unless (and (consp (cdr literal)) (null (cddr literal)) (consp (cadr literal)))
          (error "malformed negative literal: ~S" literal))
        (values (cadr literal) nil))
      (progn
        (unless (consp literal)
          (error "malformed literal (expected (PRED ...) or (NOT (PRED ...))): ~S" literal))
        (values literal t))))

(defun rw--target-marginal (literal p)
  "Given a WEIGHT literal and its target probability P (that LITERAL is true),
return (values atom prob-atom-true), normalizing a negated literal so the
probability always refers to the positive atom."
  (unless (and (realp p) (<= 0 p) (<= p 1))
    (error "target marginal must be a probability in [0,1]; got ~S for ~S" p literal))
  (multiple-value-bind (atom positivep) (rw--literal-atom-and-sign literal)
    (values atom (if positivep (float p 1.0d0) (- 1.0d0 (float p 1.0d0))))))

(defun rw--emit-for-theta (atom theta scale)
  "Integer-weighted scnf form for a real cost-when-true THETA on the positive
ATOM, applying the README shift+scale: theta>0 charges on the positive literal,
theta<0 charges its magnitude on (NOT atom), and a magnitude rounding to 0 is
dropped.  Returns a (WEIGHT ...) form, or NIL when it rounds away."
  (let ((w (round (* scale (abs theta)))))
    (if (zerop w)
        nil
        (list 'weight (if (> theta 0.0d0) atom (list 'not atom)) w))))

(defun rw--emit-for-atom (atom p scale)
  "Return (values weight-form hard-clause-form) for ATOM with target marginal P
(probability the atom is true), under the independent log-odds estimator and
integer SCALE.  Exactly one of the two returned values is non-NIL, except
p=0.5 / rounds-to-zero, which returns both NIL (the atom is left unconstrained)."
  (cond
    ;; Degenerate certainties -> hard unit clauses, not (infinite) weights.
    ((= p 0.0d0) (values nil (list 'or (list 'not atom))))
    ((= p 1.0d0) (values nil (list 'or atom)))
    ;; theta = log((1-p)/p) is the cost charged when the atom is TRUE.
    (t (values (rw--emit-for-theta atom (log (/ (- 1.0d0 p) p)) scale) nil))))

(defun rw--read-scnf (scnf-file)
  "Read SCNF-FILE and return (values clauses probabilities options), each a list
of the corresponding forms.  The marginal targets are (PROBABILITY literal p)
forms -- a distinct keyword from the (WEIGHT ...) cost form so that an input
\(probabilities) and an output (integer costs) can never be confused.  Signals an
error on any form that is not (OR ...), (PROBABILITY ...), or (OPTION ...)."
  (let ((forms (let ((*read-eval* nil))
                 (with-open-file (in scnf-file :direction :input)
                   (loop for f = (read in nil :eof)
                         until (eq f :eof)
                         do (unless (and (consp f) (member (car f) '(or probability option)))
                              (error "malformed scnf form (expected (OR ...), (PROBABILITY ...), or (OPTION ...)): ~S" f))
                         collect f)))))
    (values (remove-if-not (lambda (f) (eq (car f) 'or)) forms)
            (remove-if-not (lambda (f) (eq (car f) 'probability)) forms)
            (remove-if-not (lambda (f) (eq (car f) 'option)) forms))))

(defun rw--probability-gid (pf)
  "The tie-group id of a (PROBABILITY literal p [gid]) form -- the 4th element if
present, else NIL (the caller treats a missing gid as an untied singleton)."
  (when (>= (length pf) 4) (fourth pf)))

(defun rw--collect-groups (probabilities)
  "Group (PROBABILITY literal p [gid]) forms by tie-group id.  Returns an ordered
list of (gid p . atoms): GID the group id, P its shared target marginal P(atom
true) (constant within the group), ATOMS the group's positive atoms in first-seen
order.  Forms with no gid are each their own singleton group.  Signals an error if
one literal is targeted under two different gids (overlapping forms) or if P is
not constant within a gid."
  (let ((order '())
        (gid->p (make-hash-table :test 'equal))
        (gid->atoms (make-hash-table :test 'equal))
        (atom->gid (make-hash-table :test 'equal))
        (singletons 0))
    (dolist (pf probabilities)
      (unless (and (consp pf) (member (length pf) '(3 4)))
        (error "malformed PROBABILITY form (expected (PROBABILITY literal p [gid])): ~S" pf))
      (multiple-value-bind (atom p) (rw--target-marginal (second pf) (third pf))
        (let ((gid (or (rw--probability-gid pf) (list :untied (incf singletons)))))
          ;; overlap: a literal targeted by two different tie groups
          (let ((prev (gethash atom atom->gid)))
            (when (and prev (not (equal prev gid)))
              (error "literal ~S is targeted by two different tie groups (~S and ~S); ~
overlapping PROBABILITY forms are not allowed" atom prev gid))
            (setf (gethash atom atom->gid) gid))
          ;; p constant within a group
          (multiple-value-bind (gp present) (gethash gid gid->p)
            (cond (present
                   (unless (= gp p)
                     (error "tie group ~S has a non-constant target probability (~S vs ~S); ~
p must be constant within a group" gid gp p)))
                  (t (setf (gethash gid gid->p) p)
                     (push gid order))))
          (unless (member atom (gethash gid gid->atoms) :test 'equal)
            (push atom (gethash gid gid->atoms))))))
    (loop for gid in (nreverse order)
          collect (list* gid (gethash gid gid->p) (nreverse (gethash gid gid->atoms))))))

;;; ----------------------------------------------------------------------------
;;; Write-back: replace (PROBABILITY ...) forms in the source .wff with the
;;; learned tied (WEIGHT ...) costs.  find-probability-forms and the gid rule
;;; MUST match FiFO.lisp (find-probability-forms / probability-form-gid) so the
;;; ids assigned here line up with the ones instantiate stamped into the .scnf.
;;; ----------------------------------------------------------------------------

(defun rw--find-probability-forms (form)
  "Depth-first list of every (PROBABILITY ...) subform of FORM, document order."
  (cond ((not (consp form)) nil)
        ((eq (car form) 'probability) (list form))
        (t (loop for sub in form append (rw--find-probability-forms sub)))))

(defun rw--wff-gids (forms)
  "eq-hash mapping each (PROBABILITY ...) form in FORMS to its tie-group id, by
FiFO's rule: an explicit trailing symbol label, else a document-order integer."
  (let ((h (make-hash-table :test 'eq)) (counter 0))
    (dolist (form (rw--find-probability-forms forms) h)
      (let ((label (cadddr form)))
        (setf (gethash form h)
              (if (and label (symbolp label)) label (incf counter)))))))

(defun rw--spec-replacement (schema-lit spec scale)
  "The replacement .wff form for a (PROBABILITY SCHEMA-LIT ...) given its group
SPEC = (:theta r) | (:hard 1) | (:hard 0): a (WEIGHT ...) cost on the positive
atom (polarity from the sign of r), a hard unit (OR ...) for a certainty, or a
tautology no-op when the weight rounds away."
  (let ((atom (rw--literal-atom-and-sign schema-lit)))   ; positive atom; p already normalized to it
    (destructuring-bind (kind val) spec
      (ecase kind
        (:hard  (if (= val 1) (list 'or atom) (list 'or (list 'not atom))))
        (:theta (or (rw--emit-for-theta atom val scale)
                    (list 'or atom (list 'not atom))))))))   ; rounds to 0 -> unconstrained

(defun rw--subst-probability (form repl)
  "Copy FORM, replacing each (PROBABILITY ...) subform with its value in the
eq-hash REPL."
  (cond ((not (consp form)) form)
        ((eq (car form) 'probability) (or (gethash form repl) form))
        (t (mapcar (lambda (sub) (rw--subst-probability sub repl)) form))))

(defun rw--write-back (wff-file out-file gid->spec scale)
  "Read WFF-FILE and write OUT-FILE, identical except each (PROBABILITY ...) form
is replaced by the (WEIGHT ...)/hard form for its tie group from GID->SPEC."
  (let* ((forms (let ((*read-eval* nil))
                  (with-open-file (in wff-file :direction :input)
                    (loop for f = (read in nil :eof) until (eq f :eof) collect f))))
         (gids (rw--wff-gids forms))
         (repl (make-hash-table :test 'eq)))
    (maphash (lambda (form gid)
               (let ((spec (gethash gid gid->spec)))
                 (unless spec
                   (error "no learned weight for tie group ~S; the .wff and .scnf disagree ~
(was the .scnf produced by instantiating this .wff?)" gid))
                 (setf (gethash form repl) (rw--spec-replacement (second form) spec scale))))
             gids)
    (with-open-file (out out-file :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format out "; weights written back into ~A~%" (file-namestring wff-file))
      (format out "; each (PROBABILITY ...) replaced by its learned tied (WEIGHT ...) cost~%")
      (dolist (f forms) (format out "~S~%" (rw--subst-probability f repl))))
    out-file))

(defun rw--default-wff-out (wff-file)
  (cl-ppcre:regex-replace "\\.[^.]*$" wff-file "_weighted.wff"))

(defun reweight (scnf-file &key out-file (scale 100) wff wff-out)
  "Read SCNF-FILE, whose (PROBABILITY literal p [gid]) lines give target marginal
probabilities, and write <root>_reweighted.scnf with integer weights produced by
the independent log-odds estimator.  Tie groups (shared gid) share one weight --
automatic here, since the weight depends only on p.  SCALE (default 100) sets the
integer resolution / temperature.

If WFF is given (the source .wff that produced SCNF-FILE), also write a copy of it
with each (PROBABILITY ...) form replaced by its tied (WEIGHT ...) cost, to
WFF-OUT (default <wff-root>_weighted.wff).  Returns the .scnf output pathname."
  (unless (and (integerp scale) (plusp scale))
    (error "scale must be a positive integer; got ~S" scale))
  (multiple-value-bind (clauses probabilities options) (rw--read-scnf scnf-file)
   (let ((groups (rw--collect-groups probabilities))
         (new-weights '())
         (new-hard '())
         (gid->spec (make-hash-table :test 'equal)))
    (dolist (g groups)
      (destructuring-bind (gid p . atoms) g
        (setf (gethash gid gid->spec)
              (cond ((= p 0d0) (list :hard 0))
                    ((= p 1d0) (list :hard 1))
                    (t (list :theta (log (/ (- 1d0 p) p))))))
        (dolist (atom atoms)
          (multiple-value-bind (weight-form hard-form) (rw--emit-for-atom atom p scale)
            (when weight-form (push weight-form new-weights))
            (when hard-form (push hard-form new-hard))))))
    (setq new-weights (nreverse new-weights)
          new-hard (nreverse new-hard))
    (unless out-file
      (setq out-file (cl-ppcre:regex-replace "\\.[^.]*$" scnf-file "_reweighted.scnf")))
    (with-open-file (out out-file :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format out "; reweighted from ~A~%" (file-namestring scnf-file))
      (format out "; method: independent log-odds (theta = log((1-p)/p)); scale: ~D~%" scale)
      (format out "; recovered real weight of any line below = integer weight / ~D~%" scale)
      (format out "; original probability assertions echoed below as ;; comments~%")
      (dolist (pf probabilities) (format out ";; ~S~%" pf))  ; provenance: the targets
      (dolist (c clauses) (format out "~S~%" c))         ; original hard clauses
      (dolist (c new-hard) (format out "~S~%" c))        ; certainties (p=0 / p=1)
      (dolist (w new-weights) (format out "~S~%" w))     ; integer-weighted literals
      (dolist (o options) (format out "~S~%" o)))        ; pass options through
    (when wff
      (rw--write-back wff (or wff-out (rw--default-wff-out wff)) gid->spec scale))
    out-file)))
