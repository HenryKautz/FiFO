;;; maxent.lisp
;;;
;;; FiFO weight-learning, Case 4 (beliefs about marginals), EXACT iterative
;;; maximum-entropy estimator -- the fixed point that the independent log-odds
;;; estimator in reweight.lisp only approximates (learning-background.md S4/S8).
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
                     &key (eta 1.0d0) (tol 1.0d-5) (max-iters 5000) (theta-max 40.0d0)
                          (max-step 2.0d0) fixed-theta)
  "Tied variant of mx--fit over tracked atoms 0..N-1.  Atom a with (aref GROUP-OF a)
>= 0 is a SOFT atom in that group; all soft atoms of a group share one theta, so
the model energy is sum_g theta_g N_g(x) (+ the fixed part below), N_g the count of
true group-g atoms (the schema-tying sufficient statistic, learning-background.md
S1).  Atom a with group -1 is a FIXED atom whose theta is held at (aref FIXED-THETA
a) -- its explicit weight's cost-when-true -- and never updated, so the soft groups
are fit in the PRESENCE of the fixed weights.  TAUS is the per-atom target
(constant within a group; unused for fixed atoms).  Fits each group's mean marginal
to its target (E[N_g] = |g| p_g) by damped diagonal Newton on the group residual.
Returns (values group-thetas per-atom-marginals iters converged)."
  (let* ((nsoft (length taus))
         (ng (max ngroups 1))
         (tau (make-array nsoft :element-type 'double-float
                                :initial-contents (mapcar (lambda (p) (float p 1d0)) taus)))
         (gtheta (make-array ng :element-type 'double-float :initial-element 0d0))
         (theta (make-array nsoft :element-type 'double-float :initial-element 0d0))
         (gsize (make-array ng :element-type 'fixnum :initial-element 0))
         (m (make-array nsoft :element-type 'double-float :initial-element 0d0))
         (work (mapcar (lambda (e) (list* (car e) (coerce (cdr e) 'double-float) 0d0)) entries))
         (converged nil) (iters 0))
    ;; count soft group sizes; pin fixed atoms' theta
    (dotimes (a nsoft)
      (let ((g (aref group-of a)))
        (if (>= g 0)
            (incf (aref gsize g))
            (setf (aref theta a) (if fixed-theta (aref fixed-theta a) 0d0)))))
    (flet ((clamp (x) (max (- theta-max) (min theta-max x)))
           (broadcast () (dotimes (a nsoft)
                           (let ((g (aref group-of a)))
                             (when (>= g 0) (setf (aref theta a) (aref gtheta g)))))))
      ;; warm start each soft group at its independent log-odds
      (let ((seen (make-array ng :initial-element nil)))
        (dotimes (a nsoft)
          (let ((g (aref group-of a)))
            (when (and (>= g 0) (not (aref seen g)))
              (setf (aref seen g) t
                    (aref gtheta g) (clamp (log (/ (- 1d0 (aref tau a)) (aref tau a)))))))))
      (broadcast)
      (dotimes (it max-iters)
        (setf iters (1+ it))
        (mx--marginals work theta nsoft m)
        (let ((gres (make-array ng :element-type 'double-float :initial-element 0d0))
              (gcur (make-array ng :element-type 'double-float :initial-element 0d0))
              (maxres 0d0))
          (dotimes (a nsoft)
            (let ((g (aref group-of a)) (ma (aref m a)))
              (when (>= g 0)
                (incf (aref gres g) (- ma (aref tau a)))         ; E[N_g] - |g| p_g
                (incf (aref gcur g) (* ma (- 1d0 ma))))))
          (dotimes (g ngroups)
            (setf maxres (max maxres (abs (/ (aref gres g) (max (aref gsize g) 1))))))
          (when (< maxres tol) (setf converged t) (return))
          ;; Damped diagonal Newton.  The per-atom-variance curvature underestimates
          ;; the true (coupled) curvature, so cap each step to avoid overshoot and
          ;; oscillation when fixed weights / clauses couple a group strongly.
          (dotimes (g ngroups)
            (let ((step (/ (* eta (aref gres g)) (max (aref gcur g) 1.0d-3))))
              (setf step (max (- max-step) (min max-step step)))
              (setf (aref gtheta g) (clamp (+ (aref gtheta g) step)))))
          (broadcast)))
      (mx--marginals work theta nsoft m))
    (values gtheta m iters converged)))

;;; ----------------------------------------------------------------------------
;;; Driver
;;; ----------------------------------------------------------------------------

(defun maxent-reweight (scnf-file &key out-file (scale 100) (eta 1.0d0) (tol 1.0d-5)
                                       (max-iters 5000) (verbose t) wff wff-out
                                       (consider-weights t))
  "Read SCNF-FILE, whose (PROBABILITY literal p [gid]) lines give target marginal
probabilities, fit weights by exact iterative maximum entropy over the feasible
set, and write <root>_reweighted.scnf with positive-integer weights.  Atoms that
share a tie-group gid share one fitted weight (the fit matches each group's mean
marginal to its target).  Only the probability-derived weights are adjusted.

Explicit (WEIGHT ...) lines already in the file are always passed through to the
output unchanged.  CONSIDER-WEIGHTS (default t) controls whether they also take
part in the fit: when t they are held FIXED in the model energy so the
probability weights are learned in their presence (the realized marginals then
account for them); when nil the fit ignores them (faster, but the achieved
marginals will not account for the explicit weights present at solve time).

Returns the .scnf output pathname; prints a target-vs-achieved report per group
when VERBOSE.  A fit that does not converge is flagged prominently -- the usual
cause is a target set that is inconsistent with the hard clauses (and/or the
fixed weights).

If WFF is given (the source .wff), also writes a copy with each (PROBABILITY ...)
form replaced by its tied (WEIGHT ...) cost, to WFF-OUT (default
<wff-root>_weighted.wff)."
  (unless (and (integerp scale) (plusp scale))
    (error "scale must be a positive integer; got ~S" scale))
  (multiple-value-bind (clauses probabilities options weights) (rw--read-scnf scnf-file)
    (rw--check-weight-probability-disjoint probabilities weights)
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
             ;; soft (fitted) atoms first, then fixed (explicit-weight) atoms when
             ;; CONSIDER-WEIGHTS -- the fixed ones are tracked in the energy with
             ;; group -1 so the soft groups fit in their presence.
             (soft-atoms '()) (taus '()) (group-of-list '())
             ;; An explicit (WEIGHT atom w) is an integer cost in OUTPUT units
             ;; (= scale * natural theta), so divide by scale to recover the
             ;; natural-units theta the fit works in.
             (fixed (when consider-weights
                      (mapcar (lambda (wf)
                                (multiple-value-bind (atom th) (rw--weight-fixed-theta wf)
                                  (cons atom (/ th scale))))
                              weights))))
        (loop for g in soft-groups for gi from 0 do
          (setf (aref gindex->gid gi) (car g))
          (dolist (atom (cddr g))
            (push atom soft-atoms) (push (cadr g) taus) (push gi group-of-list)))
        (setf soft-atoms (nreverse soft-atoms) taus (nreverse taus)
              group-of-list (nreverse group-of-list))
        (let* ((tracked-atoms (append soft-atoms (mapcar #'car fixed)))
               (tracked-taus  (append taus (mapcar (constantly 0.5d0) fixed)))
               (tracked-gofs  (append group-of-list (mapcar (constantly -1) fixed)))
               (fixed-theta (make-array (length tracked-atoms) :element-type 'double-float
                                        :initial-element 0d0)))
          (loop for a from (length soft-atoms)
                for fx in fixed do (setf (aref fixed-theta a) (cdr fx)))
          (multiple-value-bind (a2i nvars) (mx--index-atoms all-clauses tracked-atoms)
            (let* ((int-clauses (mapcar (lambda (cl) (mx--clause->ints cl a2i)) all-clauses))
                   (tracked-vars (mapcar (lambda (atom) (gethash atom a2i)) tracked-atoms))
                   (group-of (make-array (length tracked-atoms) :element-type 'fixnum
                                         :initial-contents tracked-gofs))
                   (entries (mx--enumerate int-clauses nvars tracked-vars)))
              (when (null entries)
                (error "the hard clauses are unsatisfiable; no feasible set to match marginals over"))
              (multiple-value-bind (gthetas marginals iters converged)
                  (mx--fit-tied entries tracked-taus group-of ngroups
                                :eta eta :tol tol :max-iters max-iters :fixed-theta fixed-theta)
                (let ((gmean (make-array ngroups :element-type 'double-float :initial-element 0d0))
                      (gsize (make-array ngroups :element-type 'fixnum :initial-element 0))
                      (gid->spec (make-hash-table :test 'equal))
                      (new-weights '()))
                  (loop for a from 0 below (length soft-atoms) do
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
                    (format out "; method: exact iterative MaxEnt over the feasible set (tied groups)~%")
                    (format out "; explicit weights: ~A; scale: ~D~%"
                            (if weights (if consider-weights "held fixed in the fit" "passed through, NOT in the fit")
                                "none")
                            scale)
                    (format out "; fit: ~A in ~D iteration~:P (tol ~,1E); real weight = integer / ~D~%"
                            (if converged "converged" "DID NOT CONVERGE -- targets may be inconsistent with the hard clauses")
                            iters tol scale)
                    (dotimes (gi ngroups)
                      (format out "; group ~S target ~,4F achieved-mean ~,4F~%"
                              (aref gindex->gid gi) (cadr (nth gi soft-groups)) (aref gmean gi)))
                    (format out "; original probability assertions echoed below as ;; comments~%")
                    (dolist (pf probabilities) (format out ";; ~S~%" pf))
                    (dolist (c clauses)      (format out "~S~%" c))
                    (dolist (c deg-clauses)  (format out "~S~%" c))
                    (dolist (w weights)      (format out "~S~%" w))   ; explicit weights, unchanged
                    (dolist (w new-weights)  (format out "~S~%" w))
                    (dolist (o options)      (format out "~S~%" o)))
                  (when verbose
                    (unless converged
                      (format t "~&!! MaxEnt did NOT converge in ~D iterations: the targets may be ~
inconsistent with the hard clauses~@[ and the fixed weights~].~%"
                              iters (and weights consider-weights)))
                    (format t "~&MaxEnt reweight (tied): ~A (~D iters)~%"
                            (if converged "converged" "did NOT converge") iters)
                    (format t "~&  group~30Ttarget~42Tachieved-mean~%")
                    (dotimes (gi ngroups)
                      (format t "~&  ~S~30T~,4F~42T~,4F~%"
                              (aref gindex->gid gi) (cadr (nth gi soft-groups)) (aref gmean gi)))
                    (when deg-groups
                      (format t "~&  (hard) ~{~S ~}~%" (mapcar #'car deg-groups)))
                    (when (and weights consider-weights)
                      (format t "~&  (fixed weights considered: ~{~S ~})~%" (mapcar #'car fixed)))
                    (format t "~&  -> ~A~%" out-file))
                  (when wff
                    (rw--write-back wff (or wff-out (rw--default-wff-out wff)) gid->spec scale))
                  ;; Second value: gid -> spec, for callers that map a learned
                  ;; weight back onto its source by tie-group (e.g. the PDDL pipeline).
                  (values out-file gid->spec))))))))))

;;; ----------------------------------------------------------------------------
;;; Marginal inference (Method 1 of Inference/"Marginal Inference in FiFO.md":
;;; exact enumeration).  Reuses the same feasible-set enumeration the MaxEnt fit
;;; uses, but tracks EVERY atom -- not just the weighted ones -- so it reports the
;;; marginal of every variable in the theory (e.g. SatPlan Holds state atoms as
;;; well as Occurs action atoms).
;;; ----------------------------------------------------------------------------

(defun marginals (scnf-file &key out-file weighted-only scale (node-limit 5000000) (verbose t))
  "Exact marginal probability P(atom = true) of the atoms in a weighted SCNF-FILE,
under the Gibbs distribution P(x) proportional to exp(-(sum of the REAL weights of
the true literals)) over the feasible set (assignments satisfying the hard (OR ...)
clauses).  (WEIGHT literal w) lines supply the costs; (PROBABILITY ...) targets,
if any, are ignored.  With no weights the distribution is uniform over the
feasible set.

The integer weights are divided by SCALE first -- a positive number to force one,
or NIL (the default) to read the 'scale: N' the weight-learning pipeline records
in the header (1.0 if absent), exactly as in WMC.  This matters because the
pipeline scales costs by an integer factor (100 by default) for MaxSAT, and
exp(-100*theta) is a near-zero-temperature distribution; pass :scale 1 to use the
raw integer weights.

Exact enumeration, so this is for small instances (NODE-LIMIT caps the search).

By default the marginal of EVERY atom is reported (weighted or not -- SatPlan
Holds state atoms as well as Occurs action atoms).  With WEIGHTED-ONLY, only the
atoms that carry a weight are reported, and only those are tracked during
enumeration (unweighted variables collapse into a multiplicity), which is much
cheaper -- the same enumeration the MaxEnt weight fit uses.

Prints one (MARGINAL <atom> <p>) line per reported atom (sorted by atom) to
standard output when VERBOSE, and writes the same to OUT-FILE when given.  Returns
an alist (atom . probability)."
  (multiple-value-bind (clauses probs opts weights) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let ((weight-atoms (remove-duplicates
                          (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf))) weights)
                          :test #'equal))
          (scale (rw--resolve-scale scnf-file scale verbose)))
      (when (and weighted-only (null weight-atoms))
        (when verbose (format t "; no weighted atoms in ~A~%" (file-namestring scnf-file)))
        (return-from marginals nil))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (when (zerop nvars) (error "no atoms found in ~A" scnf-file))
        (let ((int-clauses (mapcar (lambda (cl) (mx--clause->ints cl a2i)) clauses))
              (i2a (make-array (1+ nvars)))
              ;; net[i] = cost-when-true - cost-when-false for variable i (1-based);
              ;; only true literals contribute to the energy, so this signed net
              ;; cost is all the marginal computation needs.
              (net (make-array (1+ nvars) :element-type 'double-float :initial-element 0d0)))
          (maphash (lambda (atom i) (setf (aref i2a i) atom)) a2i)
          (dolist (wf weights)
            (multiple-value-bind (atom positivep) (rw--literal-atom-and-sign (second wf))
              (let ((i (gethash atom a2i)) (w (float (third wf) 1.0d0)))
                (if positivep (incf (aref net i) w) (decf (aref net i) w)))))
          ;; Track all variables, or -- for weighted-only -- just the weighted ones.
          (let* ((soft-vars (if weighted-only
                                (mapcar (lambda (a) (gethash a a2i)) weight-atoms)
                                (loop for v from 1 to nvars collect v)))
                 (nsoft (length soft-vars))
                 (thetas (make-array nsoft :element-type 'double-float)))
            ;; thetas are the REAL costs: raw net cost divided by the weight scale.
            (loop for v in soft-vars for b from 0 do (setf (aref thetas b) (/ (aref net v) scale)))
            (let ((entries (mx--enumerate int-clauses nvars soft-vars :node-limit node-limit)))
              (when (null entries)
                (error "the hard clauses are unsatisfiable; no feasible set to take marginals over"))
              (let ((work (mapcar (lambda (e) (list* (car e) (coerce (cdr e) 'double-float) 0d0)) entries))
                    (m (make-array nsoft :element-type 'double-float :initial-element 0d0)))
                (mx--marginals work thetas nsoft m)
                (let ((result (sort (loop for v in soft-vars for b from 0
                                          collect (cons (aref i2a v) (aref m b)))
                                    #'string-lessp
                                    :key (lambda (pair) (princ-to-string (car pair))))))
                  (flet ((emit (stream)
                           (dolist (pair result)
                             (format stream "(MARGINAL ~S ~,6F)~%" (car pair) (cdr pair)))))
                    (when verbose (emit *standard-output*))
                    (when out-file
                      (with-open-file (out out-file :direction :output
                                                    :if-exists :supersede :if-does-not-exist :create)
                        (format out "; marginals of ~A (~D ~:[atoms~;weighted atoms~], ~D feasible assignments)~%"
                                (file-namestring scnf-file) nsoft weighted-only (length entries))
                        (emit out))))
                  result)))))))))
