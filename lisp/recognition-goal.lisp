;;;; recognition-goal.lisp -- read a plan-recognition problem's hypotheses from
;;;; its PDDL goal, for bin/recognize.sh.
;;;;
;;;; The hypotheses are the disjuncts of ONE (or ...) in the goal.  Each must end
;;;; up as a single ATOM, because the recognizer scores a hypothesis by clamping
;;;; (holds <atom> H) true and false:
;;;;
;;;;   (hyp0)            a nullary atom -- typically a derived predicate, as
;;;;                     make-recognition-instance.lisp writes -- used as is;
;;;;   (at truck1 p3-2)  a ground atom, used as is;
;;;;   anything else     a closed formula -- (and ...), (not ...), a quantifier
;;;;                     -- which gets a fresh DERIVED nullary predicate
;;;;                     (:derived (rechypI) <formula>), with a warning.
;;;;
;;;; With :create-atoms every hypothesis that is not already nullary gets a
;;;; derived atom.  A derived atom is defined by a biconditional, so it is
;;;; count-neutral and every cost is unchanged: the two spellings must agree.
;;;;
;;;; The goal may be (or h1 ... hn) or (and <conjuncts>), whose conjuncts may be
;;;; preferences, the ONE hypothesis set, and exclusivity clauses
;;;; (or (not hi) (not hj) ...) naming only members of the set.  Exclusivity
;;;; clauses are IGNORED -- dropped from the problem both methods score, so fast
;;;; and plan-runs agree and each hypothesis is scored on its own, as Ramirez &
;;;; Geffner do.  Anything else is an error naming what it is: a second
;;;; hypothesis set (not yet handled), a plain conjunction such as
;;;; (and (hyp0) (hyp1)) -- which reads as a goal requiring BOTH, not a choice
;;;; between them -- or another hard goal beside the set.
;;;;
;;;; Entry points, each printing to standard output for the shell to read and
;;;; reporting a user error on standard error with exit code 3:
;;;;   (rg-prepare problem domain out-dir &key create-atoms priors-from-preferences)
;;;;   (rg-single-goal base-problem atom out-file)

(defun rg--die (fmt &rest args)
  ;; Unpretty: the pretty printer would break a form across lines mid-message.
  (let ((*print-pretty* nil))
    (format *error-output* "recognize.sh: ~?~%" fmt args))
  (finish-output *error-output*)
  (sb-ext:exit :code 3 :abort t))

;;; Floats are read and written as DOUBLE-floats, the default float format bound
;;; on both sides: under the single-float default 0.123456789 read back as
;;; 0.12345679, so both methods scored a quietly altered problem.
(defun rg--read (file)
  (let ((*read-eval* nil) (*read-default-float-format* 'double-float))
    (with-open-file (in file) (read in))))

(defun rg--write (file form)
  (with-open-file (out file :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (let ((*print-case* :downcase) (*print-pretty* t) (*print-right-margin* 100)
          (*read-default-float-format* 'double-float))
      (format out "~s~%" form))))

(defun rg--head= (x name)
  (and (consp x) (symbolp (first x)) (string-equal (symbol-name (first x)) name)))

(defun rg--logical-p (sym)
  (and (symbolp sym)
       (member (symbol-name sym)
               '("AND" "OR" "NOT" "IMPLY" "FORALL" "EXISTS" "PREFERENCE" "WHEN" "=")
               :test #'string-equal)))

(defun rg--var-p (x)
  (and (symbolp x) (plusp (length (symbol-name x))) (char= (char (symbol-name x) 0) #\?)))

(defun rg--atom-p (x)
  "A ground atom: a predicate applied to constants (nullary included)."
  (and (consp x) (symbolp (first x)) (not (keywordp (first x)))
       (not (rg--logical-p (first x)))
       (every (lambda (a) (or (numberp a) (and (symbolp a) (not (rg--var-p a)))))
              (rest x))))

(defun rg--nullary-p (x) (and (rg--atom-p x) (null (rest x))))

(defun rg--free-vars (f &optional bound)
  "The ?variables of formula F not bound by an enclosing forall/exists."
  (cond ((rg--var-p f) (if (member f bound) '() (list f)))
        ((not (consp f)) '())
        ((or (rg--head= f "FORALL") (rg--head= f "EXISTS"))
         (rg--free-vars (third f) (append (remove-if-not #'rg--var-p (second f)) bound)))
        (t (remove-duplicates (loop for x in f append (rg--free-vars x bound))))))

(defun rg--section (def key)
  (find-if (lambda (s) (and (consp s) (eq (first s) key))) (cddr def)))

(defun rg--goal (def) (second (rg--section def :goal)))

(defun rg--negated-member (d set)
  "The hypothesis D negates, when D is (not h) with h in SET."
  (and (rg--head= d "NOT") (= 2 (length d)) (member (second d) set :test #'equal)
       (second d)))

(defun rg--all-negations-p (f)
  (and (rg--head= f "OR") (rest f) (every (lambda (d) (rg--head= d "NOT")) (rest f))))

(defun rg--classify (goal)
  "Return (values hypothesis-forms preferences) from GOAL, or die."
  (cond
    ((null goal) (rg--die "the problem has no goal, so there are no hypotheses"))
    ((rg--head= goal "OR") (values (rest goal) '()))
    ((rg--head= goal "AND")
     (let* ((conj (rest goal))
            (prefs (remove-if-not (lambda (x) (rg--head= x "PREFERENCE")) conj))
            (rest (remove-if (lambda (x) (rg--head= x "PREFERENCE")) conj))
            (sets (remove-if-not (lambda (x) (and (rg--head= x "OR")
                                                  (not (rg--all-negations-p x))))
                                 rest))
            (negs (remove-if-not #'rg--all-negations-p rest))
            (others (remove-if (lambda (x) (rg--head= x "OR")) rest)))
       (cond
         ((> (length sets) 1)
          (rg--die "the goal has ~d hypothesis sets:~{~%    ~(~s~)~}~%  ~
                    Recognizing more than one set of hypotheses at once is not ~
                    supported yet; give the goal ONE (or ...) of hypotheses."
                   (length sets) sets))
         ((null sets)
          (cond
            ((and (= 1 (length others)) (null negs))
             (values others prefs))     ; a single hypothesis
            ;; With no other (or ...), one whose disjuncts are all negations is
            ;; the hypothesis set itself -- exclusivity clauses only accompany a set.
            ((and (null others) (= 1 (length negs)))
             (values (rest (first negs)) prefs))
            ((and (null others) negs)
             (rg--die "the goal has ~d (or ...) forms of negated literals and no other:~
                       ~{~%    ~(~s~)~}~%  Which is the hypothesis set cannot be told ~
                       apart from exclusivity clauses; recognizing more than one set is ~
                       not supported yet."
                      (length negs) negs))
            (t
             (rg--die "the goal is a conjunction with no (or ...) of hypotheses:~%    ~
                       ~(~s~)~%  A conjunction requires ALL its parts, so its ~
                       conjuncts are not alternative hypotheses.  Write the ~
                       hypotheses as one (or ...)."
                      goal))))
         (others
          (rg--die "the goal has a hard goal beside the hypotheses:~{~%    ~(~s~)~}~%  ~
                    Other goals alongside the (or ...) of hypotheses are not ~
                    supported yet."
                   others))
         (t
          (let ((set (rest (first sets))))
            (dolist (n negs)
              (dolist (d (rest n))
                (unless (rg--negated-member d set)
                  (rg--die "the clause ~(~s~) names ~(~s~), which is not one of the ~
                            hypotheses ~(~s~).~%  Only exclusivity clauses over the ~
                            hypotheses may accompany them."
                           n (second d) (first sets)))))
            (values set prefs))))))
    (t (values (list goal) '()))))

(defun rg--atom-name (form)
  "A shell-safe name for a ground atom: (at truck1 p3-2) -> at-truck1-p3-2."
  (string-downcase (format nil "~{~a~^-~}" form)))

(defun rg--declared-names (domain-def)
  "Every predicate, derived predicate, function and action name of DOMAIN-DEF."
  (let ((names '()))
    (dolist (s (cddr domain-def) names)
      (when (consp s)
        (case (first s)
          ((:predicates :functions)
           (dolist (p (rest s)) (when (consp p) (push (symbol-name (first p)) names))))
          (:derived (when (consp (second s)) (push (symbol-name (first (second s))) names)))
          (:action (push (symbol-name (second s)) names)))))))

(defun rg--add-requirements (domain-def reqs)
  (let ((found nil))
    (let ((sections
            (mapcar (lambda (s)
                      (if (and (consp s) (eq (first s) :requirements))
                          (progn (setf found t)
                                 (append s (remove-if (lambda (r) (member r (rest s))) reqs)))
                          s))
                    (cddr domain-def))))
      (list* (first domain-def) (second domain-def)
             (if found sections (cons (cons :requirements reqs) sections))))))

(defun rg--pref-weight (pref)
  "The violation weight of (preference name body w) or (... body :odds r), or NIL."
  (let ((w (fourth pref)))
    (cond ((realp w) w)
          ((eq w :odds)
           (let ((r (fifth pref)))
             (unless (and (realp r) (> r 0))
               (rg--die ":odds of preference ~(~a~) must be a positive real, got ~(~s~)"
                        (second pref) r))
             (log (float r 1d0))))
          (t nil))))

(defun rg-prepare (problem domain out-dir &key create-atoms priors-from-preferences)
  "Classify PROBLEM's goal and write OUT-DIR/rec-problem-base.pddl -- the goal
reduced to (or <atom> ...) plus its preferences, exclusivity clauses dropped --
and, when any hypothesis needs a derived atom, OUT-DIR/rec-domain.pddl.  Prints
PROBLEM, DOMAIN, then HYP <name> <atom> lines in goal order and PRIOR <name> <w>
lines, tab separated."
  (let* ((pdef (rg--read problem))
         (ddef (rg--read domain))
         (taken (rg--declared-names ddef)))
    (multiple-value-bind (forms prefs) (rg--classify (rg--goal pdef))
      (let ((dup (find-if (lambda (f) (> (count f forms :test #'equal) 1)) forms)))
        (when dup (rg--die "hypothesis ~(~s~) appears twice in the goal" dup)))
      (dolist (f forms)
        (let ((free (rg--free-vars f)))
          (when free
            (rg--die "hypothesis ~(~s~) has free variable~p ~{~(~a~)~^, ~}: a ~
                      hypothesis must be a closed formula"
                     f (length free) free))))
      ;; A fresh prefix for created atoms, clear of every name already in use.
      (let* ((prefix (loop for p = "rechyp" then (concatenate 'string p "x")
                           unless (loop for i below (length forms)
                                        thereis (member (format nil "~a~d" p i) taken
                                                        :test #'string-equal))
                             return p))
             (rules '()) (hyps '()) (base-dir (pathname out-dir)))
        (loop for f in forms for i from 0
              do (let* ((need (and (not (rg--nullary-p f))
                                   (or create-atoms (not (rg--atom-p f)))))
                        (atom (if need
                                  (list (intern (string-upcase (format nil "~a~d" prefix i))))
                                  f))
                        (name (cond ((rg--atom-p f) (rg--atom-name f))
                                    (t (string-downcase (symbol-name (first atom)))))))
                   (when need
                     (push `(:derived ,atom ,f) rules)
                     (let ((*print-pretty* nil))
                       (if (rg--atom-p f)
                           (format *error-output* "; ~(~s~) -> derived atom ~(~s~) ~
                                                   (--create-hypothesis-atoms)~%" f atom)
                           (format *error-output* "recognize.sh: WARNING: hypothesis ~(~s~) ~
                                                   is not a single atom; scoring it through ~
                                                   the derived atom ~(~s~)~%" f atom))))
                   (push (list name atom f) hyps)))
        (setf hyps (nreverse hyps) rules (nreverse rules))
        ;; Report names must be distinct: they are used for priors and file names.
        ;; A renamed hypothesis takes the first free suffix: a fixed one could
        ;; collide with a name already used, e.g. (on-a-b 3) next to (on-a b).
        (let ((seen (make-hash-table :test #'equal)))
          (dolist (h hyps)
            (when (gethash (first h) seen)
              (setf (first h) (loop for k from 2
                                    for c = (format nil "~a-~d" (first h) k)
                                    unless (or (gethash c seen)
                                               (find c hyps :key #'first :test #'string=))
                                      return c)))
            (setf (gethash (first h) seen) t)))
        ;; Preferences on a hypothesis become its prior under --priors-from-preferences.
        (let ((priors '()) (kept '()))
          (dolist (p prefs)
            (let ((h (and priors-from-preferences
                          (find-if (lambda (h) (or (equal (third p) (third h))
                                                   (equal (third p) (second h))))
                                   hyps))))
              (if h
                  (let ((w (rg--pref-weight p)))
                    (unless w
                      (rg--die "preference ~(~a~) on ~(~s~) has no inline weight;~%  ~
                                give one, e.g. (preference ~(~a~) ~(~s~) 2) or ~
                                (preference ~(~a~) ~(~s~) :odds 2) -- the :metric ~
                                route is not read here"
                               (second p) (third p) (second p) (third p)
                               (second p) (third p)))
                    ;; Violation penalties ADD, so several preferences on one
                    ;; hypothesis give the prior exp(w1 + w2 + ...).
                    (let ((cell (assoc (first h) priors :test #'string=)))
                      (if cell
                          (incf (second cell) w)
                          (push (list (first h) w) priors))))
                  (push p kept))))
          (setf priors (nreverse priors) kept (nreverse kept))
          (let* ((atoms (mapcar #'second hyps))
                 (set (if (rest atoms) (cons 'or atoms) (first atoms)))
                 (goal (if kept (list* 'and set kept) set))
                 (base (merge-pathnames "rec-problem-base.pddl" base-dir))
                 (dom (and rules (merge-pathnames "rec-domain.pddl" base-dir))))
            (rg--write base (list* (first pdef) (second pdef)
                                   (mapcar (lambda (s)
                                             (if (and (consp s) (eq (first s) :goal))
                                                 (list :goal goal)
                                                 s))
                                           (cddr pdef))))
            (when dom
              (rg--write dom (append (rg--add-requirements
                                      ddef '(:derived-predicates :disjunctive-preconditions))
                                     rules)))
            (format t "PROBLEM~c~a~%DOMAIN~c~a~%" #\Tab (namestring base) #\Tab
                    (if dom (namestring dom) "-"))
            (let ((*print-case* :downcase) (*print-pretty* nil))
              (dolist (h hyps) (format t "HYP~c~a~c~s~%" #\Tab (first h) #\Tab (second h)))
              (let ((*read-default-float-format* (quote double-float)))
                ;; a plain decimal: a ratio such as 1/3 printed as text that awk misreads
                (dolist (p priors) (format t "PRIOR~c~a~c~a~%" #\Tab (first p) #\Tab
                                           (float (second p) 1d0)))))))))))

(defun rg-single-goal (base atom-text out)
  "Write OUT: BASE (as rg-prepare wrote it) with its (or ...) of hypotheses
replaced by the one hypothesis atom ATOM-TEXT, its preferences kept."
  (let* ((pdef (rg--read base))
         (atom (let ((*read-eval* nil) (*read-default-float-format* 'double-float))
                 (read-from-string atom-text)))
         (goal (rg--goal pdef))
         (new (cond ((rg--head= goal "OR") atom)
                    ((and (rg--head= goal "AND") (rg--head= (second goal) "OR"))
                     (list* 'and atom (cddr goal)))
                    (t goal))))
    (rg--write out (list* (first pdef) (second pdef)
                          (mapcar (lambda (s)
                                    (if (and (consp s) (eq (first s) :goal))
                                        (list :goal new)
                                        s))
                                  (cddr pdef))))))
