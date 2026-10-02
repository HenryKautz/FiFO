;;; wmc.lisp
;;;
;;; FiFO -> ADDMC bridge: exact weighted model counting and marginal inference
;;; via ADDMC (Algebraic Decision Diagram Model Counter, vardigroup/ADDMC).
;;;
;;; This is "Method 3 (WMC tools)" of Probability/probability.md.  Where maxent.lisp's
;;; (marginals ...) enumerates the feasible set in Lisp -- exact but exponential --
;;; this path compiles the same weighted .scnf to a weighted CNF, hands it to the
;;; ADDMC executable, and parses the count back.  ADDMC counts via algebraic
;;; decision diagrams, so it scales to instances far beyond brute enumeration.
;;;
;;; The probability model is identical to maxent.lisp's: the WCNF defines a Gibbs
;;; distribution over the feasible set F (the satisfying assignments of the hard
;;; (OR ...) clauses),
;;;
;;;     P(x) proportional to exp(-(sum of the weights of the true literals)),  x in F,
;;;
;;; so the partition function Z = sum_{x in F} exp(-cost(x)) is exactly a weighted
;;; model count, and the marginal P(L) = Z[clauses and L] / Z is a ratio of two
;;; weighted model counts.
;;;
;;; Emitted format: MCC-2020 weighted CNF (ADDMC's --wf 4).  Each FiFO weighted
;;; literal L with total cost-when-true theta becomes the MCC weight line
;;; "w <lit> exp(-theta)"; the opposite literal keeps ADDMC's default weight 1.0.
;;; This matches FiFO's encoding W(L true) = exp(-theta), W(L false) = 1 directly,
;;; and -- unlike the Cachet format -- lets the two literal weights be independent.
;;;
;;; WMC--WRITE-MCC also emits the LATER competition dialect (:dialect :mcc-2024),
;;; which SharpSAT-TD and other post-2020 counters read.  The two are NOT textually
;;; interconvertible -- they disagree on what an unstated literal polarity means --
;;; so see that function's docstring before adding a back end that consumes one.
;;;
;;; Entry points:
;;;   (wmc "file.scnf" &key ...)             -- partition function Z
;;;   (marginals-addmc "file.scnf" &key ...) -- per-atom marginals via clamping
;;;   (wmc-write-wcnf "file.scnf" out &key dialect ...) -- the weighted CNF alone

(load (merge-pathnames "maxent.lisp" (or *load-pathname* *default-pathname-defaults*)))

(defvar *addmc* "addmc"
  "Name of the ADDMC weighted-model-counter binary, found on PATH.  Point at a
different build the way you would for any other program -- by putting it earlier
on PATH -- rather than through a FiFO-specific setting.")

;;; ----------------------------------------------------------------------------
;;; Emitting MCC-2020 weighted CNF
;;; ----------------------------------------------------------------------------

(defun wmc--scratch-wcnf ()
  "A unique scratch .wcnf path (in the current directory, using FiFO's
scratch-file naming), so a generated/deleted scratch file can never collide with
or clobber a user's file."
  (format nil "~A.wcnf" (make-scratch-file-root)))

(defun wmc--literal-costs (weights a2i)
  "From the (WEIGHT literal w) forms, return a hash table mapping a signed DIMACS
literal (+i for the positive atom, -i for a negated one) to its TOTAL
cost-when-true, summing duplicate/tied forms.  The MCC weight of that literal is
exp(- total cost)."
  (let ((cost (make-hash-table :test 'eql)))
    (dolist (wf weights)
      (multiple-value-bind (atom positivep) (rw--literal-atom-and-sign (second wf))
        (let ((var (or (gethash atom a2i)
                       (error "weighted atom ~S is not indexed" atom)))
              (w (third wf)))
          (unless (realp w) (error "non-numeric weight in ~S" wf))
          (let ((lit (if positivep var (- var))))
            (incf (gethash lit cost 0.0d0) (float w 1.0d0))))))
    cost))

(defun wmc--write-mcc (clauses weights a2i nvars out-stream
                       &key extra-units (scale 1.0d0) (dialect :mcc-2020))
  "Write the weighted CNF for CLAUSES + WEIGHTS to OUT-STREAM in DIALECT.
EXTRA-UNITS is a list of signed DIMACS literals emitted as extra unit clauses
(used to clamp atoms when computing marginals).  Each literal's total cost is
divided by SCALE before exponentiating, recovering the real cost from the
pipeline's integer (cost * scale) weights.

DIALECT is :MCC-2020 (ADDMC's --wf 4) or :MCC-2024 (the Model Counting
Competition format from 2021 on, which SharpSAT-TD reads).  They differ in three
ways, and the third is a trap:

  problem line   'p wcnf V C'             vs  'p cnf V C'
  weight line    'w <lit> <w>', trailing  vs  'c p weight <lit> <w> 0' -- the
                 0 optional                   trailing 0 is REQUIRED, the parser
                                              matching on exactly 6 tokens
  missing side   defaults to 1.0          vs  INFERRED, differently (below)

The 2024 weight lines are comments so the file is also a legal plain DIMACS CNF.
That is what makes a purely textual translation between the dialects unsafe: a
reader that skips comments counts the formula UNWEIGHTED and says nothing.

The trap is the default.  FiFO's model is W(L true) = exp(-theta),
W(L false) = 1, and under :MCC-2020 we emit only the charged literal and let
ADDMC default its opposite to 1.0.  SharpSAT-TD instead INFERS a missing polarity
from the one given: if neither is given both are 1, but if one is given and lies
in [0,1] it assumes the other is 1 - w -- a PROBABILITY reading, not FiFO's --
and if one is given outside [0,1] (which a negative FiFO cost produces, say a
learned weight or (weight ... :odds r) with r > 1) it is a hard error.  So
reusing the 2020 weight lines would silently rescale the distribution in the
common case and crash in the other.

We therefore emit BOTH polarities of EVERY variable under :MCC-2024, each as
exp(-cost/scale) with an absent cost taken as 0 (hence weight 1).  That is 2V
weight lines rather than one per charged literal, but then no inference rule of
any reader can fire: the file states FiFO's distribution outright rather than
leaning on a convention the two counters do not share."
  (let* ((cost (wmc--literal-costs weights a2i))
         (nclauses (+ (length clauses) (length extra-units)))
         (lit-weight (lambda (lit)
                       (exp (- (/ (gethash lit cost 0.0d0) scale))))))
    (ecase dialect
      (:mcc-2020 (format out-stream "p wcnf ~D ~D~%" nvars nclauses))
      ;; 'c t wmc' declares the track.  SharpSAT-TD asserts if this disagrees with
      ;; its -WE/-WD mode, so it must say wmc and not mc.
      (:mcc-2024 (format out-stream "c t wmc~%p cnf ~D ~D~%" nvars nclauses)))
    (dolist (cl clauses)
      (loop for i across (mx--clause->ints cl a2i)
            do (format out-stream "~D " i))
      (format out-stream "0~%"))
    (dolist (u extra-units)
      (format out-stream "~D 0~%" u))
    ;; '~,16,,,,,'eE forces a C-parseable 'e' exponent (not Lisp's 'd').  Both
    ;; readers accept it: ADDMC uses std::stod, and SharpSAT-TD's ParseWeight is
    ;; stod plus an 'a/b' fraction form.
    (ecase dialect
      (:mcc-2020
       ;; Only the charged literals; each opposite side defaults to 1.0.
       (maphash (lambda (lit c)
                  (declare (ignore c))
                  (format out-stream "w ~D ~,16,,,,,'eE~%" lit (funcall lit-weight lit)))
                cost))
      (:mcc-2024
       ;; Both polarities of every variable, so nothing is left to infer.
       (loop for v from 1 to nvars
             do (dolist (lit (list v (- v)))
                  (format out-stream "c p weight ~D ~,16,,,,,'eE 0~%"
                          lit (funcall lit-weight lit))))))))

;;; ----------------------------------------------------------------------------
;;; Running ADDMC and parsing its count
;;; ----------------------------------------------------------------------------

(defun wmc--parse-count (out err)
  "Parse the weighted model count from ADDMC's OUT (stdout); ERR is included in
error messages.  ADDMC prints one solution line 's wmc <value>' (or 's mc
<value>' for an unweighted formula)."
  (let ((line (with-input-from-string (s out)
                (loop for l = (read-line s nil :eof)
                      until (eq l :eof)
                      when (and (>= (length l) 1) (char= (char l 0) #\s))
                        do (return l)))))
    (unless line
      (error "ADDMC produced no 's' result line.~%--- stdout ---~%~A~%--- stderr ---~%~A"
             out err))
    (let ((toks (cl-ppcre:split "\\s+" (string-trim '(#\Space #\Tab) line))))
      (unless (>= (length toks) 3)
        (error "cannot parse ADDMC result line: ~S" line))
      (let* ((*read-default-float-format* 'double-float)
             (val (ignore-errors (read-from-string (third toks)))))
        (unless (realp val)
          (error "ADDMC result is not a number: ~S" line))
        (float val 1.0d0)))))

(defun wmc--run-addmc (wcnf-file &key (addmc *addmc*) epsilon)
  "Run ADDMC on WCNF-FILE (MCC weight format, --wf 4) and return the weighted
model count as a double-float.  EPSILON, when non-NIL, is passed as ADDMC's --ep
(CUDD terminal-merging tolerance); NIL uses ADDMC's default of 0 (exact, full
double precision)."
  (multiple-value-bind (out err code)
      (handler-case
          (uiop:run-program (append (list addmc "--cf" wcnf-file "--wf" "4")
                                    (when epsilon
                                      (list "--ep" (format nil "~,16,,,,,'eE"
                                                           (float epsilon 1.0d0)))))
                            :output :string :error-output :string
                            :ignore-error-status t)
        (error (c)
          (error "could not run ADDMC (~A): ~A~%Put an 'addmc' on PATH (bin/install-solvers.sh --only addmc)."
                 addmc c)))
    (when (and code (not (zerop code)))
      (error "ADDMC (~A) exited with code ~A.~%--- stdout ---~%~A~%--- stderr ---~%~A"
             addmc code out err))
    (wmc--parse-count out err)))

;;; ----------------------------------------------------------------------------
;;; Conditioning: ground evidence -> hard clauses
;;; ----------------------------------------------------------------------------

(defun wmc--read-forms (path)
  "Read all FiFO forms (top-level s-expressions) from PATH."
  (let ((*read-eval* nil))
    (with-open-file (in path :direction :input)
      (loop for f = (read in nil :eof) until (eq f :eof) collect f))))

(defun wmc--evidence-clauses (evidence evidence-file)
  "Clausify ground FiFO EVIDENCE formulas (a list of forms) plus the forms in
EVIDENCE-FILE into hard (OR ...) clauses, using FiFO's parser, to be conjoined
with the theory -- i.e. to condition on them.  The formulas must be GROUND
(propositional, over atoms already named in the scnf): grounding a quantified or
parametric formula needs the domains in the .wff, which the scnf has discarded.
Returns the list of clauses (possibly empty)."
  (let ((forms (append evidence
                       (when evidence-file (wmc--read-forms evidence-file)))))
    (when forms
      (handler-case
          (parse forms) ; resets FiFO's globals; we read the scnf separately, so harmless
        (error (c)
          (error "could not clausify evidence ~S:~%  ~A~%Evidence must be a GROUND formula over atoms already in the scnf; quantified or parametric evidence needs the .wff (re-instantiate with the assertion added)."
                 forms c))))))

(defun wmc--clause-atoms (clauses)
  "The set (document order) of atoms occurring in CLAUSES, a list of (OR ...) forms."
  (remove-duplicates
   (loop for cl in clauses
         append (mapcar (lambda (lit) (rw--literal-atom-and-sign lit)) (cdr cl)))
   :test #'equal :from-end t))

;;; ----------------------------------------------------------------------------
;;; Entry points
;;; ----------------------------------------------------------------------------

(defun wmc (scnf-file &key wcnf-file keep-wcnf scale epsilon evidence evidence-file
                           (addmc *addmc*) (verbose t))
  "Exact weighted model count (partition function Z) of a weighted .scnf via ADDMC.
Z = sum over the feasible set of exp(-(sum of the REAL weights of the true
literals)).  The integer weights are divided by SCALE first -- a positive number
to force one, or NIL (the default) to read the 'scale: N' the weight-learning
pipeline records in the header (1.0 if absent).  This matters because the
pipeline scales costs by an integer factor (100 by default) for MaxSAT, and e.g.
exp(-100*theta) is a near-zero distribution; pass :scale 1 to count with the raw
integer weights.  EPSILON is ADDMC's CUDD terminal-merging tolerance (its --ep);
NIL (default) uses ADDMC's default of 0 -- exact, full double precision -- while a
positive value trades exactness for speed/memory.  EVIDENCE (a list of ground
FiFO formulas) and EVIDENCE-FILE (a file of them) are conjoined with the theory as
HARD clauses, so Z becomes the count of the theory conditioned on that evidence;
the formulas must be ground (see WMC--EVIDENCE-CLAUSES).  Writes a scratch MCC
weighted CNF (WCNF-FILE, default a unique scratch name), runs ADDMC, and returns Z
as a double-float.  The scratch file is deleted unless KEEP-WCNF is set or
WCNF-FILE was given explicitly."
  ;; NB: bind the weight forms to a NON-special name -- the obvious WEIGHTS is
  ;; FiFO's global special, which (parse ...) inside wmc--evidence-clauses resets.
  (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let* ((weight-atoms (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                 weight-forms))
           (scale (rw--resolve-scale scnf-file scale verbose))
           (evidence-clauses (wmc--evidence-clauses evidence evidence-file))
           (clauses (append clauses evidence-clauses)))
      (when (and verbose evidence-clauses)
        (format t "; conditioning on ~D evidence clause~:P~%" (length evidence-clauses)))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (let ((wcnf (or wcnf-file (wmc--scratch-wcnf))))
          (with-open-file (s wcnf :direction :output
                                  :if-exists :supersede :if-does-not-exist :create)
            (wmc--write-mcc clauses weight-forms a2i nvars s :scale scale))
          (let ((z (wmc--run-addmc wcnf :addmc addmc :epsilon epsilon)))
            (if (or keep-wcnf wcnf-file)
                (when (and verbose keep-wcnf) (format t "; wcnf kept: ~A~%" wcnf))
                (ignore-errors (delete-file wcnf)))
            (when verbose (format t "(WMC ~,16,,,,,'eE)~%" z))
            z))))))

(defun wmc-write-wcnf (scnf-file out-file &key (dialect :mcc-2020) scale
                                                 evidence evidence-file (verbose t))
  "Write SCNF-FILE's weighted CNF to OUT-FILE in DIALECT and return OUT-FILE.
The counting back ends generate this file internally and delete it; this is the
same writer exposed on its own, for handing a FiFO theory to an external counter
(SharpSAT-TD takes :dialect :mcc-2024) or for inspecting what a counter is
actually being asked.  SCALE, EVIDENCE and EVIDENCE-FILE behave as in WMC.
Returns (values out-file nvars nclauses)."
  ;; Same preamble as WMC, and the same warning applies: bind the weight forms to
  ;; a NON-special name, since WEIGHTS is FiFO's global special and (parse ...)
  ;; inside wmc--evidence-clauses resets it.
  (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let* ((weight-atoms (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                 weight-forms))
           (scale (rw--resolve-scale scnf-file scale verbose))
           (evidence-clauses (wmc--evidence-clauses evidence evidence-file))
           (clauses (append clauses evidence-clauses)))
      (when (and verbose evidence-clauses)
        (format t "; conditioning on ~D evidence clause~:P~%" (length evidence-clauses)))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (with-open-file (s out-file :direction :output
                                    :if-exists :supersede :if-does-not-exist :create)
          (wmc--write-mcc clauses weight-forms a2i nvars s :scale scale :dialect dialect))
        (when verbose
          (format t "; wrote ~A (~(~A~), ~D var~:P, ~D clause~:P)~%"
                  out-file dialect nvars (length clauses)))
        (values out-file nvars (length clauses))))))

(defun marginals-addmc (scnf-file &key out-file weighted-only keep-wcnf scale epsilon
                                       evidence evidence-file (addmc *addmc*) (verbose t))
  "Exact marginal P(atom = true) of every atom in a weighted .scnf, via ADDMC.
For partition function Z and each target atom's clamped count Z_a (Z with a unit
clause forcing the atom true), reports P(a) = Z_a / Z.  This is exact but costs
one ADDMC run for Z plus one per target atom.  With WEIGHTED-ONLY, only the atoms
that carry a weight are reported (and clamped); otherwise every atom is.  SCALE is
as in WMC: NIL (default) reads the pipeline's 'scale: N' header so the marginals
reflect the REAL costs rather than the MaxSAT-scaled integers; pass :scale 1 for
the raw weights.  EPSILON is ADDMC's CUDD terminal-merging tolerance (its --ep);
NIL (default) uses ADDMC's default of 0 -- exact, full double precision.  EVIDENCE
(a list of ground FiFO formulas) and EVIDENCE-FILE (a file of them) are conjoined
with the theory as HARD clauses, so the reported marginals are CONDITIONAL on that
evidence -- each P(a) becomes P(a | evidence); the formulas must be ground (see
WMC--EVIDENCE-CLAUSES).  Atoms introduced only by the evidence (e.g. Tseitin
auxiliaries) are not themselves reported.  Prints one (MARGINAL <atom> <p>) line
per atom (sorted) and, with OUT-FILE, also writes them there.  Returns an alist of
(atom . probability)."
  ;; NB: WEIGHT-FORMS, not the special WEIGHTS (which parse resets) -- see wmc.
  (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let ((weight-atoms (remove-duplicates
                         (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                 weight-forms)
                         :test #'equal)))
      (when (and weighted-only (null weight-atoms))
        (when verbose (format t "; no weighted atoms in ~A~%" scnf-file))
        (return-from marginals-addmc nil))
      (setf scale (rw--resolve-scale scnf-file scale verbose))
      (let* ((evidence-clauses (wmc--evidence-clauses evidence evidence-file))
             ;; report only theory atoms (and weighted atoms), never evidence-only auxiliaries
             (theory-atoms (remove-duplicates (append (wmc--clause-atoms clauses) weight-atoms)
                                              :test #'equal :from-end t))
             (clauses (append clauses evidence-clauses)))
        (when (and verbose evidence-clauses)
          (format t "; conditioning on ~D evidence clause~:P~%" (length evidence-clauses)))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (let ((i2a (make-array (1+ nvars) :initial-element nil))
              (wcnf (wmc--scratch-wcnf)))
          (maphash (lambda (atom i) (setf (aref i2a i) atom)) a2i)
          (flet ((count-with (extra-units)
                   (with-open-file (s wcnf :direction :output
                                           :if-exists :supersede :if-does-not-exist :create)
                     (wmc--write-mcc clauses weight-forms a2i nvars s :extra-units extra-units :scale scale))
                   (wmc--run-addmc wcnf :addmc addmc :epsilon epsilon)))
            (let* ((target-vars (if weighted-only
                                    (mapcar (lambda (a) (gethash a a2i)) weight-atoms)
                                    ;; hide internal reification atoms from the default
                                    ;; listing (also skips an ADDMC run each); they show
                                    ;; under --weighted-only, where P(atom)=P(formula)
                                    (mapcar (lambda (a) (gethash a a2i))
                                            (remove-if #'reified-formula-atom-p theory-atoms))))
                   (z (count-with nil)))
              (when (<= z 0.0d0)
                (unless keep-wcnf (ignore-errors (delete-file wcnf)))
                (error "partition function is 0 -- the hard clauses are unsatisfiable, or a too-large :epsilon floored the count to 0; either way no marginals exist"))
              (let ((results
                      (sort (loop for v in target-vars
                                  for zt = (count-with (list v))
                                  collect (cons (aref i2a v) (/ zt z)))
                            #'string< :key (lambda (c) (format nil "~S" (car c))))))
                (unless keep-wcnf (ignore-errors (delete-file wcnf)))
                (when verbose
                  (dolist (r results)
                    (format t "(MARGINAL ~S ~,16,,,,,'eE)~%" (car r) (cdr r))))
                (when out-file
                  (with-open-file (o out-file :direction :output
                                              :if-exists :supersede :if-does-not-exist :create)
                    (dolist (r results)
                      (format o "(MARGINAL ~S ~,16,,,,,'eE)~%" (car r) (cdr r)))))
                results)))))))))
