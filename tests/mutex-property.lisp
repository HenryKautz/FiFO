;;; mutex-property.lisp -- property test for (mutex G1 G2).
;;;
;;; For random mutex forms over the 24 atoms (p 1)..(p 12), (q 1)..(q 12) --
;;; random label sets, guards and member formulas (literals of either polarity,
;;; conjunctions, disjunctions), sometimes the same generator twice, sometimes a
;;; second formula that equals the first's for labels below a cut and differs
;;; above it (so one mutex mixes labels whose members are the same literal with
;;; labels whose members differ) -- instantiate the form three ways, each through
;;; the real scnf file round trip:
;;;
;;;     default        the smaller of pairwise and the linear encoding
;;;     pairwise       (option *mutex-pairwise* 1)
;;;     compact off    no auxiliary atom at all
;;;
;;; and check that each scnf has exactly as many models as the DEFINITION has:
;;;
;;;     #{ assignments of the 24 atoms : for all c in L1, d in L2, c /= d,
;;;                                      not (phi1[c] and phi2[d]) }
;;;
;;; The definition is written out here as clauses, pair by pair, from the forms
;;; themselves (sharing no code with FiFO), and every clause set is counted over
;;; EVERY atom it contains by an exact DPLL counter written here, so an
;;; auxiliary atom left free or under-defined shows up as a factor of 2, and one
;;; defined too strongly as a lost model.
;;;
;;; It FAILS unless the linear encoding actually fired in some trials (default
;;; strictly smaller than pairwise), and unless some trials had member formulas
;;; that needed their own defined atom: a run that only ever wrote pairs would
;;; pass vacuously.
;;;
;;; Mutation-checked (SEED=1; the first three at 100 trials, the rest at 150):
;;; no suffix clauses -> 23 mismatches; a prefix atom not forced false when its
;;; parts are -> 99; a member atom defined one way only -> 42; every shared
;;; label treated as having the same
;;; literal (so the suffix chain is skipped wrongly) -> 10 (0 before the
;;; mixed-label case was added); the pair with equal labels excluded too -> 136.
;;; Writing this test also found that negating a member by parsing (not phi)
;;; went wrong for a member containing a vacuous if (parse-not reads
;;; (not (if <false> ...)) as true); mutex-member now negates phi's clauses.
;;;
;;;   FIFO=<path to FiFO.lisp>  SEED=<n>  TRIALS=<n>  sbcl --non-interactive --load mutex-property.lisp
;;; Exit 0 on success.

(load (or (uiop:getenv "FIFO") (error "set FIFO to the FiFO.lisp to test")))

(defvar *rs* (sb-ext:seed-random-state (parse-integer (or (uiop:getenv "SEED") "1"))))
(defparameter *labels* '(1 2 3 4 5 6 7 8 9 10 11 12))
(defparameter *atoms*
  (append (mapcar (lambda (i) (list 'p i)) *labels*)
          (mapcar (lambda (i) (list 'q i)) *labels*)))

(defun pick (list) (nth (random (length list) *rs*) list))

;;; ---------------------------------------------------------------- generator

(defun rand-member-formula (v)
  "A member formula in variable V."
  (pick (list `(p ,v) `(p ,v) `(q ,v) `(not (p ,v)) `(not (q ,v))
              `(and (p ,v) (q ,v)) `(or (p ,v) (not (q ,v)))
              `(and (not (p ,v)) (q ,v)))))

(defun rand-labels ()
  (let ((l (remove-if (lambda (x) (declare (ignore x)) (< (random 1.0 *rs*) 0.25)) *labels*)))
    (or l (list (pick *labels*)))))

(defun rand-guard (v)
  (if (< (random 1.0 *rs*) 0.7) 'true `(neq ,v ,(pick *labels*))))

(defun rand-generator (v)
  (list v (cons 'set (rand-labels)) (rand-guard v) (rand-member-formula v)))

(defun rand-mutex ()
  (let ((g1 (rand-generator 'i)))
    (list 'mutex g1
          (if (< (random 1.0 *rs*) 0.3)
              (cons 'j (subst 'j 'i (cdr g1)))      ; the same family: at-most-one
              (let ((g2 (rand-generator 'j))
                    (r (random 1.0 *rs*)))
                (cond ((< r 0.35)       ; reuse g1's formula: shared labels share a literal
                       (list 'j (second g2) (third g2) (subst 'j 'i (fourth g1))))
                      ((< r 0.6)        ; g1's formula below a cut, another above it:
                                        ; some shared labels share a literal, some not
                       (let ((k (pick *labels*)))
                         (list 'j (second g2) (third g2)
                               `(and (if (< j ,k) ,(subst 'j 'i (fourth g1)))
                                     (if (>= j ,k) (q j))))))
                      (t g2)))))))

(defun resolve-ifs (f)
  "F with each (and (if test g) ...) member resolved for the label substituted in."
  (if (and (consp f) (eq (car f) 'and) (some (lambda (g) (and (consp g) (eq (car g) 'if))) (cdr f)))
      (let ((kept (loop for g in (cdr f)
                        if (and (consp g) (eq (car g) 'if))
                          when (eval (second g)) collect (third g) end
                        else collect g)))
        (if (cdr kept) (cons 'and kept) (car kept)))
      f))

;;; ------------------------------------------------------- the definition's count

(defun family (gen)
  "(label . formula) for every label of GEN passing its guard."
  (destructuring-bind (v dom guard body) gen
    (loop for c in (cdr dom)
          when (or (eq guard 'true) (not (eql c (third guard))))
            collect (cons c (resolve-ifs (subst c v body))))))

(defun negate-lit (l) (if (and (consp l) (eq (car l) 'not)) (cadr l) (list 'not l)))

(defun negation-cnf (f)
  "Clauses of (not F), F a literal or an and/or of literals (all the generator
makes)."
  (case (car f)
    (and (list (mapcar #'negate-lit (cdr f))))
    (or (mapcar (lambda (l) (list (negate-lit l))) (cdr f)))
    (t (list (list (negate-lit f))))))

(defun definition-clauses (form)
  "The definition, written out here: for each pair c /= d, the clauses of
(not phi1[c]) or (not phi2[d]) -- the product of the two negations."
  (let ((x (family (second form))) (y (family (third form))))
    (loop for (c . f1) in x
          append (loop for (d . f2) in y
                       unless (eql c d)
                         append (loop for a in (negation-cnf f1)
                                      append (loop for b in (negation-cnf f2)
                                                   collect (cons 'or (append a b))))))))

(defun definition-count (form)
  (scnf-count (definition-clauses form)))

;;; ---------------------------------------------------- exact count of an scnf

(defun dpll-count (clauses nvars)
  "Models of CLAUSES (lists of nonzero integers) over variables 1..NVARS."
  (labels ((assign (cls lit)
             (loop for c in cls
                   unless (member lit c)
                     collect (remove (- lit) c)))
           (count-models (cls free)
             (cond ((member nil cls) 0)
                   ((null cls) (expt 2 free))
                   (t (let ((unit (find-if (lambda (c) (null (cdr c))) cls)))
                        (if unit
                            (count-models (assign cls (car unit)) (1- free))
                            (let ((v (abs (car (first cls)))))
                              (+ (count-models (assign cls v) (1- free))
                                 (count-models (assign cls (- v)) (1- free))))))))))
    (count-models clauses nvars)))

(defun scnf-count (clauses)
  "Models of CLAUSES over every atom in them plus any of *ATOMS* they lack."
  (let ((ids (make-hash-table :test #'equal)) (n 0))
    (dolist (a *atoms*) (setf (gethash a ids) (incf n)))
    (flet ((id (lit)
             (let* ((neg (and (consp lit) (eq (car lit) 'not)))
                    (a (if neg (cadr lit) lit))
                    (k (or (gethash a ids) (setf (gethash a ids) (incf n)))))
               (if neg (- k) k))))
      (let ((cls (mapcar (lambda (c) (mapcar #'id (cdr c))) clauses)))
        (dpll-count cls n)))))

(defun instantiate-clauses (form &key (compact t) pairwise)
  "Instantiate FORM and read the scnf BACK from disk."
  (let ((wff "mutex-prop.wff") (scnf "mutex-prop.scnf"))
    (with-open-file (s wff :direction :output :if-exists :supersede)
      (when pairwise (format s "(option *mutex-pairwise* 1)~%"))
      (format s "~S~%" form))
    (let ((*compact-encoding* compact))
      (instantiate wff :scnfile scnf))
    (with-open-file (s scnf)
      (loop for x = (read s nil :eof) until (eq x :eof)
            when (and (consp x) (eq (car x) 'or)) collect x))))

(defun mentions-tseitin (clauses)
  (some (lambda (cl) (some (lambda (l) (search "TSEITIN" (princ-to-string l))) (cdr cl)))
        clauses))

(let ((trials (parse-integer (or (uiop:getenv "TRIALS") "200")))
      (bad 0) (linear 0) (defined-members 0))
  (dotimes (i trials)
    (let* ((form (rand-mutex))
           (want (definition-count form))
           (default (instantiate-clauses form))
           (pairwise (instantiate-clauses form :pairwise t))
           (off (instantiate-clauses form :compact nil))
           (counts (mapcar #'scnf-count (list default pairwise off))))
      (when (< (length default) (length pairwise)) (incf linear))
      (when (mentions-tseitin pairwise) (incf defined-members))
      (unless (every (lambda (k) (eql k want)) counts)
        (incf bad)
        (format t "MISMATCH definition ~D  default/pairwise/off ~{~A~^ ~}~%  ~S~%"
                want counts form))))
  (format t "trials ~D, linear encoding used ~D, members given a defined atom ~D, mismatches ~D~%"
          trials linear defined-members bad)
  (sb-ext:exit :code (if (and (zerop bad) (plusp linear) (plusp defined-members)) 0 1)))
