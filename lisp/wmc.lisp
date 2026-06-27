;;; wmc.lisp
;;;
;;; FiFO -> ADDMC bridge: exact weighted model counting and marginal inference
;;; via ADDMC (Algebraic Decision Diagram Model Counter, vardigroup/ADDMC).
;;;
;;; This is "Method 3 (WMC tools)" of Inference/marginals.md.  Where maxent.lisp's
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
;;; Entry points:
;;;   (wmc "file.scnf" &key ...)             -- partition function Z
;;;   (marginals-addmc "file.scnf" &key ...) -- per-atom marginals via clamping

(load (merge-pathnames "maxent.lisp" (or *load-pathname* *default-pathname-defaults*)))

(defvar *addmc* (or (uiop:getenv "ADDMC") "addmc")
  "Path or name of the ADDMC weighted-model-counter binary.  Defaults to the
ADDMC environment variable, else \"addmc\" (found on PATH).")

;;; ----------------------------------------------------------------------------
;;; Emitting MCC-2020 weighted CNF
;;; ----------------------------------------------------------------------------

(defun wmc--scratch-wcnf ()
  "A unique scratch .wcnf path (in the current directory, using FiFO's
scratch-file naming), so a generated/deleted scratch file can never collide with
or clobber a user's file."
  (format nil "~A.wcnf" (make-scratch-file-root)))

(defun wmc--detect-scale (scnf-file)
  "Scan SCNF-FILE's comment header for a 'scale: <n>' annotation -- written by the
weight-learning pipeline (reweight.lisp / maxent.lisp), whose integer weights are
the real costs MULTIPLIED by this scale.  Return the scale as a double-float, or
1.0 when there is no such annotation (e.g. hand-written or SatPlan-cost scnfs,
whose weights are already real costs)."
  (with-open-file (in scnf-file :direction :input)
    (loop for line = (read-line in nil :eof)
          until (eq line :eof)
          for trimmed = (string-left-trim '(#\Space #\Tab) line)
          when (and (> (length trimmed) 0) (char= (char trimmed 0) #\;))
            do (let ((groups (nth-value 1 (cl-ppcre:scan-to-strings
                                           "scale:\\s*([0-9]+(?:\\.[0-9]+)?)" trimmed))))
                 (when groups
                   (return-from wmc--detect-scale
                     (float (read-from-string (aref groups 0)) 1.0d0))))))
  1.0d0)

(defun wmc--resolve-scale (scnf-file scale verbose)
  "Resolve the weight scale for SCNF-FILE: SCALE if a positive number was given,
otherwise auto-detected from the header (default 1.0).  The integer weights are
divided by this before being exponentiated, recovering the real costs."
  (let ((s (cond ((null scale) (wmc--detect-scale scnf-file))
                 ((and (realp scale) (> scale 0)) (float scale 1.0d0))
                 (t (error "scale must be a positive number, or NIL to auto-detect; got ~S"
                           scale)))))
    (when (and verbose (/= s 1.0d0))
      (format t "; weight scale ~F: real cost = integer weight / ~:*~F (pass :scale 1 to use raw weights)~%" s))
    s))

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

(defun wmc--write-mcc (clauses weights a2i nvars out-stream &key extra-units (scale 1.0d0))
  "Write the MCC-2020 weighted CNF for CLAUSES + WEIGHTS to OUT-STREAM.
EXTRA-UNITS is a list of signed DIMACS literals emitted as extra unit clauses
(used to clamp atoms when computing marginals).  Each literal's total cost is
divided by SCALE before exponentiating, recovering the real cost from the
pipeline's integer (cost * scale) weights."
  (let* ((cost (wmc--literal-costs weights a2i))
         (nclauses (+ (length clauses) (length extra-units))))
    (format out-stream "p wcnf ~D ~D~%" nvars nclauses)
    (dolist (cl clauses)
      (loop for i across (mx--clause->ints cl a2i)
            do (format out-stream "~D " i))
      (format out-stream "0~%"))
    (dolist (u extra-units)
      (format out-stream "~D 0~%" u))
    ;; Weight lines: exp(-cost/scale) for each charged literal; ADDMC defaults the
    ;; rest to 1.0.  '~,16,,,,,'eE forces a C-parseable 'e' exponent (not Lisp's 'd').
    (maphash (lambda (lit c)
               (format out-stream "w ~D ~,16,,,,,'eE~%" lit (exp (- (/ c scale)))))
             cost)))

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

(defun wmc--run-addmc (wcnf-file &key (addmc *addmc*))
  "Run ADDMC on WCNF-FILE (MCC weight format, --wf 4) and return the weighted
model count as a double-float."
  (multiple-value-bind (out err code)
      (handler-case
          (uiop:run-program (list addmc "--cf" wcnf-file "--wf" "4")
                            :output :string :error-output :string
                            :ignore-error-status t)
        (error (c)
          (error "could not run ADDMC (~A): ~A~%Set the ADDMC environment variable or pass :addmc to point at the binary."
                 addmc c)))
    (when (and code (not (zerop code)))
      (error "ADDMC (~A) exited with code ~A.~%--- stdout ---~%~A~%--- stderr ---~%~A"
             addmc code out err))
    (wmc--parse-count out err)))

;;; ----------------------------------------------------------------------------
;;; Entry points
;;; ----------------------------------------------------------------------------

(defun wmc (scnf-file &key wcnf-file keep-wcnf scale (addmc *addmc*) (verbose t))
  "Exact weighted model count (partition function Z) of a weighted .scnf via ADDMC.
Z = sum over the feasible set of exp(-(sum of the REAL weights of the true
literals)).  The integer weights are divided by SCALE first -- a positive number
to force one, or NIL (the default) to read the 'scale: N' the weight-learning
pipeline records in the header (1.0 if absent).  This matters because the
pipeline scales costs by an integer factor (100 by default) for MaxSAT, and e.g.
exp(-100*theta) is a near-zero distribution; pass :scale 1 to count with the raw
integer weights.  Writes a
scratch MCC weighted CNF (WCNF-FILE, default a unique scratch name), runs ADDMC,
and returns Z as a double-float.  The scratch file is deleted unless KEEP-WCNF is
set or WCNF-FILE was given explicitly."
  (multiple-value-bind (clauses probs opts weights) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let ((weight-atoms (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                weights))
          (scale (wmc--resolve-scale scnf-file scale verbose)))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (let ((wcnf (or wcnf-file (wmc--scratch-wcnf))))
          (with-open-file (s wcnf :direction :output
                                  :if-exists :supersede :if-does-not-exist :create)
            (wmc--write-mcc clauses weights a2i nvars s :scale scale))
          (let ((z (wmc--run-addmc wcnf :addmc addmc)))
            (if (or keep-wcnf wcnf-file)
                (when (and verbose keep-wcnf) (format t "; wcnf kept: ~A~%" wcnf))
                (ignore-errors (delete-file wcnf)))
            (when verbose (format t "(WMC ~,16,,,,,'eE)~%" z))
            z))))))

(defun marginals-addmc (scnf-file &key out-file weighted-only keep-wcnf scale
                                       (addmc *addmc*) (verbose t))
  "Exact marginal P(atom = true) of every atom in a weighted .scnf, via ADDMC.
For partition function Z and each target atom's clamped count Z_a (Z with a unit
clause forcing the atom true), reports P(a) = Z_a / Z.  This is exact but costs
one ADDMC run for Z plus one per target atom.  With WEIGHTED-ONLY, only the atoms
that carry a weight are reported (and clamped); otherwise every atom is.  SCALE is
as in WMC: NIL (default) reads the pipeline's 'scale: N' header so the marginals
reflect the REAL costs rather than the MaxSAT-scaled integers; pass :scale 1 for
the raw weights.  Prints one (MARGINAL <atom> <p>) line per atom (sorted) and,
with OUT-FILE, also writes them there.  Returns an alist of (atom . probability)."
  (multiple-value-bind (clauses probs opts weights) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let ((weight-atoms (remove-duplicates
                         (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                 weights)
                         :test #'equal)))
      (when (and weighted-only (null weight-atoms))
        (when verbose (format t "; no weighted atoms in ~A~%" scnf-file))
        (return-from marginals-addmc nil))
      (setf scale (wmc--resolve-scale scnf-file scale verbose))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (let ((i2a (make-array (1+ nvars) :initial-element nil))
              (wcnf (wmc--scratch-wcnf)))
          (maphash (lambda (atom i) (setf (aref i2a i) atom)) a2i)
          (flet ((count-with (extra-units)
                   (with-open-file (s wcnf :direction :output
                                           :if-exists :supersede :if-does-not-exist :create)
                     (wmc--write-mcc clauses weights a2i nvars s :extra-units extra-units :scale scale))
                   (wmc--run-addmc wcnf :addmc addmc)))
            (let* ((target-vars (if weighted-only
                                    (mapcar (lambda (a) (gethash a a2i)) weight-atoms)
                                    (loop for v from 1 to nvars collect v)))
                   (z (count-with nil)))
              (when (<= z 0.0d0)
                (unless keep-wcnf (ignore-errors (delete-file wcnf)))
                (error "partition function is 0 -- the hard clauses are unsatisfiable, so no marginals exist"))
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
                results))))))))
