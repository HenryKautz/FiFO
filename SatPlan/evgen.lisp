;;;; evgen.lisp -- build a plan-recognition evidence file from a solved problem.
;;;;
;;;; Given a PDDL problem and the .answer file planner.sh wrote for it, extract
;;;; the fluents and actions true at a chosen set of time slices and write them
;;;; out as FiFO evidence forms, ready for planner.sh --evidence-file:
;;;;
;;;;    (holds (at pkg1 c1-p2) 3)
;;;;    (occurs (fly plane1 c2-air c1-air) 4)
;;;;    (not (holds (in pkg1 truck2) 3))      ; only with :negative-evidence 1
;;;;
;;;; FiFO forms rather than the PDDL modal evidence language because only these
;;;; can pin a FLUENT to a slice: the modal (at <slice> <action>) takes an action,
;;;; and hold-during takes a range, not a point.  They are also exactly the syntax
;;;; the .answer file itself uses, so the positive half of the job is a filter.
;;;;
;;;; Everything emitted is checked against the problem's real ground universe,
;;;; because slice-pinned evidence fails SILENTLY downstream: an out-of-range
;;;; slice or a misspelled predicate becomes a fresh unconstrained atom, and the
;;;; planner then returns the UNCONDITIONED answer with no error at all.  A
;;;; generator that emitted such a literal would be worse than useless, so an
;;;; unknown --observe name, a slice past the solution's horizon, and an empty
;;;; result set are each an error here.
;;;;
;;;; The ground universe is re-derived rather than read from the .map file beside
;;;; the solution: that .map is a byproduct cleanupfifo.sh deletes.  FiFO's parse
;;;; leaves every domain in the global Bind table, so parsing the wff with
;;;; *satplan-numslices* bound to the solution's horizon gives (gethash 'FLUENTS
;;;; Bind) and (gethash 'ACTIONS Bind) exactly.
;;;;
;;;; Entry point: (evgen :problem ... :evidence ... :slices "1-3,5").
;;;; SatPlan/evgen.sh is the command line wrapper.
;;;;
;;;; Requires FiFO.lisp and pddl2fifo.lisp to be loaded first (both live in
;;;; CL-USER, and so does this).

;;; ------------------------------------------------------------- slice specs

(defun evgen--split (string char)
  (loop with start = 0
        for pos = (position char string :start start)
        collect (subseq string start pos)
        while pos do (setf start (1+ pos))))

(defun evgen--slice-number (text spec)
  (let ((s (string-trim " " text)))
    (when (or (string= s "") (notevery #'digit-char-p s))
      (error "--slices ~s contains ~s, which is not a slice number" spec s))
    (let ((n (parse-integer s)))
      ;; Slices are 1-based: (domain slices (range 1 numslices)) in satplan.wff.
      (when (< n 1)
        (error "--slices ~s names slice ~d, but slices are numbered from 1" spec n))
      n)))

(defun evgen--parse-slices (spec)
  "Parse a slice specification -- integers and A-B ranges separated by commas,
e.g. \"1-3,5\" -- into a sorted list of distinct positive integers."
  (let ((text (string-trim " " (or spec ""))))
    (when (string= text "")
      (error "--slices is required: a slice specification such as \"1-3,5\""))
    (let ((out '()))
      (dolist (piece (evgen--split text #\,))
        (let ((p (string-trim " " piece)))
          (when (string= p "")
            (error "empty entry in --slices ~s (a stray comma?)" spec))
          (let ((dash (position #\- p)))
            (cond
              ((null dash)
               (push (evgen--slice-number p spec) out))
              (t
               (let ((lo (evgen--slice-number (subseq p 0 dash) spec))
                     (hi (evgen--slice-number (subseq p (1+ dash)) spec)))
                 (when (> lo hi)
                   (error "--slices range ~a is backwards: ~d is greater than ~d"
                          p lo hi))
                 (loop for i from lo to hi do (push i out))))))))
      (sort (remove-duplicates out) #'<))))

;;; ---------------------------------------------------------- solution file

(defun evgen--read-solution (file)
  "Read a planner .answer file.  Returns (values true-table horizon), where
TRUE-TABLE maps (kind term slice) to T for every literal the solution reports
true, and HORIZON is the largest slice mentioned."
  (unless (probe-file file)
    (error "solution file not found: ~a~%  ~
            planner.sh writes <problem>.answer beside the problem; pass ~
            --solution to name a different one" file))
  (let ((forms (let ((*read-eval* nil))
                 (with-open-file (in file :direction :input)
                   (loop for f = (read in nil 'eof) until (eql f 'eof) collect f))))
        (table (make-hash-table :test #'equal))
        (horizon 0))
    (unless forms
      (error "solution file ~a is empty" file))
    ;; The verdict comes first.  Anything but SAT means there is no plan to take
    ;; observations from, and writing an empty evidence file would be worse than
    ;; saying so: downstream, empty evidence silently conditions on nothing.
    (let ((verdict (first forms)))
      (unless (and (symbolp verdict) (string-equal (symbol-name verdict) "SAT"))
        (error "solution file ~a reports ~a, not SAT: there is no plan to observe"
               file verdict)))
    (dolist (f (rest forms))
      (when (and (consp f) (symbolp (first f)) (= (length f) 3)
                 (member (symbol-name (first f)) '("HOLDS" "OCCURS") :test #'string-equal)
                 (integerp (third f)))
        (let ((kind (intern (string-upcase (symbol-name (first f))) :keyword)))
          (setf (gethash (list kind (second f) (third f)) table) t)
          (setf horizon (max horizon (third f))))))
    (when (zerop horizon)
      (error "solution file ~a has no (HOLDS ...) or (OCCURS ...) literals" file))
    (values table horizon)))

;;; --------------------------------------------------------- ground universe

(defun evgen--ground-universe (wff-file horizon)
  "Parse WFF-FILE with the timeline fixed at HORIZON slices and return
(values fluents actions) -- the problem's ground fluent and action lists, as
FiFO's own domain machinery computes them."
  (setq *satplan-numslices* horizon)
  (let ((*current-wff-directory*
          (uiop:pathname-directory-pathname (truename wff-file)))
        (*read-eval* nil))
    (with-open-file (in wff-file :direction :input)
      (parse (loop for f = (read in nil 'eof) until (eql f 'eof) collect f))))
  (values (gethash 'FLUENTS Bind) (gethash 'ACTIONS Bind)))

(defun evgen--head (term)
  "The predicate or action name of a ground term: AT for (AT PKG1 C1-P2)."
  (if (consp term) (first term) term))

(defun evgen--observe-names (observe)
  "Parse the --observe string into a list of upper-case name strings, or NIL for
no restriction."
  (let ((text (string-trim " " (or observe ""))))
    (if (string= text "")
        nil
        (let ((names (remove "" (mapcar (lambda (s) (string-trim " " s))
                                        (evgen--split text #\,))
                             :test #'string=)))
          (unless names
            (error "--observe ~s names nothing (a stray comma?)" observe))
          (mapcar #'string-upcase names)))))

(defun evgen--restrict (terms names)
  (if (null names)
      terms
      (remove-if-not (lambda (tm) (member (symbol-name (evgen--head tm)) names
                                          :test #'string=))
                     terms)))

;;; ------------------------------------------------------------------- emit

(defun evgen--header-lines (args horizon count)
  (append
   (list "Generated by evgen.sh -- edit the generator, not this file."
         (format nil "Solution horizon: ~d slice~:p (fluents 1-~d, actions 1-~d); ~
                      ~d literal~:p."
                 horizon horizon (1- horizon) count)
         ""
         "Every setting used, defaults included; re-run with these to reproduce it:"
         "")
   (loop for (flag . value) in args collect (format nil "  ~a ~a" flag value))))

(defun evgen--distinct-heads (terms)
  (let ((out '()))
    (dolist (tm terms (sort out #'string< :key #'symbol-name))
      (pushnew (evgen--head tm) out))))

(defun evgen--check-observe-names (names fluents actions observe)
  "Every --observe name must match something.  A name that matches nothing would
otherwise silently shrink the evidence, and an evidence file missing the literal
you meant to condition on produces a plausible WRONG answer, not an error."
  (when names
    (let* ((known (append (evgen--distinct-heads fluents)
                          (evgen--distinct-heads actions)))
           (known-names (mapcar #'symbol-name known))
           (unmatched (remove-if (lambda (n) (member n known-names :test #'string=))
                                 names)))
      (when unmatched
        (error "--observe ~s names ~{~(~a~)~^, ~}, which ~:[are~;is~] not a fluent ~
                or action in this problem.~%  Known: ~{~(~a~)~^ ~}"
               observe unmatched (= 1 (length unmatched))
               (sort (copy-list known-names) #'string<))))))

(defun evgen--resolved-domain (problem-path)
  "The domain file pddl2fifo resolves (:domain <name>) to: <name>.pddl beside the
problem."
  (let* ((forms (let ((*read-eval* nil))
                  (with-open-file (in problem-path) (read in))))
         (dom (second (find-if (lambda (f) (and (consp f) (symbolp (first f))
                                                (string-equal (symbol-name (first f))
                                                              ":DOMAIN")))
                               forms))))
    (if dom
        (merge-pathnames (make-pathname :name (string-downcase (symbol-name dom))
                                        :type "pddl")
                         problem-path)
        problem-path)))

(defun evgen--verify-emitted (lines fluents actions horizon)
  "Every literal written must name a real ground atom at a real slice.  Downstream
an unknown atom is not an error but a fresh unconstrained variable, which makes
the evidence quietly do nothing, so the check belongs here."
  (dolist (l lines)
    (let* ((lit (if (eq (first l) 'not) (second l) l))
           (kind (first lit)) (term (second lit)) (slice (third lit))
           (universe (if (eq kind 'holds) fluents actions))
           (limit (if (eq kind 'holds) horizon (1- horizon))))
      (unless (member term universe :test #'equal)
        (error "internal: ~s is not a ground ~(~a~) of this problem" term kind))
      (unless (<= 1 slice limit)
        (error "internal: slice ~d is out of range for ~(~a~) (1-~d)"
               slice kind limit)))))

(defun evgen--write (evidence problem-path solution-path domain
                     requested horizon true fluents actions
                     slices observe negative-evidence)
  (let ((lines '()) (count 0))
    ;; Universe order, so the output is stable and positives/negatives interleave
    ;; in a fixed sequence rather than depending on the solution's print order.
    (dolist (s requested)
      (dolist (f fluents)
        (let ((hit (gethash (list :holds f s) true)))
          (cond (hit (push (list 'holds f s) lines) (incf count))
                ((= negative-evidence 1)
                 (push (list 'not (list 'holds f s)) lines) (incf count)))))
      ;; Actions live on actslices = 1..numslices-1, so the final slice has none.
      (when (< s horizon)
        (dolist (a actions)
          (let ((hit (gethash (list :occurs a s) true)))
            (cond (hit (push (list 'occurs a s) lines) (incf count))
                  ((= negative-evidence 1)
                   (push (list 'not (list 'occurs a s)) lines) (incf count)))))))
    (setf lines (nreverse lines))
    (when (zerop count)
      (error "no observations selected: slices ~a~@[ restricted to ~a~] produced ~
              nothing.~%  An empty evidence file conditions on nothing, silently, ~
              so this is an error rather than a file."
             slices (and (string/= (string-trim " " observe) "") observe)))
    (evgen--verify-emitted lines fluents actions horizon)
    (let ((args (list (cons "--problem" (namestring problem-path))
                      (cons "--evidence" (namestring evidence))
                      (cons "--solution" (namestring solution-path))
                      ;; The domain as given, or the file pddl2fifo resolved
                      ;; (:domain ...) to, so the block is a complete command line.
                      (cons "--domain" (namestring
                                        (or domain
                                            (evgen--resolved-domain problem-path))))
                      (cons "--slices" slices)
                      (cons "--observe" (if (string= (string-trim " " observe) "")
                                            "\"\"" observe))
                      (cons "--negative-evidence" negative-evidence))))
      (with-open-file (out evidence :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
        (let ((*print-case* :downcase))
          (dolist (line (evgen--header-lines args horizon count))
            (if (string= line "")
                (format out ";;~%")
                (format out ";; ~a~%" line)))
          (terpri out)
          (dolist (l lines) (format out "~s~%" l)))))
    (values evidence count horizon)))

(defun evgen (&key problem solution domain evidence slices (observe "")
                   (negative-evidence 0) (satplan "satplan.wff"))
  "Write an evidence file from a solved PDDL problem.  See the file header."
  (unless problem  (error "--problem is required: the PDDL problem instance"))
  (unless evidence (error "--evidence is required: the file to write"))
  (unless (member negative-evidence '(0 1))
    (error "--negative-evidence must be 0 or 1, got ~a" negative-evidence))
  (let ((problem-path (probe-file problem)))
    (unless problem-path (error "problem file not found: ~a" problem))
    (let* ((requested (evgen--parse-slices slices))
           (solution-path (or solution
                              (merge-pathnames (make-pathname :type "answer")
                                               problem-path))))
      (multiple-value-bind (true horizon) (evgen--read-solution solution-path)
        ;; A slice past the horizon has no atoms at all, and evidence naming one
        ;; is silently vacuous downstream -- the planner invents a fresh variable
        ;; and returns the unconditioned answer.  Refuse instead.
        (let ((over (remove-if (lambda (s) (<= s horizon)) requested)))
          (when over
            (error "--slices names slice~p ~{~d~^, ~} beyond the solution's horizon ~
                    of ~d~%  (fluents run 1-~d, actions 1-~d)"
                   (length over) over horizon horizon (1- horizon))))
        ;; Regenerate the wff from the problem: idempotent, and the same file
        ;; planner.sh leaves beside the problem.  SATPLAN is passed straight into
        ;; the generated (include ...); an ABSOLUTE path is what the wrapper
        ;; supplies, since parse-include merges it against the wff's directory and
        ;; the default relative "satplan.wff" only resolves for a problem sitting
        ;; beside the axioms.
        (let ((wff (pddl2fifo (namestring problem-path)
                              :domain-file (and domain (namestring domain))
                              :satplan-path satplan)))
          (multiple-value-bind (all-fluents all-actions)
              (evgen--ground-universe wff horizon)
            (let ((names (evgen--observe-names observe)))
              ;; Check the names against the whole universe BEFORE restricting:
              ;; a name matching nothing must be an error, not a quietly smaller
              ;; evidence file.
              (evgen--check-observe-names names all-fluents all-actions observe)
              (let ((fluents (evgen--restrict all-fluents names))
                    (actions (evgen--restrict all-actions names)))
                (evgen--write evidence problem-path solution-path domain
                              requested horizon true fluents actions
                              slices observe negative-evidence)))))))))

