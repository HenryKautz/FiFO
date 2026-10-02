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
;;; The second counter here is SharpSAT-TD (Korhonen & Jarvisalo, MCC 2021; the
;;; macOS port is github.com/HenryKautz/sharpsat-td), fed the :mcc-2024 dialect.
;;; Where ADDMC counts in doubles, SharpSAT-TD's -WE mode counts in MPFR floats.
;;; It never sets their precision, so the mantissa is MPFR's default 53 bits --
;;; double precision -- but the EXPONENT is unbounded: a count of 1e-5000 is
;;; carried, where a double underflows to 0.  The printed decimal is read back as
;;; an exact rational, so a marginal Z_a/Z is computed without that underflow
;;; even when Z itself is far outside double range.
;;; It is guided by a tree decomposition from its companion flow_cutter_pace17,
;;; which runs for *SHARPSAT-DECOT* seconds on EVERY call: marginals make 1+n calls.
;;;
;;; Entry points:
;;;   (wmc "file.scnf" &key counter ...)        -- partition function Z
;;;   (marginals-addmc "file.scnf" &key ...)    -- per-atom marginals via clamping
;;;   (marginals-sharpsat "file.scnf" &key ...) -- the same, counted by SharpSAT-TD
;;;   (wmc-write-wcnf "file.scnf" out &key dialect ...) -- the weighted CNF alone

(load (merge-pathnames "maxent.lisp" (or *load-pathname* *default-pathname-defaults*)))

(defvar *addmc* "addmc"
  "Name of the ADDMC weighted-model-counter binary, found on PATH.  Point at a
different build the way you would for any other program -- by putting it earlier
on PATH -- rather than through a FiFO-specific setting.")

(defvar *sharpsat* "sharpSAT"
  "Name of the SharpSAT-TD binary, found on PATH like *ADDMC*.  Its companion
flow_cutter_pace17 must sit beside it (bin/install-solvers.sh installs both), or
be named by the SHARPSAT_FLOWCUTTER environment variable.")

(defvar *sharpsat-decot* 1
  "Seconds SharpSAT-TD's flowcutter spends looking for a tree decomposition (its
-decot) on each call.  The search is anytime and always runs the full budget, so
this is a floor on every count -- and marginals make one count per atom.  1 s
suits FiFO-scale theories; SharpSAT-TD's authors used 60-600 s on competition
instances, where a better decomposition repays it.")

(defvar *sharpsat-cache-mb* 4000
  "SharpSAT-TD's component-cache limit in MB (its -cs).  Always passed: left
unset, SharpSAT-TD sizes the cache from 'free' RAM, which its macOS build reads
as TOTAL physical memory -- 95% of all RAM, enough to drive the machine into swap.
The authors suggest about half the memory you can spare, minus 500.")

(defvar *wmc-jobs* 4
  "How many clamped counts the marginals back ends (ADDMC, SharpSAT-TD) run at
once.  The 1 + n counts are independent and, under SharpSAT-TD, each spends most
of its time in flowcutter's fixed budget, so they parallelize almost perfectly.
1 runs them one at a time.  Under SharpSAT-TD the cache limit is a TOTAL budget
split across the jobs (see MARGINALS-SHARPSAT), so more jobs never means more
memory.")

;;; ----------------------------------------------------------------------------
;;; Running independent counts in parallel
;;; ----------------------------------------------------------------------------

(defvar *wmc-scratch-lock* (sb-thread:make-mutex :name "wmc scratch names")
  "Serializes MAKE-SCRATCH-FILE-ROOT, whose random half draws from one shared
random state: two threads drawing at once could get the SAME root, and then read
and delete each other's files -- the collision class the pid in the root exists
to prevent between processes.")

(defun wmc--scratch-root ()
  (sb-thread:with-mutex (*wmc-scratch-lock*) (make-scratch-file-root)))

(defun wmc--parallel-map (fn items jobs)
  "(multiple-value-list (FN item)) for each of ITEMS, in order, on up to JOBS
threads.  The first error any job signals is re-signalled here once all have
stopped, and no new job starts after it.

New SBCL threads see the GLOBAL value of a special, not the caller's binding, so
a (let ((*solver-timeout* 2)) ...) around the call would silently be lost --
every count would run under the default 600 s.  The specials a count reads are
therefore captured here and rebound in each thread."
  (let ((n (length items)))
    (if (or (<= jobs 1) (<= n 1))
        (mapcar (lambda (x) (multiple-value-list (funcall fn x))) items)
        (let ((vec (coerce items 'vector))
              (results (make-array n))
              (next 0)
              (err nil)
              (lock (sb-thread:make-mutex :name "wmc jobs"))
              (timeout *solver-timeout*)
              (grace *solver-kill-grace*)
              (cwd *default-pathname-defaults*))
          (flet ((worker ()
                   (let ((*solver-timeout* timeout)
                         (*solver-kill-grace* grace)
                         (*default-pathname-defaults* cwd))
                     (loop
                       (let ((i (sb-thread:with-mutex (lock)
                                  (when (and (null err) (< next n))
                                    (prog1 next (incf next))))))
                         (unless i (return))
                         (handler-case
                             (setf (aref results i)
                                   (multiple-value-list (funcall fn (aref vec i))))
                           (error (e)
                             (sb-thread:with-mutex (lock)
                               (unless err (setf err e))))))))))
            (mapc #'sb-thread:join-thread
                  (loop repeat (min jobs n)
                        collect (sb-thread:make-thread #'worker :name "wmc count"))))
          (when err (error err))
          (coerce results 'list)))))

;;; ----------------------------------------------------------------------------
;;; Emitting MCC-2020 weighted CNF
;;; ----------------------------------------------------------------------------

(defun wmc--scratch-wcnf ()
  "A unique scratch .wcnf path (in the current directory, using FiFO's
scratch-file naming), so a generated/deleted scratch file can never collide with
or clobber a user's file."
  (format nil "~A.wcnf" (wmc--scratch-root)))

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

(defun wmc--unit-propagate (int-clauses nvars)
  "Unit propagation over INT-CLAUSES (simple-vectors of signed variable indices).
Returns a vector indexed 1..NVARS of +1 / -1 / 0 (forced true / forced false /
free), or :CONFLICT if propagation derives the empty clause.  Queue-based with
occurrence lists, so linear in the total clause size: marginals call it once per
clamped count."
  (let* ((nc (length int-clauses))
         (assign (make-array (1+ nvars) :initial-element 0))
         (occ (make-array (1+ (* 2 nvars)) :initial-element nil)) ; lit -> clauses
         (nfalse (make-array nc :initial-element 0))
         (sat (make-array nc :initial-element nil))
         (queue '()))
    (flet ((idx (lit) (+ lit nvars))
           (value (lit) (let ((a (aref assign (abs lit)))) (if (minusp lit) (- a) a))))
      (loop for c across int-clauses for i from 0
            do (loop for lit across c do (push i (aref occ (idx lit)))))
      (labels ((set-true (lit)   ; returns NIL on conflict
                 (case (value lit)
                   (1 t)
                   (-1 nil)
                   (t (setf (aref assign (abs lit)) (if (minusp lit) -1 1))
                      (dolist (i (aref occ (idx lit))) (setf (aref sat i) t))
                      (push lit queue)
                      t))))
        (loop for c across int-clauses
              do (case (length c)
                   (0 (return-from wmc--unit-propagate :conflict))
                   (1 (unless (set-true (aref c 0))
                        (return-from wmc--unit-propagate :conflict)))))
        (loop while queue
              do (let ((lit (pop queue)))
                   (dolist (i (aref occ (idx (- lit))))
                     (unless (aref sat i)
                       (let* ((c (aref int-clauses i))
                              (nf (incf (aref nfalse i))))
                         (cond ((>= nf (length c))
                                (return-from wmc--unit-propagate :conflict))
                               ((= nf (1- (length c)))
                                (let ((u (find-if (lambda (l) (zerop (value l))) c)))
                                  ;; NIL: the remaining literal repeats a false one
                                  ;; (a clause listing a literal twice)
                                  (unless (and u (set-true u))
                                    (return-from wmc--unit-propagate :conflict)))))))))))
      assign)))

(defun wmc--checked-weight (lit cost atom-of)
  "exp(-COST) as a NORMAL double, or an error naming the literal.  A weight below
the normal range would be written as 0 -- turning a soft cost into a hard
prohibition, silently -- or as a subnormal that std::stod (both counters' weight
parser) rejects; one above it cannot be written at all."
  (let ((w (ignore-errors (exp (- cost)))))
    (unless (and w (not (sb-ext:float-infinity-p w))
                 (>= w least-positive-normalized-double-float))
      (error "the weight exp(-~,4F) of literal ~:[(NOT ~S)~;~S~] is outside double range (cost must be within about +-708 after --scale).~%A cost that large is effectively hard: assert the literal as a hard clause instead, or give a larger --scale."
             cost (plusp lit) (funcall atom-of (abs lit))))
    w))

(defun wmc--write-mcc (clauses weights a2i nvars out-stream
                       &key extra-units (scale 1.0d0) (dialect :mcc-2020) fold)
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
leaning on a convention the two counters do not share.

Every weight written must be a NORMAL double (WMC--CHECKED-WEIGHT): a cost above
about 708 would otherwise be written as 0 or a subnormal -- a soft cost silently
turned hard, or a weight std::stod refuses.  FOLD (for FiFO's own counting runs,
never for a file handed to someone else) moves as much as it can out of the file
and into a returned LOG FACTOR, so the true count is (file's count) * exp(factor):

  - a literal FORCED by unit propagation (over the clauses plus EXTRA-UNITS)
    contributes the constant factor exp(-cost) to every model, so its cost goes
    to the factor and its variable is written with weight 1 both ways;
  - under :MCC-2024, each free variable's two weights are rescaled so the larger
    is 1, the shift again going to the factor -- which handles a large NEGATIVE
    cost too.

What still does not fit is a weight genuinely too small RELATIVE to its own
variable's other polarity, and that is an error naming the literal.  Returns
(values LOG-FACTOR) -- 0 without FOLD -- or :UNSAT when propagation finds a
conflict, in which case the count is 0 and the file is not worth running."
  (let* ((cost (wmc--literal-costs weights a2i))
         (nclauses (+ (length clauses) (length extra-units)))
         (int-clauses (mapcar (lambda (cl) (mx--clause->ints cl a2i)) clauses))
         (forced (when fold
                   (wmc--unit-propagate
                    (coerce (append int-clauses
                                    (mapcar (lambda (u) (vector u)) extra-units))
                            'simple-vector)
                    nvars)))
         (i2a (let ((v (make-array (1+ nvars) :initial-element nil)))
                (maphash (lambda (atom i) (setf (aref v i) atom)) a2i)
                v))
         (atom-of (lambda (i) (aref i2a i)))
         (factor 0.0d0))
    (when (eq forced :conflict)
      (return-from wmc--write-mcc :unsat))
    (flet ((c (lit) (/ (gethash lit cost 0.0d0) scale))
           (forced-sign (v) (if forced (aref forced v) 0)))
      (ecase dialect
        (:mcc-2020 (format out-stream "p wcnf ~D ~D~%" nvars nclauses))
        ;; 'c t wmc' declares the track.  SharpSAT-TD asserts if this disagrees with
        ;; its -WE/-WD mode, so it must say wmc and not mc.
        (:mcc-2024 (format out-stream "c t wmc~%p cnf ~D ~D~%" nvars nclauses)))
      (dolist (ints int-clauses)
        (loop for i across ints do (format out-stream "~D " i))
        (format out-stream "0~%"))
      (dolist (u extra-units)
        (format out-stream "~D 0~%" u))
      ;; '~,16,,,,,'eE forces a C-parseable 'e' exponent (not Lisp's 'd').  Both
      ;; readers accept it: ADDMC uses std::stod, and SharpSAT-TD's ParseWeight is
      ;; stod plus an 'a/b' fraction form.
      (ecase dialect
        (:mcc-2020
         ;; Only the charged literals; each opposite side defaults to 1.0.  A
         ;; forced literal is folded out (its opposite never occurs in a model, so
         ;; omitting both lines is exact once the factor is applied).
         (maphash (lambda (lit cst)
                    (declare (ignore cst))
                    (let ((s (forced-sign (abs lit))))
                      (if (/= s 0)
                          (when (= s (signum lit)) (decf factor (c lit)))
                          (format out-stream "w ~D ~,16,,,,,'eE~%"
                                  lit (wmc--checked-weight lit (c lit) atom-of)))))
                  cost))
        (:mcc-2024
         ;; Both polarities of every variable, so nothing is left to infer.
         (loop for v from 1 to nvars
               do (let* ((s (forced-sign v))
                         (cp (c v)) (cn (c (- v)))
                         ;; the shift moved into the factor: the forced side's
                         ;; whole cost, or (FOLD only) the cheaper side's
                         (shift (cond ((= s 1) cp)
                                      ((= s -1) cn)
                                      (fold (min cp cn))
                                      (t 0.0d0))))
                    (decf factor shift)
                    (dolist (lit (list v (- v)))
                      (format out-stream "c p weight ~D ~,16,,,,,'eE 0~%" lit
                              (if (/= s 0)
                                  1.0d0
                                  (wmc--checked-weight lit (- (c lit) shift) atom-of)))))))))
    factor))

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

(defun wmc--read-file-string (path)
  "The contents of PATH as a string, or \"\" if it does not exist."
  (or (ignore-errors (uiop:read-file-string path)) ""))

(defun wmc--run-counter (name program args install)
  "Run a counter PROGRAM with ARGS through RUN-PROGRAM-TO-FILE, so it is bounded by
*SOLVER-TIMEOUT* like every other solver run, and return (values stdout stderr).
NAME is for messages and INSTALL the install-solvers.sh name.  An exact counter
has no partial answer, so a timeout or a non-zero exit is an error."
  (let* ((root (wmc--scratch-root))
         (out-file (format nil "~A.counter-out" root))
         (err-file (format nil "~A.counter-err" root)))
    (unwind-protect
         (multiple-value-bind (code timed-out)
             (handler-case
                 (run-program-to-file program args out-file
                                      :timeout *solver-timeout* :error-file err-file)
               (error (c)
                 (error "could not run ~A (~A): ~A~%Put it on PATH (bin/install-solvers.sh --only ~A)."
                        name program c install)))
           (let ((out (wmc--read-file-string out-file))
                 (err (wmc--read-file-string err-file)))
             (when timed-out
               (error "~A timed out after ~A s (*solver-timeout*); an exact count has no partial answer"
                      name *solver-timeout*))
             (when (and code (not (zerop code)))
               (error "~A (~A) exited with code ~A.~%--- stdout ---~%~A~%--- stderr ---~%~A"
                      name program code out err))
             (values out err)))
      (ignore-errors (delete-file out-file))
      (ignore-errors (delete-file err-file)))))

(defun wmc--run-addmc (wcnf-file &key (addmc *addmc*) epsilon)
  "Run ADDMC on WCNF-FILE (MCC weight format, --wf 4) and return the weighted
model count as a double-float.  EPSILON, when non-NIL, is passed as ADDMC's --ep
(CUDD terminal-merging tolerance); NIL uses ADDMC's default of 0 (exact, full
double precision).  Bounded by *SOLVER-TIMEOUT*."
  (multiple-value-bind (out err)
      (wmc--run-counter "ADDMC" addmc
                        (append (list "--cf" wcnf-file "--wf" "4")
                                (when epsilon
                                  (list "--ep" (format nil "~,16,,,,,'eE"
                                                       (float epsilon 1.0d0)))))
                        "addmc")
    (wmc--parse-count out err)))

;;; ----------------------------------------------------------------------------
;;; Running SharpSAT-TD and parsing its count
;;; ----------------------------------------------------------------------------

(defun wmc--decimal-to-rational (string)
  "The exact rational value of a decimal STRING such as \"-1.25e-300\", or NIL if
it is not one (e.g. \"inf\" or \"nan\").  Reading it with the Lisp reader would
round it to a double, and underflow to 0 below about 1e-308 -- the very range
SharpSAT-TD's unbounded exponent exists to reach."
  (multiple-value-bind (match groups)
      (cl-ppcre:scan-to-strings "^([-+]?)([0-9]*)(?:\\.([0-9]*))?(?:[eE]([-+]?[0-9]+))?$"
                                (string-trim '(#\Space #\Tab #\Return) string))
    (when match
      (let* ((sign (if (string= (aref groups 0) "-") -1 1))
             (int (or (aref groups 1) ""))
             (frac (or (aref groups 2) ""))
             (exp (if (aref groups 3) (parse-integer (aref groups 3)) 0))
             (digits (concatenate 'string int frac)))
        (when (plusp (length digits))
          (* sign (parse-integer digits) (expt 10 (- exp (length frac)))))))))

(defun wmc--parse-sharpsat (out err)
  "The count in SharpSAT-TD's output OUT, as an exact rational.  It reports a
result as one of 'c s exact arb int N', 'c s exact arb float X' or 'c s exact
double float X' -- comment lines, by the 2024 competition format -- and NOT as an
's wmc' line; its 's' line only says SATISFIABLE/UNSATISFIABLE, and an instance
found contradictory during search is still 's SATISFIABLE' with a count of 0, so
the 's' line is no verdict.  ERR is included in error messages."
  (let ((line (with-input-from-string (s out)
                (loop with found = nil
                      for l = (read-line s nil nil)
                      while l
                      when (cl-ppcre:scan "^c s exact " l) do (setq found l)
                      finally (return found)))))
    (unless line
      (error "SharpSAT-TD produced no 'c s exact' result line.~%--- stdout ---~%~A~%--- stderr ---~%~A"
             out err))
    (let* ((toks (cl-ppcre:split "\\s+" (string-trim '(#\Space #\Tab #\Return) line)))
           (val (wmc--decimal-to-rational (car (last toks)))))
      (unless val
        (error "SharpSAT-TD result is not a number: ~S" line))
      val)))

(defun wmc--run-sharpsat (wcnf-file &key (sharpsat *sharpsat*) (decot *sharpsat-decot*)
                                         (cache-mb *sharpsat-cache-mb*))
  "Run SharpSAT-TD on WCNF-FILE (:mcc-2024 dialect) in arbitrary-precision weighted
mode and return the count as an exact rational.  DECOT is flowcutter's budget in
seconds, CACHE-MB the component-cache limit.  The run is bounded by
*SOLVER-TIMEOUT* like every other solver run; an exact counter has no partial
answer to give, so a timeout is an error."
  (unless (and (realp decot) (> decot 0.0001) (< decot 10000))
    (error "SharpSAT-TD's decomposition time must be in (0.0001, 10000) seconds, got ~S" decot))
  (unless (and (integerp cache-mb) (plusp cache-mb))
    (error "SharpSAT-TD's cache limit must be a positive integer number of MB, got ~S" cache-mb))
  (let ((tmpdir (string-right-trim "/" (namestring (uiop:temporary-directory)))))
    (multiple-value-bind (out err)
        (wmc--run-counter "SharpSAT-TD" sharpsat
                          (list "-WE"
                                "-decot" (format nil "~F" decot)
                                "-decow" "100"
                                "-tmpdir" tmpdir
                                "-cs" (format nil "~D" cache-mb)
                                "-prec" "20"
                                wcnf-file)
                          "sharpsat-td")
      (wmc--parse-sharpsat out err))))

;;; ----------------------------------------------------------------------------
;;; Choosing a counter
;;; ----------------------------------------------------------------------------

(defun wmc--counter (counter &key (addmc *addmc*) epsilon (sharpsat *sharpsat*)
                                  (decot *sharpsat-decot*) (cache-mb *sharpsat-cache-mb*))
  "For COUNTER (:addmc or :sharpsat-td), return (values RUN DIALECT NAME): RUN maps a
weighted-CNF path to its count, DIALECT is the file format that counter reads,
and NAME is for messages.  ADDMC counts in doubles and SharpSAT-TD in exact
rationals; callers only add, divide and compare, which works for both."
  (ecase counter
    (:addmc
     (values (lambda (wcnf) (wmc--run-addmc wcnf :addmc addmc :epsilon epsilon))
             :mcc-2020 "ADDMC"))
    (:sharpsat-td
     (when epsilon (error ":epsilon is ADDMC's tolerance; SharpSAT-TD has none"))
     (values (lambda (wcnf) (wmc--run-sharpsat wcnf :sharpsat sharpsat :decot decot
                                                     :cache-mb cache-mb))
             :mcc-2024 "SharpSAT-TD"))))

(defun wmc--log (x)
  "Natural log of a positive rational or float X, computed without converting X to
a double first -- so it works far outside double range."
  (flet ((log-int (n)    ; n = m * 2^k with m held to 53 bits
           (let ((k (max 0 (- (integer-length n) 53))))
             (+ (log (float (ash n (- k)) 1.0d0)) (* k (log 2.0d0))))))
    (let ((r (rational x)))
      (- (log-int (numerator r)) (log-int (denominator r))))))

(defun wmc--count-value (raw factor)
  "The true count RAW * exp(FACTOR) as a NORMAL double-float, where RAW is the
counter's result (a double from ADDMC, an exact rational from SharpSAT-TD) and
FACTOR the log factor the writer folded out.  0 stays 0 (unsatisfiable).
Anything outside the normal range is an error -- not a 0, which would read as
unsatisfiable, and not a subnormal, which would print 17 digits of which only a
few mean anything."
  (when (zerop raw) (return-from wmc--count-value 0.0d0))
  (let ((lz (+ (wmc--log raw) factor)))
    (unless (< (log least-positive-normalized-double-float) lz
               (log most-positive-double-float))
      (error "the count is outside the normal double-float range (about 2.2e-308 to 1.8e308); marginals, being ratios of counts, are unaffected"))
    (flet ((normal (x) (and x (not (sb-ext:float-infinity-p x))
                            (>= (abs x) least-positive-normalized-double-float)
                            x)))
      ;; Most precise first: the raw count as a double times exp(factor), when
      ;; both are normal; else exp of the log, which loses about |log Z| ulps.
      (let* ((r (normal (ignore-errors (float raw 1.0d0))))
             (e (normal (ignore-errors (exp factor))))
             (p (and r e (normal (ignore-errors (* r e))))))
        (or p (exp lz))))))

(defun wmc--ratio (raw-a factor-a raw factor)
  "Z_a / Z for two counts in (raw, log-factor) form, as a double in [0,1].  The
raw ratio is taken exactly first (both rationals under SharpSAT-TD), and the
factors enter only as their DIFFERENCE, so neither Z need be representable."
  (if (zerop raw-a)
      0.0d0
      (let ((q (/ (rational raw-a) (rational raw)))
            (d (- factor-a factor)))
        (if (zerop d)
            (float q 1.0d0)
            (exp (+ (wmc--log q) d))))))

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
                           (counter :addmc) (addmc *addmc*) (sharpsat *sharpsat*)
                           (decot *sharpsat-decot*) (cache-mb *sharpsat-cache-mb*)
                           (verbose t))
  "Exact weighted model count (partition function Z) of a weighted .scnf, via ADDMC
or, with :COUNTER :SHARPSAT-TD, via SharpSAT-TD (DECOT and CACHE-MB are its
decomposition budget and cache limit; see *SHARPSAT-DECOT*).
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
the formulas must be ground (see WMC--EVIDENCE-CLAUSES).  Writes a scratch
weighted CNF in the counter's dialect (WCNF-FILE, default a unique scratch name),
runs the counter, and returns Z as a double-float (an error if SharpSAT-TD's count
is outside double range).  The scratch file is deleted unless KEEP-WCNF is set or
WCNF-FILE was given explicitly."
  ;; NB: bind the weight forms to a NON-special name -- the obvious WEIGHTS is
  ;; FiFO's global special, which (parse ...) inside wmc--evidence-clauses resets.
  (multiple-value-bind (run dialect)
      (wmc--counter counter :addmc addmc :epsilon epsilon :sharpsat sharpsat
                            :decot decot :cache-mb cache-mb)
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
          (let ((wcnf (or wcnf-file (wmc--scratch-wcnf)))
                (keep (or keep-wcnf wcnf-file)))
            (unwind-protect
                 ;; Fold forced literals out only into a PRIVATE scratch file: a
                 ;; file the user keeps must denote the theory's own Z.
                 (let* ((factor (with-open-file (s wcnf :direction :output
                                                        :if-exists :supersede
                                                        :if-does-not-exist :create)
                                  (wmc--write-mcc clauses weight-forms a2i nvars s
                                                  :scale scale :dialect dialect
                                                  :fold (not keep))))
                        (z (if (eq factor :unsat)
                               0.0d0
                               (wmc--count-value (funcall run wcnf) factor))))
                   (when (and verbose keep-wcnf) (format t "; wcnf kept: ~A~%" wcnf))
                   (when verbose (format t "(WMC ~,16,,,,,'eE)~%" z))
                   z)
              (unless keep (ignore-errors (delete-file wcnf))))))))))

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

(defun wmc--marginals (scnf-file counter &key out-file weighted-only keep-wcnf scale
                                              evidence evidence-file counter-args atoms
                                              (jobs *wmc-jobs*) (verbose t))
  "The body of MARGINALS-ADDMC and MARGINALS-SHARPSAT: P(a) = Z_a / Z by clamping,
counted by COUNTER (:addmc or :sharpsat-td, with COUNTER-ARGS passed to
WMC--COUNTER).  Each count is written with forced literals folded out (see
WMC--WRITE-MCC) and comes back as (raw, log-factor); the ratio is taken exactly
on the raws and the factors enter only as a difference (WMC--RATIO), so neither
Z need fit in a double.  A clamp that unit propagation refutes is a count of 0
without running the counter.  ATOMS, when given, restricts the clamped counts to
those atoms -- 1 + k runs instead of 1 + n -- for a caller that needs only a few,
as --hypotheses does; an atom the theory lacks is an error.  The clamped counts
are independent and run JOBS at a time (default *WMC-JOBS*) after Z, which runs
first and alone; KEEP-WCNF keeps Z's file."
  (multiple-value-bind (run dialect name) (apply #'wmc--counter counter counter-args)
    ;; NB: WEIGHT-FORMS, not the special WEIGHTS (which parse resets) -- see wmc.
    (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
      (declare (ignore probs opts))
      (let ((weight-atoms (remove-duplicates
                           (mapcar (lambda (wf) (rw--literal-atom-and-sign (second wf)))
                                   weight-forms)
                           :test #'equal)))
        (when (and weighted-only (null weight-atoms))
          (when verbose (format t "; no weighted atoms in ~A~%" scnf-file))
          (return-from wmc--marginals nil))
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
              ;; COUNT-WITH writes FILE and counts it; with no FILE it uses its own
              ;; scratch file and deletes it, which is what lets the clamped
              ;; counts run concurrently (WMC--PARALLEL-MAP).  Everything it reads
              ;; besides its argument is read-only here.
              (labels ((count-in (file extra-units)   ; -> (values raw log-factor)
                         (let ((factor (with-open-file (s file :direction :output
                                                               :if-exists :supersede
                                                               :if-does-not-exist :create)
                                         (wmc--write-mcc clauses weight-forms a2i nvars s
                                                         :extra-units extra-units :scale scale
                                                         :dialect dialect :fold t))))
                           (if (eq factor :unsat)
                               (values 0 0.0d0)
                               (values (funcall run file) factor))))
                       (count-with (extra-units &optional file)
                         (if file
                             (count-in file extra-units)
                             (let ((own (wmc--scratch-wcnf)))
                               (unwind-protect (count-in own extra-units)
                                 (ignore-errors (delete-file own)))))))
                (unwind-protect
                     (let ((target-vars
                             (cond (atoms
                                    (mapcar (lambda (a)
                                              (or (gethash a a2i)
                                                  (error "~S is not an atom of ~A" a scnf-file)))
                                            atoms))
                                   (weighted-only
                                    (mapcar (lambda (a) (gethash a a2i)) weight-atoms))
                                   ;; hide internal reification atoms from the default
                                   ;; listing (also skips a counter run each); they show
                                   ;; under --weighted-only, where P(atom)=P(formula)
                                   (t (mapcar (lambda (a) (gethash a a2i))
                                              (remove-if #'reified-formula-atom-p theory-atoms))))))
                       ;; Z first, alone and in WCNF (the file KEEP-WCNF keeps), so an
                       ;; unsatisfiable theory fails before any clamp is started.
                       (multiple-value-bind (z zf) (count-with nil wcnf)
                         (when (<= z 0)
                           (error "partition function is 0 (~A) -- ~:[the hard clauses are unsatisfiable~;the hard clauses are unsatisfiable, or a too-large :epsilon floored the count to 0; either way~], so no marginals exist"
                                  name (eq counter :addmc)))
                       (let ((results
                               (sort (mapcar (lambda (v zr)
                                               (cons (aref i2a v)
                                                     (wmc--ratio (first zr) (second zr) z zf)))
                                             target-vars
                                             (wmc--parallel-map
                                              (lambda (v) (count-with (list v)))
                                              target-vars jobs))
                                     #'string< :key (lambda (c) (format nil "~S" (car c))))))
                         (when verbose
                           (dolist (r results)
                             (format t "(MARGINAL ~S ~,16,,,,,'eE)~%" (car r) (cdr r))))
                         (when out-file
                           (with-open-file (o out-file :direction :output
                                                       :if-exists :supersede :if-does-not-exist :create)
                             (dolist (r results)
                               (format o "(MARGINAL ~S ~,16,,,,,'eE)~%" (car r) (cdr r)))))
                         results)))
                  (unless keep-wcnf (ignore-errors (delete-file wcnf))))))))))))

(defun marginals-addmc (scnf-file &key out-file weighted-only keep-wcnf scale epsilon
                                       evidence evidence-file atoms (addmc *addmc*)
                                       (jobs *wmc-jobs*) (verbose t))
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
per atom (sorted) and, with OUT-FILE, also writes them there.  ATOMS restricts the
report (and the clamped runs) to just those atoms.  The clamped runs go JOBS at a
time (*WMC-JOBS*).  Returns an alist of (atom . probability)."
  (wmc--marginals scnf-file :addmc
                  :out-file out-file :weighted-only weighted-only :keep-wcnf keep-wcnf
                  :scale scale :evidence evidence :evidence-file evidence-file
                  :atoms atoms :jobs jobs :verbose verbose
                  :counter-args (list :addmc addmc :epsilon epsilon)))

(defun marginals-sharpsat (scnf-file &key out-file weighted-only keep-wcnf scale
                                          evidence evidence-file atoms (sharpsat *sharpsat*)
                                          (decot *sharpsat-decot*)
                                          (cache-mb *sharpsat-cache-mb*)
                                          (jobs *wmc-jobs*) (verbose t))
  "MARGINALS-ADDMC with SharpSAT-TD as the counter: the same clamping, the same
arguments and output, but each count is SharpSAT-TD's (in the :mcc-2024 dialect)
and comes back as an exact rational, so Z_a/Z does not underflow even where a
double Z would.  DECOT is flowcutter's per-call budget in seconds (see
*SHARPSAT-DECOT*).  The run makes 1 + n calls, each paying DECOT, which is why
they run JOBS at a time.  CACHE-MB is a TOTAL budget: each run gets CACHE-MB /
JOBS (at least 100), so adding jobs never adds memory."
  (let* ((jobs (max 1 jobs))
         (per-job (if (> jobs 1) (max 100 (floor cache-mb jobs)) cache-mb)))
    (wmc--marginals scnf-file :sharpsat-td
                    :out-file out-file :weighted-only weighted-only :keep-wcnf keep-wcnf
                    :scale scale :evidence evidence :evidence-file evidence-file
                    :atoms atoms :jobs jobs :verbose verbose
                    :counter-args (list :sharpsat sharpsat :decot decot :cache-mb per-job))))
