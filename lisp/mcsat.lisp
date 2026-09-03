;;; mcsat.lisp
;;;
;;; FiFO -> MC-SAT bridge: APPROXIMATE marginal inference by MCMC, via the
;;; MC-SAT mode of WalkSAT v58 (gitlab.com/HenryKautz/Walksat, Walksat_v58_MC-SAT).
;;;
;;; Where maxent.lisp's (marginals ...), wmc.lisp's (marginals-addmc ...) and
;;; ddnnf.lisp's (ddnnf-marginals ...) are all EXACT -- and so bounded by the
;;; instance's treewidth / feasible-set size -- this path samples.  MC-SAT (Poon &
;;; Domingos, AAAI 2006) is slice-sampling MCMC whose inner near-uniform sampler is
;;; SampleSAT (Wei, Erenrich & Selman 2004); it handles instances the exact
;;; counters cannot, at the price of Monte-Carlo error.  The whole sampler lives in
;;; the C binary: FiFO writes one weighted CNF, shells out once, and reads the
;;; marginals back -- the same posture as the addmc and d4 bridges.
;;;
;;; The probability model is the same Gibbs distribution as everywhere else in the
;;; probabilistic layer,
;;;
;;;     P(x) proportional to exp(-(sum of the weights of the true literals)),  x in F,
;;;
;;; over the feasible set F (the assignments satisfying the hard (OR ...) clauses).
;;;
;;; Encoding.  MC-SAT reads a weighted CNF whose clauses are led by 'h' (hard) or
;;; by a NON-NEGATIVE real weight w, and it REWARDS satisfaction:
;;;
;;;     P(x) proportional to exp(sum of the weights of the SATISFIED soft clauses).
;;;
;;; FiFO's costs are the opposite sign and may be negative, so each weighted
;;; literal L with total cost-when-true theta becomes a soft UNIT clause:
;;;
;;;     theta > 0  ->  soft clause (not L) with weight  theta   (reward for L false)
;;;     theta < 0  ->  soft clause      L  with weight -theta   (reward for L true)
;;;
;;; Both give exp(-theta) : 1 odds on L, i.e. exactly FiFO's W(L true) = exp(-theta),
;;; W(L false) = 1, and neither ever needs a negative weight (which MC-SAT rejects,
;;; since its slice step includes a satisfied soft clause with probability
;;; 1 - e^{-w}).  The hard (OR ...) clauses are written with the 'h' prefix.
;;;
;;; Entry point:
;;;   (marginals-mcsat "file.scnf" &key ...)  -- approximate marginals, one binary run

(load (merge-pathnames "wmc.lisp" (or *load-pathname* *default-pathname-defaults*)))

(defvar *walksat* "walksat"
  "Name of the WalkSAT binary providing MC-SAT mode, found on PATH.  Must be
version 58 or later -- earlier releases have no -mcsat option (they print their
help text and ignore it), which MCSAT--CHECK-VERSION detects and refuses, so an
old walksat earlier on PATH fails loudly rather than quietly.")

;;; ----------------------------------------------------------------------------
;;; Emitting the MC-SAT weighted CNF
;;; ----------------------------------------------------------------------------

(defun mcsat--soft-units (weights a2i scale)
  "The soft unit clauses for the (WEIGHT literal w) forms: a list of
(weight . signed-dimacs-literal) pairs with weight > 0, rewarding the literal that
FiFO does NOT charge for.  Costs are divided by SCALE first; a literal whose total
cost is zero contributes nothing."
  (let ((softs '()))
    (maphash (lambda (lit c)
               (let ((theta (/ c scale)))
                 (unless (zerop theta)
                   ;; cost theta when LIT is true == reward theta when LIT is false
                   (push (cons (abs theta) (if (plusp theta) (- lit) lit)) softs))))
             (wmc--literal-costs weights a2i))
    ;; deterministic order (by |literal|) so the same scnf yields the same wcnf
    (sort softs #'< :key (lambda (s) (abs (cdr s))))))

(defun mcsat--write-wcnf (clauses weights a2i nvars out-stream &key (scale 1.0d0))
  "Write the MC-SAT weighted CNF for CLAUSES + WEIGHTS to OUT-STREAM: the hard
clauses led by 'h', then one soft unit clause per charged literal (see
MCSAT--SOFT-UNITS).  Returns the number of soft clauses written."
  (let* ((softs (mcsat--soft-units weights a2i scale))
         (nclauses (+ (length clauses) (length softs))))
    (when (zerop nclauses)
      (error "nothing to sample: the scnf has no clauses and no non-zero weights"))
    (format out-stream "p wcnf ~D ~D~%" nvars nclauses)
    (dolist (cl clauses)
      (format out-stream "h ")
      (loop for i across (mx--clause->ints cl a2i)
            do (format out-stream "~D " i))
      (format out-stream "0~%"))
    ;; '~,16,,,,,'eE forces a C-parseable 'e' exponent (not Lisp's 'd').
    (dolist (s softs)
      (format out-stream "~,16,,,,,'eE ~D 0~%" (float (car s) 1.0d0) (cdr s)))
    (length softs)))

;;; ----------------------------------------------------------------------------
;;; Seeding the initial assignment from a complete (CDCL) solver
;;; ----------------------------------------------------------------------------
;;;
;;; MC-SAT has to start from SOME model of the hard clauses, and the sampler finds
;;; one by stochastic local search -- precisely WalkSAT's weakest workload.  On
;;; structured encodings (SatPlan) that search fails outright where a CDCL solver
;;; succeeds instantly, and no flip budget rescues it (measured: LogisticsCosts pb1
;;; survives 20 tries x 20M flips without finding a model of a satisfiable theory).
;;; So we solve the hard clauses once with FiFO's SAT solver and hand the model to
;;; walksat's -init, which seeds the FIRST try of its initial solve; later tries
;;; stay random, so a bad seed cannot wedge the restart loop.  As a bonus, a CDCL
;;; UNSAT verdict is a PROOF, reported at once instead of after 100 futile tries.

(defun mcsat--write-dimacs (clauses a2i nvars path)
  "Write the hard CLAUSES as plain DIMACS CNF over variables 1..NVARS to PATH."
  (with-open-file (s path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    (format s "p cnf ~D ~D~%" nvars (length clauses))
    (dolist (cl clauses)
      (loop for i across (mx--clause->ints cl a2i)
            do (format s "~D " i))
      (format s "0~%"))))

(defun mcsat--parse-sat-model (out nvars)
  "Parse a DIMACS SAT solver's stdout.  Returns (values status literals): STATUS is
:SAT, :UNSAT or NIL (unrecognized), and LITERALS the signed literals of the model
on the 'v' lines (NIL unless :SAT).  A token that is not an integer in
[-NVARS, NVARS] makes the model unrecognized -- which is how a bit-string model
line (some MaxSAT solvers) is rejected, since it would otherwise parse as one
enormous literal.  Seeding is only an optimization, so unrecognized simply means
no seed."
  (let ((status nil) (lits '()) (bad nil))
    (with-input-from-string (s out)
      (loop for raw = (read-line s nil :eof)
            until (eq raw :eof)
            for line = (string-trim '(#\Space #\Tab #\Return) raw)
            do (cond
                 ((and (> (length line) 1) (char-equal (char line 0) #\s)
                       (member (char line 1) '(#\Space #\Tab)))
                  (setf status (if (search "UNSAT" line :test #'char-equal) :unsat :sat)))
                 ((and (> (length line) 1) (char-equal (char line 0) #\v)
                       (member (char line 1) '(#\Space #\Tab)))
                  (dolist (tok (rest (cl-ppcre:split "\\s+" line)))
                    (let ((n (parse-integer tok :junk-allowed t)))
                      (cond ((or (null n) (> (abs n) nvars)) (setf bad t))
                            ((zerop n))          ; the DIMACS terminator
                            (t (push n lits)))))))))
    (cond ((eq status :unsat) (values :unsat nil))
          ((and (eq status :sat) (not bad) lits) (values :sat (nreverse lits)))
          (t (values nil nil)))))

(defun mcsat--seed-init-file (clauses a2i nvars &key (solver *solver*) (verbose t))
  "Solve the hard CLAUSES with the CDCL SAT solver and write its model as a walksat
-init file.  Returns the init file's path, or NIL when no model could be obtained
(no solver on PATH, or output we do not recognize) -- in which case the sampler
just falls back to its own search.  Signals an error when the solver PROVES the
clauses unsatisfiable, since then no marginals exist."
  (when (null clauses) (return-from mcsat--seed-init-file nil))
  (let ((cnf (format nil "~A.cnf" (make-scratch-file-root)))
        (init (format nil "~A.init" (make-scratch-file-root))))
    (unwind-protect
         (progn
           (mcsat--write-dimacs clauses a2i nvars cnf)
           (multiple-value-bind (out err code)
               (handler-case
                   (uiop:run-program (list solver cnf)
                                     :output :string :error-output :string
                                     :ignore-error-status t)
                 (error (c)
                   (declare (ignore c))
                   (when verbose
                     (format t "; could not run the SAT solver ~A to seed the initial assignment;~%; MC-SAT will search for one itself (set *solver*, or expect trouble on structured instances)~%"
                             solver))
                   (return-from mcsat--seed-init-file nil)))
             (declare (ignore err code))
             (multiple-value-bind (status lits) (mcsat--parse-sat-model out nvars)
               (case status
                 (:unsat
                  (error "the hard clauses are unsatisfiable (proved by ~A) -- the theory (with any evidence) has no models, so no marginals exist"
                         solver))
                 (:sat
                  (with-open-file (s init :direction :output
                                          :if-exists :supersede :if-does-not-exist :create)
                    (dolist (l lits) (format s "~D " l))
                    (terpri s))
                  (when verbose
                    (format t "; seeded MC-SAT's initial assignment from ~A (~D literals)~%"
                            solver (length lits)))
                  init)            ; the caller deletes it after the run
                 (t
                  (when verbose
                    (format t "; ~A produced no parseable model; MC-SAT will find its own initial assignment~%"
                            solver))
                  nil)))))
      (ignore-errors (delete-file cnf)))))

;;; ----------------------------------------------------------------------------
;;; Running the sampler and parsing its marginals
;;; ----------------------------------------------------------------------------

(defun mcsat--flag (name value &key (format "~D"))
  "The two-element option list (NAME VALUE) when VALUE is non-NIL, else NIL."
  (when value (list name (format nil format value))))

(defun mcsat--run (wcnf-file nvars &key (walksat *walksat*) samples burnin seed
                                        unitprop walk-prob temp cutoff
                                        init-cutoff init-tries init-file)
  "Run WALKSAT in -mcsat mode on WCNF-FILE.  Returns (values marginals diagnostics),
where MARGINALS is a vector indexed 1..NVARS of P(var = true) and DIAGNOSTICS is
the list of the binary's 'c ...' lines (sample counts, SampleSAT fallback rate,
effective sample size, unit-propagation statistics)."
  (let ((args (append (list walksat "-mcsat")
                      (mcsat--flag "-samples" samples)
                      (mcsat--flag "-burnin" burnin)
                      (mcsat--flag "-seed" seed)
                      (mcsat--flag "-samplesat-cutoff" cutoff)
                      (mcsat--flag "-mcsat-init-cutoff" init-cutoff)
                      (mcsat--flag "-mcsat-init-tries" init-tries)
                      (mcsat--flag "-mcsat-wp" walk-prob :format "~,6F")
                      (mcsat--flag "-mcsat-temp" temp :format "~,6F")
                      (when unitprop (list "-unitprop"))
                      ;; seeds the FIRST try of the initial hard-clause solve
                      (when init-file (list "-init" (namestring init-file)))
                      (list (namestring wcnf-file)))))
    (multiple-value-bind (out err code)
        (handler-case
            (uiop:run-program args :output :string :error-output :string
                                   :ignore-error-status t)
          (error (c)
            (error "could not run walksat (~A): ~A~%Put a version 58 (MC-SAT) 'walksat' on PATH (bin/install-solvers.sh --only walksat)."
                   walksat c)))
      (when (and code (not (zerop code)))
        ;; The common failure is an infeasible theory (often over-constraining
        ;; evidence); report that in FiFO's terms rather than dumping the log.
        (when (search "UNSATISFIABLE" err)
          (error "the hard clauses are unsatisfiable -- the theory (with any evidence) has no models, so no marginals exist"))
        (when (search "could not satisfy the hard clauses" err)
          (error "MC-SAT could not find a model of the hard clauses.~%Seeding the initial assignment from the CDCL solver is the fix for structured instances (:seed-from-sat t, the default -- check that ~S runs); failing that, raise :init-cutoff / :init-tries.~%~A"
                 *solver* (string-trim '(#\Newline) err)))
        (error "walksat (~A) exited with code ~A.~%--- stdout ---~%~A~%--- stderr ---~%~A"
               walksat code out err))
      (let ((marginals (make-array (1+ nvars) :initial-element nil))
            (diagnostics '())
            (seen 0))
        (with-input-from-string (s out)
          (loop for raw = (read-line s nil :eof)
                until (eq raw :eof)
                for line = (string-trim '(#\Space #\Tab #\Return) raw)
                do (cond
                     ((and (> (length line) 1) (char= (char line 0) #\c)
                           (member (char line 1) '(#\Space #\Tab)))
                      (push (string-left-trim '(#\Space #\Tab) (subseq line 1)) diagnostics))
                     ((and (> (length line) 1) (char= (char line 0) #\v)
                           (member (char line 1) '(#\Space #\Tab)))
                      (let* ((toks (cl-ppcre:split "\\s+" line))
                             (*read-default-float-format* 'double-float)
                             (var (and (>= (length toks) 3)
                                       (parse-integer (second toks) :junk-allowed t)))
                             (p (and (>= (length toks) 3)
                                     (ignore-errors (read-from-string (third toks))))))
                        (unless (and var (realp p) (<= 1 var nvars))
                          (error "cannot parse marginal line from walksat: ~S" line))
                        (setf (aref marginals var) (float p 1.0d0))
                        (incf seen))))))
        (when (zerop seen)
          (error "walksat (~A) produced no 'v <var> <p>' marginal lines -- is it version 58 or later?  (Earlier releases print their help text and ignore -mcsat.)~%--- stdout ---~%~A~%--- stderr ---~%~A"
                 walksat out err))
        (values marginals (nreverse diagnostics))))))

(defun mcsat--efficiency (diagnostics)
  "The sampling efficiency (mean ESS / samples) reported on the binary's 'ess'
diagnostic line, or NIL when there is none.  Values near 1 mean near-independent
samples; a very low value means the chain barely moved and the marginals should
not be trusted."
  (loop for d in diagnostics
        for groups = (nth-value 1 (cl-ppcre:scan-to-strings
                                   "efficiency=([0-9]*\\.?[0-9]+)" d))
        when groups
          do (return (let ((*read-default-float-format* 'double-float))
                       (float (read-from-string (aref groups 0)) 1.0d0)))))

;;; ----------------------------------------------------------------------------
;;; Entry point
;;; ----------------------------------------------------------------------------

(defun mcsat--frozen-p (diagnostics)
  "True when the sampler reported that the chain never moved although variables were
free to move.  This is the dangerous failure: every marginal comes back pinned at 0
or 1 -- indistinguishable, in the marginals alone, from a genuinely determined
problem -- but the numbers are just the starting assignment.  The ESS estimate
cannot see it (a frozen chain has no non-deterministic variables to estimate from),
which is why the binary reports mixing separately."
  (some (lambda (d) (search "chain is FROZEN" d)) diagnostics))

(defvar *mcsat-efficiency-warning* 0.1d0
  "Sampling efficiencies below this are reported as a warning: the MCMC chain
mixed too slowly for its marginals to be trusted (strongly coupled model).")

(defun marginals-mcsat (scnf-file &key out-file weighted-only keep-wcnf wcnf-file scale
                                       evidence evidence-file
                                       samples burnin seed unitprop walk-prob temp cutoff
                                       init-cutoff init-tries (seed-from-sat t)
                                       (sat-solver *solver*)
                                       (walksat *walksat*) (verbose t))
  "APPROXIMATE marginal P(atom = true) of every atom in a weighted .scnf, by MC-SAT
sampling (WalkSAT v58's -mcsat mode).  Unlike the maxent/addmc/ddnnf/d4 back ends
this is a Monte-Carlo estimate, not an exact count: it runs the sampler ONCE for
all atoms (rather than one exact count per atom) and so scales to instances the
exact counters cannot handle, at the price of sampling error.  Set SEED for
reproducibility and raise SAMPLES for tighter estimates.

Watch the reported sampling efficiency (effective sample size / samples): MC-SAT
mixes poorly on strongly coupled models -- when many weights are large almost every
satisfied clause enters the constraint set each step and the chain freezes -- and a
very low efficiency means the marginals are untrustworthy, not merely noisy.

MC-SAT must start from a model of the hard clauses, and finds one by stochastic
local search -- which fails outright on structured (SatPlan) encodings.  So by
default (SEED-FROM-SAT, on) the hard clauses are first solved with FiFO's CDCL SAT
solver (SAT-SOLVER, default *solver*) and its model seeds the sampler's initial
assignment; an UNSAT verdict is then a proof, reported at once.  Pass
:seed-from-sat nil to let the sampler find its own starting point.

SAMPLES, BURNIN, SEED, WALK-PROB (SampleSAT's WalkSAT-vs-annealing mix), TEMP (its
annealing temperature), CUTOFF (flips per sample), INIT-CUTOFF/INIT-TRIES (budget
for the initial hard-clause solve) and UNITPROP are passed through to the binary;
NIL leaves each at the binary's default.  With WEIGHTED-ONLY, only the atoms that
carry a weight are reported; otherwise every atom is.  SCALE is as in WMC: NIL (the
default) reads the pipeline's 'scale: N' header so the marginals reflect the REAL
costs rather than the MaxSAT-scaled integers; pass :scale 1 for the raw weights.
EVIDENCE (a list of ground FiFO formulas) and EVIDENCE-FILE (a file of them) are
conjoined with the theory as HARD clauses, so each P(a) becomes P(a | evidence);
the formulas must be ground (see WMC--EVIDENCE-CLAUSES).  Atoms introduced only by
the evidence (e.g. Tseitin auxiliaries) are not themselves reported.  Prints one
(MARGINAL <atom> <p>) line per atom (sorted) and, with OUT-FILE, also writes them
there.  The scratch weighted CNF is deleted unless KEEP-WCNF is set or WCNF-FILE
was given explicitly.  Returns (values alist-of-(atom . probability) efficiency
frozen-p) -- FROZEN-P is the chain-never-moved verdict (see MCSAT--FROZEN-P), in
which case the marginals are the starting assignment and must not be used."
  ;; NB: WEIGHT-FORMS, not the special WEIGHTS (which parse resets) -- see wmc.
  (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let ((weight-atoms (remove-duplicates
                         (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                 weight-forms)
                         :test #'equal)))
      (when (and weighted-only (null weight-atoms))
        (when verbose (format t "; no weighted atoms in ~A~%" scnf-file))
        (return-from marginals-mcsat nil))
      (setf scale (rw--resolve-scale scnf-file scale verbose))
      (let* ((evidence-clauses (wmc--evidence-clauses evidence evidence-file))
             ;; report only theory atoms (and weighted atoms), never evidence-only auxiliaries
             (theory-atoms (remove-duplicates (append (wmc--clause-atoms clauses) weight-atoms)
                                              :test #'equal :from-end t))
             (clauses (append clauses evidence-clauses)))
        (when (and verbose evidence-clauses)
          (format t "; conditioning on ~D evidence clause~:P~%" (length evidence-clauses)))
        (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
          (let ((wcnf (or wcnf-file (wmc--scratch-wcnf)))
                ;; Solve the hard clauses with the CDCL solver first and hand the
                ;; model to walksat's -init: local search alone cannot reach a model
                ;; of a structured encoding (see MCSAT--SEED-INIT-FILE).
                (init-file (when seed-from-sat
                             (mcsat--seed-init-file clauses a2i nvars
                                                    :solver sat-solver :verbose verbose))))
            (with-open-file (s wcnf :direction :output
                                    :if-exists :supersede :if-does-not-exist :create)
              (mcsat--write-wcnf clauses weight-forms a2i nvars s :scale scale))
            (multiple-value-bind (marginals diagnostics)
                (unwind-protect
                     (mcsat--run wcnf nvars :walksat walksat :samples samples :burnin burnin
                                            :seed seed :unitprop unitprop :walk-prob walk-prob
                                            :temp temp :cutoff cutoff
                                            :init-cutoff init-cutoff :init-tries init-tries
                                            :init-file init-file)
                  (when init-file (ignore-errors (delete-file init-file)))
                  (if (or keep-wcnf wcnf-file)
                      (when (and verbose keep-wcnf) (format t "; wcnf kept: ~A~%" wcnf))
                      (ignore-errors (delete-file wcnf))))
              (let* ((targets (if weighted-only
                                  weight-atoms
                                  ;; hide internal reification atoms from the default
                                  ;; listing; they show under --weighted-only, where
                                  ;; P(atom) = P(the reified formula)
                                  (remove-if #'reified-formula-atom-p theory-atoms)))
                     (efficiency (mcsat--efficiency diagnostics))
                     (frozen (mcsat--frozen-p diagnostics))
                     (results (sort (loop for a in targets
                                          for v = (gethash a a2i)
                                          collect (cons a (aref marginals v)))
                                    #'string< :key (lambda (c) (format nil "~S" (car c))))))
                (when verbose
                  (dolist (d diagnostics) (format t "; ~A~%" d))
                  (cond
                    (frozen
                     (format t "; WARNING: the chain never moved -- the marginals below are the STARTING~%; assignment, not the distribution.  Every one of them is a 0 or a 1, which looks~%; like a determined problem but is not.  Do not use them; run an exact back end~%; (--solver addmc / d4) on this instance.~%"))
                    ((and efficiency (< efficiency *mcsat-efficiency-warning*))
                     (format t "; WARNING: sampling efficiency ~,3F is very low -- the chain barely moved,~%; so these marginals are unreliable, not merely noisy.  The model is probably too~%; strongly coupled for MCMC; try an exact back end (addmc/d4) on a smaller instance.~%"
                             efficiency)))
                  (dolist (r results)
                    (format t "(MARGINAL ~S ~,6F)~%" (car r) (cdr r))))
                (when out-file
                  (with-open-file (o out-file :direction :output
                                              :if-exists :supersede :if-does-not-exist :create)
                    (format o "; approximate marginals of ~A via MC-SAT~@[ (weighted atoms only)~]~%"
                            (file-namestring scnf-file) weighted-only)
                    (dolist (d diagnostics) (format o "; ~A~%" d))
                    (dolist (r results)
                      (format o "(MARGINAL ~S ~,6F)~%" (car r) (cdr r)))))
                (values results efficiency frozen)))))))))
