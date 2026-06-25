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
  '(:strips :typing :negative-preconditions :disjunctive-preconditions
    :constraints :preferences :action-costs))

(defparameter *reserved-domain-names*
  '("OBJECTS" "ACTIONS" "FLUENTS" "COSTS" "SLICES" "ACTSLICES"
    "INITIAL-STATE" "GOAL-STATE" "NEGATIVE-GOAL-STATE" "GOAL-FLUENTS"
    "CONSTRAINT-FLUENTS" "PREF-FLUENTS" "FLUENTCOST-FLUENTS" "NUMSLICES")
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

(defun translate-state-formula (g slice)
  "Translate a state description G (a literal or an and/or/not/imply combination
of literals) into a FiFO formula asserting it at SLICE: each atom becomes
(holds <atom> slice)."
  (cond ((negation-p g) (list 'not (translate-state-formula (second g) slice)))
        ((and (consp g) (sym-name= (first g) "AND"))
         (cons 'and (mapcar (lambda (x) (translate-state-formula x slice)) (rest g))))
        ((and (consp g) (sym-name= (first g) "OR"))
         (cons 'or (mapcar (lambda (x) (translate-state-formula x slice)) (rest g))))
        ((and (consp g) (sym-name= (first g) "IMPLY"))
         (list 'implies (translate-state-formula (second g) slice)
                        (translate-state-formula (third g) slice)))
        ((consp g) (list 'holds g slice))
        (t (error "Cannot translate state formula ~s" g))))

(defun translate-goal-formula (g)
  "Translate a PDDL goal description G into a FiFO formula asserting it at the
final time slice (numslices)."
  (translate-state-formula g 'numslices))

;;; Trajectory constraints (the :constraints section).  We support four modal
;;; operators over the slice timeline (slice 1 = initial state, numslices =
;;; final): (always phi), (at-end phi), (hold-during t1 t2 phi), and
;;; (occur-sometime t1 t2 <ground-action>).  Time bounds t1..t2 are inclusive
;;; integer slice numbers.  phi is a state description; the action of
;;; occur-sometime is a fully instantiated action term.

(defun constraint-time-bound (x role c)
  (unless (integerp x)
    (error "The ~a of constraint ~s must be an integer slice number, got ~s" role c x))
  x)

(defun collect-constraint-fluents (c)
  "Fluents referenced by a state-formula constraint, so they get Holds variables
and frame axioms.  occur-sometime refers to an action, not a fluent, and a single
state may be referenced at any slice, so its fluents come via collect-goal-fluents."
  (cond ((and (consp c) (sym-name= (first c) "ALWAYS")) (collect-goal-fluents (second c)))
        ((and (consp c) (sym-name= (first c) "AT-END")) (collect-goal-fluents (second c)))
        ((and (consp c) (sym-name= (first c) "HOLD-DURING")) (collect-goal-fluents (fourth c)))
        ((and (consp c) (sym-name= (first c) "OCCUR-SOMETIME")) '())
        (t '())))

(defun translate-constraint (c)
  "Translate one (:constraints ...) modal formula into a FiFO formula over the
slice timeline.  Supported: always, at-end, hold-during, occur-sometime."
  (cond
    ((and (consp c) (sym-name= (first c) "ALWAYS"))
     `(all s slices true ,(translate-state-formula (second c) 's)))
    ((and (consp c) (sym-name= (first c) "AT-END"))
     (translate-state-formula (second c) 'numslices))
    ((and (consp c) (sym-name= (first c) "HOLD-DURING"))
     (let ((t1 (constraint-time-bound (second c) "first time bound" c))
           (t2 (constraint-time-bound (third c) "second time bound" c)))
       `(all s slices (and (>= s ,t1) (<= s ,t2))
          ,(translate-state-formula (fourth c) 's))))
    ((and (consp c) (sym-name= (first c) "OCCUR-SOMETIME"))
     (let ((t1 (constraint-time-bound (second c) "first time bound" c))
           (t2 (constraint-time-bound (third c) "second time bound" c)))
       `(exists s actslices (and (>= s ,t1) (<= s ,t2))
          (occurs ,(fourth c) s))))
    (t (error "Unsupported trajectory constraint ~s~@
               (supported: always, at-end, hold-during, occur-sometime)" c))))

;;; Preferences (soft goals / soft constraints).
;;;
;;; A (preference <name> <body>) declared in the :goal or :constraints section is
;;; a soft requirement: violating it costs the weight given to (is-violated <name>)
;;; in the :metric.  We reify the body's satisfaction with a fresh proposition
;;; (pref-violated <name>): the hard clause (or <body> (pref-violated <name>))
;;; forces the proposition true whenever the body is false, and the soft weight
;;; (weight (pref-violated <name>) w) charges w when it is true.  The MaxSAT solver
;;; then minimizes total weight, so (pref-violated <name>) is true in the answer
;;; exactly for the violated preferences.

(defun preference-p (x)
  (and (consp x) (sym-name= (first x) "PREFERENCE")))

(defun parse-preference (f)
  "Parse (preference <name> <body> [<weight> | :probability <p>]) into the list
(name body weight prob): WEIGHT is the inline numeric weight (signed -- a learned
weight may be negative) or nil; PROB is the target probability that the preference
is SATISFIED (0<p<1) or nil.  At most one is given; with neither, the weight comes
from the :metric."
  (let ((name (second f)) (body (third f)) (extra (cdddr f)))
    (unless (and name body)
      (error "Malformed preference ~s (expected (preference <name> <body> [<weight>|:probability <p>]))" f))
    (cond ((null extra) (list name body nil nil))
          ((and (null (cdr extra)) (numberp (car extra)))
           (list name body (car extra) nil))
          ((and (eq (car extra) :probability) (cdr extra) (null (cddr extra)))
           (let ((p (cadr extra)))
             (unless (and (realp p) (< 0 p 1))
               (error "Preference ~a :probability must be strictly between 0 and 1, got ~s" name p))
             (list name body nil p)))
          (t (error "Malformed preference ~s (expected (preference <name> <body> [<weight>|:probability <p>]))" f)))))

(defun split-preferences (forms)
  "Partition a list of top-level conjuncts into (values hard preferences), where
each preference is (name body weight prob) -- weight/prob nil unless given inline."
  (let ((hard '()) (prefs '()))
    (dolist (f forms)
      (if (preference-p f)
          (push (parse-preference f) prefs)
          (push f hard)))
    (values (nreverse hard) (nreverse prefs))))

(defun constraint-head-p (body)
  "True if BODY is a trajectory-constraint modal formula (vs. a state description)."
  (and (consp body)
       (member (first body) '("ALWAYS" "AT-END" "HOLD-DURING" "OCCUR-SOMETIME")
               :test #'sym-name=)))

(defun translate-preference-body (body)
  "Translate a preference BODY to the FiFO formula whose truth means the
preference is satisfied: a trajectory-constraint body via translate-constraint, a
plain state description as a goal (asserted at the final slice)."
  (if (constraint-head-p body)
      (translate-constraint body)
      (translate-goal-formula body)))

(defun collect-preference-fluents (body)
  "Fluents referenced by a preference body, so they get Holds variables and frame
axioms."
  (if (constraint-head-p body)
      (collect-constraint-fluents body)
      (collect-goal-fluents body)))

(defun parse-metric-term (term)
  "Decode one :metric summand.  Returns (values KIND NAME COEFF): KIND is :cost
for k*(total-cost) or :pref for k*(is-violated <name>); the optional integer
coefficient k defaults to 1."
  (labels ((total-cost-p (x) (and (consp x) (sym-name= (first x) "TOTAL-COST")))
           (is-viol-p (x) (and (consp x) (sym-name= (first x) "IS-VIOLATED"))))
    (cond
      ((total-cost-p term) (values :cost nil 1))
      ((is-viol-p term) (values :pref (second term) 1))
      ((and (consp term) (sym-name= (first term) "*"))
       (let* ((a (second term)) (b (third term))
              (k (cond ((integerp a) a) ((integerp b) b)
                       (t (error "Metric term ~s needs an integer coefficient" term))))
              (x (if (integerp a) b a)))
         (cond ((total-cost-p x) (values :cost nil k))
               ((is-viol-p x) (values :pref (second x) k))
               (t (error "Unsupported metric term ~s" term)))))
      (t (error "Unsupported metric term ~s~@
                 (expected (total-cost) or (is-violated <name>), optionally k*...)" term)))))

(defun parse-metric (problem-def)
  "Parse (:metric minimize <expr>).  Returns (values total-cost-coeff weight-alist
metric-present-p): total-cost-coeff is the summed coefficient of (total-cost) (0
if absent), and weight-alist maps each preference name to its summed coefficient."
  (let ((section (get-section problem-def :metric)))
    (if (null section)
        (values 1 nil nil)
        (let ((dir (second section)) (expr (third section))
              (coeff 0) (weights '()))
          (unless (sym-name= dir "MINIMIZE")
            (error "Only (:metric minimize ...) is supported, got ~s" dir))
          (dolist (term (if (and (consp expr) (sym-name= (first expr) "+"))
                            (rest expr)
                            (list expr)))
            (multiple-value-bind (kind name k) (parse-metric-term term)
              (if (eq kind :cost)
                  (incf coeff k)
                  (let ((cell (assoc name weights :test #'sym-name=)))
                    (if cell (incf (cdr cell) k) (push (cons name k) weights))))))
          (values coeff weights t)))))

;;; Per-step fluent costs.
;;;
;;; A problem may contain one or more (:fluent-cost <literal> <cost>) forms.  Each
;;; charges <cost> for every slice in which <literal> holds (a FiFO-specific
;;; extension with no standard PDDL counterpart -- PDDL costs attach to actions,
;;; not states).  It compiles to a per-slice weight, the same pattern satplan.wff
;;; uses for action costs: (all s slices true (weight (holds <literal> s) <cost>)).

(defun parse-fluent-cost (s)
  "Parse (:fluent-cost <literal> <cost>) or (:fluent-cost <literal> :probability <p>)
into (literal cost prob): COST a signed number or nil; PROB the target marginal
P(literal holds), 0<p<1, or nil.  Exactly one of cost/prob is given."
  (let ((lit (second s)) (rest (cddr s)))
    (unless (and (consp lit) rest)
      (error "Malformed :fluent-cost ~s (expected (:fluent-cost <literal> <cost>|:probability <p>))" s))
    (cond ((and (null (cdr rest)) (numberp (car rest)))
           (list lit (car rest) nil))
          ((and (eq (car rest) :probability) (cdr rest) (null (cddr rest)))
           (let ((p (cadr rest)))
             (unless (and (realp p) (< 0 p 1))
               (error ":fluent-cost ~s :probability must be strictly between 0 and 1, got ~s" s p))
             (list lit nil p)))
          (t (error "Malformed :fluent-cost ~s (expected (:fluent-cost <literal> <cost>|:probability <p>))" s)))))

(defun fluent-costs (problem-def)
  "All (:fluent-cost ...) forms in PROBLEM-DEF, as a list of (literal cost prob)."
  (loop for s in (define-sections problem-def)
        when (and (consp s) (eq (first s) :fluent-cost))
          collect (parse-fluent-cost s)))

(defun fluent-cost-weight-literal (lit)
  "The weighted literal for a per-step fluent cost on LIT over the slice S:
(holds <atom> s), or (not (holds <atom> s)) when LIT is negated."
  (if (negation-p lit)
      `(not (holds ,(second lit) s))
      `(holds ,lit s)))

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

(defun translate-action (action-form forbidden effect-preds &optional (cost-scale 1))
  "Translate one (:action ...) form into an observed FiFO formula.  Preconditions
on static predicates (those not in EFFECT-PREDS) become an (if ...) guard rather
than Pre/PreNeg facts.  The action's cost (if any) is multiplied by COST-SCALE,
the coefficient of (total-cost) in the :metric.
Returns (values formula has-negative-preconditions-p parameter-types)."
  (destructuring-bind (key name &rest body) action-form
    (declare (ignore key))
    (let* ((param-pairs (parse-typed-list (getf body :parameters)
                                          (format nil "parameters of action ~a" name)))
           (precondition (getf body :precondition))
           (effect (getf body :effect))
           (cost-slot (getf body :cost))
           (prob-slot (getf body :probability))
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
           (pre+ '()) (pre- '()) (guard '()) (adds '()) (dels '()) (cost nil) (prob nil))
      (dolist (p (conjuncts precondition))
        (cond ((preference-p p)
               (error "Action ~a has a precondition preference ~s.~@
                       pddl2fifo supports preferences only in the :goal and ~
                       :constraints sections, not in action preconditions."
                      name p))
              ((disjunctive-precondition-p p)
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
      ;; A :cost slot is an alternative to an (increase (total-cost) n) effect.
      (when cost-slot
        (when cost
          (error "Action ~a has both a :cost slot and an (increase (total-cost) ...) effect"
                 name))
        (unless (numberp cost-slot)
          (error "The :cost of action ~a must be a number, got ~s" name cost-slot))
        (setq cost cost-slot))
      ;; A :probability slot is the learnable alternative to a cost: the action's
      ;; occurrence gets a target marginal that the learning pipeline turns into a
      ;; weight.  Mutually exclusive with a cost on the same action.
      (when prob-slot
        (when cost
          (error "Action ~a has both a cost and a :probability; give it one or the other"
                 name))
        (unless (and (realp prob-slot) (< 0 prob-slot 1))
          (error "The :probability of action ~a must be a number strictly between 0 and 1, got ~s"
                 name prob-slot))
        (setq prob prob-slot))
      (unless (or adds dels)
        (error "Action ~a has no add or delete effects" name))
      (let* ((negp (consp pre-))
             (rguard (nreverse guard))
             (facts (append
                      (mapcar (lambda (f) (list 'pre act f)) (nreverse pre+))
                      (mapcar (lambda (f) (list 'preneg act f)) (nreverse pre-))
                      (mapcar (lambda (f) (list 'add act f)) (nreverse adds))
                      (mapcar (lambda (f) (list 'del act f)) (nreverse dels))
                      (when cost (list (list 'cost act (* cost-scale cost))))))
             (conj0 (if (rest facts) (cons 'and facts) (first facts)))
             ;; Gate the action's facts on its static preconditions: when the
             ;; guard is false (an observed static atom does not hold) the (if ...)
             ;; expands to nothing, pruning that ground action at instantiation.
             (conj (if rguard (list 'if (cons 'and rguard) conj0) conj0))
             (quants (mapcar (lambda (b p)
                               (cons (cdr b) (type-set-expression (cdr p))))
                             bindings param-pairs))
             ;; Per-schema probability form: target the action's Occurs over every
             ;; slice; the tie-label (:action name) makes all groundings of this
             ;; schema share one learned weight and maps back to the source action.
             (prob-form
               (when prob
                 (let ((inner (list 'all 's 'actslices 'true
                                    (list 'probability (list 'occurs act 's) prob
                                          (list :action name)))))
                   (wrap-quantifiers quants
                     (if rguard (list 'if (cons 'and rguard) inner) inner))))))
        (values (wrap-quantifiers quants conj)
                negp
                (mapcar #'cdr param-pairs)
                prob-form)))))

(defun reassemble-conjunction (forms)
  "Rebuild a goal/constraint formula from its top-level conjuncts: nil, the single
form, or (and ...).  reassemble-conjunction (conjuncts f) reproduces f when f has
no preferences removed, so non-preference problems are unaffected."
  (cond ((null forms) nil)
        ((null (rest forms)) (first forms))
        (t (cons 'and forms))))

(defun parse-problem (problem-def)
  "Returns (values domain-name object-pairs init goal+ goal- goal constraints
preferences).  object-pairs is an alist of (object . type).  goal+/goal- are
filled only for a simple (conjunction-of-literals) hard goal; goal is the hard
goal description (preferences removed).  constraints is the list of hard
(:constraints ...) modal formulas.  preferences is a list of (name . body) for
the (preference ...) forms found in either section."
  (let ((object-pairs (parse-typed-list (rest (get-section problem-def :objects))
                                        ":objects"))
        (init-section (rest (get-section problem-def :init)))
        (goal-form (second (get-section problem-def :goal)))
        (constraints-form (second (get-section problem-def :constraints)))
        (domain-name (second (get-section problem-def :domain)))
        (init '()) (goal+ '()) (goal- '()))
    (dolist (f init-section)
      (cond ((and (consp f) (sym-name= (first f) "="))
             nil)                  ; function initialization, e.g. (= (total-cost) 0)
            ((negation-p f)
             nil)                  ; redundant under the closed-world assumption
            ((consp f) (push f init))
            (t (error "Cannot translate init fact ~s" f))))
    ;; Pull (preference ...) forms out of the goal and constraint conjunctions;
    ;; what remains is the hard goal / hard constraints.
    (multiple-value-bind (goal-hard goal-prefs)
        (split-preferences (and goal-form (conjuncts goal-form)))
      (multiple-value-bind (constraint-hard constraint-prefs)
          (split-preferences (and constraints-form (conjuncts constraints-form)))
        (let ((goal (reassemble-conjunction goal-hard)))
          ;; Split a conjunction of literals into positive/negative goal sets; a
          ;; disjunctive/nested hard goal is left to the caller as the raw GOAL.
          (when (simple-goal-p goal)
            (dolist (g (conjuncts goal))
              (cond ((negation-p g) (push (second g) goal-))
                    ((consp g) (push g goal+))
                    (t (error "Cannot translate goal ~s" g)))))
          (values domain-name object-pairs (nreverse init)
                  (nreverse goal+) (nreverse goal-) goal
                  constraint-hard
                  (append goal-prefs constraint-prefs)))))))

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
    (multiple-value-bind (domain-name object-pairs init goal+ goal- goal constraints preferences)
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
               ;; Fluents mentioned by trajectory constraints need Holds
               ;; variables and frame axioms even if no action/goal touches them.
               (constraint-fluents (remove-duplicates
                                     (mapcan #'collect-constraint-fluents constraints)
                                     :test #'equal))
               ;; Preferences (soft goals/constraints).  The :metric gives the
               ;; coefficient of (total-cost) -- by which action costs are scaled
               ;; -- and the violation weight of each preference.  The metric is
               ;; only consulted when preferences exist, so cost-only problems are
               ;; unaffected (they keep cost-scale 1 and ignore :metric, as before).
               (cost-scale 1)
               ;; Preferences with a :probability are learned; they go to prob-prefs
               ;; as (name body p).  The rest are weight-bearing (active-prefs).
               (prob-prefs
                 (loop for (name body inline-w prob) in preferences
                       when prob collect (list name body prob)))
               (active-prefs                       ; (name body . weight), weight /= 0
                 (when (some (lambda (pr) (null (fourth pr))) preferences)
                   (multiple-value-bind (coeff weights metric-present)
                       (parse-metric problem-def)
                     (when metric-present (setq cost-scale coeff))
                     ;; Weight precedence: an inline weight wins; else the :metric
                     ;; coefficient; else 0 when a metric is present (preference is
                     ;; ignored) or 1 when none is (minimize # of violations).
                     (loop for (name body inline-w prob) in preferences
                           unless prob
                           collect (let ((metric-w (and metric-present
                                                        (cdr (assoc name weights :test #'sym-name=)))))
                                     (when (and inline-w metric-w)
                                       (warn "Preference ~a has an inline weight ~a; ignoring its ~
                                              :metric coefficient ~a" name inline-w metric-w))
                                     (list* name body
                                            (cond (inline-w inline-w)
                                                  (metric-w metric-w)
                                                  (metric-present 0)
                                                  (t 1))))
                             into prs
                           finally (return (remove-if (lambda (pr) (zerop (cddr pr))) prs))))))
               (pref-fluents (remove-duplicates
                               (append
                                 (loop for entry in active-prefs
                                       append (collect-preference-fluents (second entry)))
                                 (loop for entry in prob-prefs
                                       append (collect-preference-fluents (second entry))))
                               :test #'equal))
               ;; Per-step fluent costs (:fluent-cost forms).  Like preferences,
               ;; the named fluents need Holds variables and frame axioms.
               (fluent-cost-list (fluent-costs problem-def))
               (fluentcost-fluents (remove-duplicates
                                     (loop for fc in fluent-cost-list
                                           append (collect-goal-fluents (car fc)))
                                     :test #'equal))
               ;; Reachability lower bound on the horizon (see reachable-min-slices).
               (min-slices (reachable-min-slices domain-def all-object-pairs type-table init goal))
               (types-used '())
               (action-forms '())
               (prob-forms '())          ; per-schema (probability (occurs ...) p tag) forms
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
              (multiple-value-bind (form negp param-types prob-form)
                  (translate-action s forbidden effect-preds cost-scale)
                (push form action-forms)
                (when prob-form (push prob-form prob-forms))
                (when negp (setq any-neg-pre t))
                (dolist (tp param-types)
                  (dolist (c (type-components tp))
                    (pushnew c types-used :test #'string-equal))))))
          (setq action-forms (nreverse action-forms)
                prob-forms (nreverse prob-forms))
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
              ;; Fluents named only by trajectory constraints (always/at-end/
              ;; hold-during).  occur-sometime contributes no fluents.
              (when constraint-fluents
                (write-form out `(domain constraint-fluents (set ,@constraint-fluents))))
              ;; Fluents named only by preference bodies.
              (when pref-fluents
                (write-form out `(domain pref-fluents (set ,@pref-fluents))))
              ;; Fluents named only by per-step fluent costs.
              (when fluentcost-fluents
                (write-form out `(domain fluentcost-fluents (set ,@fluentcost-fluents))))
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
                              (when general-goal '(goal-fluents))
                              (when constraint-fluents '(constraint-fluents))
                              (when pref-fluents '(pref-fluents))
                              (when fluentcost-fluents '(fluentcost-fluents))))))
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
              (when constraints
                (terpri out)
                (format out ";; Trajectory constraints (:constraints)~%")
                (dolist (c constraints)
                  (write-form out (translate-constraint c))))
              ;; Preferences: reify each body's satisfaction with (pref-violated
              ;; <name>) and charge its violation weight via a soft (weight ...).
              (when active-prefs
                (terpri out)
                (format out ";; Preferences (soft): violated when the body fails;~%")
                (format out ";; (weight ...) charges the metric cost of each violation~%")
                (dolist (entry active-prefs)
                  (destructuring-bind (name body . w) entry
                    (write-form out
                      `(or ,(translate-preference-body body) (pref-violated ,name)))
                    (write-form out `(weight (pref-violated ,name) ,w)))))
              ;; Preference probabilities: reify as above, but give (pref-violated
              ;; <name>) a target marginal -- the weight is learned downstream.  The
              ;; :probability is P(satisfied)=p, so P(pref-violated)=1-p.  Tie-tag
              ;; (:pref <name>) maps the learned weight back to the source form.
              (when prob-prefs
                (terpri out)
                (format out ";; Preference probabilities (target P(satisfied); learned)~%")
                (dolist (entry prob-prefs)
                  (destructuring-bind (name body p) entry
                    (write-form out
                      `(or ,(translate-preference-body body) (pref-violated ,name)))
                    (write-form out
                      `(probability (pref-violated ,name) ,(- 1 p) (:pref ,name))))))
              ;; Per-step fluent costs: charge the cost for every slice the fluent holds.
              (when fluent-cost-list
                (terpri out)
                (format out ";; Per-step fluent costs (:fluent-cost): charged/targeted~%")
                (format out ";; once per slice in which the fluent holds~%")
                (dolist (fc fluent-cost-list)
                  (destructuring-bind (lit c p) fc
                    (write-form out
                      (if p
                          ;; target P(literal holds)=p per slice, tied across slices
                          `(all s slices true
                                (probability ,(fluent-cost-weight-literal lit) ,p (:fluent ,lit)))
                          `(all s slices true (weight ,(fluent-cost-weight-literal lit) ,c)))))))
              (terpri out)
              (write-form out (list 'include satplan-path))
              ;; Per-schema action probabilities go AFTER the include so that the
              ;; actslices domain and the Occurs predicate (defined in satplan.wff)
              ;; are available; each is tied per schema and learned downstream.
              (when prob-forms
                (terpri out)
                (format out ";; Action probabilities (target marginals on Occurs;~%")
                (format out ";; tied per action schema, learned by the weight pipeline)~%")
                (dolist (pf prob-forms) (write-form out pf)))))
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
