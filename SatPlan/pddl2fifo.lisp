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
  '(:strips :typing :negative-preconditions :disjunctive-preconditions :action-costs))

(defparameter *reserved-domain-names*
  '("OBJECTS" "ACTIONS" "FLUENTS" "COSTS" "SLICES" "ACTSLICES"
    "INITIAL-STATE" "GOAL-STATE" "NEGATIVE-GOAL-STATE" "GOAL-FLUENTS" "NUMSLICES")
  "Domain names used by the generated encoding and satplan.wff; PDDL types may not collide with these.")

(defparameter *static-dummy* 'pddl2fifo-static-dummy
  "A constant that appears in no object/type domain, used to register a static
observed predicate even when it has no true instances.  Like satplan.wff's dummy
facts, such a dummy fact generates no clauses.")

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
                 (unless (and type
                              (or (symbolp type)
                                  (and (consp type) (sym-name= (first type) "EITHER"))))
                   (error "Expected a type name or (either ...) after '-' in ~a; got ~s"
                          context type))
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

(defun either-type-p (type)
  "True if TYPE is a disjunctive (either t1 t2 ...) PDDL type."
  (and (consp type) (sym-name= (first type) "EITHER")))

(defun type-components (type)
  "The member types of an (either ...) type, or the type itself as a singleton."
  (if (either-type-p type) (rest type) (list type)))

(defun object-has-type-p (declared-type query-type type-table)
  "True if an object DECLARED with DECLARED-TYPE (a type name or an
(either ...) type) is of QUERY-TYPE -- i.e. some component of the declared
type is QUERY-TYPE or one of its subtypes."
  (some (lambda (component) (subtype-p component query-type type-table))
        (type-components declared-type)))

(defun objects-of-type (type object-pairs type-table)
  "All objects whose declared type is TYPE, one of its subtypes, or an
(either ...) type that includes such a type."
  (loop for (obj . tp) in object-pairs
        when (object-has-type-p tp type type-table)
          collect obj))

(defun type-domain-name (type)
  "FiFO domain name for a PDDL type; the universal type maps to OBJECTS."
  (if (sym-name= type "OBJECT") 'objects type))

(defun nested-union (set-expressions)
  (if (rest set-expressions)
      (list 'union (first set-expressions) (nested-union (rest set-expressions)))
      (first set-expressions)))

(defun type-set-expression (type)
  "FiFO set expression for a PDDL type: a domain name for a simple type, or a
(union ...) of the member domains for an (either ...) type."
  (if (either-type-p type)
      (nested-union (mapcar #'type-domain-name (rest type)))
      (type-domain-name type)))

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
                          while (equal (cdr p) dom)
                          collect (car p)))
             (inner (wrap-quantifiers (nthcdr (length group) pairs) body)))
        (if (rest group)
            (list 'all group dom 'true inner)
            (list 'all (first group) dom 'true inner)))))

;;; Static predicates
;;;
;;; A predicate that never appears in any action's add or delete effect is
;;; static: its truth value is fixed by the initial state.  Such a predicate is
;;; turned into an observed predicate -- its positive instances are asserted as
;;; observations (from the initial state) and its preconditions become an
;;; instantiation-time guard rather than time-indexed Holds fluents.

(defun action-effect-predicates (action-form)
  "Predicate names appearing in the add/delete effects of ACTION-FORM."
  (let ((effect (getf (cddr action-form) :effect)) (preds '()))
    (dolist (e (conjuncts effect) preds)
      (cond ((and (consp e) (sym-name= (first e) "INCREASE")) nil)
            ((and (negation-p e) (consp (second e)))
             (pushnew (first (second e)) preds :test #'sym-name=))
            ((consp e)
             (pushnew (first e) preds :test #'sym-name=))))))

(defun collect-effect-predicates (domain-def)
  "All predicate names that appear in some action's add or delete effect."
  (let ((preds '()))
    (dolist (s (define-sections domain-def) preds)
      (when (and (consp s) (eq (first s) :action))
        (dolist (p (action-effect-predicates s))
          (pushnew p preds :test #'sym-name=))))))

(defun static-predicate-p (name effect-preds)
  "True if NAME never appears in an add/delete effect (so it is static)."
  (not (member name effect-preds :test #'sym-name=)))

(defun collect-static-predicate-arities (domain-def effect-preds)
  "Alist (predicate-name . arity) for the static predicates that appear in some
action precondition."
  (let ((arities '()))
    (dolist (s (define-sections domain-def) arities)
      (when (and (consp s) (eq (first s) :action))
        (dolist (p (conjuncts (getf (cddr s) :precondition)))
          (let ((atom (if (negation-p p) (second p) p)))
            (when (and (consp atom) (static-predicate-p (first atom) effect-preds))
              (unless (assoc (first atom) arities :test #'sym-name=)
                (push (cons (first atom) (length (rest atom))) arities)))))))))

;;; Reachability analysis
;;;
;;; A relaxed planning-graph analysis gives a lower bound on the number of time
;;; slices a plan needs.  Ignoring delete effects and negative preconditions
;;; (both of which only make more reachable), build successive fluent layers:
;;; layer 0 is the initial state; each next layer adds the add-effects of every
;;; ground action whose positive preconditions hold in the current layer.  The
;;; first layer at which all positive goals appear is a lower bound on the
;;; parallel plan length, so numslices >= that layer + 1.  If the goals never
;;; appear (the layers reach a fixpoint without them), even the relaxed problem
;;; is unsolvable, hence so is the real one.

(defun reachability-cartesian (lists)
  "All tuples drawing one element from each list in LISTS."
  (if (null lists)
      (list '())
      (let ((rest (reachability-cartesian (cdr lists))))
        (mapcan (lambda (x) (mapcar (lambda (r) (cons x r)) rest)) (car lists)))))

(defun reachability-param-objects (type object-pairs type-table)
  "Objects that can fill a parameter of TYPE (a type name or an (either ...))."
  (if (either-type-p type)
      (remove-duplicates
        (mapcan (lambda (tc) (copy-list (objects-of-type tc object-pairs type-table)))
                (rest type))
        :test #'equal)
      (objects-of-type type object-pairs type-table)))

(defun reachability-ground-substitute (form bindings)
  "Replace each PDDL ?variable in FORM by its object in the BINDINGS alist."
  (cond ((pddl-variable-p form) (or (cdr (assoc form bindings)) form))
        ((consp form) (mapcar (lambda (x) (reachability-ground-substitute x bindings)) form))
        (t form)))

(defun action-relaxed-parts (action-form)
  "For the relaxed analysis, return (values params positive-preconditions
add-effects) of ACTION-FORM, dropping negative preconditions, deletes, and
costs."
  (destructuring-bind (key name &rest body) action-form
    (declare (ignore key name))
    (let ((params (parse-typed-list (getf body :parameters) "reachability parameters"))
          (prep '()) (adds '()))
      (dolist (p (conjuncts (getf body :precondition)))
        (when (and (consp p) (not (negation-p p)))
          (push p prep)))
      (dolist (e (conjuncts (getf body :effect)))
        (cond ((and (consp e) (sym-name= (first e) "INCREASE")) nil)
              ((negation-p e) nil)
              ((consp e) (push e adds))))
      (values params (nreverse prep) (nreverse adds)))))

(defun relaxed-ground-actions (domain-def object-pairs type-table)
  "All ground actions for the relaxed analysis, each as (positive-preconditions
. add-effects) with parameters replaced by objects."
  (let ((result '()))
    (dolist (s (define-sections domain-def) result)
      (when (and (consp s) (eq (first s) :action))
        (multiple-value-bind (params prep adds) (action-relaxed-parts s)
          (dolist (binding (mapcar (lambda (tuple) (mapcar #'cons (mapcar #'car params) tuple))
                                   (reachability-cartesian
                                     (mapcar (lambda (p)
                                               (reachability-param-objects (cdr p) object-pairs type-table))
                                             params))))
            (push (cons (mapcar (lambda (a) (reachability-ground-substitute a binding)) prep)
                        (mapcar (lambda (a) (reachability-ground-substitute a binding)) adds))
                  result)))))))

;;; Goals
;;;
;;; A goal description is a literal (an atom or (not atom)) or a combination with
;;; and / or / not / imply.  A "simple" goal -- a conjunction of literals -- is
;;; handled by the goal-state / negative-goal-state domains; anything using or or
;;; imply (or nesting) is emitted as a direct FiFO formula instead.

(defun goal-connective-p (sym)
  (and (symbolp sym)
       (member sym '("AND" "OR" "NOT" "IMPLY" "FORALL" "EXISTS") :test #'sym-name=)))

(defun goal-atom-p (g)
  "True if G is an atomic goal (a predicate application, not a connective)."
  (and (consp g) (not (goal-connective-p (first g)))))

(defun goal-literal-p (g)
  (if (negation-p g) (goal-atom-p (second g)) (goal-atom-p g)))

(defun simple-goal-p (g)
  "True if G is a conjunction of literals (the goal-state/negative-goal-state form)."
  (cond ((null g) t)
        ((and (consp g) (sym-name= (first g) "AND")) (every #'goal-literal-p (rest g)))
        (t (goal-literal-p g))))

(defun collect-goal-fluents (g)
  "All atomic fluents appearing anywhere in goal G (regardless of polarity)."
  (cond ((null g) '())
        ((negation-p g) (collect-goal-fluents (second g)))
        ((and (consp g) (or (sym-name= (first g) "AND")
                            (sym-name= (first g) "OR")
                            (sym-name= (first g) "IMPLY")))
         (remove-duplicates (mapcan #'collect-goal-fluents (rest g)) :test #'equal))
        ((consp g) (list g))
        (t '())))

(defun translate-goal-formula (g)
  "Translate a PDDL goal description G into a FiFO formula asserting it at the
final time slice: atoms become (holds <atom> numslices), with and/or/not/imply
mapped to the FiFO connectives."
  (cond ((negation-p g) (list 'not (translate-goal-formula (second g))))
        ((and (consp g) (sym-name= (first g) "AND"))
         (cons 'and (mapcar #'translate-goal-formula (rest g))))
        ((and (consp g) (sym-name= (first g) "OR"))
         (cons 'or (mapcar #'translate-goal-formula (rest g))))
        ((and (consp g) (sym-name= (first g) "IMPLY"))
         (list 'implies (translate-goal-formula (second g)) (translate-goal-formula (third g))))
        ((consp g) (list 'holds g 'numslices))
        (t (error "Cannot translate goal ~s" g))))

(defun goal-satisfiable-relaxed-p (g reachable)
  "Whether goal G can be satisfied given the REACHABLE atom set, for the relaxed
reachability analysis.  Negative and implicative subgoals are treated
optimistically (assumed satisfiable), which keeps the resulting bound admissible."
  (cond ((null g) t)
        ((negation-p g) t)
        ((and (consp g) (sym-name= (first g) "AND"))
         (every (lambda (x) (goal-satisfiable-relaxed-p x reachable)) (rest g)))
        ((and (consp g) (sym-name= (first g) "OR"))
         (some (lambda (x) (goal-satisfiable-relaxed-p x reachable)) (rest g)))
        ((and (consp g) (sym-name= (first g) "IMPLY")) t)
        ((consp g) (gethash g reachable))
        (t t)))

(defun reachable-min-slices (domain-def object-pairs type-table init goal)
  "Lower bound on numslices from relaxed planning-graph reachability.  GOAL is the
raw goal description (so disjunctive goals are handled: a disjunct that becomes
satisfiable earlier lowers the bound).  Returns an integer >= 2, or :unreachable
if the goal is unreachable even in the relaxation (so the problem is unsolvable)."
  (let ((actions (relaxed-ground-actions domain-def object-pairs type-table))
        (reachable (make-hash-table :test #'equal))
        (level 0))
    (dolist (f init) (setf (gethash f reachable) t))
    (loop
      (when (goal-satisfiable-relaxed-p goal reachable)
        (return (max 2 (1+ level))))
      (let ((changed nil))
        (dolist (ga actions)
          (when (every (lambda (p) (gethash p reachable)) (car ga))
            (dolist (a (cdr ga))
              (unless (gethash a reachable)
                (setf (gethash a reachable) t)
                (setq changed t)))))
        (unless changed (return :unreachable))
        (incf level)))))

;;; Translation

(defun disjunctive-precondition-p (p)
  "True if precondition P is a disjunction, implication, or quantifier (or a
negation of one) -- anything beyond a possibly-negated atom.  pddl2fifo accepts
:disjunctive-preconditions only in the problem :goal, not in action
preconditions, so these are rejected with an explanatory error."
  (flet ((complex-head (f)
           (and (consp f)
                (member (first f) '("OR" "IMPLY" "FORALL" "EXISTS")
                        :test #'sym-name=))))
    (or (complex-head p)
        (and (negation-p p) (complex-head (second p))))))

(defun translate-action (action-form forbidden effect-preds)
  "Translate one (:action ...) form into an observed FiFO formula.  Preconditions
on static predicates (those not in EFFECT-PREDS) become an (if ...) guard rather
than Pre/PreNeg facts.
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
                       (unless (and (cdr p)
                                    (or (symbolp (cdr p)) (either-type-p (cdr p))))
                         (error "Unsupported type ~s for parameter ~s of action ~a"
                                (cdr p) (car p) name))
                       (cons (car p) (fifo-variable (car p) forbidden)))
                     param-pairs))
           (vars (mapcar #'cdr bindings))
           (act (if vars (cons name vars) name))
           (pre+ '()) (pre- '()) (guard '()) (adds '()) (dels '()) (cost nil))
      (dolist (p (conjuncts precondition))
        (cond ((disjunctive-precondition-p p)
               (error "Action ~a has a disjunctive or quantified precondition ~s.~@
                       pddl2fifo supports :disjunctive-preconditions only in the ~
                       problem :goal, not in action preconditions."
                      name p))
              ((negation-p p)
               (let ((atom (second p)))
                 (unless (consp atom)
                   (error "Cannot translate precondition ~s of action ~a" p name))
                 (let ((subst (substitute-terms atom bindings name)))
                   (if (static-predicate-p (first atom) effect-preds)
                       (push (list 'not subst) guard)
                       (push subst pre-)))))
              ((consp p)
               (let ((subst (substitute-terms p bindings name)))
                 (if (static-predicate-p (first p) effect-preds)
                     (push subst guard)
                     (push subst pre+))))
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
             (conj0 (if (rest facts) (cons 'and facts) (first facts)))
             ;; Gate the action's facts on its static preconditions: when the
             ;; guard is false (an observed static atom does not hold) the (if ...)
             ;; expands to nothing, pruning that ground action at instantiation.
             (conj (if guard
                       (list 'if (cons 'and (nreverse guard)) conj0)
                       conj0))
             (quants (mapcar (lambda (b p)
                               (cons (cdr b) (type-set-expression (cdr p))))
                             bindings param-pairs)))
        (values (wrap-quantifiers quants conj)
                negp
                (mapcar #'cdr param-pairs))))))

(defun parse-problem (problem-def)
  "Returns (values domain-name object-pairs init goal+ goal- goal), where
object-pairs is an alist of (object . type).  goal+/goal- are filled only for a
simple (conjunction-of-literals) goal; goal is always the raw goal description."
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
    ;; Split a conjunction of literals into positive/negative goal sets; a
    ;; disjunctive/nested goal is left to the caller as the raw GOAL.
    (when (simple-goal-p goal)
      (dolist (g (conjuncts goal))
        (cond ((negation-p g) (push (second g) goal-))
              ((consp g) (push g goal+))
              (t (error "Cannot translate goal ~s" g)))))
    (values domain-name object-pairs (nreverse init) (nreverse goal+) (nreverse goal-) goal)))

;;; Output

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
    (multiple-value-bind (domain-name object-pairs init goal+ goal- goal)
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
               (effect-preds (collect-effect-predicates domain-def))
               (static-arities (collect-static-predicate-arities domain-def effect-preds))
               ;; Split the initial state: static-predicate facts become
               ;; observations; the rest are time-indexed fluents (initial-state).
               (static-init (remove-if-not
                              (lambda (f) (static-predicate-p (first f) effect-preds)) init))
               (dynamic-init (remove-if
                               (lambda (f) (static-predicate-p (first f) effect-preds)) init))
               ;; A goal using or/imply (or nesting) is emitted as a direct
               ;; formula rather than the goal-state/negative-goal-state domains.
               (general-goal (not (simple-goal-p goal)))
               (goal-fluents (when general-goal (collect-goal-fluents goal)))
               ;; Reachability lower bound on the horizon (see reachable-min-slices).
               (min-slices (reachable-min-slices domain-def all-object-pairs type-table init goal))
               (types-used '())
               (action-forms '())
               (any-neg-pre nil))
          (unless all-objects
            (error "No objects: ~a has no :objects and ~a has no :constants"
                   problem-path domain-path))
          (dolist (p all-object-pairs)
            (dolist (tp (type-components (cdr p)))
              (pushnew tp types-used :test #'string-equal)))
          (dolist (p type-table)
            (pushnew (car p) types-used :test #'string-equal))
          (dolist (s (define-sections domain-def))
            (when (and (consp s) (eq (first s) :action))
              (multiple-value-bind (form negp param-types)
                  (translate-action s forbidden effect-preds)
                (push form action-forms)
                (when negp (setq any-neg-pre t))
                (dolist (tp param-types)
                  (dolist (c (type-components tp))
                    (pushnew c types-used :test #'string-equal))))))
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
              (when (or static-arities static-init)
                (terpri out)
                (format out ";; Static predicates (never added or deleted): observed,~%")
                (format out ";; with all positive instances from the initial state.  The~%")
                (format out ";; dummy facts only register each predicate as observed.~%")
                (write-form out
                  `(observed
                     ,@(mapcar (lambda (pa)
                                 (cons (car pa)
                                       (make-list (cdr pa) :initial-element *static-dummy*)))
                               static-arities)
                     ,@static-init)))
              (terpri out)
              (format out ";; Action preconditions, effects, and costs~%")
              (write-form out `(observed ,@action-forms))
              (terpri out)
              (format out ";; Initial and goal states~%")
              (when dynamic-init
                (write-form out `(domain initial-state (set ,@dynamic-init))))
              (when goal+
                (write-form out `(domain goal-state (set ,@goal+))))
              (when goal-
                (write-form out `(domain negative-goal-state (set ,@goal-))))
              ;; For a disjunctive/nested goal, gather its fluents so they get
              ;; Holds variables and frame axioms; the goal itself is asserted as
              ;; a direct formula below (and goal-state is left empty).
              (when general-goal
                (write-form out
                  (if goal-fluents
                      `(domain goal-fluents (set ,@goal-fluents))
                      '(domain goal-fluents (set-difference fluents fluents)))))
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
                              (when dynamic-init '(initial-state))
                              (when goal+ '(goal-state))
                              (when goal- '(negative-goal-state))
                              (when general-goal '(goal-fluents))))))
              (write-form out '(domain costs (collect c (cost * c))))
              ;; FiFO sets cannot be literally empty, so an empty initial or
              ;; positive goal state becomes the difference of a domain with itself.
              (unless dynamic-init
                (write-form out '(domain initial-state (set-difference fluents fluents))))
              (unless goal+
                (write-form out '(domain goal-state (set-difference fluents fluents))))
              (when goal-
                (terpri out)
                (format out ";; Negative goals~%")
                (write-form out
                  '(all f negative-goal-state true (not (holds f numslices)))))
              (when general-goal
                (terpri out)
                (format out ";; Goal (disjunctive/nested) asserted directly at the final slice~%")
                (write-form out (translate-goal-formula goal)))
              (terpri out)
              (write-form out (list 'include satplan-path))))
          (format t "Wrote ~a~%" (namestring out-path))
          ;; Return the wff pathname and the reachability lower bound on numslices
          ;; (an integer, or :unreachable if the relaxed problem has no plan).
          (values out-path min-slices))))))

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
