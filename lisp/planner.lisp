;;;; planner.lisp -- search for the smallest-horizon plan for a FiFO SatPlan
;;;; problem, minimizing cost when the domain has action costs.
;;;;
;;;; Load after FiFO.lisp (and, for PDDL input, pddl2fifo.lisp):
;;;;   (load "FiFO.lisp") (load "SatPlan/pddl2fifo.lisp") (load "SatPlan/planner.lisp")
;;;;   (plan-and-report "problem.pddl" :minslices 2 :maxslices 6)
;;;;
;;;; The driver calls FiFO's file-based API (instantiate / propositionalize /
;;;; satisfy / interpret) repeatedly in one Lisp image.  The parse-level globals
;;;; (Bind, ObservedPredicates, ObservedLiterals, Weights) are reset by
;;;; setup-global-env, which parse -- and therefore instantiate -- calls on every
;;;; iteration, so no parse state leaks between horizons.  The only globals that
;;;; persist are the option variables, and the loop sets the three it depends on
;;;; (*satplan-numslices*, *cnf-format*, *solver*) explicitly at the start of
;;;; each iteration.

(defun planner-file (problem-path type)
  "The companion file of PROBLEM-PATH with the given TYPE, e.g. \"scnf\"."
  (namestring (merge-pathnames (make-pathname :type type) problem-path)))

(defun answer-objective (answer-file)
  "The (*objective* N) value interpret wrote into ANSWER-FILE -- the MaxSAT
solver's reported cost -- or NIL if the file has none."
  (with-open-file (s answer-file :direction :input :if-does-not-exist nil)
    (when s
      (let ((*read-eval* nil))
        (loop for form = (read s nil :eof) until (eq form :eof)
              when (and (consp form) (symbolp (car form))
                        (string= (symbol-name (car form)) "*OBJECTIVE*"))
                return (second form))))))

(defun wcnf-scale-offset (wcnf-file)
  "Read the 'c weights scaled by S' / 'c weight shift offset M' comment lines a
weighted .cnf/.wcnf carries (written only when non-trivial) and return (values S
M), defaulting to 1 and 0.  The true plan cost of a solution is its raw objective
/ S + M -- so for the usual non-negative integer action costs (S=1, M=0) the raw
objective already is the true cost; this corrects it when weights were shifted
(e.g. negative costs from learned weights)."
  (let ((scale 1) (offset 0))
    (with-open-file (s wcnf-file :direction :input :if-does-not-exist nil)
      (when s
        (let ((*read-eval* nil))
          (loop for line = (read-line s nil) while line do
            (let (m)
              (cond ((setq m (nth-value 1 (cl-ppcre:scan-to-strings "scaled by\\s+(\\S+):" line)))
                     (setq scale (read-from-string (aref m 0))))
                    ((setq m (nth-value 1 (cl-ppcre:scan-to-strings "shift offset\\s+(\\S+):" line)))
                     (setq offset (read-from-string (aref m 0))))))))))
    (values scale offset)))

(defun plan-true-cost (answer-file wcnf-file)
  "True plan cost = raw objective / scale + offset, or NIL when there is no
objective."
  (let ((raw (answer-objective answer-file)))
    (when raw
      (multiple-value-bind (scale offset) (wcnf-scale-offset wcnf-file)
        (+ (/ raw scale) offset)))))

(defun plan (problem-file
             &key minslices maxslices
                  (sat-solver "kissat")
                  (weighted-solver "tt-open-wbo-inc-Glucose4_1")
                  domain-file (satplan-path "satplan.wff")
                  stop-after (longer 0)
                  (stream *standard-output*))
  "Search horizons MINSLICES..MAXSLICES for the smallest plan for PROBLEM-FILE.
A .pddl problem is translated with pddl2fifo; a .wff is used directly (its
numslices must read *satplan-numslices*, as pddl2fifo-generated wffs do).

If MINSLICES is unspecified it defaults to the lower bound from pddl2fifo's
relaxed reachability analysis (2 for a .wff problem, which has no PDDL to
analyze).  If MAXSLICES is unspecified it defaults to twice MINSLICES.  For a
PDDL problem whose goals are unreachable even in the relaxation, no search is
done and :UNSAT is returned.

Phase 1 finds the smallest horizon with a satisfying model, instantiating in
plain CNF and testing with the pure SAT solver SAT-SOLVER.  If the domain has no
action costs that model is the answer.  If it does, phase 2 re-solves at that
horizon in WCNF with the weighted solver WEIGHTED-SOLVER to minimize total cost.

LONGER (default 0) extends phase 2: instead of minimizing cost only at the
smallest feasible horizon s, it solves each horizon s..s+LONGER and returns the
cheapest plan found (a longer horizon can admit a lower-cost plan).  Costs at
different horizons are compared as true plan costs (raw objective / scale +
offset).  LONGER has no effect when the domain has no action costs.

STOP-AFTER halts the pipeline early: :WFF returns once the wff exists (just the
PDDL translation, or the input itself for a .wff), and :SCNF returns after
instantiating it once at the smallest horizon (MINSLICES / the reachability
bound, or a fixed --numslices), leaving the .scnf without solving.

Returns (values STATUS SLICES FILE): STATUS is :SAT, :UNSAT (no plan in range),
:STOPPED-WFF, :STOPPED-SCNF, or :ERROR.  On :SAT the answer is written to
<problem-root>.answer; on the :STOPPED-* statuses FILE is the generated wff/scnf.
Progress is printed to STREAM."
  (let* ((problem-path (pathname problem-file))
         (wff (if (string-equal (or (pathname-type problem-path) "") "wff")
                  (namestring problem-path)
                  (planner-file problem-path "wff")))
         (scnf   (planner-file problem-path "scnf"))
         (cnf    (planner-file problem-path "cnf"))
         (wcnf   (planner-file problem-path "wcnf"))
         (map    (planner-file problem-path "map"))
         (satout (planner-file problem-path "satout"))
         (answer (planner-file problem-path "answer")))
    (handler-case
        (let ((reach-min nil))
          ;; Build the wff from PDDL when needed, capturing the reachability bound.
          (unless (string-equal (or (pathname-type problem-path) "") "wff")
            (multiple-value-bind (out rmin)
                (apply #'pddl2fifo (namestring problem-path)
                       :satplan-path satplan-path
                       (when domain-file (list :domain-file domain-file)))
              (unless out (error "wff generation failed"))
              (setq reach-min rmin)))
          (when (eq stop-after :wff)
            (format stream "Stopped after generating the wff: ~A~%" wff)
            (return-from plan (values :stopped-wff nil wff)))
          (when (and (not minslices) (integerp reach-min))
            (format stream "Reachability analysis: a plan needs at least ~A time slices.~%"
                    reach-min))
          (if (eq reach-min :unreachable)
              ;; Relaxed reachability proves the (real) problem unsolvable.
              (progn
                (format stream "Reachability analysis: the goals are unreachable; no plan exists.~%")
                (values :unsat nil nil))
          (let* ((lo (or minslices (and (integerp reach-min) reach-min) 2))
                 (hi (or maxslices (* 2 lo)))
                 (found nil) (has-costs nil))
            (when (eq stop-after :scnf)
              (setq *satplan-numslices* lo *cnf-format* 'cnf)
              (unless (instantiate wff :scnfile scnf)
                (error "instantiation failed at ~A slices" lo))
              (format stream "Stopped after generating the scnf at ~A time slices: ~A~%" lo scnf)
              (return-from plan (values :stopped-scnf lo scnf)))
            ;; Phase 1: smallest horizon with a satisfying model (pure SAT).
            (loop for n from lo to hi until found do
              (format stream "Trying ~A time slices with ~A (cnf)...~%" n sat-solver)
              (setq *satplan-numslices* n *cnf-format* 'cnf *solver* sat-solver)
              (unless (instantiate wff :scnfile scnf)
                (error "instantiation failed at ~A slices" n))
              (unless (propositionalize scnf :cnffile cnf :mapfile map)
                (error "propositionalization failed at ~A slices" n))
              (case (satisfy cnf :satoutfile satout)
                (sat (setq found n))
                (unsat (format stream "  unsatisfiable with ~A time slices~%" n))
                (t (error "SAT solver ~A failed at ~A slices" sat-solver n))))
            (cond
              ((not found) (values :unsat nil nil))
              (t
               (format stream "Found a plan with ~A time slices.~%" found)
               ;; The domain has costs iff the instantiated scnf carries weights.
               (setq has-costs (file-contains-string-p "(WEIGHT" scnf))
               (cond
                 ((not has-costs)
                  ;; No costs: the shortest feasible model is the answer; a longer
                  ;; search could only find equally costless (cost-0) plans.
                  (when (plusp longer)
                    (format stream "(no action costs; --longer has no effect)~%"))
                  (interpret satout :mapfile map :solnfile answer)
                  (values :sat found answer))
                 (t
                  ;; Costs: minimize at each horizon found..found+LONGER and keep
                  ;; the cheapest plan (comparing true costs across horizons).
                  (let ((best-cost nil) (best-n nil)
                        (best-answer (planner-file problem-path "best.answer")))
                    (loop for n from found to (+ found longer) do
                      (format stream "Minimizing cost at ~A time slices with ~A (wcnf)...~%"
                              n weighted-solver)
                      (setq *satplan-numslices* n *cnf-format* 'wcnf *solver* weighted-solver)
                      (unless (instantiate wff :scnfile scnf)
                        (error "instantiation failed at ~A slices" n))
                      (unless (propositionalize scnf :cnffile wcnf :mapfile map)
                        (error "propositionalization failed at ~A slices" n))
                      (case (satisfy wcnf :satoutfile satout)
                        (sat
                         (interpret satout :mapfile map :solnfile answer)
                         (let ((cost (plan-true-cost answer wcnf)))
                           (format stream "  ~A time slices: cost ~A~%" n (or cost "(none)"))
                           (when (and cost (or (null best-cost) (< cost best-cost)))
                             (setq best-cost cost best-n n)
                             (uiop:copy-file answer best-answer))))
                        (unsat (format stream "  unsatisfiable with ~A time slices~%" n))
                        (t (error "weighted solver ~A failed at ~A slices" weighted-solver n))))
                    (cond
                      (best-n
                       (uiop:copy-file best-answer answer)   ; restore the cheapest
                       (when (probe-file best-answer) (delete-file best-answer))
                       (when (plusp longer)
                         (format stream "Cheapest plan over ~A..~A slices: cost ~A at ~A slices.~%"
                                 found (+ found longer) best-cost best-n))
                       (values :sat best-n answer))
                      (t (values :unsat nil nil)))))))))))
      (error (e)
        (format *error-output* "planner: ~A~%" e)
        (values :error nil nil)))))

(defun plan-and-report (problem-file &rest args)
  "Run PLAN, print the answer file on success, and return a Unix exit code
(0 solved, 0 no-plan-in-range, 1 error)."
  (multiple-value-bind (status slices answer) (apply #'plan problem-file args)
    (case status
      (:sat
       (format t "SOLVED with ~A time slices.~%" slices)
       (format t "Answer file: ~A~%" answer)
       (format t "----------------------------------------~%")
       (with-open-file (s answer :direction :input)
         (loop for line = (read-line s nil) while line do (format t "~A~%" line)))
       0)
      ((:stopped-wff :stopped-scnf)
       (format t "Wrote ~A~%" answer)   ; ANSWER holds the generated wff/scnf path
       0)
      (:unsat
       (format t "UNSATISFIABLE: no plan exists within the given horizon.~%")
       0)
      (t
       (format *error-output* "FAILED: the problem could not be solved.~%")
       1))))
