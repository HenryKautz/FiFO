;;;; maxterm.lisp -- FiFO -> max-term marginals.
;;;;
;;;; The maximum-term (Viterbi / zero-temperature / ground-state) approximation
;;;; replaces a partition function by its single largest term:
;;;;
;;;;     Z_S = e^{-beta c_min(S)} * Omega_S(beta),   Omega_S >= 1
;;;;
;;;; and drops the degeneracy factor Omega_S.  A marginal is a ratio of two such
;;;; sums over the polarities of an atom, so
;;;;
;;;;     P(a) = sigma( beta*(c_min(~a) - c_min(a)) + log(Omega_a / Omega_~a) )
;;;;
;;;; and dropping the ratio leaves
;;;;
;;;;     P(a) ~= sigma( beta*(c_min(~a) - c_min(a)) )
;;;;
;;;; which is Ramirez & Geffner's recognizer with the hypothesis replaced by an
;;;; atom.  Each c_min is a MaxSAT solve with a unit clause clamping the atom, so
;;;; this costs MaxSAT calls where exact counting costs weighted model counts --
;;;; the same trade recognize.sh makes, generalised from goal posteriors to
;;;; arbitrary atoms.  See Probability/probability-background.md sections 14-15.
;;;;
;;;; THIS DOES NOT COMPUTE GIBBS MARGINALS.  The dropped Omega ratio is the
;;;; ASYMMETRY in near-optimal multiplicity between the two polarities, so the
;;;; method approximates what the weights contribute and discards what the
;;;; counting contributes.  On an unweighted theory every difference is 0 and it
;;;; returns 0.5 for everything, carrying no information at all.  Output is
;;;; therefore labelled (MAXTERM-MARGINAL ...), not (MARGINAL ...): it answers a
;;;; different question, and downstream code that greps for MARGINAL should not
;;;; silently pick these up.
;;;;
;;;; Two things it gets exactly right.  A backbone atom -- one whose opposite
;;;; polarity is UNSAT -- comes back as 0 or 1 with a PROOF, not an estimate.
;;;; And a group of atoms the theory makes exclusive can be renormalised over,
;;;; which recovers the exact answer in the cases where independence per atom
;;;; would not (see mt--detect-groups).

(load (merge-pathnames "wmc.lisp" (or *load-pathname* *default-pathname-defaults*)))

(defvar *maxterm-solver* nil
  "MaxSAT solver for the max-term marginals; NIL uses *solver*.  Must be a
weighted solver -- these are minimum-cost queries, not satisfiability ones.")

;;; ---------------------------------------------------------------------------
;;; Writing the weighted CNF
;;; ---------------------------------------------------------------------------

(defun mt--write-wcnf (path int-clauses costs nvars extra-units)
  "Write hard INT-CLAUSES and the soft unit clauses implied by COSTS (signed
literal -> cost when true) in the 2022 WCNF format, forcing every literal in
EXTRA-UNITS true as an additional hard clause.  Returns (values scale offset):
the solver reports an integer objective, and the real cost is
objective / scale + offset.

The scaling is not optional bookkeeping.  DIMACS wcnf requires POSITIVE INTEGER
weights, so FiFO's shift-and-scale-weights multiplies the costs by the smallest
integer that makes them integral and re-bases any negative cost onto the opposite
polarity.  Writing raw real costs instead produces a file that a MaxSAT solver
answers with no objective line at all."
  (let ((weightdata '()))
    (maphash (lambda (lit c) (unless (zerop c) (push (list lit c) weightdata))) costs)
    (multiple-value-bind (soft offset scale) (shift-and-scale-weights weightdata)
      (with-open-file (s path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
        (format s "c max-term query over ~D variables~%" nvars)
        (dolist (cl int-clauses) (format s "h ~{~D ~}0~%" (coerce cl 'list)))
        (dolist (u extra-units) (format s "h ~D 0~%" u))
        (dolist (sc soft) (format s "~D ~D 0~%" (cadr sc) (car sc))))
      (values scale offset))))

;;; ---------------------------------------------------------------------------
;;; Running the solver
;;; ---------------------------------------------------------------------------

(defun mt--objective (satout)
  "The last 'o <cost>' value in SATOUT as a rational, or NIL."
  (multiple-value-bind (status objective) (solution-lines satout)
    (declare (ignore status))
    (when objective
      (let ((tok (string-trim " " (subseq objective 2))))
        (ignore-errors (let ((*read-eval* nil)) (read-from-string tok)))))))

(defun mt--solve (int-clauses costs nvars extra-units root &key (verbose t))
  "Minimum cost of the theory with EXTRA-UNITS forced true.
Returns (values cost status), where STATUS is :OPTIMUM, :BEST (the solver was cut
short by *solver-timeout*, so COST is an upper bound), or :UNSAT (COST is NIL)."
  (let* ((wcnf (concatenate 'string root ".wcnf"))
         (out  (concatenate 'string root ".satout"))
         (solver (or *maxterm-solver* *solver*)))
    (multiple-value-bind (scale offset) (mt--write-wcnf wcnf int-clauses costs nvars extra-units)
    (multiple-value-bind (code timed-out)
        (run-program-to-file solver (list wcnf) out :timeout *solver-timeout*)
      (declare (ignore code))
      (let ((verdict (solver-verdict out))
            (obj (mt--objective out)))
        (cond ((eq verdict 'unsat) (values nil :unsat))
              ((null obj)
               (error "solver ~A produced no objective for ~A~@[ (timed out)~]~%~
                       -- is it a MaxSAT solver?  max-term needs minimum costs, not just models."
                      solver wcnf timed-out))
              (t
               (when (and timed-out verbose)
                 (format t "; ~A: solver stopped at the time limit; cost is an upper bound~%" root))
               (values (+ (/ obj scale) offset) (if timed-out :best :optimum)))))))))

;;; ---------------------------------------------------------------------------
;;; Exclusive groups
;;; ---------------------------------------------------------------------------
;;;
;;; Exclusivity is a property of the THEORY, not of the query: the exact back ends
;;; need no declaration because they see the constraints directly.  So this
;;; detects rather than asks.  The query set supplies the candidates, so there is
;;; no subset search -- only the atoms actually being reported are considered.

(defun mt--detect-groups (clauses query-atoms)
  "Groups of QUERY-ATOMS that the clauses make mutually exclusive, found
syntactically.  Returns a list of (atoms . exhaustivep).

Looks for the natural encoding: an at-least-one clause (OR H1 ... Hk) over a
subset of the query atoms, and/or the pairwise at-most-one clauses
(OR (NOT Hi) (NOT Hj)).  A group that is at-most-one but not at-least-one is
reported with EXHAUSTIVEP nil, and gets a virtual \"none of them\" outcome when
it is normalised -- renormalising such a group to 1 would be wrong.

Compact at-most-one encodings that introduce auxiliary variables are invisible
here; mt--verify-group proves exclusivity semantically instead."
  (let ((qset (make-hash-table :test 'equal))
        (amo (make-hash-table :test 'equal))   ; unordered pair -> t
        (alo '()))
    (dolist (a query-atoms) (setf (gethash a qset) t))
    (dolist (cl clauses)
      (let ((lits (cdr cl)))
        ;; (OR (NOT Hi) (NOT Hj)) over two query atoms: at-most-one for the pair
        (when (and (= (length lits) 2)
                   (every (lambda (l) (and (consp l) (eq (car l) 'not)
                                           (gethash (second l) qset)))
                          lits))
          (setf (gethash (sort (list (second (first lits)) (second (second lits)))
                               #'string< :key #'princ-to-string)
                         amo)
                t))))
    ;; at-least-one clauses: all literals positive and in the query set
    (dolist (cl clauses)
      (let ((lits (cdr cl)))
        (when (and (>= (length lits) 2)
                   (every (lambda (l) (and (not (and (consp l) (eq (car l) 'not)))
                                           (gethash l qset)))
                          lits))
          (push (copy-list lits) alo))))
    ;; Build groups: every at-least-one set whose pairs are all at-most-one is an
    ;; exclusive+exhaustive group.  Remaining maximal at-most-one cliques among
    ;; the query atoms become exclusive-only groups.
    (let ((groups '()) (claimed (make-hash-table :test 'equal)))
      (flet ((pair-amo-p (x y)
               (gethash (sort (list x y) #'string< :key #'princ-to-string) amo)))
        (dolist (g (sort alo #'> :key #'length))
          (when (and (notany (lambda (a) (gethash a claimed)) g)
                     (loop for (x . rest) on g always
                           (loop for y in rest always (pair-amo-p x y))))
            (dolist (a g) (setf (gethash a claimed) t))
            (push (cons g t) groups)))
        ;; exclusive-only cliques over what is left
        (let ((rest (remove-if (lambda (a) (gethash a claimed)) query-atoms)))
          (dolist (a rest)
            (unless (gethash a claimed)
              (let ((clique (list a)))
                (dolist (b rest)
                  (unless (or (equal a b) (gethash b claimed))
                    (when (every (lambda (c) (pair-amo-p b c)) clique)
                      (push b clique))))
                (when (> (length clique) 1)
                  (dolist (c clique) (setf (gethash c claimed) t))
                  (push (cons (nreverse clique) nil) groups)))))))
      (nreverse groups))))

(defun mt--verify-group (int-clauses a2i group exhaustivep root)
  "Prove GROUP's exclusivity against the theory with plain SAT calls rather than
trusting the syntactic scan: at-most-one holds iff theory /\\ Hi /\\ Hj is UNSAT
for every pair, and at-least-one iff forcing all of them false is UNSAT.
Returns (values amo-ok alo-ok)."
  (let ((idx (mapcar (lambda (a) (gethash a a2i)) group))
        (amo t) (alo nil))
    (loop for (x . rest) on idx while amo do
      (dolist (y rest)
        (when amo
          (let ((cnf (concatenate 'string root "-v.cnf"))
                (out (concatenate 'string root "-v.satout")))
            (with-open-file (s cnf :direction :output :if-exists :supersede
                                   :if-does-not-exist :create)
              (format s "p cnf ~D ~D~%" (hash-table-count a2i)
                      (+ 2 (length int-clauses)))
              (dolist (cl int-clauses) (format s "~{~D ~}0~%" (coerce cl 'list)))
              (format s "~D 0~%~D 0~%" x y))
            (run-program-to-file *solver* (list cnf) out :timeout *solver-timeout*)
            (unless (eq (solver-verdict out) 'unsat) (setq amo nil))))))
    (when exhaustivep
      (let ((cnf (concatenate 'string root "-v.cnf"))
            (out (concatenate 'string root "-v.satout")))
        (with-open-file (s cnf :direction :output :if-exists :supersede
                               :if-does-not-exist :create)
          (format s "p cnf ~D ~D~%" (hash-table-count a2i)
                  (+ (length idx) (length int-clauses)))
          (dolist (cl int-clauses) (format s "~{~D ~}0~%" (coerce cl 'list)))
          (dolist (i idx) (format s "-~D 0~%" i)))
        (run-program-to-file *solver* (list cnf) out :timeout *solver-timeout*)
        (setq alo (eq (solver-verdict out) 'unsat))))
    (values amo alo)))

;;; ---------------------------------------------------------------------------
;;; The estimator
;;; ---------------------------------------------------------------------------

(defun mt--sigmoid (z) (cond ((> z 40) 1.0d0) ((< z -40) 0.0d0)
                             (t (/ 1d0 (+ 1d0 (exp (- z)))))))
(defun mt--logit (p) (cond ((>= p 1) 40d0) ((<= p 0) -40d0) (t (log (/ p (- 1d0 p))))))

(defun mt--model (satout nvars)
  "The solver's model as a bit vector indexed 1..NVARS (element 0 unused)."
  (let ((v (make-array (1+ nvars) :initial-element nil)))
    (multiple-value-bind (status objective model) (solution-lines satout)
      (declare (ignore status objective))
      (when model
        (let ((body (string-trim " " (subseq model 2))))
          (if (find #\Space body)
              ;; space-separated signed literals
              (with-input-from-string (s body)
                (loop for tok = (read s nil nil) while tok do
                  (when (and (integerp tok) (/= tok 0) (<= (abs tok) nvars))
                    (setf (aref v (abs tok)) (plusp tok)))))
              ;; bit string, one character per variable
              (loop for ch across body
                    for i from 1 to nvars
                    do (setf (aref v i) (char= ch #\1)))))))
    v))

(defun mt--renormalise (results group exhaustivep int-clauses costs nvars a2i root b verbose)
  "Renormalise RESULTS over an exclusive GROUP.  For an at-most-one group that is
not exhaustive a virtual \"none of them\" outcome is scored by one extra solve, so
the group's probabilities sum to less than 1 rather than being inflated to 1."
  (let* ((rows (remove-if-not (lambda (r) (member (first r) group :test #'equal)) results))
         (ps (mapcar #'second rows))
         (none (unless exhaustivep
                 (let ((units (mapcar (lambda (a) (- (gethash a a2i))) group)))
                   (multiple-value-bind (c st) (mt--solve int-clauses costs nvars units root :verbose verbose)
                     (if (eq st :unsat) nil (mt--sigmoid (* b (- c)))))))) )
    (let ((total (+ (reduce #'+ ps) (or none 0))))
      (when (plusp total)
        (loop for r in rows do (setf (second r) (/ (second r) total)))))))

(defun marginals-maxterm (scnf-file &key query all-atoms weighted-only out-file
                                         scale beta evidence evidence-file
                                         priors groups verify-groups
                                         (solver nil) (verbose t))
  "Max-term marginals of the queried atoms of a weighted .scnf.

For each atom a, two minimum-cost queries give c_min(a) and c_min(~a) and

    logit P(a) = beta * (c_min(~a) - c_min(a))  +  logit(prior)

with beta = 1/scale by default.  Only 1 + n solves are needed for n atoms: the
unconstrained optimum already supplies whichever polarity it happens to set, so
only the opposite clamp has to be solved.

QUERY is a list of atoms; ALL-ATOMS reports every atom, WEIGHTED-ONLY every
weighted one.  PRIORS is an alist (atom . p): a prior REPLACES that atom's own
unit weight rather than stacking on it, which is well defined because a unit cost
is constant across the models where its atom is true and therefore factors out of
the minimisation -- so applying a prior needs no re-solving at all.

Results are printed as (MAXTERM-MARGINAL <atom> <p>), deliberately not as
(MARGINAL ...): see the file header for why these are not Gibbs marginals."
  (let ((*maxterm-solver* (or solver *maxterm-solver*)))
    (multiple-value-bind (clauses probs opts weights) (rw--read-scnf scnf-file)
      (declare (ignore probs opts))
      (let* ((sc (rw--resolve-scale scnf-file scale verbose))
             (b (or beta (/ 1d0 sc)))
             (ev (wmc--evidence-clauses evidence evidence-file))
             (all-clauses (append clauses ev))
             (soft-atoms (mapcar (lambda (w) (nth-value 0 (rw--literal-atom-and-sign (second w))))
                                 weights)))
        (multiple-value-bind (a2i nvars) (mx--index-atoms all-clauses soft-atoms)
          (let* ((int-clauses (mapcar (lambda (c) (mx--clause->ints c a2i)) all-clauses))
                 (costs (wmc--literal-costs weights a2i))
                 (theory-atoms (let (r) (maphash (lambda (k v) (declare (ignore v)) (push k r)) a2i)
                                    (sort r #'string< :key #'princ-to-string)))
                 (qatoms (cond (query (mapcar (lambda (a) (if (stringp a) (read-from-string a) a)) query))
                               (weighted-only (remove-duplicates soft-atoms :test #'equal))
                               (all-atoms (remove-if #'reified-formula-atom-p theory-atoms))
                               (t (error "max-term needs a query: pass :query, :all-atoms or :weighted-only"))))
                 (root (format nil "~A-maxterm" (replace-suffix-with-regex scnf-file "\\..*?$" "")))
                 (results '()))
            (dolist (a qatoms)
              (unless (gethash a a2i)
                (error "queried atom ~S does not occur in ~A" a scnf-file)))
            (when verbose
              (format t "; max-term marginals: ~D atom(s), beta = ~,6F (scale ~A)~%" (length qatoms) b sc)
              (format t "; NOT Gibbs marginals -- the degeneracy term is dropped; see~%~
                         ; Probability/probability-background.md section 14~%"))
            ;; 1. the unconstrained optimum
            (multiple-value-bind (c0 status0) (mt--solve int-clauses costs nvars '() root :verbose verbose)
              (when (eq status0 :unsat)
                (error "the theory~@[ with evidence~] is unsatisfiable -- no marginals exist" ev))
              ;; the model tells us which polarity each atom already takes
              (let ((model (mt--model (concatenate 'string root ".satout") nvars)))
                (dolist (a qatoms)
                  (let* ((i (gethash a a2i))
                         (true-in-opt (aref model i))
                         (other (if true-in-opt (- i) i)))
                    (multiple-value-bind (c1 st1)
                        (mt--solve int-clauses costs nvars (list other) root :verbose verbose)
                      (let* ((c-true  (if true-in-opt c0 c1))
                             (c-false (if true-in-opt c1 c0))
                             (proved (eq st1 :unsat))
                             (theta (or (gethash i costs) 0))
                             (prior (cdr (assoc a priors :test #'equal)))
                             (delta (cond ((null c1) (if true-in-opt 1d10 -1d10))
                                          (t (- c-false c-true))))
                             ;; theta factors out of the minimisation, so removing
                             ;; the atom's own weight is arithmetic, not a re-solve.
                             (delta0 (if prior (+ delta theta) delta))
                             (z (+ (* b delta0) (if prior (mt--logit prior) 0)))
                             (p (mt--sigmoid z)))
                        (push (list a p proved (or (eq st1 :best) (eq status0 :best))) results)))))))
            (setq results (nreverse results))
            ;; 2. exclusive groups
            (let ((gs (unless (eq groups :none)
                        (mt--detect-groups all-clauses qatoms))))
              (when (and gs verify-groups)
                (setq gs (remove-if-not
                          (lambda (g)
                            (multiple-value-bind (amo alo)
                                (mt--verify-group int-clauses a2i (car g) (cdr g) root)
                              (and amo (or (not (cdr g)) alo))))
                          gs)))
              (dolist (g gs)
                (when verbose
                  (format t "; exclusive group~:[ (at-most-one; a \"none\" outcome is included)~;~]: ~{~S~^ ~}~%"
                          (cdr g) (car g)))
                (mt--renormalise results (car g) (cdr g)
                                 int-clauses costs nvars a2i root b verbose)))
            ;; 3. report
            (dolist (r results)
              (format t "(MAXTERM-MARGINAL ~S ~,6F)~:[~; [proved]~]~:[~; [bound]~]~%"
                      (first r) (second r) (third r) (fourth r)))
            (when out-file
              (with-open-file (o out-file :direction :output :if-exists :supersede
                                          :if-does-not-exist :create)
                (format o "; max-term marginals of ~A (beta ~,6F)~%" scnf-file b)
                (dolist (r results)
                  (format o "(MAXTERM-MARGINAL ~S ~,6F)~%" (first r) (second r)))))
            results))))))


