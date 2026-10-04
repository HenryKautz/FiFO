;;; ddnnf.lisp
;;;
;;; FiFO's OWN d-DNNF compiler + circuit evaluator for exact marginal inference.
;;; This is the third "Method 3 (WMC tools)" backend of Probability/probability.md,
;;; alongside maxent.lisp (exact Lisp enumeration) and wmc.lisp (the external
;;; ADDMC counter).  Unlike either of those, it COMPILES the hard theory ONCE into
;;; a circuit and then answers many queries cheaply -- in particular, conditioning
;;; on different sets of LITERAL evidence reuses the same compiled circuit, which is
;;; what neither enumeration nor a per-count ADDMC run can do.
;;;
;;; What it builds.  A trace-based knowledge compiler grown from the exhaustive
;;; DPLL already in maxent.lisp's mx--enumerate: instead of summing counts, the
;;; search RECORDS itself as a DAG of nodes ---
;;;   * each decision branch (x / not x)           -> an OR node  (deterministic)
;;;   * each split into variable-disjoint clause    -> an AND node (decomposable)
;;;     components
;;;   * a component cache (signature -> node)        -> sharing, i.e. a DAG not a tree
;;; The result is a smooth, deterministic, decomposable NNF -- a d-DNNF.  Weights
;;; live OUTSIDE the Boolean structure (per signed literal, exactly as in wmc.lisp:
;;; W(L true) = exp(-cost/scale)), so the SAME circuit serves any weighting and any
;;; literal-evidence clamp.
;;;
;;; Smoothness is by CONSTRUCTION: whenever a variable drops out of a subproblem
;;; (satisfied by a decision or unit, or never mentioned) it is reintroduced as a
;;; free node free(v) = OR(lit(+v), lit(-v)) = (W(+v) + W(-v)).  So every model uses
;;; exactly one leaf of every variable, and the evaluator below assumes smoothness.
;;; (A future d4/c2d importer producing this same struct would only need to add a
;;; smoothing pass -- the evaluator, evidence handling, and CLI would be reused.)
;;;
;;; Evaluation (two passes over the DAG, child-before-parent then reverse):
;;;   * UP pass    -> node values; the root value is Z (the partition function).
;;;   * DOWN pass  -> node derivatives; for every variable v,
;;;                   Z[v=true] = sum over the +v leaves of value*derivative,
;;;                   and the marginal P(v=true) = Z[v=true] / Z.
;;; ALL marginals come out of one up/down pass -- O(circuit) -- versus ADDMC's one
;;; full count per atom.
;;;
;;; Entry points:
;;;   (ddnnf-compile "file.scnf" &key ...)   -- scnf -> compiled circuit (the cost)
;;;   (ddnnf-query   circuit &key clamp)     -- (values Z z-true-vector), reuses it
;;;   (ddnnf-marginals "file.scnf" &key ...) -- compile + report (single call)
;;;   (ddnnf-marginals-sets "file.scnf" sets-file &key ...) -- compile ONCE, query
;;;                                             each evidence set (the payoff case)

(load (merge-pathnames "wmc.lisp" (or *load-pathname* *default-pathname-defaults*)))

;;; ----------------------------------------------------------------------------
;;; Circuit representation
;;; ----------------------------------------------------------------------------

(defstruct (dnode (:conc-name dn-) (:constructor mk-dnode (type &key kids lit)))
  type                  ; :true :false :lit :and :or
  kids                  ; list of node ids (for :and / :or)
  lit)                  ; signed DIMACS literal (for :lit)

(defstruct ddnnf
  nodes                 ; adjustable vector of dnode, in topological order (kids precede parents)
  root                  ; id of the root node (always the highest id)
  nvars                 ; number of propositional variables
  a2i                   ; atom -> 1..nvars
  i2a                   ; vector index -> atom
  leaf-cost             ; hash signed-lit -> total cost-when-true (from wmc--literal-costs)
  scale                 ; weight scale; leaf weight of L = exp(-(cost(L)/scale))
  clauses               ; the normalized integer clauses (for recompiling with evidence)
  projected)            ; NIL, or a bit vector over 0..nvars: the variables a PROJECTED
                        ; compile kept (see ddnnf-compile-d4 :project).  Only those
                        ; appear in the circuit, so only those have marginals.

;;; ----------------------------------------------------------------------------
;;; Builder: interning nodes into the DAG
;;; ----------------------------------------------------------------------------

(defstruct bld
  nodes                 ; adjustable vector with fill-pointer
  lit-ids               ; signed-lit -> id   (intern literal leaves)
  free-ids              ; var -> id          (intern free(v) nodes)
  true-id false-id      ; the unique constant nodes
  sub-cache)            ; clause-signature -> id  (the component cache; makes it a DAG)

(defun bld-new ()
  (make-bld :nodes (make-array 16 :adjustable t :fill-pointer 0)
            :lit-ids (make-hash-table)
            :free-ids (make-hash-table)
            :sub-cache (make-hash-table :test 'equal)))

(defvar *ddnnf-node-limit* 2000000
  "Cap on the number of circuit nodes the compiler will create before giving up.
A blowup here means the instance has too much structure (treewidth) for this
trace-based compiler -- the signal to use --solver addmc instead.")

(defun bld-add (b nd)
  (when (>= (fill-pointer (bld-nodes b)) *ddnnf-node-limit*)
    (error "d-DNNF circuit exceeded ~:D nodes; this instance is too large for the ~
trace-based compiler -- use --solver addmc (or raise *ddnnf-node-limit*)"
           *ddnnf-node-limit*))
  (vector-push-extend nd (bld-nodes b))
  (1- (fill-pointer (bld-nodes b))))

(defun bld-true (b)  (or (bld-true-id b)  (setf (bld-true-id b)  (bld-add b (mk-dnode :true)))))
(defun bld-false (b) (or (bld-false-id b) (setf (bld-false-id b) (bld-add b (mk-dnode :false)))))

(defun bld-lit (b lit)
  (or (gethash lit (bld-lit-ids b))
      (setf (gethash lit (bld-lit-ids b)) (bld-add b (mk-dnode :lit :lit lit)))))

(defun bld-and (b ids)
  "AND of the given node ids, with the obvious simplifications: a FALSE child makes
the whole thing FALSE, TRUE children drop out, and a single surviving child is
returned directly (preserving DAG sharing)."
  (let ((kids '()))
    (dolist (id ids)
      (case (dn-type (aref (bld-nodes b) id))
        (:true nil)
        (:false (return-from bld-and (bld-false b)))
        (t (push id kids))))
    (setf kids (nreverse kids))
    (cond ((null kids) (bld-true b))
          ((null (cdr kids)) (car kids))
          (t (bld-add b (mk-dnode :and :kids kids))))))

(defun bld-or (b ids)
  "OR of the given node ids; FALSE children drop out, a single surviving child is
returned directly.  Callers only ever build DETERMINISTIC ORs (the two sides of a
decision on a variable, or a free variable's two polarities), so the children are
mutually exclusive and weighted counting over the result is exact."
  (let ((kids '()))
    (dolist (id ids)
      (case (dn-type (aref (bld-nodes b) id))
        (:false nil)
        (t (push id kids))))
    (setf kids (nreverse kids))
    (cond ((null kids) (bld-false b))
          ((null (cdr kids)) (car kids))
          (t (bld-add b (mk-dnode :or :kids kids))))))

(defun bld-free (b v)
  "free(v) = OR(lit(+v), lit(-v)) -- a variable unconstrained by the clauses, which
in the weighted count contributes (W(+v) + W(-v)).  Interned per variable."
  (or (gethash v (bld-free-ids b))
      (setf (gethash v (bld-free-ids b))
            (bld-or b (list (bld-lit b v) (bld-lit b (- v)))))))

;;; ----------------------------------------------------------------------------
;;; Clause utilities (integer clauses: each a list of signed var indices)
;;; ----------------------------------------------------------------------------

(defun ddnnf--vars (clauses)
  "Set (as a list) of variables mentioned in CLAUSES."
  (let ((s '()))
    (dolist (cl clauses) (dolist (l cl) (pushnew (abs l) s)))
    s))

(defun ddnnf--normalize-clauses (clauses)
  "Drop duplicate literals within a clause and discard tautological clauses
(those containing both v and -v)."
  (let ((out '()))
    (dolist (cl clauses)
      (let ((lits (remove-duplicates cl :test #'eql)))
        (unless (some (lambda (l) (member (- l) lits)) lits)
          (push lits out))))
    (nreverse out)))

(defun ddnnf--list< (a b)
  "Lexicographic order on two ascending integer lists (for canonical signatures)."
  (cond ((null a) (not (null b)))
        ((null b) nil)
        ((< (car a) (car b)) t)
        ((> (car a) (car b)) nil)
        (t (ddnnf--list< (cdr a) (cdr b)))))

(defun ddnnf--signature (clauses)
  "A canonical key (sorted clauses of sorted literals) for the component cache, so
two search paths reaching the same residual clause set share one node."
  (sort (mapcar (lambda (cl) (sort (copy-list cl) #'<)) clauses) #'ddnnf--list<))

(defun ddnnf--condition (clauses v val)
  "CLAUSES with variable V fixed: VAL true => v true.  Satisfied clauses drop out;
the falsified literal is removed from the rest (which may leave an empty clause,
later detected as a conflict)."
  (let ((sat (if val v (- v))) (fls (if val (- v) v)) (out '()))
    (dolist (cl clauses)
      (cond ((member sat cl) nil)
            ((member fls cl) (push (remove fls cl) out))
            (t (push cl out))))
    (nreverse out)))

(defun ddnnf--propagate (clauses)
  "Unit-propagate CLAUSES to a fixpoint.  Returns either (values :conflict nil nil)
or (values :ok forced residual): FORCED is the list of signed literals the
propagation assigned, RESIDUAL the remaining clauses (none satisfied, none unit,
all literals over still-unassigned variables)."
  (let ((assign (make-hash-table)))
    (flet ((lv (l) (let ((a (gethash (abs l) assign)))
                     (cond ((null a) 0) ((eql a (if (plusp l) 1 -1)) 1) (t -1)))))
      (loop
        (let ((residual '()) (newunit nil) (conflict nil))
          (block scan
            (dolist (cl clauses)
              (let ((lits '()) (sat nil))
                (dolist (l cl)
                  (case (lv l) (1 (setf sat t) (return)) (-1 nil) (t (push l lits))))
                (unless sat
                  (cond ((null lits) (setf conflict t) (return-from scan))
                        ((null (cdr lits))
                         (setf (gethash (abs (car lits)) assign) (if (plusp (car lits)) 1 -1))
                         (setf newunit t))
                        (t (push (nreverse lits) residual)))))))
          (when conflict (return (values :conflict nil nil)))
          (unless newunit
            (let ((forced '()))
              (maphash (lambda (v s) (push (* s v) forced)) assign)
              (return (values :ok forced (nreverse residual))))))))))

(defun ddnnf--components (clauses)
  "Partition CLAUSES into variable-disjoint connected components (union-find over
the variables).  Returns a list of clause lists."
  (let ((parent (make-hash-table)))
    (labels ((rt (x)
               (let ((p (gethash x parent)))
                 (cond ((null p) (setf (gethash x parent) x) x)
                       ((eql p x) x)
                       (t (let ((r (rt p))) (setf (gethash x parent) r) r)))))
             (uni (a b) (let ((ra (rt a)) (rb (rt b)))
                          (unless (eql ra rb) (setf (gethash ra parent) rb)))))
      (dolist (cl clauses)
        (let ((vs (mapcar #'abs cl)))
          (rt (car vs))
          (loop for (a b) on vs while b do (uni a b))))
      (let ((groups (make-hash-table)) (out '()))
        (dolist (cl clauses) (push cl (gethash (rt (abs (car cl))) groups)))
        (maphash (lambda (k v) (declare (ignore k)) (push v out)) groups)
        out))))

(defun ddnnf--choose-var (clauses)
  "Branching variable: the most frequently occurring one in CLAUSES."
  (let ((cnt (make-hash-table)) (best nil) (bestc -1))
    (dolist (cl clauses) (dolist (l cl) (incf (gethash (abs l) cnt 0))))
    (maphash (lambda (v c) (when (> c bestc) (setf best v bestc c))) cnt)
    best))

;;; ----------------------------------------------------------------------------
;;; The compiler proper
;;; ----------------------------------------------------------------------------

(defun ddnnf--compile-cs (b clauses)
  "Compile a clause set to a node smooth over exactly vars(CLAUSES); memoized."
  (if (null clauses)
      (bld-true b)
      (let ((sig (ddnnf--signature clauses)))
        (or (gethash sig (bld-sub-cache b))
            (setf (gethash sig (bld-sub-cache b)) (ddnnf--compile-cs-1 b clauses))))))

(defun ddnnf--compile-cs-1 (b clauses)
  (let ((vv (ddnnf--vars clauses)))
    (multiple-value-bind (status forced residual) (ddnnf--propagate clauses)
      (if (eq status :conflict)
          (bld-false b)
          (let* ((rvars (ddnnf--vars residual))
                 (freev (set-difference vv (union (mapcar #'abs forced) rvars)))
                 (kids '()))
            ;; forced unit leaves + any variable that fell out of the clauses (free)
            (dolist (l forced) (push (bld-lit b l) kids))
            (dolist (v freev)  (push (bld-free b v) kids))
            ;; the still-constrained residual: AND its independent components,
            ;; or branch when it is a single inseparable component
            (when residual
              (let ((comps (ddnnf--components residual)))
                (if (cdr comps)
                    (dolist (c comps) (push (ddnnf--compile-cs b c) kids))
                    (push (ddnnf--decide b (car comps)) kids))))
            (bld-and b (nreverse kids)))))))

(defun ddnnf--decide (b component)
  "Shannon-decompose COMPONENT on a chosen variable into a deterministic OR.  Each
branch reintroduces any component variable that the branch satisfied away as a
free node, keeping the result smooth over vars(COMPONENT)."
  (let ((vv (ddnnf--vars component))
        (v (ddnnf--choose-var component)))
    (flet ((branch (lit val)
             (let* ((sub (ddnnf--condition component v val))
                    (vanished (set-difference vv (cons (abs lit) (ddnnf--vars sub))))
                    (kids (list (bld-lit b lit))))
               (dolist (u vanished) (push (bld-free b u) kids))
               (push (ddnnf--compile-cs b sub) kids)
               (bld-and b (nreverse kids)))))
      (bld-or b (list (branch v t) (branch (- v) nil))))))

;;; ----------------------------------------------------------------------------
;;; Building a circuit from clauses / from an scnf
;;; ----------------------------------------------------------------------------

(defun ddnnf--build (int-clauses nvars a2i cost scale)
  "Compile normalized INT-CLAUSES (over variables 1..NVARS) into a DDNNF struct."
  (let* ((b (bld-new))
         (clause-vars (ddnnf--vars int-clauses))
         (never (set-difference (loop for v from 1 to nvars collect v) clause-vars))
         (body (ddnnf--compile-cs b int-clauses))
         (root (bld-and b (append (mapcar (lambda (v) (bld-free b v)) never)
                                  (list body))))
         (i2a (make-array (1+ nvars))))
    (maphash (lambda (atom i) (setf (aref i2a i) atom)) a2i)
    (make-ddnnf :nodes (bld-nodes b) :root root :nvars nvars :a2i a2i :i2a i2a
                :leaf-cost cost :scale scale :clauses int-clauses)))

(defun ddnnf-compile (scnf-file &key scale (verbose t))
  "Read a weighted SCNF-FILE and compile its hard clauses into a reusable d-DNNF
circuit.  SCALE divides the integer weights before exponentiating (NIL = read the
'scale: N' header, exactly as in WMC).  This is the expensive step; reuse the
returned circuit across many queries with DDNNF-QUERY / DDNNF-MARGINALS-SETS."
  (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let* ((scale (rw--resolve-scale scnf-file scale verbose))
           (weight-atoms (mapcar (lambda (w) (rw--literal-atom-and-sign (second w)))
                                 weight-forms)))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (when (zerop nvars) (error "no atoms found in ~A" scnf-file))
        (let ((int-clauses (ddnnf--normalize-clauses
                            (mapcar (lambda (cl) (coerce (mx--clause->ints cl a2i) 'list))
                                    clauses)))
              (cost (wmc--literal-costs weight-forms a2i)))
          (ddnnf--build int-clauses nvars a2i cost scale))))))

;;; ----------------------------------------------------------------------------
;;; Alternative producer: compile the Boolean structure with the external d4
;;; (d4v2) compiler, then parse + smooth its dump into the SAME ddnnf struct.
;;;
;;; d4 is the state-of-the-art decision-DNNF compiler; here it replaces the
;;; home-grown mx--compile front end while everything downstream (evaluator,
;;; evidence, persistence, marginals) is reused unchanged.  d4 only compiles the
;;; HARD clauses (plain DIMACS) -- weights stay on our side and are applied at the
;;; leaves during evaluation.  d4's output is a decision-DNNF in its arc format and
;;; is NOT smooth, so we smooth it on import (insert free(v)=OR(+v,-v) for variables
;;; that drop off a branch), which is exactly what our leaf-sum marginal evaluator
;;; assumes.
;;;
;;; d4 arc format (one token stream per line, terminated by 0):
;;;   o <id> 0 | a <id> 0 | t <id> 0 | f <id> 0   -- OR / AND / TRUE / FALSE node
;;;   <src> <dst> <lit...> 0                       -- arc src->dst carrying literals
;;; An OR node is the disjunction of its arcs; an AND node the conjunction; an arc
;;; (dst, lits) denotes (conj of lits) AND (subtree at dst).
;;; ----------------------------------------------------------------------------

(defvar *d4* "d4"
  "Name of the d4 (d4v2) d-DNNF compiler, found on PATH.  d4v2 builds it as
demo/compiler/build/compiler; bin/install-solvers.sh installs that as \"d4\".
Optional -- only the d4 producer needs it.")

(defun ddnnf--write-dimacs-file (int-clauses nvars path &key show)
  "Write hard INT-CLAUSES (over variables 1..NVARS) as DIMACS CNF to PATH.  SHOW,
a bit vector, adds d4's projection line 'c p show <vars> 0'."
  (with-open-file (s path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (format s "p cnf ~D ~D~%" nvars (length int-clauses))
    (when show
      (format s "c p show~{ ~D~} 0~%"
              (loop for v from 1 to nvars when (= 1 (sbit show v)) collect v)))
    (dolist (cl int-clauses)
      (dolist (l cl) (format s "~D " l))
      (format s "0~%"))))

(defun ddnnf--run-d4 (cnf-file nnf-file &key (d4 *d4*))
  "Run the d4 compiler on CNF-FILE, dumping its d-DNNF to NNF-FILE.  Preprocessing
is left at d4's default 'basic', which performs NO variable elimination (so every
variable still appears in the dump and our smoothing is correct)."
  (multiple-value-bind (out err code)
      (handler-case
          (uiop:run-program (list d4 "-i" cnf-file "--dump-file" nnf-file)
                            :output :string :error-output :string :ignore-error-status t)
        (error (c)
          (error "could not run the d4 compiler (~A): ~A~%Put a 'd4' on PATH (bin/install-solvers.sh --only d4)."
                 d4 c)))
    (declare (ignore out))
    (when (and code (not (zerop code)) (not (probe-file nnf-file)))
      (error "d4 (~A) failed (exit ~A) and produced no dump.~%--- stderr ---~%~A" d4 code err))
    (unless (probe-file nnf-file)
      (error "d4 produced no dump file ~A~%--- stderr ---~%~A" nnf-file err))
    nnf-file))

(defun ddnnf--read-d4-nnf (path)
  "Parse a d4 NNF dump.  Returns (values node-type arcs) where NODE-TYPE maps an
id to :or/:and/:true/:false and ARCS maps a src id to a list of (dst . lits)."
  (let ((node-type (make-hash-table)) (arcs (make-hash-table)))
    (with-open-file (in path :direction :input)
      (loop for line = (read-line in nil :eof)
            until (eq line :eof)
            for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
            unless (zerop (length trimmed))
              do (if (alpha-char-p (char trimmed 0))
                     (let ((toks (cl-ppcre:split "\\s+" trimmed)))
                       (setf (gethash (parse-integer (second toks)) node-type)
                             (ecase (char trimmed 0)
                               (#\o :or) (#\a :and) (#\t :true) (#\f :false))))
                     (let* ((toks (mapcar #'parse-integer (cl-ppcre:split "\\s+" trimmed)))
                            (src (first toks)) (dst (second toks))
                            (lits (butlast (cddr toks)))) ; drop terminating 0
                       (push (cons dst lits) (gethash src arcs))))))
    ;; restore arc order (we pushed)
    (maphash (lambda (k v) (setf (gethash k arcs) (nreverse v))) arcs)
    (values node-type arcs)))

(defun ddnnf--d4-scope (id node-type arcs cache)
  "Set (list) of variables occurring in the subtree rooted at d4 node ID; memoized."
  (multiple-value-bind (s hit) (gethash id cache)
    (if hit s
        (setf (gethash id cache)
              (case (gethash id node-type)
                ((:true :false) '())
                (t (let ((acc '()))
                     (dolist (arc (gethash id arcs))
                       (dolist (l (cdr arc)) (pushnew (abs l) acc))
                       (dolist (v (ddnnf--d4-scope (car arc) node-type arcs cache))
                         (pushnew v acc)))
                     acc)))))))

(defun ddnnf--d4-build (b id node-type arcs scopes build-cache)
  "Build d4 node ID into builder B, smooth over its scope; returns our node id."
  (or (gethash id build-cache)
      (setf (gethash id build-cache)
            (case (gethash id node-type)
              (:true (bld-true b))
              (:false (bld-false b))
              (:or
               ;; OR of arcs; smooth each arc up to the OR's scope.
               (let ((oscope (gethash id scopes)) (kids '()))
                 (dolist (arc (gethash id arcs))
                   (let* ((dst (car arc)) (lits (cdr arc))
                          (covered (copy-list (gethash dst scopes)))
                          (akids (list (ddnnf--d4-build b dst node-type arcs scopes build-cache))))
                     (dolist (l lits)
                       (pushnew (abs l) covered)
                       (push (bld-lit b l) akids))
                     (dolist (v (set-difference oscope covered))
                       (push (bld-free b v) akids))
                     (push (bld-and b (nreverse akids)) kids)))
                 (bld-or b (nreverse kids))))
              (:and
               ;; AND of arcs (decomposable: disjoint scopes, no smoothing needed).
               (let ((kids '()))
                 (dolist (arc (gethash id arcs))
                   (let ((akids (list (ddnnf--d4-build b (car arc) node-type arcs scopes build-cache))))
                     (dolist (l (cdr arc)) (push (bld-lit b l) akids))
                     (push (bld-and b (nreverse akids)) kids)))
                 (bld-and b (nreverse kids))))))))

(defun ddnnf--var-atom (a2i v)
  "The atom numbered V in A2I (a linear search -- for error messages only)."
  (block find
    (maphash (lambda (atom i) (when (= i v) (return-from find atom))) a2i)
    v))

(defun ddnnf--build-from-d4 (nnf-file nvars a2i cost scale int-clauses &key projected)
  "Turn a d4 NNF dump into a (smooth) DDNNF struct over variables 1..NVARS -- or,
for a PROJECTED dump (PROJECTED a bit vector of the kept variables), over those
variables only.  Root smoothing then adds free(v) for the kept variables alone:
smoothing over every variable would count each projected-away one as a free
factor of 2, which is exactly the existential the projection removed."
  (multiple-value-bind (node-type arcs) (ddnnf--read-d4-nnf nnf-file)
    (let ((dsts (make-hash-table)) (root-id nil)
          (scopes (make-hash-table)) (build-cache (make-hash-table))
          (b (bld-new)))
      ;; root = the one node that is never an arc destination
      (maphash (lambda (src lst) (declare (ignore src))
                 (dolist (a lst) (setf (gethash (car a) dsts) t)))
               arcs)
      (maphash (lambda (id ty) (declare (ignore ty))
                 (unless (gethash id dsts) (setf root-id id)))
               node-type)
      (unless root-id (error "could not find the d4 NNF root in ~A" nnf-file))
      (maphash (lambda (id ty) (declare (ignore ty))
                 (ddnnf--d4-scope id node-type arcs scopes))
               node-type)
      (when projected
        (let ((stray (find-if (lambda (v) (zerop (sbit projected v)))
                              (gethash root-id scopes))))
          (when stray
            (error "d4's projected dump mentions variable ~D (~S), which is not in the ~
projection -- d4 did not honour the 'c p show' line, so the circuit would not be ~
the projected one"
                   stray (ddnnf--var-atom a2i stray)))))
      (let* ((body (ddnnf--d4-build b root-id node-type arcs scopes build-cache))
             (never (set-difference (loop for v from 1 to nvars
                                          when (or (null projected) (= 1 (sbit projected v)))
                                            collect v)
                                    (gethash root-id scopes)))
             (root (bld-and b (append (mapcar (lambda (v) (bld-free b v)) never)
                                      (list body))))
             (i2a (make-array (1+ nvars))))
        (maphash (lambda (atom i) (setf (aref i2a i) atom)) a2i)
        (make-ddnnf :nodes (bld-nodes b) :root root :nvars nvars :a2i a2i :i2a i2a
                    :leaf-cost cost :scale scale :clauses int-clauses
                    :projected projected)))))

;;; ----------------------------------------------------------------------------
;;; Projection: which atoms to keep, and the check that keeping only them is exact
;;;
;;; A projected compile counts the models of (exists Y. F(X,Y)) -- every X
;;; assignment that EXTENDS to a model of F, counted once.  That equals F's own
;;; weighted count, marginal for marginal, exactly when X DETERMINES Y: each X has
;;; at most one Y.  For a SatPlan theory the plan (the actions) determines every
;;; state atom, so X = actions suffices for the Boolean structure -- but every
;;; WEIGHTED atom must be in X too, since the projection forgets the rest, weights
;;; included; and so must every atom whose marginal is wanted.  The goal atoms are
;;; kept because they are what plan recognition asks about.
;;; ----------------------------------------------------------------------------

(defun ddnnf--read-projection-header (scnf-file)
  "The '; fifo-projection-...' comment lines the planner writes at the TOP of an
scnf (see plan--write-projection-header in planner.lisp).  Only the leading
block of comment and blank lines is read -- the first clause ends the search, so
a large theory is not scanned to its end.  Returns (values horizon action-terms
goal-terms actions-p goal-p): the -P values say whether each line was PRESENT,
since an empty list and a missing line mean different things to the caller.  A
malformed line (no colon, unreadable value) is skipped, not an error."
  (let ((horizon nil) (actions nil) (goal nil) (actions-p nil) (goal-p nil)
        (*read-eval* nil))
    (with-open-file (in scnf-file :direction :input)
      (loop for line = (read-line in nil :eof)
            until (eq line :eof)
            for trimmed = (string-left-trim '(#\Space #\Tab) line)
            until (and (plusp (length trimmed)) (char/= (char trimmed 0) #\;))
            when (and (> (length line) 19) (string= "; fifo-projection-" line :end2 18))
              do (let ((colon (position #\: line)))
                   (when colon
                     (let ((key (subseq line 18 colon))
                           (val (ignore-errors (read-from-string line t nil :start (1+ colon)))))
                       (cond ((and (string= key "horizon") (null horizon) (integerp val))
                              (setq horizon val))
                             ((and (string= key "actions") (not actions-p) (listp val))
                              (setq actions val actions-p t))
                             ((and (string= key "goal") (not goal-p) (listp val))
                              (setq goal val goal-p t))))))))
    (values horizon actions goal actions-p goal-p)))

(defun ddnnf--holds-slice (atom)
  "The slice of a (HOLDS x s) atom with an integer s, else NIL."
  (and (consp atom) (eq (car atom) 'holds) (integerp (third atom)) (third atom)))

(defun ddnnf--structural-goal-atoms (clauses)
  "Fallback when an scnf carries no goal header: the atoms of every all-positive
clause made only of (HOLDS x N) atoms at the last slice N -- a conjunctive goal's
units, a disjunctive goal's clause.  It misses negative goals and goals encoded
with a TSEITIN selector, and can include a non-goal atom; none of that can make
an answer wrong (the definability check guards exactness), only change which
atoms can be asked about."
  (let ((n 0) (acc '()))
    (dolist (cl clauses)
      (dolist (l (cdr cl))
        (let ((s (ddnnf--holds-slice (rw--literal-atom-and-sign l))))
          (when (and s (> s n)) (setq n s)))))
    (dolist (cl clauses (remove-duplicates acc :test #'equal))
      (when (and (cdr cl)
                 (every (lambda (l) (eql (ddnnf--holds-slice l) n)) (cdr cl)))
        (dolist (l (cdr cl)) (push l acc))))))

(defun ddnnf--projection-vars (scnf-file clauses a2i nvars weight-atoms extra-atoms verbose)
  "The bit vector of variables a projected compile keeps: the ACTIONS, the
final-slice GOAL atoms, every WEIGHTED atom, and EXTRA-ATOMS.

Actions and goal atoms come from the planner's header in SCNF-FILE (the declared
ACTIONS domain at slices 1..N-1, and the parsed hard goal at N).  EACH falls back
to inference on its own when its line is absent -- a .wff given to planner.sh has
a horizon and actions but no parsed goal; a theory not made by planner.sh has no
header at all: actions are then the atoms headed OCCURS (the SatPlan encoding's
action predicate) and goal atoms come from the structural goal rule.  EXTRA-ATOMS
must all be in the theory; each is an error otherwise."
  (let ((keep (make-array (1+ nvars) :element-type 'bit :initial-element 0))
        (n-actions 0) (n-goal 0) (sources '()))
    (flet ((add (atom) (let ((v (gethash atom a2i)))
                         (when (and v (zerop (sbit keep v)))
                           (setf (sbit keep v) 1)
                           t))))
      (multiple-value-bind (horizon actions goal actions-p goal-p)
          (ddnnf--read-projection-header scnf-file)
        (cond
          ((and horizon actions-p)
           (push "actions from the header" sources)
           (dolist (a actions)
             (loop for s from 1 below horizon
                   do (when (add (list 'occurs a s)) (incf n-actions)))))
          (t
           (push "actions inferred (OCCURS atoms)" sources)
           (maphash (lambda (atom v)
                      (declare (ignore v))
                      (when (and (consp atom) (eq (car atom) 'occurs) (add atom))
                        (incf n-actions)))
                    a2i)))
        (cond
          ((and horizon goal-p)
           (push "goal from the header" sources)
           (dolist (g goal)
             ;; A 0-ary goal predicate may be written (hyp0) or bare.
             (when (or (add (list 'holds g horizon))
                       (and (consp g) (null (cdr g)) (add (list 'holds (car g) horizon))))
               (incf n-goal))))
          (t
           (push "goal inferred (final-slice goal clauses; no header goal line)" sources)
           (dolist (g (ddnnf--structural-goal-atoms clauses))
             (when (add g) (incf n-goal))))))
      (dolist (w weight-atoms) (add w))
      (dolist (x extra-atoms)
        (unless (gethash x a2i)
          (error "~S is not an atom of ~A, so it cannot be kept in the projection" x scnf-file))
        (add x)))
    (when verbose
      (format t "; projection: ~{~A~^; ~} -- ~D action, ~D goal, ~D kept in all~%"
              (reverse sources) n-actions n-goal (count 1 keep)))
    keep))

(defvar *ddnnf-definability-solver* "kissat"
  "SAT solver for the projection exactness check (any DIMACS solver exiting 10/20).")

(defun ddnnf--definability-witness (int-clauses nvars keep)
  "NIL when the variables in the bit vector KEEP determine all the others under
INT-CLAUSES; otherwise a variable they do not determine.  Padoa's method: with
Y' a renamed copy of the non-kept variables, F(X,Y) & F(X,Y') & OR(y xor y') is
UNSATISFIABLE exactly when X determines Y.  One SAT call, bounded by
*solver-timeout*; anything but a definite verdict is an error, since an
unchecked projection could silently be the wrong count."
  (let ((ys (loop for v from 1 to nvars when (zerop (sbit keep v)) collect v)))
    (when (null ys) (return-from ddnnf--definability-witness nil))
    (let* ((ren (lambda (l) (let ((v (abs l)))
                              (if (= 1 (sbit keep v)) l (* (signum l) (+ v nvars))))))
           (dvar (lambda (y) (+ y (* 2 nvars))))
           (base (make-scratch-file-root))
           (cnf (format nil "~A-padoa.cnf" base))
           (out (format nil "~A-padoa.out" base)))
      (unwind-protect
           (progn
             (with-open-file (s cnf :direction :output :if-exists :supersede)
               (format s "p cnf ~D ~D~%" (* 3 nvars)
                       (+ (* 2 (length int-clauses)) (* 2 (length ys)) 1))
               (dolist (cl int-clauses)
                 (format s "~{~D ~}0~%" cl)
                 (format s "~{~D ~}0~%" (mapcar ren cl)))
               (dolist (y ys)
                 (let ((y2 (+ y nvars)) (d (funcall dvar y)))
                   (format s "~D ~D ~D 0~%" (- d) y y2)          ; d -> (y or y')
                   (format s "~D ~D ~D 0~%" (- d) (- y) (- y2))))  ; d -> (~y or ~y')
               (format s "~{~D ~}0~%" (mapcar dvar ys)))
             (let ((code (run-program-to-file *ddnnf-definability-solver* (list cnf) out
                                              :timeout *solver-timeout*)))
               (case code
                 (20 nil)
                 (10 (let ((true (make-hash-table)))
                       (with-open-file (in out)
                         (loop for line = (read-line in nil) while line
                               when (and (> (length line) 1) (char= (char line 0) #\v))
                                 do (dolist (tok (cl-ppcre:split "\\s+" (subseq line 1)))
                                      (let ((x (ignore-errors (parse-integer tok))))
                                        (when (and x (plusp x)) (setf (gethash x true) t))))))
                       ;; SAT means SOME y differs; name one the model shows.  A
                       ;; model we could not read must not be guessed at: naming
                       ;; an arbitrary atom would send the user chasing the wrong one.
                       (or (find-if (lambda (y) (gethash (funcall dvar y) true)) ys)
                           (error "the projection is not exact (~A found two models that ~
differ off the projection), but its model could not be read to name an atom ~
that differs -- does it print 'v' lines?"
                                  *ddnnf-definability-solver*))))
                 (t (error "the projection exactness check did not finish (~A exit ~A); ~
refusing to compile a projection that might not be exact"
                           *ddnnf-definability-solver* code)))))
        (ignore-errors (delete-file cnf))
        (ignore-errors (delete-file out))))))

(defun ddnnf--compile-ints-d4 (int-clauses nvars a2i cost scale &key (d4 *d4*) verbose projected)
  "Compile INT-CLAUSES with d4 and import the dump.  PROJECTED, when given, is the
bit vector of variables to keep: the projection is verified exact, d4 is told it
with a 'c p show' line, and the import smooths over those variables only."
  (let* ((base (make-scratch-file-root))
         (cnf (format nil "~A.cnf" base))
         (nnf (format nil "~A.nnf" base)))
    (when projected
      (let ((y (ddnnf--definability-witness int-clauses nvars projected)))
        (when y
          (error "projection is not exact: ~S is not determined by the ~D projected atoms ~
(two models agree on all of them and differ on it), so the projected count would ~
not be the theory's.  Add it to the projection (marginals.sh --project-also), or ~
compile without --project."
                 (ddnnf--var-atom a2i y) (count 1 projected))))
      (when verbose
        (format t "; projecting onto ~D of ~D atoms (verified exact)~%"
                (count 1 projected) nvars)))
    (unwind-protect
         (progn
           (ddnnf--write-dimacs-file int-clauses nvars cnf :show projected)
           (ddnnf--run-d4 cnf nnf :d4 d4)
           (when verbose (format t "; compiled with d4: ~A~%" d4))
           (ddnnf--build-from-d4 nnf nvars a2i cost scale int-clauses :projected projected))
      (ignore-errors (delete-file cnf))
      (ignore-errors (delete-file nnf)))))

(defun ddnnf-compile-d4 (scnf-file &key scale (d4 *d4*) (verbose t)
                                         project project-atoms evidence evidence-file)
  "Like DDNNF-COMPILE, but the Boolean structure is compiled by the external d4
(d4v2) decision-DNNF compiler (via *d4* / D4) and smoothed on import, instead of
the home-grown trace compiler.  Returns the same DDNNF struct, so DDNNF-QUERY,
DDNNF-MARGINALS, evidence, and save/load all work identically.  Useful when an
instance is too structured for the home-grown compiler (where d4's heuristics win).

With PROJECT, compile only the projection onto the actions, the final-slice goal
atoms, every weighted atom, and PROJECT-ATOMS (atoms the caller will ask about
or condition on) -- see DDNNF--PROJECTION-VARS.  The projection is checked to be
EXACT first (DDNNF--DEFINABILITY-WITNESS): those atoms must determine every other
one, or the error names an atom that is not determined.  The circuit then holds,
and reports marginals for, the projected atoms only.

EVIDENCE / EVIDENCE-FILE (ground FiFO forms, as for DDNNF-MARGINALS) are
clausified against the theory and conjoined BEFORE compiling -- one compile of
the conditioned theory, where compiling the theory and then conditioning would
compile (and check) twice for non-unit evidence.  Every atom they name must be
the theory's, or an auxiliary atom minted for the evidence itself."
  (multiple-value-bind (clauses probs opts weight-forms) (rw--read-scnf scnf-file)
    (declare (ignore probs opts))
    (let ((evidence-clauses (wmc--evidence-clauses evidence evidence-file clauses)))
     (when evidence-clauses
      (let ((theory (make-hash-table :test #'equal)))
        (dolist (a (wmc--clause-atoms clauses)) (setf (gethash a theory) t))
        (dolist (w weight-forms) (setf (gethash (rw--literal-atom-and-sign (second w)) theory) t))
        (dolist (a (wmc--clause-atoms evidence-clauses))
          (unless (or (gethash a theory) (evidence-aux-atom-p a))
            (error "evidence atom ~S is not in the theory; evidence must be ground over existing atoms"
                   a))))
      (setq clauses (append clauses evidence-clauses))))
    (let* ((scale (rw--resolve-scale scnf-file scale verbose))
           (weight-atoms (mapcar (lambda (w) (rw--literal-atom-and-sign (second w)))
                                 weight-forms)))
      (multiple-value-bind (a2i nvars) (mx--index-atoms clauses weight-atoms)
        (when (zerop nvars) (error "no atoms found in ~A" scnf-file))
        (let ((int-clauses (ddnnf--normalize-clauses
                            (mapcar (lambda (cl) (coerce (mx--clause->ints cl a2i) 'list))
                                    clauses)))
              (cost (wmc--literal-costs weight-forms a2i)))
          (ddnnf--compile-ints-d4
           int-clauses nvars a2i cost scale
           :d4 d4 :verbose verbose
           :projected (when project
                        (ddnnf--projection-vars scnf-file clauses a2i nvars weight-atoms
                                                project-atoms verbose))))))))

;;; ----------------------------------------------------------------------------
;;; Persistence: save / load a compiled circuit
;;;
;;; A compiled circuit is a flat, topologically-ordered array of nodes whose
;;; children are integer ids (not pointers), plus the atom map, weights and
;;; clauses -- all plain readable data.  So it serializes to a single s-expression
;;; (a ".dnnf" text file) that round-trips across SBCL sessions with no fasl or
;;; version coupling.  Compile once, save, and reuse on later marginals calls.
;;; ----------------------------------------------------------------------------

(defun ddnnf--node->sexp (nd)
  (ecase (dn-type nd)
    (:true '(:t))
    (:false '(:f))
    (:lit (list :l (dn-lit nd)))
    (:and (list* :a (dn-kids nd)))
    (:or  (list* :o (dn-kids nd)))))

(defun ddnnf--sexp->node (s)
  (ecase (car s)
    (:t (mk-dnode :true))
    (:f (mk-dnode :false))
    (:l (mk-dnode :lit :lit (second s)))
    (:a (mk-dnode :and :kids (cdr s)))
    (:o (mk-dnode :or  :kids (cdr s)))))

(defun ddnnf-save (circuit path)
  "Serialize the compiled CIRCUIT to PATH as one readable s-expression.  The atom
map is stored as the ordered atom list (1..nvars), the weights as an alist; the
expensive Boolean structure is the node list.  Returns PATH."
  (let ((*package* (find-package :common-lisp-user))
        (*print-readably* nil) (*print-pretty* nil) (*print-circle* nil)
        (*print-length* nil) (*print-level* nil)
        (lc '()))
    (maphash (lambda (lit c) (push (list lit c) lc)) (ddnnf-leaf-cost circuit))
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (prin1 (list :fifo-ddnnf 1
                   :nvars (ddnnf-nvars circuit)
                   :root (ddnnf-root circuit)
                   :scale (ddnnf-scale circuit)
                   :nodes (loop for i from 0 below (fill-pointer (ddnnf-nodes circuit))
                                collect (ddnnf--node->sexp (aref (ddnnf-nodes circuit) i)))
                   :atoms (loop for v from 1 to (ddnnf-nvars circuit)
                                collect (aref (ddnnf-i2a circuit) v))
                   :leaf-cost lc
                   :clauses (ddnnf-clauses circuit)
                   ;; the kept variables of a projected circuit (absent = not
                   ;; projected); without it a reload would report the dropped
                   ;; atoms as marginal 0
                   :projected (let ((p (ddnnf-projected circuit)))
                                (and p (loop for v from 1 to (ddnnf-nvars circuit)
                                             when (= 1 (sbit p v)) collect v))))
             out)
      (terpri out)))
  path)

(defun ddnnf-load (path)
  "Reconstruct a circuit previously written by DDNNF-SAVE.  Returns a DDNNF struct
ready to query -- no recompilation."
  (let* ((*package* (find-package :common-lisp-user))
         (*read-eval* nil)
         (*read-default-float-format* 'double-float)
         (form (with-open-file (in path :direction :input) (read in nil :eof))))
    (unless (and (consp form) (eq (car form) :fifo-ddnnf))
      (error "~A is not a FiFO d-DNNF circuit file" path))
    (let ((version (cadr form)) (data (cddr form)))
      (unless (eql version 1)
        (error "unsupported d-DNNF circuit file version ~S in ~A" version path))
      (let* ((nvars (getf data :nvars))
             (node-sexps (getf data :nodes))
             (nodes (make-array (max 1 (length node-sexps)) :adjustable t :fill-pointer 0))
             (a2i (make-hash-table :test 'equal))
             (i2a (make-array (1+ nvars)))
             (cost (make-hash-table :test 'eql)))
        (dolist (s node-sexps) (vector-push-extend (ddnnf--sexp->node s) nodes))
        (loop for atom in (getf data :atoms) for v from 1
              do (setf (gethash atom a2i) v (aref i2a v) atom))
        (dolist (pair (getf data :leaf-cost))
          (setf (gethash (first pair) cost) (float (second pair) 1.0d0)))
        (make-ddnnf :nodes nodes :root (getf data :root) :nvars nvars
                    :a2i a2i :i2a i2a :leaf-cost cost
                    :scale (float (getf data :scale) 1.0d0)
                    :clauses (getf data :clauses)
                    :projected (let ((kept (getf data :projected)))
                                 (when kept
                                   (let ((p (make-array (1+ nvars) :element-type 'bit
                                                                   :initial-element 0)))
                                     (dolist (v kept p) (setf (sbit p v) 1))))))))))

;;; ----------------------------------------------------------------------------
;;; Evaluation: Z (up pass) and all marginals (down pass)
;;; ----------------------------------------------------------------------------

(defun ddnnf--clamp-factor (clamp lit)
  "0 when CLAMP fixes LIT's variable to the opposite polarity (so this leaf is
ruled out by the evidence), else 1.  CLAMP maps var -> required +1/-1."
  (if clamp
      (let ((req (gethash (abs lit) clamp)))
        (cond ((null req) 1.0d0)
              ((eql req (if (plusp lit) 1 -1)) 1.0d0)
              (t 0.0d0)))
      1.0d0))

(defun ddnnf--leaf-weight (c lit clamp)
  "Weight of a literal leaf: exp(-cost/scale) for a charged literal (else 1),
times the evidence clamp factor."
  (let* ((cost (gethash lit (ddnnf-leaf-cost c)))
         (w (if cost (exp (- (/ cost (ddnnf-scale c)))) 1.0d0)))
    (* w (ddnnf--clamp-factor clamp lit))))

(defun ddnnf--eval (c clamp)
  "UP pass.  Returns (values Z value-vector); Z is the root value."
  (let* ((nodes (ddnnf-nodes c)) (n (fill-pointer nodes))
         (val (make-array n :element-type 'double-float :initial-element 0d0)))
    (dotimes (i n)
      (let ((nd (aref nodes i)))
        (setf (aref val i)
              (ecase (dn-type nd)
                (:true 1d0)
                (:false 0d0)
                (:lit (ddnnf--leaf-weight c (dn-lit nd) clamp))
                (:and (let ((p 1d0)) (dolist (k (dn-kids nd)) (setf p (* p (aref val k)))) p))
                (:or  (let ((s 0d0)) (dolist (k (dn-kids nd)) (incf s (aref val k))) s))))))
    (values (aref val (ddnnf-root c)) val)))

(defun ddnnf--marginals-vec (c val)
  "DOWN pass over the (smooth, deterministic) circuit.  Returns a vector ZTRUE,
1..nvars, where ZTRUE[v] is the unnormalized weight of the models with v true."
  (let* ((nodes (ddnnf-nodes c)) (n (fill-pointer nodes))
         (der (make-array n :element-type 'double-float :initial-element 0d0))
         (ztrue (make-array (1+ (ddnnf-nvars c)) :element-type 'double-float
                                                 :initial-element 0d0)))
    (setf (aref der (ddnnf-root c)) 1d0)
    (loop for i from (1- n) downto 0 do
      (let* ((nd (aref nodes i)) (di (aref der i)))
        (unless (zerop di)
          (case (dn-type nd)
            (:or  (dolist (k (dn-kids nd)) (incf (aref der k) di)))
            (:and (let ((kids (dn-kids nd)))
                    ;; d[k] += d[i] * (product of sibling values); recomputed
                    ;; directly (no division) so a zero sibling is handled exactly.
                    (dolist (k kids)
                      (let ((sib 1d0))
                        (dolist (j kids) (unless (eql j k) (setf sib (* sib (aref val j)))))
                        (incf (aref der k) (* di sib))))))))))
    ;; Each model uses exactly one +v leaf (smoothness + determinism), so summing
    ;; value*derivative over the +v leaves gives Z[v=true] with no double counting.
    (dotimes (i n)
      (let ((nd (aref nodes i)))
        (when (and (eq (dn-type nd) :lit) (plusp (dn-lit nd)))
          (incf (aref ztrue (dn-lit nd)) (* (aref val i) (aref der i))))))
    ztrue))

(defun ddnnf-query (circuit &key clamp)
  "Evaluate CIRCUIT (optionally under a literal CLAMP, var -> +1/-1).  Returns
(values Z ztrue-vector).  Reuses the compiled circuit -- this is the cheap step."
  (multiple-value-bind (z val) (ddnnf--eval circuit clamp)
    (when (<= z 0d0)
      (error "partition function is 0 -- the (conditioned) theory is unsatisfiable"))
    (values z (ddnnf--marginals-vec circuit val))))

;;; ----------------------------------------------------------------------------
;;; Evidence: ground literals clamp (reuse); anything else recompiles
;;; ----------------------------------------------------------------------------

(defun ddnnf--form-clause->ints (clause a2i &optional new-var)
  "Convert a ground FiFO (OR lit ...) form to a list of signed DIMACS literals,
erroring if any atom is not already in the theory -- except an auxiliary atom
the clausifier minted for the evidence itself, e.g. (TSEITIN EVIDENCE 1), which
by construction is in no theory: NEW-VAR, when given, is called on it and must
return a fresh variable (and record it in A2I).  Only NAMESPACED auxiliaries
qualify: a stray (TSEITIN 9) given a fresh variable would constrain nothing."
  (mapcar (lambda (lit)
            (multiple-value-bind (atom positivep) (rw--literal-atom-and-sign lit)
              (let ((i (or (gethash atom a2i)
                           (and new-var (evidence-aux-atom-p atom) (funcall new-var atom)))))
                (unless i
                  (error "evidence atom ~S is not in the theory; evidence must be ground over existing atoms"
                         atom))
                (if positivep i (- i)))))
          (cdr clause)))

(defun ddnnf--apply-evidence (circuit evidence evidence-file verbose)
  "Resolve EVIDENCE (ground FiFO forms) + EVIDENCE-FILE against CIRCUIT.  Unit
evidence becomes a CLAMP and the compiled circuit is reused; any non-unit evidence
clause is added as a hard clause and the circuit is recompiled (no reuse).
Returns (values circuit* clamp)."
  (let ((ev (wmc--evidence-clauses evidence evidence-file (ddnnf-a2i circuit))))
    (if (null ev)
        (values circuit nil)
        (let* ((units '()) (nonunits '()) (clamp (make-hash-table))
               ;; Compound evidence may mint auxiliary atoms (Tseitin selectors)
               ;; the compiled theory has no variable for.  They get fresh
               ;; variables in a COPY of the map (the circuit's own is untouched)
               ;; and force a recompile, since a clamp cannot name them.  The copy
               ;; is made only when one is present, so the common case -- unit
               ;; evidence clamped onto a reused circuit -- pays nothing for it.
               (a2i (if (some (lambda (a) (and (evidence-aux-atom-p a)
                                               (not (gethash a (ddnnf-a2i circuit)))))
                              (wmc--clause-atoms ev))
                        (let ((copy (make-hash-table :test #'equal)))
                          (maphash (lambda (k v) (setf (gethash k copy) v)) (ddnnf-a2i circuit))
                          copy)
                        (ddnnf-a2i circuit)))
               (nvars (ddnnf-nvars circuit))
               (new-var (lambda (atom) (setf (gethash atom a2i) (incf nvars)))))
          (dolist (cl ev)
            (let ((ints (ddnnf--form-clause->ints cl a2i new-var)))
              (if (null (cdr ints))
                  (let ((l (car ints)))
                    (push l units)
                    (setf (gethash (abs l) clamp) (if (plusp l) 1 -1)))
                  (push ints nonunits))))
          ;; A projected circuit has no leaf for an atom it projected away, so a
          ;; CLAMP on one would be silently ignored -- the unconditioned answer.
          ;; Such evidence takes the recompile path instead, which conjoins it.
          (let* ((proj (ddnnf-projected circuit))
                 (dropped-unit (and proj
                                    (some (lambda (l) (and (<= (abs l) (ddnnf-nvars circuit))
                                                           (zerop (sbit proj (abs l)))))
                                          units))))
          (cond
            ((or nonunits dropped-unit (> nvars (ddnnf-nvars circuit)))
             (let* ((clauses (ddnnf--normalize-clauses
                              (append (ddnnf-clauses circuit) nonunits (mapcar #'list units))))
                    (proj (ddnnf-projected circuit))
                    (newc
                      (if proj
                          ;; Recompile PROJECTED (and re-checked: the evidence's own
                          ;; auxiliary atoms join the non-kept side and must be
                          ;; determined too).  FiFO's own compiler cannot project.
                          (let ((keep (make-array (1+ nvars) :element-type 'bit
                                                             :initial-element 0)))
                            (replace keep proj)
                            (ddnnf--compile-ints-d4 clauses nvars a2i
                                                    (ddnnf-leaf-cost circuit) (ddnnf-scale circuit)
                                                    :projected keep :verbose verbose))
                          (ddnnf--build clauses nvars a2i
                                        (ddnnf-leaf-cost circuit) (ddnnf-scale circuit)))))
               (when verbose
                 (cond (nonunits
                        (format t "; evidence has ~D non-unit clause~:P; recompiled (circuit not reused)~%"
                                (length nonunits)))
                       (dropped-unit
                        (format t "; evidence names an atom this projected circuit dropped; ~
recompiled with it conjoined (circuit not reused)~%"))
                       (t
                        (format t "; evidence introduces ~D auxiliary atom~:P the circuit lacks; ~
recompiled (circuit not reused)~%"
                                (- nvars (ddnnf-nvars circuit))))))
               (values newc nil)))
            (t
             (when (and verbose units)
               (format t "; conditioning on ~D unit-evidence literal~:P (circuit reused)~%"
                       (length units)))
             (values circuit clamp))))))))

;;; ----------------------------------------------------------------------------
;;; Reporting / entry points
;;; ----------------------------------------------------------------------------

(defun ddnnf--weight-vars (circuit)
  "Hash set of variables that carry a weight."
  (let ((wv (make-hash-table)))
    (maphash (lambda (lit c) (declare (ignore c)) (setf (gethash (abs lit) wv) t))
             (ddnnf-leaf-cost circuit))
    wv))

(defun ddnnf--report (circuit clamp &key out-file weighted-only (verbose t))
  "Run a query on CIRCUIT under CLAMP and report P(atom = true) per atom."
  (let ((wv (ddnnf--weight-vars circuit)))
    (when (and weighted-only (zerop (hash-table-count wv)))
      (when verbose (format t "; no weighted atoms~%"))
      (return-from ddnnf--report nil))
    (multiple-value-bind (z ztrue) (ddnnf-query circuit :clamp clamp)
      (let* ((nvars (ddnnf-nvars circuit))
             (i2a (ddnnf-i2a circuit))
             (proj (ddnnf-projected circuit))
             ;; A projected circuit has no leaves for the atoms it projected away:
             ;; their "marginal" would read as 0.  Report the kept atoms only.
             (targets (loop for v from 1 to nvars
                            when (and (or (not weighted-only) (gethash v wv))
                                      (or (null proj) (= 1 (sbit proj v))))
                              collect v))
             (results (sort (loop for v in targets
                                  collect (cons (aref i2a v) (/ (aref ztrue v) z)))
                            #'string-lessp :key (lambda (p) (princ-to-string (car p))))))
        (when (and proj verbose)
          (format t "; projected circuit: marginals for the ~D kept atoms only~%"
                  (count 1 proj)))
        ;; Suppress auxiliary atoms (reification, Tseitin) from the default
        ;; listing; reified ones still show under --weighted-only
        ;; (P(atom) = P(the reified formula)).
        (unless weighted-only
          (setq results (remove-if #'auxiliary-atom-p results :key #'car)))
        (flet ((emit (s) (dolist (r results)
                           (format s "(MARGINAL ~S ~,6F)~%" (car r) (cdr r)))))
          (when verbose (emit *standard-output*))
          (when out-file
            (with-open-file (o out-file :direction :output
                                        :if-exists :supersede :if-does-not-exist :create)
              (format o "; marginals of ~A via FiFO d-DNNF~@[ (weighted atoms only)~]~%"
                      (file-namestring (or out-file "")) weighted-only)
              (emit o))))
        results))))

(defun ddnnf-marginals (scnf-file &key circuit save-circuit out-file weighted-only scale
                                       evidence evidence-file (compiler :home) (d4 *d4*)
                                       project project-atoms
                                       (verbose t))
  "Exact marginal P(atom = true) of every atom via a compiled d-DNNF circuit.

The theory comes from either CIRCUIT -- a prebuilt DDNNF struct or the path to one
saved by DDNNF-SAVE, in which case NO recompilation happens -- or, when CIRCUIT is
NIL, by compiling SCNF-FILE.  COMPILER selects the front end: :home (default) uses
the built-in trace compiler; :d4 shells out to the external d4 (d4v2) compiler (at
D4) and smooths its dump.  With SAVE-CIRCUIT (a path), the base circuit is written
there for reuse on later calls.

Conditions on EVIDENCE / EVIDENCE-FILE (ground FiFO formulas; unit literals reuse
the circuit, anything else triggers a recompile from the stored clauses), and
reports every atom's marginal -- or, with WEIGHTED-ONLY, only the weighted atoms.
SCALE divides the integer weights (NIL reads the 'scale: N' header when compiling;
on a loaded CIRCUIT, a non-NIL SCALE overrides the stored one without recompiling,
since the weights are kept separate from the Boolean structure).  Prints one
(MARGINAL <atom> <p>) line per atom (and to OUT-FILE if given); returns an alist.

PROJECT (d4 only) compiles the projection onto the actions, the final-slice goal
atoms, the weighted atoms and PROJECT-ATOMS, after checking that it is exact --
see DDNNF-COMPILE-D4.  Only those atoms are reported.  Evidence is then CONJOINED
into that one compile (a projected circuit could not clamp an atom it dropped,
and compile-then-condition would compile twice for non-unit evidence) -- unless
SAVE-CIRCUIT asks for the unconditioned circuit, in which case the evidence's
atoms are kept in the projection and it is applied afterwards as usual."
  (when (and project (not (eq compiler :d4)) (not circuit))
    (error "projection needs the d4 compiler (FiFO's own compiler cannot project)"))
  (let* ((conjoin (and project scnf-file (not circuit) (not save-circuit)
                       (or evidence evidence-file)))
         (base (cond (circuit (if (stringp circuit) (ddnnf-load circuit) circuit))
                     (scnf-file
                      (if (eq compiler :d4)
                          (ddnnf-compile-d4
                           scnf-file :scale scale :d4 d4 :verbose verbose
                           :project project
                           :evidence (and conjoin evidence)
                           :evidence-file (and conjoin evidence-file)
                           ;; A saved circuit is the UNconditioned one; keep the
                           ;; evidence's atoms in it so conditioning stays a clamp.
                           :project-atoms
                           (if (and project save-circuit (or evidence evidence-file))
                               (append project-atoms
                                       (remove-if #'evidence-aux-atom-p
                                                  (wmc--clause-atoms
                                                   (wmc--evidence-clauses evidence evidence-file))))
                               project-atoms))
                          (ddnnf-compile scnf-file :scale scale :verbose verbose)))
                     (t (error "ddnnf-marginals: provide an scnf file or :circuit")))))
    (when (and circuit scale)
      (setf (ddnnf-scale base) (float scale 1.0d0)))
    (when save-circuit
      (ddnnf-save base save-circuit)
      (when verbose (format t "; saved compiled circuit to ~A~%" save-circuit)))
    (multiple-value-bind (c clamp)
        (if conjoin
            (values base nil)
            (ddnnf--apply-evidence base evidence evidence-file verbose))
      (ddnnf--report c clamp :out-file out-file :weighted-only weighted-only
                             :verbose verbose))))

(defun ddnnf-marginals-sets (scnf-file sets-file &key weighted-only scale (verbose t))
  "Compile SCNF-FILE ONCE, then report marginals for each evidence set in
SETS-FILE -- the compile-once / query-many case.  Each non-blank line of SETS-FILE
is one evidence set: a sequence of ground FiFO literal/clause forms conjoined for
that query (a blank line, or a line of just a comment, is the no-evidence set).
Unit-literal sets reuse the compiled circuit; a set with non-unit evidence is
recompiled for that set only.  Returns a list of (set-index . alist)."
  (let ((circuit (ddnnf-compile scnf-file :scale scale :verbose verbose))
        (idx 0) (out '()))
    (with-open-file (in sets-file :direction :input)
      (loop for line = (read-line in nil :eof)
            until (eq line :eof)
            for trimmed = (string-trim '(#\Space #\Tab) line)
            unless (or (zerop (length trimmed)) (char= (char trimmed 0) #\;))
              do (let ((forms (let ((*read-eval* nil))
                                (with-input-from-string (s (format nil "(~A)" trimmed))
                                  (read s)))))
                   (incf idx)
                   (when verbose (format t "~%; == evidence set ~D: ~A ==~%" idx trimmed))
                   (multiple-value-bind (c clamp)
                       (ddnnf--apply-evidence circuit forms nil verbose)
                     (push (cons idx (ddnnf--report c clamp :weighted-only weighted-only
                                                            :verbose verbose))
                           out)))))
    (nreverse out)))
