;;; ddnnf.lisp
;;;
;;; FiFO's OWN d-DNNF compiler + circuit evaluator for exact marginal inference.
;;; This is the third "Method 3 (WMC tools)" backend of Inference/marginals.md,
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
  clauses)              ; the normalized integer clauses (for recompiling with evidence)

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
                   :clauses (ddnnf-clauses circuit))
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
                    :clauses (getf data :clauses))))))

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

(defun ddnnf--form-clause->ints (clause a2i)
  "Convert a ground FiFO (OR lit ...) form to a list of signed DIMACS literals,
erroring if any atom is not already in the theory."
  (mapcar (lambda (lit)
            (multiple-value-bind (atom positivep) (rw--literal-atom-and-sign lit)
              (let ((i (gethash atom a2i)))
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
  (let ((ev (wmc--evidence-clauses evidence evidence-file)))
    (if (null ev)
        (values circuit nil)
        (let ((units '()) (nonunits '()) (clamp (make-hash-table)))
          (dolist (cl ev)
            (let ((ints (ddnnf--form-clause->ints cl (ddnnf-a2i circuit))))
              (if (null (cdr ints))
                  (let ((l (car ints)))
                    (push l units)
                    (setf (gethash (abs l) clamp) (if (plusp l) 1 -1)))
                  (push ints nonunits))))
          (cond
            (nonunits
             (let ((newc (ddnnf--build
                          (ddnnf--normalize-clauses
                           (append (ddnnf-clauses circuit) nonunits (mapcar #'list units)))
                          (ddnnf-nvars circuit) (ddnnf-a2i circuit)
                          (ddnnf-leaf-cost circuit) (ddnnf-scale circuit))))
               (when verbose
                 (format t "; evidence has ~D non-unit clause~:P; recompiled (circuit not reused)~%"
                         (length nonunits)))
               (values newc nil)))
            (t
             (when (and verbose units)
               (format t "; conditioning on ~D unit-evidence literal~:P (circuit reused)~%"
                       (length units)))
             (values circuit clamp)))))))

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
             (targets (if weighted-only
                          (loop for v from 1 to nvars when (gethash v wv) collect v)
                          (loop for v from 1 to nvars collect v)))
             (results (sort (loop for v in targets
                                  collect (cons (aref i2a v) (/ (aref ztrue v) z)))
                            #'string-lessp :key (lambda (p) (princ-to-string (car p))))))
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
                                       evidence evidence-file (verbose t))
  "Exact marginal P(atom = true) of every atom via FiFO's own d-DNNF compiler.

The theory comes from either CIRCUIT -- a prebuilt DDNNF struct or the path to one
saved by DDNNF-SAVE, in which case NO recompilation happens -- or, when CIRCUIT is
NIL, by compiling SCNF-FILE.  With SAVE-CIRCUIT (a path), the base circuit is
written there for reuse on later calls.

Conditions on EVIDENCE / EVIDENCE-FILE (ground FiFO formulas; unit literals reuse
the circuit, anything else triggers a recompile from the stored clauses), and
reports every atom's marginal -- or, with WEIGHTED-ONLY, only the weighted atoms.
SCALE divides the integer weights (NIL reads the 'scale: N' header when compiling;
on a loaded CIRCUIT, a non-NIL SCALE overrides the stored one without recompiling,
since the weights are kept separate from the Boolean structure).  Prints one
(MARGINAL <atom> <p>) line per atom (and to OUT-FILE if given); returns an alist."
  (let ((base (cond (circuit (if (stringp circuit) (ddnnf-load circuit) circuit))
                    (scnf-file (ddnnf-compile scnf-file :scale scale :verbose verbose))
                    (t (error "ddnnf-marginals: provide an scnf file or :circuit")))))
    (when (and circuit scale)
      (setf (ddnnf-scale base) (float scale 1.0d0)))
    (when save-circuit
      (ddnnf-save base save-circuit)
      (when verbose (format t "; saved compiled circuit to ~A~%" save-circuit)))
    (multiple-value-bind (c clamp)
        (ddnnf--apply-evidence base evidence evidence-file verbose)
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
