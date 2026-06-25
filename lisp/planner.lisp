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

(defun plan (problem-file
             &key minslices maxslices
                  (sat-solver "kissat")
                  (weighted-solver "tt-open-wbo-inc-Glucose4_1")
                  domain-file (satplan-path "satplan.wff")
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

Returns (values STATUS SLICES ANSWER-FILE): STATUS is :SAT, :UNSAT (no plan in
range), or :ERROR.  On :SAT the answer is written to <problem-root>.answer.
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
                 (has-costs
                  (format stream "Domain has action costs; minimizing cost with ~A (wcnf)...~%"
                          weighted-solver)
                  (setq *satplan-numslices* found *cnf-format* 'wcnf *solver* weighted-solver)
                  (unless (instantiate wff :scnfile scnf)
                    (error "instantiation failed at ~A slices" found))
                  (unless (propositionalize scnf :cnffile wcnf :mapfile map)
                    (error "propositionalization failed at ~A slices" found))
                  (unless (eql (satisfy wcnf :satoutfile satout) 'sat)
                    (error "weighted solver ~A did not return SAT on the wcnf" weighted-solver))
                  (interpret satout :mapfile map :solnfile answer)
                  (values :sat found answer))
                 (t
                  (interpret satout :mapfile map :solnfile answer)
                  (values :sat found answer))))))))
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
      (:unsat
       (format t "UNSATISFIABLE: no plan exists within the given horizon.~%")
       0)
      (t
       (format *error-output* "FAILED: the problem could not be solved.~%")
       1))))
