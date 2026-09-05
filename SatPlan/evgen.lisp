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

(defun evgen--header-lines (args horizon count recognition)
  "The comment block: what the file is, then every setting that made it."
  (append
   (remove ""
    (list "Generated by evgen.sh -- edit the generator, not this file."
          (format nil "Solution horizon: ~d slice~:p (fluents 1-~d, actions 1-~d); ~
                       ~d literal~:p."
                  horizon horizon (1- horizon) count)
          (if recognition
              "Recognition mode: ONE (and ...) form, so recognize.sh can negate it."
              "")
          :blank
          "Every setting used, defaults included; re-run with these to reproduce it:"
          :blank)
    :test #'equal)
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
                     slices observe negative-evidence recognition)
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
                      (cons "--negative-evidence" negative-evidence)
                      (cons "--recognition" (if recognition 1 0)))))
      (with-open-file (out evidence :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
        (let ((*print-case* :downcase))
          (dolist (line (evgen--header-lines args horizon count recognition))
            (if (eq line :blank)
                (format out ";;~%")
                (format out ";; ~a~%" line)))
          (terpri out)
          ;; recognize.sh forms the not-comply case by wrapping the file's whole
          ;; contents in (not ...), which is only valid if the file holds ONE
          ;; form -- so conjoin them rather than writing a literal per line.
          (if recognition
              (format out "(and~{~%  ~s~})~%" lines)
              (dolist (l lines) (format out "~s~%" l))))))
    (values evidence count horizon)))

;;; --------------------------------------------------------- dataset export

;;; The inverse of SatPlan/Examples/Plan_Recognition/make-recognition-instance.lisp:
;;; that reads the R&G dataset format -- domain.pddl, a template.pddl whose goal is
;;; the placeholder <HYPOTHESIS>, hyps.dat, obs.dat -- and builds a FiFO instance
;;; from it.  This writes the format back out, so an instance developed here can be
;;; handed to a tool chain that speaks it.
;;;
;;; Why not PDDL 3.0 :constraints, which is the obvious thing to reach for: every
;;; con-GD operand is a state formula, so there is NO standard operator saying an
;;; action occurred (FiFO's occur-sometime is its own extension, with no PDDL
;;; counterpart) -- and action observations are most recognition evidence.  Beyond
;;; that, FiFO slices are PARALLEL, so a slice index means nothing to a sequential
;;; planner, and few current planners read :constraints at all.

(defun evgen--section (define-form name)
  "The (NAME ...) section of a PDDL define form, or NIL."
  (find-if (lambda (s) (and (consp s) (symbolp (first s))
                            (string-equal (symbol-name (first s)) name)))
           (cddr define-form)))

(defun evgen--hypothesis-names (problem-def)
  "The nullary predicate names of a recognition goal (or (hyp0) ... (hypN)), in
that order.  NIL when the goal is not such a disjunction."
  (let ((goal (second (evgen--section problem-def "GOAL"))))
    (when (and (consp goal) (symbolp (first goal))
               (string-equal (symbol-name (first goal)) "OR")
               (every (lambda (d) (and (consp d) (null (rest d)) (symbolp (first d))))
                      (rest goal)))
      (mapcar #'first (rest goal)))))

(defun evgen--derived-conjunctions (domain-def names)
  "For each NAME, the list of ground atoms its (:derived (name) (and ...)) rule
conjoins.  Errors on a name the domain does not define."
  (let ((rules (remove-if-not (lambda (s) (and (consp s) (eq (first s) :derived)))
                              (cddr domain-def))))
    (mapcar
     (lambda (name)
       (let ((rule (find-if (lambda (r) (and (consp (second r))
                                             (eq (first (second r)) name)))
                            rules)))
         (unless rule
           (error "the goal names ~(~a~), but the domain has no (:derived (~(~a~)) ...) rule"
                  name name))
         (let ((body (third rule)))
           ;; (and a b c) or a bare single atom
           (if (and (consp body) (symbolp (first body))
                    (string-equal (symbol-name (first body)) "AND"))
               (rest body)
               (list body)))))
     names)))

(defun evgen--dat-line (atoms)
  "One hyps.dat line: ground atoms separated by commas, upper case, as the
published datasets write them."
  (let ((*print-case* :upcase))
    (format nil "~{~a~^,~}" (mapcar (lambda (a) (format nil "~s" a)) atoms))))

(defun evgen--strip-sections (define-form drop-p)
  "DEFINE-FORM with the sections DROP-P accepts removed."
  (list* (first define-form) (second define-form)
         (remove-if drop-p (cddr define-form))))

(defun evgen--export-domain (domain-def hyp-names)
  "The domain without its hypothesis rules -- those become hyps.dat.  Everything
else, cost machinery included, is preserved: we cannot tell a cost the importer
added from one the domain always had, and (increase (total-cost) n) is standard
PDDL that any recipient can read or ignore.

:derived-predicates is dropped from :requirements only when NO derived section
survives -- a domain may define derived predicates that are not hypotheses (see
SatPlan/Examples/DerivedPreds), and those must keep the flag."
  (let ((stripped (evgen--strip-sections
                   domain-def
                   (lambda (s) (and (consp s) (eq (first s) :derived)
                                    (consp (second s))
                                    (member (first (second s)) hyp-names))))))
    (if (find-if (lambda (s) (and (consp s) (eq (first s) :derived))) (cddr stripped))
        stripped
        (list* (first stripped) (second stripped)
               (mapcar (lambda (s)
                         (if (and (consp s) (symbolp (first s))
                                  (string-equal (symbol-name (first s)) "REQUIREMENTS"))
                             (remove-if (lambda (r)
                                          (and (symbolp r)
                                               (string-equal (symbol-name r)
                                                             "DERIVED-PREDICATES")))
                                        s)
                             s))
                       (cddr stripped))))))

(defun evgen--export-template (problem-def)
  "The problem as a template: the hypothesis disjunction replaced by the
<HYPOTHESIS> placeholder, and the (= (total-cost) 0) the importer adds to :init
removed, so a re-import reproduces the original exactly."
  (list* (first problem-def) (second problem-def)
         (mapcar
          (lambda (s)
            (cond ((and (consp s) (symbolp (first s))
                        (string-equal (symbol-name (first s)) "GOAL"))
                   (list (first s) (list (intern "AND") (intern "<HYPOTHESIS>"))))
                  ((and (consp s) (symbolp (first s))
                        (string-equal (symbol-name (first s)) "INIT"))
                   (remove-if (lambda (f)
                                (and (consp f) (symbolp (first f))
                                     (string= (symbol-name (first f)) "=")
                                     (equal (second f) '(total-cost))))
                              s))
                  (t s)))
          (cddr problem-def))))

(defun evgen--true-hypothesis (names true horizon)
  "The hypothesis the solution actually achieved.  Derived predicates DO appear in
the .answer, so this is read rather than guessed; NIL if none is reported."
  (find-if (lambda (n) (gethash (list :holds (list n) horizon) true)) names))

(defun evgen--replace-all (string old new)
  (with-output-to-string (o)
    (loop with start = 0
          for pos = (search old string :start2 start)
          do (write-string string o :start start :end (or pos (length string)))
             (when (null pos) (return))
             (write-string new o)
             (setf start (+ pos (length old))))))

(defun evgen--write-pddl (path define-form &optional header)
  "Print a PDDL define form, preceded by HEADER as ;; comment lines.  PDDL is
case-insensitive, so :downcase is only a convention -- except for the
<HYPOTHESIS> placeholder, which the published datasets write in caps and which
readers may well match as text, so it is put back after printing.  A 0-ary
:parameters prints from Lisp as NIL, which a Lisp reader takes as the empty list
but a real PDDL parser does not, so that is put back too."
  (let ((text (let ((*print-case* :downcase) (*print-right-margin* 78))
                (with-output-to-string (o) (pprint define-form o) (terpri o)))))
    (setf text (evgen--replace-all text "<hypothesis>" "<HYPOTHESIS>"))
    (setf text (evgen--replace-all text ":parameters nil" ":parameters ()"))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (dolist (line header) (format out ";; ~a~%" line))
      (when header (terpri out))
      (write-string text out))))

(defun evgen--write-lines (path lines)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (dolist (l lines) (write-line l out))))

(defun evgen--dataset-readme (problem-path solution-path domain-path
                              names observations true-hyp slices observe horizon)
  (append
   (list "# Plan-recognition instance"
         ""
         (format nil "~d candidate hypotheses, ~d observation~:p."
                 (length names) (length observations))
         ""
         "Files, in the format Ramirez & Geffner's datasets use:"
         ""
         "| file | contents |"
         "|---|---|"
         "| `domain.pddl` | the domain, with the hypothesis rules removed |"
         "| `template.pddl` | the initial state; its goal is the `<HYPOTHESIS>` placeholder |"
         "| `hyps.dat` | one candidate goal per line, ground atoms separated by commas |"
         "| `obs.dat` | the observed actions, one per line, in order |"
         (if true-hyp "| `real_hyp.dat` | the hypothesis the source plan actually achieved |"
             "| (no `real_hyp.dat`) | the solution reported no hypothesis true at its final slice |")
         ""
         "## What the observations do and do not say"
         ""
         "`obs.dat` records **actions, in order, without times**.  Two consequences:"
         ""
         "- A fluent observation cannot be written in this format, so only actions"
         "  were exported."
         (format nil "- FiFO's time slices are PARALLEL -- a slice may hold several actions at~%  ~
                      once -- while `obs.dat` is a linear sequence.  Actions observed in the~%  ~
                      same slice are consecutive here in an arbitrary order.  That is sound~%  ~
                      for a sequential planner, since they do not interfere, but it is a~%  ~
                      total order the source plan did not assert.")
         ""
         "## Provenance"
         ""
         "```")
   (list (format nil "problem   ~a" (file-namestring problem-path))
         (format nil "domain    ~a" (file-namestring domain-path))
         (format nil "solution  ~a (horizon ~d slices)"
                 (file-namestring solution-path) horizon)
         (format nil "slices    ~a" slices)
         (format nil "observe   ~a"
                 (if (string= (string-trim " " observe) "") "(all actions)" observe))
         "```")))

(defun evgen--export-dataset (dir problem-path domain-path solution-path
                              requested horizon true actions
                              slices observe)
  "Write the R&G dataset files into DIR.  Returns the number of observations."
  (let* ((problem-def (let ((*read-eval* nil))
                        (with-open-file (in problem-path) (read in))))
         (domain-def (let ((*read-eval* nil))
                       (with-open-file (in domain-path) (read in))))
         (names (evgen--hypothesis-names problem-def)))
    (unless names
      (error "--export-dataset needs a recognition instance: ~a's goal is not a ~
              disjunction (or (hyp0) ... (hypN)) of nullary derived predicates.~%  ~
              That disjunction and the domain's (:derived (hypI) ...) rules are ~
              what hyps.dat is made of."
             (file-namestring problem-path)))
    (let* ((conjunctions (evgen--derived-conjunctions domain-def names))
           ;; observations: the actions true at the requested slices, in slice
           ;; order.  A slice may hold SEVERAL -- FiFO's slices are parallel --
           ;; and obs.dat is a linear sequence, so they come out consecutive in
           ;; the universe's order, which the README calls out.
           (observations
             (loop for s in requested
                   when (< s horizon)
                     nconc (loop for a in actions
                                 when (gethash (list :occurs a s) true)
                                   collect (cons a s))))
           (true-hyp (evgen--true-hypothesis names true horizon)))
      (when (null observations)
        (error "no action observations selected: slices ~a~@[ restricted to ~a~] ~
                produced none.~%  obs.dat records ACTIONS -- a fluent cannot be ~
                written in this format."
               slices (and (string/= (string-trim " " observe) "") observe)))
      (ensure-directories-exist (merge-pathnames "x" dir))
      (evgen--write-pddl (merge-pathnames "domain.pddl" dir)
                         (evgen--export-domain domain-def names))
      (evgen--write-pddl (merge-pathnames "template.pddl" dir)
                         (evgen--export-template problem-def))
      (evgen--write-lines (merge-pathnames "hyps.dat" dir)
                          (mapcar #'evgen--dat-line conjunctions))
      (evgen--write-lines (merge-pathnames "obs.dat" dir)
                          (let ((*print-case* :upcase))
                            (mapcar (lambda (o) (format nil "~s" (car o))) observations)))
      (when true-hyp
        (evgen--write-lines
         (merge-pathnames "real_hyp.dat" dir)
         (list (evgen--dat-line (nth (position true-hyp names) conjunctions)))))
      (evgen--write-lines
       (merge-pathnames "README.md" dir)
       (evgen--dataset-readme problem-path solution-path domain-path
                              names observations true-hyp slices observe horizon))
      (length observations))))

;;; ---------------------------------------------- :constraints export

;;; Observations as PDDL 3.0 trajectory constraints, at the EXACT slices the
;;; solution puts them at:
;;;
;;;   fluent f true at slice t  ->  (hold-during t t f)      standard PDDL 3.0
;;;   action a occurs at slice t ->  (occur-sometime t t a)  NOT standard
;;;
;;; The asymmetry is the whole story: every PDDL 3.0 con-GD operand is a STATE
;;; formula, so there is no standard way to say an action occurred.
;;; occur-sometime is FiFO's own extension, and a problem carrying one is
;;; readable only by a planner that has been taught it -- which the emitted file
;;; says in a comment, so a recipient learns it from the file rather than from a
;;; parse error.  A fluents-only export is plain PDDL 3.0 and carries no note.

(defparameter *evgen-occur-sometime-note*
  '("NOTE: the (occur-sometime t1 t2 <action>) constraints below are NOT part of"
    "PDDL 3.0.  Every standard con-GD operator takes a STATE formula, so the"
    "standard has no way to say that an action occurred; occur-sometime is a"
    "FiFO extension.  A planner must support it to read this problem."
    "The (hold-during t t <fluent>) constraints ARE standard and need nothing.")
  "Emitted only when the observations include actions.")

(defun evgen--constraint-forms (requested horizon true fluents actions)
  "The con-GD forms for the observations, slice by slice.  Returns
(values forms action-count)."
  (let ((forms '()) (nactions 0))
    (dolist (s requested)
      (dolist (f fluents)
        (when (gethash (list :holds f s) true)
          (push (list 'hold-during s s f) forms)))
      (when (< s horizon)
        (dolist (a actions)
          (when (gethash (list :occurs a s) true)
            (push (list 'occur-sometime s s a) forms)
            (incf nactions)))))
    (values (nreverse forms) nactions)))

(defun evgen--add-requirement (domain-def name)
  "DOMAIN-DEF with NAME in its :requirements, added only if absent."
  (list* (first domain-def) (second domain-def)
         (mapcar (lambda (s)
                   (if (and (consp s) (symbolp (first s))
                            (string-equal (symbol-name (first s)) "REQUIREMENTS")
                            (notany (lambda (r) (and (symbolp r)
                                                     (string-equal (symbol-name r)
                                                                   (symbol-name name))))
                                    (rest s)))
                       (append s (list name))
                       s))
                 (cddr domain-def))))

(defun evgen--conjuncts (form)
  (if (and (consp form) (symbolp (first form))
           (string-equal (symbol-name (first form)) "AND"))
      (rest form)
      (list form)))

(defun evgen--add-constraints (problem-def forms)
  "PROBLEM-DEF with a (:constraints (and ...)) section.  An existing section is
extended rather than replaced, so an export of an already-constrained problem
keeps what it had."
  (let ((existing (evgen--section problem-def "CONSTRAINTS")))
    (if existing
        (list* (first problem-def) (second problem-def)
               (mapcar (lambda (s)
                         (if (eq s existing)
                             (list (first s) (cons 'and (append (evgen--conjuncts (second s))
                                                                forms)))
                             s))
                       (cddr problem-def)))
        ;; place it before :goal, where PDDL 3.0 puts it
        (let ((goal (evgen--section problem-def "GOAL")))
          (list* (first problem-def) (second problem-def)
                 (loop for s in (cddr problem-def)
                       when (eq s goal) collect (list :constraints (cons 'and forms))
                       collect s))))))

(defun evgen--constraints-readme (problem-path domain-path solution-path
                                  forms nactions slices observe horizon)
  (let ((nfluents (- (length forms) nactions)))
    (list*
     "# Observations as PDDL 3.0 trajectory constraints"
     ""
     (format nil "~d constraint~:p: ~d fluent observation~:p and ~d action observation~:p, ~
                  each pinned to the slice the source plan puts it at."
             (length forms) nfluents nactions)
     ""
     "| file | contents |"
     "|---|---|"
     "| `domain.pddl` | the domain, unchanged except that `:constraints` is in `:requirements` |"
     "| `problem.pddl` | the problem, plus a `(:constraints (and ...))` section |"
     ""
     (append
      (if (plusp nactions)
          (list "## Portability"
                ""
                "A fluent observation is `(hold-during t t <fluent>)`, which is standard"
                "PDDL 3.0.  An action observation is `(occur-sometime t t <action>)`, which"
                "is **not**: every standard con-GD operator takes a state formula, so the"
                "standard cannot say an action occurred.  This file contains action"
                "observations, so a planner must support `occur-sometime` to read it."
                "")
          (list "## Portability"
                ""
                "Every constraint here is `(hold-during t t <fluent>)`, which is standard"
                "PDDL 3.0.  No extension is needed."
                ""))
      (list "## Times"
            ""
            (format nil "Slices are the source plan's, numbered from 1 to ~d.  They are~%~
                         PARALLEL: a slice may hold several actions at once, so a constraint~%~
                         at slice t does not mean \"the t-th step of a sequential plan\"."
                    horizon)
            ""
            "## Provenance"
            ""
            "```"
            (format nil "problem   ~a" (file-namestring problem-path))
            (format nil "domain    ~a" (file-namestring domain-path))
            (format nil "solution  ~a (horizon ~d slices)"
                    (file-namestring solution-path) horizon)
            (format nil "slices    ~a" slices)
            (format nil "observe   ~a"
                    (if (string= (string-trim " " observe) "") "(everything)" observe))
            "```")))))

(defun evgen--export-constraints (dir problem-path domain-path solution-path
                                  requested horizon true fluents actions
                                  slices observe)
  "Write domain.pddl + problem.pddl into DIR, the problem carrying the
observations as trajectory constraints.  Returns the constraint count."
  (let* ((problem-def (let ((*read-eval* nil))
                        (with-open-file (in problem-path) (read in))))
         (domain-def (let ((*read-eval* nil))
                       (with-open-file (in domain-path) (read in)))))
    (multiple-value-bind (forms nactions)
        (evgen--constraint-forms requested horizon true fluents actions)
      (when (null forms)
        (error "no observations selected: slices ~a~@[ restricted to ~a~] produced ~
                nothing, so there is nothing to constrain."
               slices (and (string/= (string-trim " " observe) "") observe)))
      (ensure-directories-exist (merge-pathnames "x" dir))
      (evgen--write-pddl (merge-pathnames "domain.pddl" dir)
                         (evgen--add-requirement domain-def :constraints))
      (evgen--write-pddl (merge-pathnames "problem.pddl" dir)
                         (evgen--add-constraints problem-def forms)
                         (when (plusp nactions) *evgen-occur-sometime-note*))
      (evgen--write-lines
       (merge-pathnames "README.md" dir)
       (evgen--constraints-readme problem-path domain-path solution-path
                                  forms nactions slices observe horizon))
      (length forms))))

;;; ------------------------------------- ordering-constraints export

;;; The observations as ONE (occur-in-order M N a1 ... ak) constraint: their
;;; order, and the coarse span the solution showed, without pinning each action
;;; to a slice.  Actions only -- there is no ordering form for a fluent.
;;;
;;; occur-in-order needs STRICTLY INCREASING slices, and FiFO's are PARALLEL, so
;;; two observations sharing a slice cannot be written as a sequence: doing so
;;; would demand they occupy different slices, which the source plan does not
;;; satisfy, and the exported problem could come back unsatisfiable.  That is a
;;; fidelity break rather than a footnote, so a tie is refused.

(defun evgen--ordering-observations (requested horizon true actions)
  "The observed actions as (action . slice), in slice order.  Errors on two at
the same slice."
  (let ((obs (loop for s in requested
                   when (< s horizon)
                     nconc (loop for a in actions
                                 when (gethash (list :occurs a s) true)
                                   collect (cons a s)))))
    (let ((dup (loop for (a . s) in obs
                     when (> (count s obs :key #'cdr) 1) return s)))
      (when dup
        (error "slice ~d holds ~d observed actions, and occur-in-order needs ~
                STRICTLY increasing slices.~%  ~
                Exporting them as a sequence would demand they happen at ~
                different slices -- a claim the source plan does not make, and ~
                the exported problem could be unsatisfiable.~%  ~
                Narrow the selection until at most one action is observed per ~
                slice -- --slices to drop the crowded ones, --observe to keep ~
                fewer action names (note it filters by NAME, so it cannot ~
                separate two groundings of the same action) -- or use ~
                --export-constraints, which pins each observation to its own ~
                slice and handles parallel ones natively."
               dup (count dup obs :key #'cdr))))
    obs))

(defparameter *evgen-occur-in-order-note*
  '("NOTE: (occur-in-order M N <action>+) is NOT part of PDDL 3.0.  Every"
    "standard con-GD operator takes a STATE formula, so the standard has no way"
    "to say that an action occurred, let alone that several occurred in order;"
    "occur-in-order is a FiFO extension.  A planner must support it to read this"
    "problem.  It asserts an order-preserving embedding: there are strictly"
    "increasing slices in [M, N] at which the listed actions occur, in this"
    "order, with anything else allowed in between.  N = -1 means no upper bound.")
  "Always emitted -- unlike hold-during, there is no standard fallback here.")

(defun evgen--ordering-readme (problem-path domain-path solution-path
                               obs m n slices observe horizon)
  (append
   (list "# Observations as an ordering constraint"
         ""
         (format nil "~d observed action~:p, as one (occur-in-order ~d ~d ...) ~
                      constraint: their ORDER, and the span of the source plan ~
                      they fell in, without pinning any of them to a slice."
                 (length obs) m n)
         ""
         "| file | contents |"
         "|---|---|"
         "| `domain.pddl` | the domain, unchanged except that `:constraints` is in `:requirements` |"
         "| `problem.pddl` | the problem, plus the ordering constraint |"
         ""
         "## Portability"
         ""
         "`occur-in-order` is a FiFO extension -- PDDL 3.0 has no operator for an"
         "action occurring, so there is no standard form for this.  A planner must"
         "support it.  The problem file repeats this in a comment."
         ""
         "## What it does and does not say"
         ""
         (format nil "The actions occur in the order listed, at strictly increasing~%~
                      slices somewhere in [~d, ~d].  It does NOT say which slice each~%~
                      one falls at, nor that they are consecutive -- anything may~%~
                      happen in between.  Slices are the source plan's, 1 to ~d."
                 m n horizon)
         ""
         "## Provenance"
         ""
         "```")
   (list (format nil "problem   ~a" (file-namestring problem-path))
         (format nil "domain    ~a" (file-namestring domain-path))
         (format nil "solution  ~a (horizon ~d slices)"
                 (file-namestring solution-path) horizon)
         (format nil "slices    ~a" slices)
         (format nil "observe   ~a"
                 (if (string= (string-trim " " observe) "") "(all actions)" observe))
         "```")))

(defun evgen--export-ordering (dir problem-path domain-path solution-path
                               requested horizon true actions slices observe)
  "Write domain.pddl + problem.pddl into DIR, the problem carrying the
observations as a single occur-in-order constraint.  Returns their count."
  (let* ((problem-def (let ((*read-eval* nil))
                        (with-open-file (in problem-path) (read in))))
         (domain-def (let ((*read-eval* nil))
                       (with-open-file (in domain-path) (read in))))
         (obs (evgen--ordering-observations requested horizon true actions)))
    (when (null obs)
      (error "no action observations selected: slices ~a~@[ restricted to ~a~] ~
              produced none.~%  An ordering constraint records ACTIONS; a fluent ~
              has no ordering form."
             slices (and (string/= (string-trim " " observe) "") observe)))
    (let* ((m (reduce #'min obs :key #'cdr))
           (n (reduce #'max obs :key #'cdr))
           (form (list* 'occur-in-order m n (mapcar #'car obs))))
      (ensure-directories-exist (merge-pathnames "x" dir))
      (evgen--write-pddl (merge-pathnames "domain.pddl" dir)
                         (evgen--add-requirement domain-def :constraints))
      (evgen--write-pddl (merge-pathnames "problem.pddl" dir)
                         (evgen--add-constraints problem-def (list form))
                         *evgen-occur-in-order-note*)
      (evgen--write-lines
       (merge-pathnames "README.md" dir)
       (evgen--ordering-readme problem-path domain-path solution-path
                               obs m n slices observe horizon))
      (length obs))))

(defun evgen (&key problem solution domain evidence slices (observe "")
                   (negative-evidence 0) (recognition nil) export-dataset
                   export-constraints export-ordering (satplan "satplan.wff"))
  "Write an evidence file from a solved PDDL problem.  See the file header."
  (unless problem  (error "--problem is required: the PDDL problem instance"))
  (unless (or evidence export-dataset export-constraints export-ordering)
    (error "nothing to write: give --evidence <file>, --export-dataset <dir>, ~
            --export-constraints <dir>, --export-ordering-constraints <dir>, ~
            or several"))
  (unless (member negative-evidence '(0 1))
    (error "--negative-evidence must be 0 or 1, got ~a" negative-evidence))
  ;; Complete observability pins the trajectory, so c(O) becomes the cost of that
  ;; one trajectory -- finite for the hypotheses that can produce it, infinite for
  ;; the rest -- and the posterior collapses to 0/1 with no gradation.  Meanwhile
  ;; the not-comply case is "at least one of thousands of literals differs", which
  ;; almost any plan satisfies, so c(not O) is just the unconstrained optimum for
  ;; every hypothesis and the difference carries nothing.  A graded difference is
  ;; the whole point of the recognizer, so the combination is refused.
  (when (and recognition (= negative-evidence 1))
    (error "--recognition and --negative-evidence 1 do not go together.~%  ~
            Negative evidence asserts COMPLETE observability, which pins the ~
            trajectory: every hypothesis' cost becomes 0 or infinite and the ~
            posterior loses its gradation."))
  ;; obs.dat records ACTIONS in order; there is no way to write a fluent, and
  ;; nothing to write "this was false".
  (when (and export-dataset (= negative-evidence 1))
    (error "--export-dataset and --negative-evidence 1 do not go together: ~
            obs.dat records only what was observed to HAPPEN."))
  ;; (hold-during t t (not f)) would express a negative FLUENT, but there is no
  ;; con-GD form for "this action did not occur" -- and honouring half of the
  ;; request silently would be worse than declining it.
  (when (and export-ordering (= negative-evidence 1))
    (error "--export-ordering-constraints and --negative-evidence 1 do not go ~
            together: an ordering constraint records only what did happen."))
  (when (and export-constraints (= negative-evidence 1))
    (error "--export-constraints and --negative-evidence 1 do not go together: ~
            PDDL has no trajectory constraint saying an action did NOT occur."))
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
              ;; A fluent named in --observe cannot reach obs.dat, and quietly
              ;; dropping it would export less than was asked for.
              (when export-dataset
                (let ((fluent-names (mapcar #'symbol-name
                                            (evgen--distinct-heads all-fluents))))
                  (let ((bad (remove-if-not (lambda (n) (member n fluent-names
                                                                :test #'string=))
                                            (or names '()))))
                    (when bad
                      (error "--export-dataset cannot record the fluent~p ~
                              ~{~(~a~)~^, ~} named in --observe: obs.dat holds ~
                              ACTIONS in order, and has no way to say a fluent ~
                              held.~%  Restrict --observe to action names."
                             (length bad) bad)))))
              (let ((fluents (evgen--restrict all-fluents names))
                    (actions (evgen--restrict all-actions names)))
                (let ((written nil) (n 0))
                  (when evidence
                    (multiple-value-bind (f c) (evgen--write evidence problem-path
                                                 solution-path domain requested horizon
                                                 true fluents actions slices observe
                                                 negative-evidence recognition)
                      (setf written f n c)))
                  (when export-ordering
                    (let ((n (evgen--export-ordering export-ordering problem-path
                               (or domain (evgen--resolved-domain problem-path))
                               solution-path requested horizon true actions
                               slices observe)))
                      (format *error-output* "Wrote ~a (~d observation~:p, ordered)~%"
                              export-ordering n)))
                  (when export-constraints
                    (let ((n (evgen--export-constraints export-constraints problem-path
                               (or domain (evgen--resolved-domain problem-path))
                               solution-path requested horizon true fluents actions
                               slices observe)))
                      (format *error-output* "Wrote ~a (~d constraint~:p)~%"
                              export-constraints n)))
                  (when export-dataset
                    (let ((obs (evgen--export-dataset export-dataset problem-path
                                 (or domain (evgen--resolved-domain problem-path))
                                 solution-path requested horizon true actions
                                 slices observe)))
                      (let ((h (length (evgen--hypothesis-names
                                        (let ((*read-eval* nil))
                                          (with-open-file (in problem-path) (read in)))))))
                        (format *error-output*
                                "Wrote ~a (~d observation~:p, ~d ~:[hypotheses~;hypothesis~])~%"
                                export-dataset obs h (= h 1)))))
                  (values written n horizon))))))))))

