;;;; make-recognition-instance.lisp -- build a runnable plan-recognition
;;;; instance from a goal-plan-recognition dataset problem.
;;;;
;;;; From a dataset domain, a template.pddl (initial state with a
;;;; <HYPOTHESIS> goal placeholder), the hyps.dat candidate-goal list, and an
;;;; evidence file holding one (occur-in-order <action>+) observation
;;;; sequence, this writes into the output directory:
;;;;
;;;;   <domain-root>-costs.pddl  the domain with uniform action costs -- every
;;;;                             action gets (increase (total-cost) <cost>),
;;;;                             so plan cost = <cost> * plan length and the
;;;;                             Gibbs distribution over trajectories is the
;;;;                             Boltzmann model exp(-cost/scale * length)
;;;;   problem.pddl              the template with the goal replaced by the
;;;;                             DISJUNCTION of all candidate goals in
;;;;                             hyps.dat (each line an (and ...) disjunct)
;;;;   evidence-<i>.txt          for i = 1..k: the first i observations of the
;;;;                             input sequence as (occur-in-order a1 ... ai),
;;;;                             for --pddl-evidence-file -- incremental
;;;;                             evidence for watching the explanation shift
;;;;                             as observations accrue
;;;;
;;;; Usage:
;;;;   sbcl --script make-recognition-instance.lisp \
;;;;        <domain.pddl> <template.pddl> <hyps.dat> <evidence-file> \
;;;;        <out-dir> [<uniform-cost>]
;;;;
;;;; <uniform-cost> defaults to 1.  With scnf weight scale s (default 1), each
;;;; action multiplies a trajectory's probability by exp(-cost/s), so the
;;;; Boltzmann temperature is beta = cost/s.

(defun sym= (a b)
  (and (symbolp a) (string-equal (symbol-name a) (string b))))

(defun read-forms (path)
  "All Lisp forms in PATH (';' comments are skipped by READ)."
  (with-open-file (in path :direction :input)
    (let ((*read-eval* nil))
      (loop for f = (read in nil :eof) until (eq f :eof) collect f))))

(defun write-forms (path header forms)
  "Write HEADER (a list of comment strings) and FORMS to PATH, downcased."
  (with-open-file (out path :direction :output
                            :if-exists :supersede :if-does-not-exist :create)
    (dolist (line header) (format out ";; ~a~%" line))
    (let ((*print-case* :downcase)
          (*print-pretty* t)
          (*print-right-margin* 78))
      (dolist (f forms) (format out "~s~%" f)))))

;;; Domain transformation: uniform action costs.

(defun add-requirements (reqs)
  "Extend a (:requirements ...) body with :action-costs,
:disjunctive-preconditions, and :derived-predicates (the generated goal is a
disjunction of derived-predicate atoms, one per hypothesis)."
  (let ((body (copy-list reqs)))
    (dolist (r '(:action-costs :disjunctive-preconditions :derived-predicates) body)
      (unless (member r body :test #'sym=) (setq body (append body (list r)))))))

(defun hyp-name (i)
  "The derived-predicate name for hypothesis I: HYP0, HYP1, ..."
  (intern (string-upcase (format nil "hyp~d" i))))

(defun add-cost-to-action (action cost)
  "Append (increase (total-cost) COST) to ACTION's :effect.  An action that
already has an increase effect is left unchanged."
  (let* ((body (copy-list (cddr action)))
         (effect (getf body :effect))
         (conjuncts (if (and (consp effect) (sym= (first effect) "AND"))
                        (rest effect)
                        (list effect))))
    (if (find-if (lambda (e) (and (consp e) (sym= (first e) "INCREASE"))) conjuncts)
        action
        (progn
          (setf (getf body :effect)
                `(and ,@conjuncts (increase (total-cost) ,cost)))
          (list* (first action) (second action) body)))))

(defun derived-hypotheses (hyps)
  "One (:derived (hypI) (and <literals>)) rule per hypothesis, so the disjunctive
goal is (or (hyp0) ... (hypN)) and each disjunct's probability is the marginal
of a single reified atom (HOLDS (hypI) numslices)."
  (loop for h in hyps for i from 0
        collect `(:derived (,(hyp-name i)) (and ,@h))))

(defun transform-domain (domain-def cost hyps)
  "DOMAIN-DEF with :action-costs machinery, uniform action costs, and one derived
predicate per hypothesis."
  (let ((has-functions nil) (sections '()))
    (dolist (s (cddr domain-def))
      (when (and (consp s) (sym= (first s) "FUNCTIONS")) (setq has-functions t)))
    (dolist (s (cddr domain-def))
      (cond ((and (consp s) (sym= (first s) "REQUIREMENTS"))
             (push (cons (first s) (add-requirements (rest s))) sections)
             (unless has-functions
               (push '(:functions (total-cost)) sections)
               (setq has-functions t)))
            ((and (consp s) (sym= (first s) "ACTION"))
             (push (add-cost-to-action s cost) sections))
            (t (push s sections))))
    (list* (first domain-def) (second domain-def)
           (append (nreverse sections) (derived-hypotheses hyps)))))

;;; Problem: template + disjunctive goal over all hypotheses.

(defun parse-hyps (path)
  "Each nonblank line of PATH -- atoms separated by commas -- as a list of atoms."
  (with-open-file (in path :direction :input)
    (loop for line = (read-line in nil nil) while line
          for cleaned = (substitute #\Space #\, line)
          for atoms = (let ((*read-eval* nil) (pos 0) (result '()))
                        (loop
                          (multiple-value-bind (form next)
                              (read-from-string cleaned nil :eof :start pos)
                            (when (eq form :eof) (return (nreverse result)))
                            (push form result)
                            (setq pos next))))
          when atoms collect atoms)))

(defun transform-problem (template-def hyps)
  "TEMPLATE-DEF with the <HYPOTHESIS> goal replaced by the disjunction of the
per-hypothesis derived predicates (or (hyp0) ... (hypN)) and (= (total-cost) 0)
added to :init."
  (let ((goal `(or ,@(loop for i from 0 below (length hyps)
                           collect (list (hyp-name i))))))
    (list* (first template-def) (second template-def)
           (mapcar (lambda (s)
                     (cond ((and (consp s) (sym= (first s) "GOAL"))
                            `(:goal ,goal))
                           ((and (consp s) (sym= (first s) "INIT"))
                            (append s '((= (total-cost) 0))))
                           (t s)))
                   (cddr template-def)))))

;;; Evidence: one file per observation prefix.

(defun read-observation-sequence (path)
  "The action list of the single (occur-in-order ...) form in PATH."
  (let ((forms (read-forms path)))
    (unless (and (= (length forms) 1)
                 (consp (first forms))
                 (sym= (first (first forms)) "OCCUR-IN-ORDER")
                 (rest (first forms)))
      (error "~a must contain exactly one non-empty (occur-in-order ...) form" path))
    (rest (first forms))))

;;; Main.

(let ((args (rest sb-ext:*posix-argv*)))
  (unless (<= 5 (length args) 6)
    (format *error-output*
            "usage: sbcl --script make-recognition-instance.lisp ~
             <domain.pddl> <template.pddl> <hyps.dat> <evidence-file> ~
             <out-dir> [<uniform-cost>]~%")
    (sb-ext:exit :code 2))
  (destructuring-bind (domain-file template-file hyps-file evidence-file out-dir
                       &optional (cost-string "1")) args
    (let* ((cost (let ((*read-eval* nil) (c (read-from-string cost-string)))
                   (unless (and (realp c) (plusp c))
                     (error "uniform-cost must be a positive number, got ~a" cost-string))
                   c))
           (domain-def (first (read-forms domain-file)))
           (template-def (first (read-forms template-file)))
           (hyps (parse-hyps hyps-file))
           (obs (read-observation-sequence evidence-file))
           (out (pathname (concatenate 'string out-dir "/")))
           (domain-out (merge-pathnames
                         (make-pathname
                           :name (concatenate 'string
                                              (pathname-name (pathname domain-file))
                                              "-costs")
                           :type "pddl")
                         out)))
      (unless (and (consp domain-def) (sym= (first domain-def) "DEFINE"))
        (error "~a does not start with a (define ...) form" domain-file))
      (unless (and (consp template-def) (sym= (first template-def) "DEFINE"))
        (error "~a does not start with a (define ...) form" template-file))
      (unless hyps (error "no candidate goals found in ~a" hyps-file))
      (ensure-directories-exist out)
      (write-forms domain-out
                   (list (format nil "Generated by make-recognition-instance.lisp from ~a:"
                                 domain-file)
                         (format nil "uniform action cost ~a (Boltzmann model: each action"
                                 cost)
                         (format nil "multiplies a trajectory's probability by exp(-~a/scale))."
                                 cost))
                   (list (transform-domain domain-def cost hyps)))
      (write-forms (merge-pathnames "problem.pddl" out)
                   (list (format nil "Generated by make-recognition-instance.lisp from ~a:"
                                 template-file)
                         (format nil "the goal is the disjunction of all ~d candidate goals in ~a."
                                 (length hyps) hyps-file))
                   (list (transform-problem template-def hyps)))
      (loop for i from 1 to (length obs) do
        (write-forms (merge-pathnames (format nil "evidence-~d.txt" i) out)
                     (list (format nil "First ~d of ~d observations from ~a."
                                   i (length obs) evidence-file))
                     (list `(occur-in-order ,@(subseq obs 0 i)))))
      (format t "Wrote ~a, problem.pddl, and evidence-1..~d.txt to ~a~%"
              (file-namestring domain-out) (length obs) out-dir))))
