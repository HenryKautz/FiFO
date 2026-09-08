;;;; hypotheses.lisp -- posteriors over a set of competing hypothesis atoms.
;;;;
;;;; marginals.sh reports P(atom | T /\ O).  When the atoms in question are
;;;; COMPETING HYPOTHESES that is already a posterior -- but one whose prior is
;;;; implicit and equal to P(h_i | T), the theory's own mass on h_i.  Where that
;;;; mass is an artifact of the encoding rather than a belief -- a goal that is
;;;; cheap to reach, a fault with many consistent explanations, a hypothesis with
;;;; more groundings -- the answer tilts toward whichever hypothesis the theory
;;;; happens to favour, regardless of what the evidence says.
;;;;
;;;; Two baselines, selected by :baseline.
;;;;
;;;;   :best-rival      P(h_i | T /\ O), read straight off one conditioned model.
;;;;                    The implicit prior above is left in place.
;;;;
;;;;   :per-hypothesis  the likelihood P(O | T /\ h_i) per hypothesis, with the
;;;;                    implicit prior divided out and an explicit prior applied
;;;;                    -- the baseline Ramirez & Geffner use, and what
;;;;                    recognize.sh computes for PDDL plan recognition.
;;;;
;;;; THE IDENTITY.  For the exact counters :per-hypothesis needs no new inference
;;;; and no extra solving, because
;;;;
;;;;     P(O | T /\ h_i)  =  P(h_i | T /\ O) * P(O | T) / P(h_i | T)
;;;;
;;;; and P(O | T) does not depend on i, so it cancels when the posterior is
;;;; normalised over the hypothesis set:
;;;;
;;;;     posterior(h_i)  proportional to  prior_i * P(h_i | T /\ O) / P(h_i | T)
;;;;
;;;; So the whole method is TWO back-end runs -- one conditioned on the evidence,
;;;; one not -- and a division.  Dividing by P(h_i | T) is literally dividing out
;;;; the implicit prior, which is what the baseline is for.
;;;;
;;;; Two consequences, both useful:
;;;;
;;;;   * No reification of O and no NEGATION of O is needed, so the evidence may
;;;;     be any set of ground formulas.  (recognize.sh insists on a single
;;;;     negatable form; that restriction belongs to the max-term estimator
;;;;     below, not to the method.)
;;;;
;;;;   * It works on maxent too, which has no :evidence keyword, because
;;;;     conditioning is done by CONJOINING the evidence clauses into a combined
;;;;     scnf -- the technique plan--scnf-to-solve uses in planner.lisp.  One
;;;;     mechanism for all five exact back ends instead of five keyword
;;;;     interfaces to keep in step.
;;;;
;;;; max-term cannot use the identity: it drops the degeneracy term differently
;;;; on each side, so it does not satisfy the log-odds algebra the derivation
;;;; needs.  It computes R&G's difference directly instead -- 2n clamped solves,
;;;; c_min(T /\ O /\ h_i) against c_min(T /\ ~O /\ h_i) -- which is why it, alone,
;;;; needs ~O.  We build ~O ourselves as (not (and . forms)), so even there the
;;;; caller is not restricted to a single evidence form.

;; maxterm.lisp pulls in wmc -> maxent -> reweight, which is everything the
;; always-needed pieces use: the scnf reader, the clausifier, the atom indexer,
;; mt--solve and the exclusive-group detector.
(load (merge-pathnames "maxterm.lisp" (or *load-pathname* *default-pathname-defaults*)))

;; ddnnf.lisp and mcsat.lisp are NOT loaded here: they are needed only when
;; --solver names them, and marginals.sh loads the selected one before this file.
;; Declaring them keeps that from adding style warnings to every other run --
;; the same treatment planner.lisp gives marginals / marginals-addmc.
(declaim (ftype (function (t &rest t) t) ddnnf-marginals marginals-mcsat))

(defparameter *hypothesis-counters* (counter-names)
  "The back ends :counter accepts, from the shared solvers.dat table.  A counter
is NAMED, never a path.")

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun hp--as-atom (x)
  "Read a hypothesis atom given as a string; pass a form through unchanged."
  (if (stringp x) (let ((*read-eval* nil)) (read-from-string x)) x))

(defun hp--theory-atoms (clauses weight-forms)
  "Every atom the scnf actually names -- in its clauses or its weight forms.
The parameter is not called WEIGHTS on purpose: (defvar Weights) makes that a
special, so a parameter of that name rebinds FiFO's global for the call."
  (remove-duplicates
   (append (wmc--clause-atoms clauses)
           (mapcar (lambda (w) (nth-value 0 (rw--literal-atom-and-sign (second w))))
                   weight-forms))
   :test #'equal :from-end t))

(defun hp--check-hypotheses (hyps atoms scnf-file)
  "Every hypothesis must already occur in the theory.  This is not pedantry:
FiFO's parser mints a fresh proposition for any atom it has not seen, and such a
proposition occurs in no clause, so the hypothesis would be entirely
unconstrained and its posterior meaningless rather than wrong-looking.  The same
silent failure plan--resolve-evidence exists to catch."
  (unless hyps (error "no hypotheses given"))
  (dolist (h hyps)
    (unless (member h atoms :test #'equal)
      (error "hypothesis atom ~S does not occur in ~A~%~
              (FiFO would mint a fresh proposition for it: it would appear in no~%~
               clause, be unconstrained, and its posterior would mean nothing)"
             h scnf-file)))
  (let ((dups (remove-if (lambda (h) (= 1 (count h hyps :test #'equal))) hyps)))
    (when dups
      (error "hypothesis ~S given more than once" (first dups)))))

(defun hp--auxiliary-atom-p (a)
  "An atom the clausifier itself minted -- a Tseitin selector gensym (uninterned)
or a reified-formula atom.  These legitimately do not occur in the theory."
  (or (and (symbolp a) (null (symbol-package a)))
      (reified-formula-atom-p a)))

(defun hp--check-evidence (ev-clauses atoms)
  "Every atom the evidence names must already be in the theory.  FiFO's parser
mints a fresh proposition for one that is not, and that proposition occurs in no
other clause -- so the evidence would CONSTRAIN NOTHING and the run would quietly
report the unconditioned answer.  Exactly the failure plan--resolve-evidence
exists to catch on the planner side, and it is just as silent here."
  (let ((strays (remove-if (lambda (a) (or (hp--auxiliary-atom-p a)
                                           (member a atoms :test #'equal)))
                           (wmc--clause-atoms ev-clauses))))
    (when strays
      (error "the evidence names ~{~S~^, ~}, which the theory does not contain.~%~
              A fresh proposition would be minted for it, appearing in no other~%~
              clause, so the evidence would constrain nothing and the answer would~%~
              be the UNCONDITIONED one, silently.~%~
              Check the spelling -- and note an scnf writes a 0-ary predicate as~%~
              P, not (P)."
             strays))))

(defun hp--combined-scnf (scnf-file extra-clauses suffix)
  "SCNF-FILE with EXTRA-CLAUSES conjoined, as a new file; SCNF-FILE itself when
there is nothing to add.  The original is copied as TEXT, not reprinted from
parsed forms, so its comment header survives -- rw--detect-scale reads the weight
scale out of those comments, and losing them would silently change beta."
  (if (null extra-clauses)
      scnf-file
      (let ((out (format nil "~A-~A.scnf"
                         (replace-suffix-with-regex scnf-file "\\..*?$" "") suffix)))
        (with-open-file (o out :direction :output :if-exists :supersede
                               :if-does-not-exist :create)
          (with-open-file (i scnf-file :direction :input)
            (loop for line = (read-line i nil) while line do (write-line line o)))
          (format o "; ~D conditioning clause~:P appended by hypothesis-posterior~%"
                  (length extra-clauses))
          (dolist (c extra-clauses) (format o "~S~%" c)))
        out)))

(defun hp--priors-vector (hyps priors)
  "The prior over HYPS as a normalised list, uniform when PRIORS is empty.
All or none: a partial prior specification is an error rather than a silent zero
for the hypotheses left out."
  (let* ((n (length hyps))
         (given (mapcar (lambda (h) (assoc h priors :test #'equal)) hyps)))
    (cond ((every #'null given)
           (make-list n :initial-element (/ 1d0 n)))
          ((some #'null given)
           (error "a prior was given for some hypotheses but not for ~S~%~
                   (give all of them or none -- a missing prior is not zero)"
                  (nth (position nil given) hyps)))
          (t
           (let* ((raw (mapcar (lambda (c) (float (cdr c) 1d0)) given))
                  (s (reduce #'+ raw)))
             (when (some #'minusp raw) (error "a prior is negative: ~S" raw))
             (when (<= s 0) (error "the priors sum to ~A; at least one must be positive" s))
             (mapcar (lambda (p) (/ p s)) raw))))))

(defun hp--lookup (alist atom scnf-file)
  "The reported marginal of ATOM.  A back end that skipped it is an error rather
than a default, since a silently missing hypothesis would just drop out of the
normalisation and shift every other posterior."
  (let ((c (assoc atom alist :test #'equal)))
    (unless c
      (error "the back end reported no marginal for ~S in ~A" atom scnf-file))
    (float (cdr c) 1d0)))

(defun hp--normalise (us)
  "Normalise non-negative weights to a distribution; all zeros gives all zeros
rather than NaN -- that happens when every hypothesis is refuted, and saying so
is better than dividing by zero."
  (let ((s (reduce #'+ us)))
    (if (<= s 0) (mapcar (constantly 0d0) us) (mapcar (lambda (u) (/ u s)) us))))

;;; ---------------------------------------------------------------------------
;;; The exact back ends, behind one call
;;; ---------------------------------------------------------------------------

(defun hp--marginals (scnf-file counter opts)
  "P(atom) for every atom of SCNF-FILE under COUNTER, as an alist (atom . p).
Every back end already returns exactly this shape, so the dispatch is the only
thing that differs."
  (let ((scale (getf opts :scale)))
    (cond
      ((string-equal counter "maxent")
       (marginals scnf-file :verbose nil :scale scale
                            :node-limit (or (getf opts :node-limit) 5000000)))
      ((string-equal counter "addmc")
       (marginals-addmc scnf-file :verbose nil :scale scale
                                  :epsilon (getf opts :epsilon)))
      ((string-equal counter "ddnnf")
       (ddnnf-marginals scnf-file :verbose nil :scale scale))
      ((string-equal counter "d4")
       (ddnnf-marginals scnf-file :verbose nil :scale scale :compiler :d4))
      ((string-equal counter "mc-sat")
       ;; :verbose nil suppresses the sampler's own diagnostics, so re-raise the
       ;; two that mean the numbers are WRONG rather than merely noisy.  A frozen
       ;; chain returns its seed with every marginal pinned at 0/1, which would
       ;; look like a confident posterior.  The 0.1 threshold mirrors
       ;; *mcsat-efficiency-warning*, named literally because mcsat.lisp is
       ;; loaded only when this branch can run.
       (multiple-value-bind (res eff frozen)
           (marginals-mcsat scnf-file :verbose nil :scale scale
                                      :samples (getf opts :samples)
                                      :burnin (getf opts :burnin)
                                      :seed (getf opts :seed)
                                      :unitprop (getf opts :unitprop)
                                      :walk-prob (getf opts :walk-prob)
                                      :temp (getf opts :temp)
                                      :cutoff (getf opts :cutoff)
                                      :init-cutoff (getf opts :init-cutoff)
                                      :init-tries (getf opts :init-tries)
                                      :seed-from-sat (getf opts :seed-from-sat t))
         (when frozen
           (format t "; WARNING: the MC-SAT chain did not move on ~A -- the marginals are~%~
                      ; the seed assignment, not a sample.  Do not trust this posterior.~%"
                   (file-namestring scnf-file)))
         (when (and eff (< eff 0.1d0))
           (format t "; WARNING: MC-SAT sampling efficiency ~,3F on ~A (below 0.1) -- the~%~
                      ; marginals are unreliable rather than merely noisy.~%"
                   eff (file-namestring scnf-file)))
         res))
      (t (error "unknown counter ~S -- expected one of ~{~A~^, ~}"
                counter *hypothesis-counters*)))))

;;; ---------------------------------------------------------------------------
;;; max-term: R&G's difference, directly
;;; ---------------------------------------------------------------------------

(defun hp--negate-forms (forms)
  "~O for a set of evidence forms: (not (and f1 ... fk)), or (not f) for one.
Building it here rather than textually is what lets the caller pass several
forms -- recognize.sh wraps a whole FILE in (not ...), which is why it must
insist the file hold exactly one form."
  (if (= 1 (length forms))
      (list 'not (first forms))
      (list 'not (cons 'and forms))))

(defun hp--maxterm-deltas (scnf-file hyps ev-forms opts)
  "For each hypothesis, (values delta status) with
delta = c_min(T /\\ ~O /\\ h) - c_min(T /\\ O /\\ h), the R&G difference.
Returns (values deltas n-unproved beta)."
  ;; NB: WEIGHTS is FiFO's global special, and (parse ...) inside
  ;; wmc--evidence-clauses resets it -- bind the weight forms to another name or
  ;; the evidence silently empties them and every cost becomes 0.
  (multiple-value-bind (clauses probs file-opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs file-opts))
    (let* ((sc (rw--resolve-scale scnf-file (getf opts :scale) nil))
           (b (or (getf opts :beta) (/ 1d0 sc)))
           (soft-atoms (mapcar (lambda (w) (nth-value 0 (rw--literal-atom-and-sign (second w))))
                               weight-forms))
           (pos (wmc--evidence-clauses ev-forms nil))
           (neg (wmc--evidence-clauses (list (hp--negate-forms ev-forms)) nil)))
      ;; One index over EVERY atom either side can mention, so the two clause
      ;; sets speak the same variable numbering.
      (multiple-value-bind (a2i nvars)
          (mx--index-atoms (append clauses pos neg) soft-atoms)
        (let* ((costs (wmc--literal-costs weight-forms a2i))
               (ints  (lambda (cls) (mapcar (lambda (c) (mx--clause->ints c a2i)) cls)))
               (with-pos (funcall ints (append clauses pos)))
               (with-neg (funcall ints (append clauses neg)))
               (root (format nil "~A-hyp" (replace-suffix-with-regex scnf-file "\\..*?$" "")))
               (unproved 0)
               (deltas '()))
          (dolist (h hyps)
            (let ((unit (gethash h a2i)))
              (multiple-value-bind (c-o st-o)
                  (mt--solve with-pos costs nvars (list unit) root :verbose nil)
                (multiple-value-bind (c-n st-n)
                    (mt--solve with-neg costs nvars (list unit) root :verbose nil)
                  (when (member st-o '(:unproved :best)) (incf unproved))
                  (when (member st-n '(:unproved :best)) (incf unproved))
                  ;; c(O) unreachable  -> the evidence refutes this hypothesis.
                  ;; c(~O) unreachable -> nothing BUT compliance is possible.
                  ;; The two costs are reported alongside the difference: they are
                  ;; the diagnostic that says WHY a hypothesis scored as it did --
                  ;; a cheap-to-reach goal whose non-complying plan is cheaper
                  ;; still looks quite different from one the evidence rules out.
                  (push (list (cond ((null c-o) :refuted)
                                    ((null c-n) :certain)
                                    (t (- c-n c-o)))
                              c-o c-n)
                        deltas)))))
          (values (nreverse deltas) unproved b))))))


;;; ---------------------------------------------------------------------------
;;; Exclusivity: reported, never asserted
;;; ---------------------------------------------------------------------------

(defun hp--set-equal (a b) (and (null (set-difference a b :test #'equal))
                                (null (set-difference b a :test #'equal))))

(defun hp--exclusivity (clauses ev-clauses hyps)
  "Whether the THEORY makes HYPS mutually exclusive and exhaustive, via the
detector max-term already uses (mt--detect-groups).  Exclusivity is a property of
the theory, not a claim the query gets to make, so this REPORTS rather than
asserts: normalising over the set is done either way, and the header says whether
the theory entails it or we merely assumed it."
  (let ((gs (mt--detect-groups (append clauses ev-clauses) hyps)))
    (cond ((find-if (lambda (g) (and (cdr g) (hp--set-equal (car g) hyps))) gs) :entailed)
          ((find-if (lambda (g) (hp--set-equal (car g) hyps)) gs) :exclusive-only)
          (t :assumed))))

;;; ---------------------------------------------------------------------------
;;; Rows: (atom posterior prior detail-plist)
;;; ---------------------------------------------------------------------------

(defun hp--exact-rows (scnf-file hyps ev-forms baseline prior-v opts counter keep)
  "The exact counters.  :per-hypothesis is two back-end runs and a division --
see THE IDENTITY in the file header; :best-rival is the single conditioned run
marginals.sh already does."
  (let* ((ev-clauses (wmc--evidence-clauses ev-forms nil))
         (cond-file (hp--combined-scnf scnf-file ev-clauses "hypev"))
         (cond-m (hp--marginals cond-file counter opts))
         (uncond-m (when (eq baseline :per-hypothesis)
                     (hp--marginals scnf-file counter opts))))
    (unless (or keep (equal cond-file scnf-file))
      (ignore-errors (delete-file cond-file)))
    (let ((cs (mapcar (lambda (h) (hp--lookup cond-m h cond-file)) hyps)))
      (ecase baseline
        (:best-rival
         (let ((post (hp--normalise (mapcar (lambda (c) (max c 0d0)) cs))))
           (mapcar (lambda (h p pr c) (list h p pr (list :marginal c)))
                   hyps post prior-v cs)))
        (:per-hypothesis
         (let* ((us (mapcar (lambda (h) (hp--lookup uncond-m h scnf-file)) hyps))
                ;; P(h|T) = 0 means the hypothesis is impossible in the theory at
                ;; all -- infeasible at this horizon, say.  Its posterior is 0;
                ;; dividing would be 0/0.
                (ratios (mapcar (lambda (c u) (if (<= u 0d0) 0d0 (/ c u))) cs us))
                (post (hp--normalise (mapcar #'* prior-v ratios))))
           ;; The ratio divides two estimates, so a small denominator amplifies
           ;; whatever error the back end has.  Exact counters do not care;
           ;; a sampler does, and silently.
           (when (and (string-equal counter "mc-sat")
                      (some (lambda (u) (and (> u 0d0) (< u 0.02d0))) us))
             (format t "; WARNING: P(h|T) below 0.02 for some hypothesis, and this baseline~%~
                        ; DIVIDES by it -- with a sampled counter that magnifies the Monte~%~
                        ; Carlo error.  Prefer an exact counter, or raise --samples.~%"))
           (mapcar (lambda (h p pr c u r)
                     (list h p pr (list :cond c :uncond u :lik-ratio r)))
                   hyps post prior-v cs us ratios)))))))

(defun hp--maxterm-rows (scnf-file hyps ev-forms baseline prior-v priors opts verbose)
  "max-term.  :best-rival delegates to marginals-maxterm (which is exactly that
cell); :per-hypothesis is R&G's difference, 2n clamped solves."
  (ecase baseline
    (:best-rival
     (let* ((res (apply #'marginals-maxterm scnf-file :query hyps :verbose verbose
                        (append (when ev-forms (list :evidence ev-forms))
                                (when priors (list :priors priors))
                                (let ((s (getf opts :scale))) (when s (list :scale s)))
                                (let ((b (getf opts :beta)))  (when b (list :beta b))))))
            (ps (mapcar (lambda (h)
                          (let ((r (find h res :key #'car :test #'equal)))
                            (if r (float (second r) 1d0) 0d0)))
                        hyps))
            (post (hp--normalise ps)))
       (mapcar (lambda (h p pr q) (list h p pr (list :maxterm-marginal q)))
               hyps post prior-v ps)))
    (:per-hypothesis
     (multiple-value-bind (deltas unproved b) (hp--maxterm-deltas scnf-file hyps ev-forms opts)
       (when (plusp unproved)
         (format t "; ~%; WARNING: ~D of the ~D max-term solves did not prove optimality.~%~
                    ; A per-hypothesis score is a DIFFERENCE of two minima, so two upper~%~
                    ; bounds do NOT cancel and these numbers are not trustworthy.  Use an~%~
                    ; exact solver:  --maxsat-solver rc2-maxsat.py~%; ~%"
                 unproved (* 2 (length hyps))))
       (let* ((liks (mapcar (lambda (d) (case (first d)
                                          (:refuted 0d0)   ; no complying plan exists
                                          (:certain 1d0)   ; no NON-complying plan exists
                                          (t (mt--sigmoid (* b (first d))))))
                            deltas))
              (post (hp--normalise (mapcar #'* prior-v liks))))
         (mapcar (lambda (h p pr l d)
                   (list h p pr (list :likelihood l :delta (first d)
                                      :c-o (or (second d) :inf)
                                      :c-not-o (or (third d) :inf))))
                 hyps post prior-v liks deltas))))))

;;; ---------------------------------------------------------------------------
;;; Reporting
;;; ---------------------------------------------------------------------------

(defun hp--details (plist)
  (loop for (k v) on plist by #'cddr
        append (list (format nil ":~(~A~)" k)
                     (if (realp v) (format nil "~,6F" v) (format nil "~(~A~)" v)))))

(defun hp--report (scnf-file rows baseline counter excl out-file verbose)
  (flet ((emit (s)
           (format s "; hypothesis posterior of ~A (baseline ~(~A~), counter ~A)~%"
                   (file-namestring scnf-file) baseline counter)
           (format s "; ~A~%"
                   (ecase excl
                     (:entailed "the theory entails the hypotheses are exclusive and exhaustive")
                     (:exclusive-only
                      "the theory makes them exclusive but NOT exhaustive -- a \"none of them\" outcome is being dropped")
                     (:assumed
                      "exclusive and exhaustive ASSUMED -- the theory does not entail it")))
           (when (eq baseline :per-hypothesis)
             (format s "; posterior is proportional to  prior * P(h|T,O) / P(h|T)~%"))
           (dolist (r rows)
             (format s "(HYPOTHESIS ~S :posterior ~,6F :prior ~,6F~{ ~A~})~%"
                     (first r) (second r) (third r) (hp--details (fourth r))))))
    (when verbose (emit *standard-output*))
    (when out-file
      (with-open-file (o out-file :direction :output :if-exists :supersede
                                  :if-does-not-exist :create)
        (emit o))))
  rows)

;;; ---------------------------------------------------------------------------
;;; The entry point
;;; ---------------------------------------------------------------------------

(defun hypothesis-posterior (scnf-file
                             &key hypotheses evidence evidence-file
                                  (baseline :best-rival) (counter "maxent")
                                  priors out-file (verbose t)
                                  scale beta node-limit epsilon maxsat-solver
                                  samples burnin seed unitprop walk-prob temp
                                  cutoff init-cutoff init-tries (seed-from-sat t)
                                  keep-intermediates)
  "Posterior over the competing HYPOTHESES atoms of SCNF-FILE given evidence.

BASELINE is :best-rival -- P(h | T /\\ O) read off one conditioned model, leaving
the theory's implicit prior in place -- or :per-hypothesis, which divides that
implicit prior out and applies PRIORS instead.  See the file header.

COUNTER is one of *hypothesis-counters*.  PRIORS is an alist (atom . p),
normalised over the hypothesis set, uniform by default.

Results print as (HYPOTHESIS <atom> :posterior p ...), deliberately NOT as
(MARGINAL ...): a per-hypothesis posterior is not a marginal of the theory, and
'grep MARGINAL' must not pick it up.  Returns the rows."
  (let* ((hyps (mapcar #'hp--as-atom hypotheses))
         (prs (mapcar (lambda (c) (cons (hp--as-atom (car c)) (cdr c))) priors))
         (ev-forms (append evidence (when evidence-file (wmc--read-forms evidence-file))))
         (opts (list :scale scale :beta beta :node-limit node-limit :epsilon epsilon
                     :samples samples :burnin burnin :seed seed :unitprop unitprop
                     :walk-prob walk-prob :temp temp :cutoff cutoff
                     :init-cutoff init-cutoff :init-tries init-tries
                     :seed-from-sat seed-from-sat))
         (*maxterm-solver* (or maxsat-solver *maxterm-solver*)))
    (setq counter (resolve-table-name counter "counter"))
    (unless (member counter *hypothesis-counters* :test #'string-equal)
      (error "unknown counter ~S -- expected one of ~{~A~^, ~}~%~
              (a counter is named, not a path; put the binary on PATH under its own name)"
             counter *hypothesis-counters*))
    (unless (member baseline '(:best-rival :per-hypothesis))
      (error "baseline must be :best-rival or :per-hypothesis, got ~S" baseline))
    (when (and (eq baseline :per-hypothesis) (null ev-forms))
      (error "the per-hypothesis baseline needs evidence: it compares P(O | h) across~%~
              hypotheses, and with no O there is nothing to compare."))
    (when (and prs (eq baseline :best-rival) (not (string-equal counter "max-term")))
      (error "priors have no defined meaning under the best-rival baseline on an exact~%~
              counter: the theory's own mass on each hypothesis IS the prior there, so~%~
              multiplying another one in would double-count it.~%~
              Use --baseline per-hypothesis, which divides that implicit prior out."))
    ;; WEIGHTS again: read into a non-special name, and take the theory's atoms
    ;; BEFORE any clausifying of evidence resets FiFO's globals.
    (multiple-value-bind (clauses probs file-opts weight-forms) (rw--read-scnf scnf-file)
      (declare (ignore probs file-opts))
      (let ((theory-atoms (hp--theory-atoms clauses weight-forms)))
        (hp--check-hypotheses hyps theory-atoms scnf-file)
        (hp--check-evidence (wmc--evidence-clauses ev-forms nil) theory-atoms))
      (let* ((prior-v (hp--priors-vector hyps prs))
             (excl (hp--exclusivity clauses (wmc--evidence-clauses ev-forms nil) hyps))
             (rows (if (string-equal counter "max-term")
                       (hp--maxterm-rows scnf-file hyps ev-forms baseline prior-v prs
                                         opts verbose)
                       (hp--exact-rows scnf-file hyps ev-forms baseline prior-v opts
                                       counter keep-intermediates))))
        (hp--report scnf-file rows baseline counter excl out-file verbose)))))
