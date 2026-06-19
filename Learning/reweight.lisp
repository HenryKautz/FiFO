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

(defun rw--collect-targets (probabilities)
  "Turn a list of (PROBABILITY literal p) forms into an alist
(atom . prob-atom-true), normalizing negated literals.  Signals an error on a
malformed form or on an atom given a target more than once."
  (let ((seen (make-hash-table :test 'equal))
        (out '()))
    (dolist (pf probabilities)
      (unless (= (length pf) 3)
        (error "malformed PROBABILITY form (expected (PROBABILITY literal p)): ~S" pf))
      (multiple-value-bind (atom p) (rw--target-marginal (second pf) (third pf))
        (when (gethash atom seen)
          (error "atom ~S is given a target probability more than once" atom))
        (setf (gethash atom seen) t)
        (push (cons atom p) out)))
    (nreverse out)))

(defun reweight (scnf-file &key out-file (scale 100))
  "Read SCNF-FILE, whose (WEIGHT literal p) lines give target marginal
probabilities, and write <root>_reweighted.scnf with integer weights produced by
the independent log-odds estimator.  SCALE (default 100) sets the integer
resolution / temperature.  Returns the output pathname."
  (unless (and (integerp scale) (plusp scale))
    (error "scale must be a positive integer; got ~S" scale))
  (multiple-value-bind (clauses probabilities options) (rw--read-scnf scnf-file)
   (let ((new-weights '())
         (new-hard '()))
    (dolist (tg (rw--collect-targets probabilities))
      (multiple-value-bind (weight-form hard-form) (rw--emit-for-atom (car tg) (cdr tg) scale)
        (when weight-form (push weight-form new-weights))
        (when hard-form (push hard-form new-hard))))
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
    out-file)))
