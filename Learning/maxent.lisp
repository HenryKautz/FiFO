;;; maxent.lisp
;;;
;;; FiFO weight-learning, Case 4 (beliefs about marginals), EXACT iterative
;;; maximum-entropy estimator -- the fixed point that the independent log-odds
;;; estimator in reweight.lisp only approximates (fifo-weight-learning.md S4/S8).
;;;
;;; The independent estimator sets theta_a = log((1-p_a)/p_a) per atom, which is
;;; correct only when the hard clauses leave the weighted atoms independent.  When
;;; the clauses couple them, the marginal an atom actually attains over the
;;; FEASIBLE set differs from p_a.  This module corrects for that coupling.
;;;
;;; Model.  Gibbs distribution over the feasible set F (the satisfying assignments
;;; of the hard clauses):
;;;
;;;     P_theta(x) proportional to exp(-theta . Phi(x)),   x in F,
;;;
;;; where Phi_a(x) = [atom a is true in x] and theta_a is the cost charged when
;;; atom a is true.  The MaxEnt program min_theta log Z(theta) + theta . tau is
;;; convex with gradient tau - E_theta[Phi]; at the optimum E_theta[Phi] = tau,
;;; i.e. the model's marginals equal the target marginals.
;;;
;;; Key structural fact: F depends only on the hard clauses, NOT on theta.  So we
;;; enumerate F ONCE, recording for each feasible assignment which weighted atoms
;;; are true (a bitmask over the soft atoms) aggregated into counts, and then the
;;; whole iterative fit is cheap re-weighting arithmetic with no solver in the
;;; loop.  Exact enumeration is the "do the counting on small instances" route of
;;; the doc; a sampler / weighted model counter could later replace mx--enumerate
;;; behind the same (entries) interface for larger instances.
;;;
;;; Degenerate targets (p=0 / p=1) are deterministic: they become hard unit
;;; clauses (added to F and to the output), never soft weights, exactly as in the
;;; independent estimator.  Final real-valued thetas are written as positive
;;; integer weights with the same shift+scale emission (rw--emit-for-theta).
;;;
;;; Entry point:  (maxent-reweight "file.scnf" &key out-file scale ...)

(load (merge-pathnames "reweight.lisp" (or *load-pathname* *default-pathname-defaults*)))

;;; ----------------------------------------------------------------------------
;;; Propositional indexing
;;; ----------------------------------------------------------------------------

(defun mx--index-atoms (clauses soft-atoms)
  "Assign 1..N integer indices to every atom occurring in CLAUSES or in
SOFT-ATOMS.  Returns (values atom->index nvars)."
  (let ((a2i (make-hash-table :test 'equal))
        (n 0))
    (flet ((intern-atom (atom)
             (or (gethash atom a2i)
                 (setf (gethash atom a2i) (incf n)))))
      (dolist (cl clauses)
        (dolist (lit (cdr cl))
          (intern-atom (rw--literal-atom-and-sign lit))))
      (dolist (atom soft-atoms) (intern-atom atom)))
    (values a2i n)))

(defun mx--clause->ints (clause a2i)
  "Convert an (OR lit ...) form to a simple-vector of signed atom indices
(+i for the positive atom, -i for a negated one)."
  (coerce (mapcar (lambda (lit)
                    (multiple-value-bind (atom positivep) (rw--literal-atom-and-sign lit)
                      (let ((i (gethash atom a2i)))
                        (if positivep i (- i)))))
                  (cdr clause))
          'simple-vector))

;;; ----------------------------------------------------------------------------
;;; Exact enumeration of the feasible set
;;; ----------------------------------------------------------------------------

(defun mx--enumerate (int-clauses nvars soft-vars &key (node-limit 5000000))
  "Enumerate all satisfying assignments of INT-CLAUSES over variables 1..NVARS,
via DPLL with unit propagation.  SOFT-VARS is the ordered list of variable
indices whose joint truth pattern we score.  Returns a list of (mask . count):
MASK is a bit integer over SOFT-VARS (bit i = soft-vars[i] is true) and COUNT is
the number of feasible full assignments with that pattern.  Free non-soft
variables are collapsed as a 2^k multiplicity rather than branched."
  (let* ((assignment (make-array (1+ nvars) :element-type 'fixnum :initial-element 0))
         (soft-bit (make-array (1+ nvars) :element-type 'fixnum :initial-element -1))
         (result (make-hash-table))
         (nodes 0))
    (loop for v in soft-vars for b from 0 do (setf (aref soft-bit v) b))
    (labels
        ((lit-true (lit)  (= (aref assignment (abs lit)) (if (plusp lit) 1 -1)))
         (lit-false (lit) (= (aref assignment (abs lit)) (if (plusp lit) -1 1)))
         (propagate ()
           ;; Force unit literals; return (values okp trail) where TRAIL lists the
           ;; variables this call assigned (to be undone by the caller).
           (let ((trail '()) (okp t) (changed t))
             (loop while (and changed okp) do
               (setf changed nil)
               (block scan
                 (dolist (cl int-clauses)
                   (let ((satisfied nil) (unassigned 0) (ulit 0))
                     (loop for lit across cl do
                       (cond ((lit-true lit) (setf satisfied t) (return))
                             ((lit-false lit))
                             (t (incf unassigned) (setf ulit lit))))
                     (unless satisfied
                       (cond ((= unassigned 0) (setf okp nil) (return-from scan))
                             ((= unassigned 1)
                              (let ((v (abs ulit)) (val (if (plusp ulit) 1 -1)))
                                (setf (aref assignment v) val)
                                (push v trail)
                                (setf changed t)))))))))
             (values okp trail)))
         (pick-branch-var ()
           ;; First unassigned variable of the first unsatisfied clause, or NIL
           ;; when every clause is already satisfied.
           (dolist (cl int-clauses nil)
             (let ((satisfied nil) (uv nil))
               (loop for lit across cl do
                 (cond ((lit-true lit) (setf satisfied t) (return))
                       ((lit-false lit))
                       (t (unless uv (setf uv (abs lit))))))
               (unless satisfied (return-from pick-branch-var uv)))))
         (collapse ()
           ;; All clauses satisfied: account for every completion of the still
           ;; unassigned variables.  Soft ones are enumerated (they change the
           ;; mask); non-soft ones contribute a 2^k multiplicity.
           (let ((free-soft '()) (free-other 0) (base 0))
             (loop for v from 1 to nvars do
               (when (zerop (aref assignment v))
                 (if (>= (aref soft-bit v) 0) (push v free-soft) (incf free-other))))
             (loop for v in soft-vars do
               (when (= (aref assignment v) 1)
                 (setf base (logior base (ash 1 (aref soft-bit v))))))
             (let ((mult (ash 1 free-other))
                   (k (length free-soft)))
               (dotimes (s (ash 1 k))
                 (let ((mask base))
                   (loop for v in free-soft for i from 0 do
                     (when (logbitp i s)
                       (setf mask (logior mask (ash 1 (aref soft-bit v))))))
                   (incf (gethash mask result 0) mult))))))
         (rec ()
           (incf nodes)
           (when (> nodes node-limit)
             (error "exact enumeration exceeded ~:D nodes; instance too large for the exact MaxEnt fit" node-limit))
           (multiple-value-bind (okp trail) (propagate)
             (unwind-protect
                  (when okp
                    (let ((bv (pick-branch-var)))
                      (if (null bv)
                          (collapse)
                          (progn
                            (setf (aref assignment bv) 1)  (rec)
                            (setf (aref assignment bv) -1) (rec)
                            (setf (aref assignment bv) 0)))))
               (dolist (v trail) (setf (aref assignment v) 0))))))
      (rec))
    (let ((entries '()))
      (maphash (lambda (mask count) (push (cons mask count) entries)) result)
      entries)))

;;; ----------------------------------------------------------------------------
;;; Iterative moment matching
;;; ----------------------------------------------------------------------------

(defun mx--marginals (work thetas nsoft m)
  "Given WORK entries (mask count . scratch), fill M with the model marginals
P_theta(atom a = true) under THETAS and return M.  Uses a log-sum-exp shift over
the per-entry energies (stashed in the scratch slot) for numerical stability."
  (dotimes (a nsoft) (setf (aref m a) 0d0))
  (let ((emin most-positive-double-float))
    (dolist (e work)
      (let ((energy 0d0) (mask (car e)))
        (dotimes (a nsoft) (when (logbitp a mask) (incf energy (aref thetas a))))
        (setf (cddr e) energy)               ; stash energy
        (when (< energy emin) (setf emin energy))))
    (let ((z 0d0))
      (dolist (e work)
        (let* ((mask (car e))
               (w (* (cadr e) (exp (- emin (cddr e))))))  ; count * exp(-(energy-emin))
          (incf z w)
          (dotimes (a nsoft) (when (logbitp a mask) (incf (aref m a) w)))))
      (dotimes (a nsoft) (setf (aref m a) (/ (aref m a) z)))))
  m)

(defun mx--fit (entries taus &key (eta 1.0d0) (tol 1.0d-5) (max-iters 5000)
                                  (theta-max 40.0d0))
  "Fit thetas so the model marginals match TAUS (a list of target probabilities,
one per soft atom in order) over the feasible set described by ENTRIES.  Returns
(values thetas marginals iters converged-p), thetas a double-float vector of
cost-when-true on each positive atom.  Update is damped diagonal Newton:
theta_a += eta * (m_a - tau_a) / max(m_a (1-m_a), 1e-3)."
  (let* ((nsoft (length taus))
         (tau (make-array nsoft :element-type 'double-float
                                :initial-contents (mapcar (lambda (p) (float p 1d0)) taus)))
         (theta (make-array nsoft :element-type 'double-float :initial-element 0d0))
         (m (make-array nsoft :element-type 'double-float :initial-element 0d0))
         ;; mutable entries: (mask count . scratch) so mx--marginals can stash
         (work (mapcar (lambda (e) (list* (car e) (coerce (cdr e) 'double-float) 0d0)) entries))
         (converged nil)
         (iters 0))
    (flet ((clamp (x) (max (- theta-max) (min theta-max x))))
      ;; warm start: independent log-odds
      (dotimes (a nsoft)
        (let ((p (aref tau a)))
          (setf (aref theta a) (clamp (log (/ (- 1d0 p) p))))))
      (dotimes (it max-iters)
        (setf iters (1+ it))
        (mx--marginals work theta nsoft m)
        (let ((maxres 0d0))
          (dotimes (a nsoft)
            (setf maxres (max maxres (abs (- (aref m a) (aref tau a))))))
          (when (< maxres tol) (setf converged t) (return))
          (dotimes (a nsoft)
            (let* ((ma (aref m a))
                   (curv (max (* ma (- 1d0 ma)) 1.0d-3))
                   (step (/ (* eta (- ma (aref tau a))) curv)))
              (setf (aref theta a) (clamp (+ (aref theta a) step)))))))
      ;; final marginals at the returned thetas
      (mx--marginals work theta nsoft m))
    (values theta m iters converged)))

(defun mx--fit-tied (entries taus group-of ngroups
                     &key (eta 1.0d0) (tol 1.0d-5) (max-iters 5000) (theta-max 40.0d0))
  "Tied variant of mx--fit: soft atom a belongs to group (aref GROUP-OF a), and
all atoms in a group share one theta -- so the model energy is sum_g theta_g
N_g(x), with N_g the count of true group-g atoms (the schema-tying sufficient
statistic, fifo-weight-learning.md S1).  TAUS is the per-atom target (constant
within a group).  Fits each group's mean marginal to its target
(E[N_g] = |g| p_g) by damped diagonal Newton on the aggregated group residual.
Returns (values group-thetas per-atom-marginals iters converged)."
  (let* ((nsoft (length taus))
         (tau (make-array nsoft :element-type 'double-float
                                :initial-contents (mapcar (lambda (p) (float p 1d0)) taus)))
         (gtheta (make-array ngroups :element-type 'double-float :initial-element 0d0))
         (theta (make-array nsoft :element-type 'double-float :initial-element 0d0))
         (gsize (make-array ngroups :element-type 'fixnum :initial-element 0))
         (m (make-array nsoft :element-type 'double-float :initial-element 0d0))
         (work (mapcar (lambda (e) (list* (car e) (coerce (cdr e) 'double-float) 0d0)) entries))
         (converged nil) (iters 0))
    (dotimes (a nsoft) (incf (aref gsize (aref group-of a))))
    (flet ((clamp (x) (max (- theta-max) (min theta-max x)))
           (broadcast () (dotimes (a nsoft) (setf (aref theta a) (aref gtheta (aref group-of a))))))
      ;; warm start: each group's independent log-odds (any member's tau works)
      (let ((seen (make-array ngroups :initial-element nil)))
        (dotimes (a nsoft)
          (let ((g (aref group-of a)))
            (unless (aref seen g)
              (setf (aref seen g) t
                    (aref gtheta g) (clamp (log (/ (- 1d0 (aref tau a)) (aref tau a)))))))))
      (broadcast)
      (dotimes (it max-iters)
        (setf iters (1+ it))
        (mx--marginals work theta nsoft m)
        (let ((gres (make-array ngroups :element-type 'double-float :initial-element 0d0))
              (gcur (make-array ngroups :element-type 'double-float :initial-element 0d0))
              (maxres 0d0))
          (dotimes (a nsoft)
            (let ((g (aref group-of a)) (ma (aref m a)))
              (incf (aref gres g) (- ma (aref tau a)))         ; E[N_g] - |g| p_g
              (incf (aref gcur g) (* ma (- 1d0 ma)))))
          (dotimes (g ngroups)
            (setf maxres (max maxres (abs (/ (aref gres g) (max (aref gsize g) 1))))))
          (when (< maxres tol) (setf converged t) (return))
          (dotimes (g ngroups)
            (setf (aref gtheta g)
                  (clamp (+ (aref gtheta g) (/ (* eta (aref gres g)) (max (aref gcur g) 1.0d-3))))))
          (broadcast)))
      (mx--marginals work theta nsoft m))
    (values gtheta m iters converged)))

;;; ----------------------------------------------------------------------------
;;; Driver
;;; ----------------------------------------------------------------------------

(defun maxent-reweight (scnf-file &key out-file (scale 100) (eta 1.0d0) (tol 1.0d-5)
                                       (max-iters 5000) (verbose t) wff wff-out)
  "Read SCNF-FILE, whose (PROBABILITY literal p [gid]) lines give target marginal
probabilities, fit weights by exact iterative maximum entropy over the feasible
set, and write <root>_reweighted.scnf with positive-integer weights.  Atoms that
share a tie-group gid share one fitted weight (the fit matches each group's mean
marginal to its target).  Returns the .scnf output pathname; prints a
target-vs-achieved report per group when VERBOSE.

If WFF is given (the source .wff), also writes a copy with each (PROBABILITY ...)
form replaced by its tied (WEIGHT ...) cost, to WFF-OUT (default
<wff-root>_weighted.wff)."
  (unless (and (integerp scale) (plusp scale))
    (error "scale must be a positive integer; got ~S" scale))
  (multiple-value-bind (clauses probabilities options) (rw--read-scnf scnf-file)
    (let ((soft-groups '()) (deg-groups '()))    ; each: (gid p . atoms)
      (dolist (g (rw--collect-groups probabilities))
        (let ((p (cadr g)))
          (if (or (= p 0d0) (= p 1d0)) (push g deg-groups) (push g soft-groups))))
      (setf soft-groups (nreverse soft-groups) deg-groups (nreverse deg-groups))
      (let* ((deg-clauses (loop for g in deg-groups
                                for p = (cadr g)
                                append (loop for atom in (cddr g)
                                             collect (if (= p 1d0)
                                                         (list 'or atom)
                                                         (list 'or (list 'not atom))))))
             (all-clauses (append clauses deg-clauses))
             (ngroups (length soft-groups))
             (gindex->gid (make-array ngroups))
             (soft-atoms '()) (taus '()) (group-of-list '()))
        (loop for g in soft-groups for gi from 0 do
          (setf (aref gindex->gid gi) (car g))
          (dolist (atom (cddr g))
            (push atom soft-atoms) (push (cadr g) taus) (push gi group-of-list)))
        (setf soft-atoms (nreverse soft-atoms) taus (nreverse taus)
              group-of-list (nreverse group-of-list))
        (multiple-value-bind (a2i nvars) (mx--index-atoms all-clauses soft-atoms)
          (let* ((int-clauses (mapcar (lambda (cl) (mx--clause->ints cl a2i)) all-clauses))
                 (soft-vars (mapcar (lambda (atom) (gethash atom a2i)) soft-atoms))
                 (group-of (make-array (length soft-atoms) :element-type 'fixnum
                                       :initial-contents group-of-list))
                 (entries (mx--enumerate int-clauses nvars soft-vars)))
            (when (null entries)
              (error "the hard clauses are unsatisfiable; no feasible set to match marginals over"))
            (multiple-value-bind (gthetas marginals iters converged)
                (mx--fit-tied entries taus group-of ngroups
                              :eta eta :tol tol :max-iters max-iters)
              ;; per-group achieved mean marginal, for reporting
              (let ((gmean (make-array ngroups :element-type 'double-float :initial-element 0d0))
                    (gsize (make-array ngroups :element-type 'fixnum :initial-element 0))
                    (gid->spec (make-hash-table :test 'equal))
                    (new-weights '()))
                (loop for a from 0 for atom in soft-atoms do
                  (incf (aref gmean (aref group-of a)) (aref marginals a))
                  (incf (aref gsize (aref group-of a))))
                (dotimes (gi ngroups)
                  (setf (aref gmean gi) (/ (aref gmean gi) (max (aref gsize gi) 1)))
                  (setf (gethash (aref gindex->gid gi) gid->spec) (list :theta (aref gthetas gi))))
                (dolist (g deg-groups)
                  (setf (gethash (car g) gid->spec) (list :hard (if (= (cadr g) 1d0) 1 0))))
                (loop for atom in soft-atoms for a from 0
                      for wf = (rw--emit-for-theta atom (aref gthetas (aref group-of a)) scale)
                      when wf do (push wf new-weights))
                (setf new-weights (nreverse new-weights))
                (unless out-file
                  (setq out-file (cl-ppcre:regex-replace "\\.[^.]*$" scnf-file "_reweighted.scnf")))
                (with-open-file (out out-file :direction :output
                                              :if-exists :supersede :if-does-not-exist :create)
                  (format out "; reweighted from ~A~%" (file-namestring scnf-file))
                  (format out "; method: exact iterative MaxEnt over the feasible set (tied groups); scale: ~D~%" scale)
                  (format out "; fit: ~A in ~D iteration~:P (tol ~,1E); real weight = integer / ~D~%"
                          (if converged "converged" "STOPPED (not converged)") iters tol scale)
                  (dotimes (gi ngroups)
                    (format out "; group ~S target ~,4F achieved-mean ~,4F~%"
                            (aref gindex->gid gi) (cadr (nth gi soft-groups)) (aref gmean gi)))
                  (format out "; original probability assertions echoed below as ;; comments~%")
                  (dolist (pf probabilities) (format out ";; ~S~%" pf))
                  (dolist (c clauses)      (format out "~S~%" c))
                  (dolist (c deg-clauses)  (format out "~S~%" c))
                  (dolist (w new-weights)  (format out "~S~%" w))
                  (dolist (o options)      (format out "~S~%" o)))
                (when verbose
                  (format t "~&MaxEnt reweight (tied): ~A (~D iters)~%"
                          (if converged "converged" "did NOT converge") iters)
                  (format t "~&  group~30Ttarget~42Tachieved-mean~%")
                  (dotimes (gi ngroups)
                    (format t "~&  ~S~30T~,4F~42T~,4F~%"
                            (aref gindex->gid gi) (cadr (nth gi soft-groups)) (aref gmean gi)))
                  (when deg-groups
                    (format t "~&  (hard) ~{~S ~}~%" (mapcar #'car deg-groups)))
                  (format t "~&  -> ~A~%" out-file))
                (when wff
                  (rw--write-back wff (or wff-out (rw--default-wff-out wff)) gid->spec scale))
                out-file))))))))
