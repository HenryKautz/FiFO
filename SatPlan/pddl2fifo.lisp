;;;; pddl2fifo.lisp -- Translate PDDL planning problems into FiFO SatPlan encodings.
;;;;
;;;; Supported PDDL requirements:
;;;;   :strips                  basic STRIPS actions
;;;;   :typing                  typed parameters, objects, constants, and
;;;;                            (:types ...) hierarchies
;;;;   :negative-preconditions  (not <atom>) in action preconditions and goals
;;;;   :action-costs            simple static costs only, i.e. effects of the
;;;;                            form (increase (total-cost) <number>)
;;;;
;;;; Usage from the shell:
;;;;   sbcl --script pddl2fifo.lisp <problem.pddl> [<domain.pddl>]
;;;;
;;;; Usage from a Lisp listener:
;;;;   (load "pddl2fifo.lisp")
;;;;   (pddl2fifo "<problem.pddl>")
;;;;   (pddl2fifo "<problem.pddl>" :domain-file "<domain.pddl>")
;;;;
;;;; If the domain file is not given, the root of its file name is taken from
;;;; the (:domain <name>) form in the problem file, and <name>.pddl is looked
;;;; up in the directory of the problem file.
;;;;
;;;; The translation is written to <problem-root>.wff in the directory of the
;;;; problem file.  Each PDDL type becomes a FiFO domain containing the objects
;;;; of that type or any of its subtypes; untyped parameters and objects fall
;;;; back to the universal domain "objects".  The output defines the domains
;;;; required by the domain-independent SatPlan axioms and ends with
;;;; (include "satplan.wff"); see SatPlan/logistics-with-collect.wff for an
;;;; example of the output form.

(defparameter *supported-requirements*
  '(:strips :typing :negative-preconditions :action-costs))

(defparameter *reserved-domain-names*
  '("OBJECTS" "ACTIONS" "FLUENTS" "COSTS" "SLICES" "ACTSLICES"
    "INITIAL-STATE" "GOAL-STATE" "NEGATIVE-GOAL-STATE" "NUMSLICES")
  "Domain names used by the generated encoding and satplan.wff; PDDL types may not collide with these.")

;;; PDDL reading and access helpers

(defun sym-name= (x name)
  (and (symbolp x) (string-equal (symbol-name x) name)))

(defun read-pddl-file (path)
  (with-open-file (in path :direction :input)
    (let ((*read-eval* nil))
      (loop for form = (read in nil in)
            until (eq form in)
            collect form))))

(defun find-define (forms kind path)
  (or (find-if (lambda (f)
                 (and (consp f)
                      (sym-name= (first f) "DEFINE")
                      (consp (second f))
                      (sym-name= (first (second f)) kind)))
               forms)
      (error "No (define (~(~a~) ...) ...) form found in ~a" kind path)))

(defun define-name (def) (second (second def)))

(defun define-sections (def) (cddr def))

(defun get-section (def key)
  (find-if (lambda (s) (and (consp s) (eq (first s) key)))
           (define-sections def)))

(defun check-requirements (domain-def)
  (dolist (r (rest (get-section domain-def :requirements)))
    (unless (member r *supported-requirements*)
      (error "Unsupported PDDL requirement ~s; supported requirements are ~{~s~^, ~}"
             r *supported-requirements*))))

;;; Typed lists and the type hierarchy

(defun parse-typed-list (lst context)
  "Parse a PDDL typed list (x y - t1 z - t2 w ...) into an alist
((x . t1) (y . t1) (z . t2) (w . object) ...).  Items left untyped
get the universal type OBJECT."
  (let ((pairs '()) (pending '()))
    (loop while lst do
      (let ((x (pop lst)))
        (cond ((sym-name= x "-")
               (let ((type (pop lst)))
                 (unless (and type (symbolp type))
                   (error "Expected a type name after '-' in ~a; got ~s" context type))
                 (dolist (p (nreverse pending)) (push (cons p type) pairs))
                 (setq pending '())))
              (t (push x pending)))))
    (dolist (p (nreverse pending)) (push (cons p 'object) pairs))
    (nreverse pairs)))

(defun parse-types (domain-def)
  "Parse the (:types ...) section into an alist mapping each type to its
supertype.  Supertypes that are not themselves declared default to OBJECT."
  (let ((pairs (parse-typed-list (rest (get-section domain-def :types)) ":types")))
    (dolist (p pairs)
      (let ((super (cdr p)))
        (unless (or (sym-name= super "OBJECT")
                    (assoc super pairs :test #'string-equal))
          (push (cons super 'object) pairs))))
    pairs))

(defun type-supertype (type type-table)
  (cond ((sym-name= type "OBJECT") nil)
        ((cdr (assoc type type-table :test #'string-equal)))
        (t 'object)))

(defun subtype-p (type ancestor type-table)
  "True if TYPE equals ANCESTOR or reaches it by following supertypes."
  (loop with seen = '()
        for tp = type then (type-supertype tp type-table)
        while tp
        when (string-equal (string tp) (string ancestor)) return t
        when (member tp seen :test #'string-equal) return nil
        do (push tp seen)))

(defun objects-of-type (type object-pairs type-table)
  "All objects whose declared type is TYPE or one of its subtypes."
  (loop for (obj . tp) in object-pairs
        when (subtype-p tp type type-table)
          collect obj))

(defun type-domain-name (type)
  "FiFO domain name for a PDDL type; the universal type maps to OBJECTS."
  (if (sym-name= type "OBJECT") 'objects type))

;;; Formula helpers

(defun conjuncts (form)
  (cond ((null form) nil)
        ((and (consp form) (sym-name= (first form) "AND")) (rest form))
        (t (list form))))

(defun negation-p (form)
  (and (consp form) (sym-name= (first form) "NOT")))

(defun pddl-variable-p (x)
  (and (symbolp x)
       (plusp (length (symbol-name x)))
       (char= (char (symbol-name x) 0) #\?)))

(defun fifo-variable (var forbidden)
  ;; ?pk -> pk, renaming if the result would capture an object constant,
  ;; a type name, or a reserved domain name
  (let ((name (subseq (symbol-name var) 1)))
    (loop while (find name forbidden :test #'string-equal :key #'string)
          do (setq name (concatenate 'string name "-V")))
    (intern (string-upcase name))))

(defun substitute-terms (form bindings action-name)
  (cond ((consp form)
         (cons (substitute-terms (car form) bindings action-name)
               (substitute-terms (cdr form) bindings action-name)))
        ((pddl-variable-p form)
         (or (cdr (assoc form bindings))
             (error "Variable ~s in action ~a is not a parameter" form action-name)))
        (t form)))

(defun wrap-quantifiers (pairs body)
  "Wrap BODY in nested (all ...) quantifiers, one per (var . domain) pair,
grouping consecutive parameters that share a domain."
  (if (null pairs)
      body
      (let* ((dom (cdr (first pairs)))
             (group (loop for p in pairs
                          while (string-equal (string (cdr p)) (string dom))
                          collect (car p)))
             (inner (wrap-quantifiers (nthcdr (length group) pairs) body)))
        (if (rest group)
            (list 'all group dom 'true inner)
            (list 'all (first group) dom 'true inner)))))

;;; Translation

(defun translate-action (action-form forbidden)
  "Translate one (:action ...) form into an observed FiFO formula.
Returns (values formula has-negative-preconditions-p parameter-types)."
  (destructuring-bind (key name &rest body) action-form
    (declare (ignore key))
    (let* ((param-pairs (parse-typed-list (getf body :parameters)
                                          (format nil "parameters of action ~a" name)))
           (precondition (getf body :precondition))
           (effect (getf body :effect))
           (bindings
             (mapcar (lambda (p)
                       (unless (pddl-variable-p (car p))
                         (error "Parameter ~s of action ~a is not a ?variable" (car p) name))
                       (unless (and (cdr p) (symbolp (cdr p)))
                         (error "Unsupported type ~s for parameter ~s of action ~a"
                                (cdr p) (car p) name))
                       (cons (car p) (fifo-variable (car p) forbidden)))
                     param-pairs))
           (vars (mapcar #'cdr bindings))
           (act (if vars (cons name vars) name))
           (pre+ '()) (pre- '()) (adds '()) (dels '()) (cost nil))
      (dolist (p (conjuncts precondition))
        (cond ((negation-p p)
               (push (substitute-terms (second p) bindings name) pre-))
              ((consp p)
               (push (substitute-terms p bindings name) pre+))
              (t (error "Cannot translate precondition ~s of action ~a" p name))))
      (dolist (e (conjuncts effect))
        (cond ((and (consp e) (sym-name= (first e) "INCREASE"))
               (unless (numberp (third e))
                 (error "Only simple static action costs are supported; got ~s in action ~a"
                        e name))
               (when cost
                 (error "Action ~a has more than one cost effect" name))
               (setq cost (third e)))
              ((negation-p e)
               (push (substitute-terms (second e) bindings name) dels))
              ((consp e)
               (push (substitute-terms e bindings name) adds))
              (t (error "Cannot translate effect ~s of action ~a" e name))))
      (unless (or adds dels)
        (error "Action ~a has no add or delete effects" name))
      (let* ((negp (consp pre-))
             (facts (append
                      (mapcar (lambda (f) (list 'pre act f)) (nreverse pre+))
                      (mapcar (lambda (f) (list 'preneg act f)) (nreverse pre-))
                      (mapcar (lambda (f) (list 'add act f)) (nreverse adds))
                      (mapcar (lambda (f) (list 'del act f)) (nreverse dels))
                      (when cost (list (list 'cost act cost)))))
             (conj (if (rest facts) (cons 'and facts) (first facts)))
             (quants (mapcar (lambda (b p)
                               (cons (cdr b) (type-domain-name (cdr p))))
                             bindings param-pairs)))
        (values (wrap-quantifiers quants conj)
                negp
                (mapcar #'cdr param-pairs))))))

(defun parse-problem (problem-def)
  "Returns (values domain-name object-pairs init goal+ goal-), where
object-pairs is an alist of (object . type)."
  (let ((object-pairs (parse-typed-list (rest (get-section problem-def :objects))
                                        ":objects"))
        (init-section (rest (get-section problem-def :init)))
        (goal (second (get-section problem-def :goal)))
        (domain-name (second (get-section problem-def :domain)))
        (init '()) (goal+ '()) (goal- '()))
    (dolist (f init-section)
      (cond ((and (consp f) (sym-name= (first f) "="))
             nil)                  ; function initialization, e.g. (= (total-cost) 0)
            ((negation-p f)
             nil)                  ; redundant under the closed-world assumption
            ((consp f) (push f init))
            (t (error "Cannot translate init fact ~s" f))))
    (dolist (g (conjuncts goal))
      (cond ((negation-p g) (push (second g) goal-))
            ((consp g) (push g goal+))
            (t (error "Cannot translate goal ~s" g))))
    (values domain-name object-pairs (nreverse init) (nreverse goal+) (nreverse goal-))))

;;; Output

(defun nested-union (set-expressions)
  (if (rest set-expressions)
      (list 'union (first set-expressions) (nested-union (rest set-expressions)))
      (first set-expressions)))

(defun write-form (out form)
  (let ((*print-case* :downcase)
        (*print-pretty* t)
        (*print-right-margin* 80))
    (write form :stream out))
  (terpri out))

(defun pddl2fifo (problem-file &key domain-file (satplan-path "satplan.wff"))
  "Translate the PDDL PROBLEM-FILE (and its domain) into a FiFO wff file.
SATPLAN-PATH is the path written into the generated (include ...) form for the
domain-independent SatPlan axioms; it is resolved relative to the directory of
the generated wff, so use e.g. \"../satplan.wff\" when the problem lives in a
subdirectory below satplan.wff.  Returns the pathname of the wff file written."
  (let* ((problem-path (pathname problem-file))
         (problem-def (find-define (read-pddl-file problem-path) "PROBLEM" problem-path)))
    (multiple-value-bind (domain-name object-pairs init goal+ goal-)
        (parse-problem problem-def)
      (unless (or domain-file domain-name)
        (error "No domain file given and no (:domain ...) form in ~a" problem-path))
      (let* ((domain-path (if domain-file
                              (pathname domain-file)
                              (merge-pathnames
                                (make-pathname :name (string-downcase (symbol-name domain-name))
                                               :type "pddl")
                                problem-path)))
             (domain-def (find-define (read-pddl-file domain-path) "DOMAIN" domain-path))
             (constant-pairs (parse-typed-list (rest (get-section domain-def :constants))
                                               ":constants"))
             (type-table (parse-types domain-def))
             (out-path (merge-pathnames (make-pathname :type "wff") problem-path)))
        (check-requirements domain-def)
        (when (and domain-name
                   (not (sym-name= (define-name domain-def) (symbol-name domain-name))))
          (warn "Problem requires domain ~a but ~a defines domain ~a"
                domain-name domain-path (define-name domain-def)))
        (let* ((all-object-pairs (append object-pairs constant-pairs))
               (all-objects (mapcar #'car all-object-pairs))
               (forbidden (append all-objects
                                  (mapcar #'car type-table)
                                  *reserved-domain-names*))
               (types-used '())
               (action-forms '())
               (any-neg-pre nil))
          (unless all-objects
            (error "No objects: ~a has no :objects and ~a has no :constants"
                   problem-path domain-path))
          (dolist (p all-object-pairs)
            (pushnew (cdr p) types-used :test #'string-equal))
          (dolist (p type-table)
            (pushnew (car p) types-used :test #'string-equal))
          (dolist (s (define-sections domain-def))
            (when (and (consp s) (eq (first s) :action))
              (multiple-value-bind (form negp param-types)
                  (translate-action s forbidden)
                (push form action-forms)
                (when negp (setq any-neg-pre t))
                (dolist (tp param-types)
                  (pushnew tp types-used :test #'string-equal)))))
          (setq action-forms (nreverse action-forms))
          (unless action-forms
            (error "Domain file ~a defines no actions" domain-path))
          (let ((named-types (sort (remove-if (lambda (tp) (sym-name= tp "OBJECT"))
                                              types-used)
                                   #'string-lessp :key #'string)))
            (dolist (tp named-types)
              (when (member (string tp) *reserved-domain-names* :test #'string-equal)
                (error "PDDL type ~a collides with a reserved FiFO domain name" tp)))
            (with-open-file (out out-path :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
              (format out ";; FiFO SatPlan encoding generated by pddl2fifo~%")
              (format out ";; Problem ~(~a~) from ~a~%"
                      (define-name problem-def) (file-namestring problem-path))
              (format out ";; Domain ~(~a~) from ~a~%~%"
                      (define-name domain-def) (file-namestring domain-path))
              (format out ";; Time horizon -- numslices is taken from the Lisp variable~%")
              (format out ";; *satplan-numslices* when it is bound to an integer, else 2.~%")
              (write-form out
                          '(alias numslices
                            (lisp (if (and (boundp '*satplan-numslices*)
                                           (integerp (symbol-value '*satplan-numslices*)))
                                      (symbol-value '*satplan-numslices*)
                                      2))))
              (write-form out '(domain slices (range 1 numslices)))
              (write-form out '(domain actslices (range 1 (- numslices 1))))
              (terpri out)
              (format out ";; Objects~%")
              (write-form out `(domain objects (set ,@all-objects)))
              (when named-types
                (terpri out)
                (format out ";; Type domains~%")
                (dolist (tp named-types)
                  (let ((members (objects-of-type tp all-object-pairs type-table)))
                    (write-form out
                      (if members
                          `(domain ,tp (set ,@members))
                          ;; FiFO sets cannot be literally empty
                          `(domain ,tp (set-difference objects objects)))))))
              (terpri out)
              (format out ";; Action preconditions, effects, and costs~%")
              (write-form out `(observed ,@action-forms))
              (terpri out)
              (format out ";; Initial and goal states~%")
              (when init
                (write-form out `(domain initial-state (set ,@init))))
              (when goal+
                (write-form out `(domain goal-state (set ,@goal+))))
              (when goal-
                (write-form out `(domain negative-goal-state (set ,@goal-))))
              (terpri out)
              (format out ";; Domains derived from the observed action schemas~%")
              (write-form out
                `(domain actions
                   ,(nested-union
                      (append '((collect a (pre a *)))
                              (when any-neg-pre '((collect a (preneg a *))))
                              '((collect a (add a *))
                                (collect a (del a *)))))))
              (write-form out
                `(domain fluents
                   ,(nested-union
                      (append '((collect f (pre * f)))
                              (when any-neg-pre '((collect f (preneg * f))))
                              '((collect f (add * f))
                                (collect f (del * f)))
                              (when init '(initial-state))
                              (when goal+ '(goal-state))
                              (when goal- '(negative-goal-state))))))
              (write-form out '(domain costs (collect c (cost * c))))
              ;; FiFO sets cannot be literally empty, so an empty initial or
              ;; positive goal state becomes the difference of a domain with itself.
              (unless init
                (write-form out '(domain initial-state (set-difference fluents fluents))))
              (unless goal+
                (write-form out '(domain goal-state (set-difference fluents fluents))))
              (when goal-
                (terpri out)
                (format out ";; Negative goals~%")
                (write-form out
                  '(all f negative-goal-state true (not (holds f numslices)))))
              (terpri out)
              (write-form out (list 'include satplan-path))))
          (format t "Wrote ~a~%" (namestring out-path))
          out-path)))))

;;; Command-line entry point.  Under "sbcl --script pddl2fifo.lisp args..."
;;; the remaining argv entries are the program arguments; under "sbcl --load"
;;; they are sbcl options starting with "-", in which case do nothing.
#+sbcl
(let ((args (rest sb-ext:*posix-argv*)))
  (when (and args
             (every (lambda (a)
                      (and (plusp (length a)) (char/= (char a 0) #\-)))
                    args))
    (if (<= 1 (length args) 2)
        (handler-case (if (second args)
                          (pddl2fifo (first args) :domain-file (second args))
                          (pddl2fifo (first args)))
          (error (e)
            (format *error-output* "pddl2fifo: ~a~%" e)
            (sb-ext:exit :code 1)))
        (progn
          (format *error-output*
                  "usage: sbcl --script pddl2fifo.lisp <problem.pddl> [<domain.pddl>]~%")
          (sb-ext:exit :code 1)))))
