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

;; Forward references within this file: the compiler's mutual recursion, and the
;; circuit loaders' shared assembly and node checks, defined after their callers.
(declaim (ftype function ddnnf--compile-cs-1 ddnnf--decide ddnnf--assemble ddnnf--check-nodes))

;;; ----------------------------------------------------------------------------
;;; Circuit representation
;;; ----------------------------------------------------------------------------

;;; The nodes are PACKED, one entry per node in a few typed arrays, with every
;;; node's children in one flat array (compressed sparse rows):
;;;   types[i]   +dn-true+ +dn-false+ +dn-lit+ +dn-and+ +dn-or+   (a byte)
;;;   lits[i]    the signed DIMACS literal of a :lit node, else 0  (32 bits)
;;;   kids[kstart[i] .. kstart[i+1]-1]   the child ids of an AND/OR (32 bits each)
;;; A node is 13 bytes plus 4 per child.  As a vector of structs whose children
;;; were Lisp lists it was ~40 bytes plus 16 per child, and a d4 circuit of a
;;; 9x9 SimpleGrid problem -- millions of nodes, tens of millions of children --
;;; did not fit a 12 GB heap.  Flat arrays are also what the binary circuit file
;;; is: loading one is a few reads straight into them (DDNNF-SAVE-BINARY).

(defconstant +dn-true+ 0)
(defconstant +dn-false+ 1)
(defconstant +dn-lit+ 2)
(defconstant +dn-and+ 3)
(defconstant +dn-or+ 4)

(deftype dn-ids () '(simple-array (unsigned-byte 32) (*)))

(defstruct (dnodes (:conc-name dns-) (:constructor %make-dnodes))
  (n 0 :type fixnum)    ; number of nodes; the arrays may be longer while building
  (types (make-array 16 :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)))
  (lits (make-array 16 :element-type '(signed-byte 32))
   :type (simple-array (signed-byte 32) (*)))
  (kstart (make-array 17 :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*)))   ; n+1 entries in use; kstart[0] = 0
  (kids (make-array 64 :element-type '(unsigned-byte 32))
   :type dn-ids))

(defun dns-new () (%make-dnodes))

(declaim (inline dns-type dns-lit dns-kids-start dns-kids-end))
(defun dns-type (d i) (aref (dns-types d) i))
(defun dns-lit (d i) (aref (dns-lits d) i))
(defun dns-kids-start (d i) (aref (dns-kstart d) i))
(defun dns-kids-end (d i) (aref (dns-kstart d) (1+ i)))

(defmacro do-dns-kids ((k d i) &body body)
  "Run BODY with K bound to each child id of node I of D, in order."
  (let ((dd (gensym)) (j (gensym)) (kids (gensym)))
    `(let* ((,dd ,d) (,kids (dns-kids ,dd)))
       (declare (type dn-ids ,kids))
       (loop for ,j of-type fixnum from (dns-kids-start ,dd ,i) below (dns-kids-end ,dd ,i)
             do (let ((,k (aref ,kids ,j))) ,@body)))))

(defun dns-kid-list (d i)
  (let ((acc '())) (do-dns-kids (k d i) (push k acc)) (nreverse acc)))

(defun dns-kind (d i)
  "The node's type as a keyword, for code that is not on a hot path."
  (svref #(:true :false :lit :and :or) (dns-type d i)))

(defun dns--grow (v need)
  "V, or a copy at least twice as long when NEED elements will not fit."
  (if (<= need (length v))
      v
      (let ((new (make-array (max need (* 2 (length v))) :element-type (array-element-type v))))
        (replace new v)
        new)))

(defun dns-push (d type lit kids)
  "Append a node of TYPE (a +dn-...+ code) with literal LIT and the child ids in
the list KIDS; return its id."
  (let* ((i (dns-n d)) (k0 (aref (dns-kstart d) i)) (k1 (+ k0 (length kids))))
    (when (>= i #xffffffff)
      (error "d-DNNF circuit has 2^32 nodes; child ids are 32 bits"))
    (setf (dns-types d) (dns--grow (dns-types d) (1+ i))
          (dns-lits d) (dns--grow (dns-lits d) (1+ i))
          (dns-kstart d) (dns--grow (dns-kstart d) (+ i 2))
          (dns-kids d) (dns--grow (dns-kids d) k1))
    (setf (aref (dns-types d) i) type
          (aref (dns-lits d) i) lit)
    (let ((kv (dns-kids d)) (j k0))
      (dolist (k kids) (setf (aref kv j) k) (incf j)))
    (setf (aref (dns-kstart d) (1+ i)) k1
          (dns-n d) (1+ i))
    i))

(defun dns-trim (d)
  "D with its arrays cut to their used length (once building is over)."
  (let ((n (dns-n d)))
    (flet ((cut (v len) (if (= len (length v)) v (subseq v 0 len))))
      (setf (dns-types d) (cut (dns-types d) n)
            (dns-lits d) (cut (dns-lits d) n)
            (dns-kids d) (cut (dns-kids d) (aref (dns-kstart d) n))
            (dns-kstart d) (cut (dns-kstart d) (1+ n))))
    d))

(defstruct ddnnf
  nodes                 ; a DNODES, in topological order (kids precede parents)
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
  nodes                 ; a DNODES, growing
  lit-ids               ; signed-lit -> id   (intern literal leaves)
  free-ids              ; var -> id          (intern free(v) nodes)
  true-id false-id      ; the unique constant nodes
  sub-cache)            ; clause-signature -> id  (the component cache; makes it a DAG)

(defun bld-new ()
  (make-bld :nodes (dns-new)
            :lit-ids (make-hash-table)
            :free-ids (make-hash-table)
            :sub-cache (make-hash-table :test 'equal)))

(defvar *ddnnf-node-limit* 2000000
  "Cap on the number of circuit nodes the compiler will create before giving up.
A blowup here means the instance has too much structure (treewidth) for this
trace-based compiler -- the signal to use --solver addmc instead.")

(defun bld-add (b type &key (lit 0) kids)
  (when (>= (dns-n (bld-nodes b)) *ddnnf-node-limit*)
    ;; the cap covers d4 imports too (they build through here), where a big
    ;; circuit is expected and raising the cap is the answer
    (error "d-DNNF circuit exceeded ~:D nodes (*ddnnf-node-limit*; marginals.sh ~
--node-limit raises it).  With the trace-based compiler (--solver ddnnf) this means ~
the instance is too large for it -- use --solver d4 or addmc"
           *ddnnf-node-limit*))
  (dns-push (bld-nodes b) type lit kids))

(defun bld-true (b)  (or (bld-true-id b)  (setf (bld-true-id b)  (bld-add b +dn-true+))))
(defun bld-false (b) (or (bld-false-id b) (setf (bld-false-id b) (bld-add b +dn-false+))))

(defun bld-lit (b lit)
  (or (gethash lit (bld-lit-ids b))
      (setf (gethash lit (bld-lit-ids b)) (bld-add b +dn-lit+ :lit lit))))

(defun bld-finish (b)
  "B's nodes, trimmed, for a DDNNF struct."
  (dns-trim (bld-nodes b)))

(defun bld-and (b ids)
  "AND of the given node ids, with the obvious simplifications: a FALSE child makes
the whole thing FALSE, TRUE children drop out, and a single surviving child is
returned directly (preserving DAG sharing)."
  (let ((kids '()))
    (dolist (id ids)
      (let ((ty (dns-type (bld-nodes b) id)))
        (cond ((= ty +dn-true+))
              ((= ty +dn-false+) (return-from bld-and (bld-false b)))
              (t (push id kids)))))
    (setf kids (nreverse kids))
    (cond ((null kids) (bld-true b))
          ((null (cdr kids)) (car kids))
          (t (bld-add b +dn-and+ :kids kids)))))

(defun bld-or (b ids)
  "OR of the given node ids; FALSE children drop out, a single surviving child is
returned directly.  Callers only ever build DETERMINISTIC ORs (the two sides of a
decision on a variable, or a free variable's two polarities), so the children are
mutually exclusive and weighted counting over the result is exact."
  (let ((kids '()))
    (dolist (id ids)
      (unless (= (dns-type (bld-nodes b) id) +dn-false+)
        (push id kids)))
    (setf kids (nreverse kids))
    (cond ((null kids) (bld-false b))
          ((null (cdr kids)) (car kids))
          (t (bld-add b +dn-or+ :kids kids)))))

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
    (make-ddnnf :nodes (bld-finish b) :root root :nvars nvars :a2i a2i :i2a i2a
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
variable still appears in the dump and our smoothing is correct).  Bounded by
*solver-timeout* like every other external solver: a compilation stopped that
way is an error, since a circuit has no partial answer.  d4 exits 0 on
satisfiable and unsatisfiable input alike, so any other code is a crash -- and a
crashed d4 can leave a PARTIAL dump, whose import would be a wrong circuit, not
an error; wmc--run-counter refuses every non-zero exit, dump or no dump."
  (multiple-value-bind (out err)
      (wmc--run-counter "d4" d4 (list "-i" cnf-file "--dump-file" nnf-file) "d4"
                        :result "a circuit")
    (declare (ignore out))
    (unless (probe-file nnf-file)
      (error "d4 produced no dump file ~A~%--- stderr ---~%~A" nnf-file err)))
  nnf-file)

(deftype ddnnf--litvec () '(simple-array (signed-byte 32) (*)))

(defun ddnnf--line-ints (line scratch)
  "The integers of LINE, in order, into the fixnum vector SCRATCH (fill pointer
reset); no intermediate strings."
  (setf (fill-pointer scratch) 0)
  (let ((i 0) (n (length line)))
    (loop
      (loop while (and (< i n) (member (char line i) '(#\Space #\Tab #\Return)))
            do (incf i))
      (when (>= i n) (return scratch))
      (multiple-value-bind (v end) (parse-integer line :start i :junk-allowed t)
        (unless v (error "d4 NNF dump: unexpected text in line ~S" line))
        (vector-push-extend v scratch)
        (setf i end)))))

(defun ddnnf--read-d4-nnf (path)
  "Parse a d4 NNF dump.  Returns (values node-type arcs) where NODE-TYPE maps an
id to :or/:and/:true/:false and ARCS maps a src id to a list of (dst . lits),
LITS a packed (signed-byte 32) vector.  A large dump holds hundreds of millions
of arc literals (the unit literals d4 records on each arc: 27 per arc on a 7x7
SimpleGrid circuit), so they are packed, not consed -- 4 bytes each, not 16."
  (let ((node-type (make-hash-table)) (arcs (make-hash-table))
        (ints (make-array 64 :element-type 'fixnum :adjustable t :fill-pointer 0)))
    (with-open-file (in path :direction :input)
      (loop for line = (read-line in nil :eof)
            until (eq line :eof)
            for start = (position-if-not (lambda (c) (member c '(#\Space #\Tab #\Return))) line)
            when start
              do (if (alpha-char-p (char line start))
                     (let ((id (parse-integer line :start (1+ start) :junk-allowed t)))
                       ;; a truncated last line ("o") must be refused here, by
                       ;; name, not stored under NIL to surface as a root error
                       (unless id
                         (error "d4 NNF dump ~A: malformed node line ~S" path line))
                       (setf (gethash id node-type)
                             (ecase (char line start)
                               (#\o :or) (#\a :and) (#\t :true) (#\f :false))))
                     (let* ((v (ddnnf--line-ints line ints))
                            (n (length v)))
                       ;; src dst lit... 0
                       (unless (and (>= n 3) (zerop (aref v (1- n))))
                         (error "d4 NNF dump ~A: malformed arc line ~S" path line))
                       ;; one allocation per arc, straight into the packed type
                       (push (cons (aref v 1)
                                   (replace (make-array (- n 3) :element-type '(signed-byte 32))
                                            v :start2 2 :end2 (1- n)))
                             (gethash (aref v 0) arcs))))))
    ;; restore arc order (we pushed)
    (maphash (lambda (k v) (setf (gethash k arcs) (nreverse v))) arcs)
    (values node-type arcs)))

;;; A d4 circuit can have millions of nodes and thousands of variables, so the
;;; import must be linear in the circuit with small constants: scopes are bit
;;; vectors (a list scope built with PUSHNEW is quadratic in time and holds
;;; nodes x scope-size conses -- billions on an 8x8 SatPlan grid), and the walks
;;; are iterative (the circuit's depth grows with the variable count, past what
;;; SBCL's default control stack allows).

(defun ddnnf--d4-postorder (root arcs fn)
  "Call FN on every d4 node reachable from ROOT, each once, children before
parents.  Iterative, so the circuit's depth does not touch the control stack."
  ;; A node is marked when it is EXPANDED (its children pushed above it), not when
  ;; pushed: a node can sit on the stack twice, and the lower copy is dropped when
  ;; it surfaces.  Marking on push would let a parent be visited before a shared
  ;; child still waiting lower down.  The circuit is acyclic, so an unvisited
  ;; child is never an expanded-but-unfinished node.
  (let ((expanded (make-hash-table)) (stack (list (cons root nil))))
    (loop while stack
          do (let ((top (car stack)))
               (cond ((cdr top)                       ; children done: visit
                      (pop stack) (funcall fn (car top)))
                     ((gethash (car top) expanded)    ; a duplicate: already handled
                      (pop stack))
                     (t
                      (setf (gethash (car top) expanded) t
                            (cdr top) t)
                      (dolist (arc (gethash (car top) arcs))
                        (unless (gethash (car arc) expanded)
                          (push (cons (car arc) nil) stack)))))))))

(defun ddnnf--free-kids (b missing acc)
  "Push free(v) onto ACC for each variable set in the bit vector MISSING; return
ACC.  POSITION on a simple bit vector scans a word at a time, so an arc that
needs little or no smoothing -- the common case -- costs nvars/64 steps."
  (declare (type simple-bit-vector missing))
  (loop for v = (position 1 missing) then (position 1 missing :start (1+ v))
        while v do (push (bld-free b v) acc))
  acc)

(defun ddnnf--d4-build (b root node-type arcs nvars)
  "Build the d4 circuit under ROOT into builder B, smoothing every OR arc up to
the OR's scope.  Returns (values our id for ROOT, ROOT's scope: a bit vector of
the variables occurring in the circuit).

Memory is what limits the import of a large dump, so one postorder pass computes
each node's scope from its children's and builds the node, and then drops what
nothing will read again: the node's parsed arcs at once, and a child's scope and
id once its last parent is built -- so only the scopes of the nodes still
awaiting a parent are alive, not one per node (nodes x nvars bits: about 2 GB on
a 9x9 SimpleGrid circuit).  An arc into a FALSE node is skipped (it would be
dropped anyway); smoothing it first used to cons tens of millions of free(v)
entries for nothing.  The scope of a node still counts every arc, as before."
  (let ((built (make-hash-table)) (scopes (make-hash-table)) (parents (make-hash-table))
        (empty (make-array (1+ nvars) :element-type 'bit :initial-element 0))
        (covered (make-array (1+ nvars) :element-type 'bit))
        (missing (make-array (1+ nvars) :element-type 'bit))
        (nodes (bld-nodes b)))
    (maphash (lambda (src lst) (declare (ignore src))
               (dolist (a lst) (incf (gethash (car a) parents 0))))
             arcs)
    (flet ((false-p (our-id) (= (dns-type nodes our-id) +dn-false+))
           (lit-kids (lits acc)
             (declare (type ddnnf--litvec lits))
             (loop for l across lits do (push (bld-lit b l) acc))
             acc))
      (ddnnf--d4-postorder
       root arcs
       (lambda (id)
         (let ((type (gethash id node-type)) (arcs-of (gethash id arcs)) (scope empty))
           (unless (member type '(:true :false))
             (setf scope (make-array (1+ nvars) :element-type 'bit :initial-element 0))
             (dolist (arc arcs-of)
               (bit-ior scope (gethash (car arc) scopes) scope)
               (loop for l across (the ddnnf--litvec (cdr arc))
                     do (setf (sbit scope (abs l)) 1))))
           (setf (gethash id scopes) scope
                 (gethash id built)
                 (ecase type
                   (:true (bld-true b))
                   (:false (bld-false b))
                   (:or
                    ;; OR of arcs; smooth each live arc up to the OR's scope.
                    (let ((kids '()))
                      (dolist (arc arcs-of)
                        (let ((child (gethash (car arc) built)))
                          (unless (false-p child)
                            (replace covered (gethash (car arc) scopes))
                            (loop for l across (the ddnnf--litvec (cdr arc))
                                  do (setf (sbit covered (abs l)) 1))
                            (bit-andc2 scope covered missing)
                            (push (bld-and b (nreverse
                                              (ddnnf--free-kids
                                               b missing (lit-kids (cdr arc) (list child)))))
                                  kids))))
                      (bld-or b (nreverse kids))))
                   (:and
                    ;; AND of arcs (decomposable: disjoint scopes, no smoothing needed).
                    (let ((kids '()))
                      (dolist (arc arcs-of)
                        (push (bld-and b (nreverse (lit-kids (cdr arc)
                                                             (list (gethash (car arc) built)))))
                              kids))
                      (bld-and b (nreverse kids))))))
           (remhash id arcs)
           ;; this node was each child's parent once per arc: when a child has no
           ;; parent left to build, nothing reads its scope or id again
           (dolist (arc arcs-of)
             (when (zerop (decf (gethash (car arc) parents)))
               (remhash (car arc) scopes)
               (remhash (car arc) built)))))))
    (values (gethash root built) (gethash root scopes))))

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
    (let ((dsts (make-hash-table)) (roots '())
          (b (bld-new)))
      ;; root = the one node that is never an arc destination.  More than one
      ;; such node means a truncated or corrupt dump: building from any one of
      ;; them would silently drop the others' subcircuits (and root smoothing
      ;; would then cover the variables they held), giving a wrong Z, not an
      ;; error.  With exactly one source, every node of the DAG is reachable.
      (maphash (lambda (src lst) (declare (ignore src))
                 (dolist (a lst)
                   (setf (gethash (car a) dsts) t)
                   (unless (gethash (car a) node-type)
                     (error "d4 NNF dump ~A has an arc to undeclared node ~D"
                            nnf-file (car a)))
                   (loop for l across (the ddnnf--litvec (cdr a))
                         unless (<= 1 (abs l) nvars)
                           do (error "d4 NNF dump ~A mentions variable ~D, outside 1..~D"
                                     nnf-file (abs l) nvars))))
               arcs)
      (maphash (lambda (id ty) (declare (ignore ty))
                 (unless (gethash id dsts) (push id roots)))
               node-type)
      (unless (= 1 (length roots))
        (error "d4 NNF dump ~A has ~:[no root~;~:*~D nodes with no parent (~{~D~^ ~}), ~
not one root~] -- truncated or corrupt"
               nnf-file (and roots (length roots)) (subseq roots 0 (min 5 (length roots)))))
      (multiple-value-bind (body rscope)
          (ddnnf--d4-build b (first roots) node-type arcs nvars)
        (when projected
          (let ((v (position 1 (bit-andc2 rscope projected))))
            (when v
              (error "d4's projected dump mentions variable ~D (~S), which is not in the ~
projection -- d4 did not honour the 'c p show' line, so the circuit would not be ~
the projected one"
                     v (ddnnf--var-atom a2i v)))))
        ;; root smoothing: the kept variables the circuit never mentions
        (let* ((never (bit-andc2 (or projected
                                     (let ((all (make-array (1+ nvars) :element-type 'bit
                                                                       :initial-element 1)))
                                       (setf (sbit all 0) 0)
                                       all))
                                 rscope))
               (root (bld-and b (ddnnf--free-kids b never (list body))))
               (i2a (make-array (1+ nvars))))
          (maphash (lambda (atom i) (setf (aref i2a i) atom)) a2i)
          (make-ddnnf :nodes (bld-finish b) :root root :nvars nvars :a2i a2i :i2a i2a
                      :leaf-cost cost :scale scale :clauses int-clauses
                      :projected projected))))))

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
;;; clauses.  It is saved in two formats:
;;;
;;;   TEXT (.dnnf)    one readable s-expression,
;;;                     (:FIFO-DDNNF 1 :NVARS n :ROOT r :SCALE s
;;;                      :NODES ((:T) (:F) (:L lit) (:A kid...) (:O kid...) ...)
;;;                      :ATOMS (...) :LEAF-COST ((lit cost) ...) :CLAUSES (...)
;;;                      :PROJECTED (var...))
;;;                   for other tools and for reading by eye.  Written and read a
;;;                   node at a time, never as one list in memory.
;;;   BINARY (.dnnfb) the node arrays as they are in memory, so loading is a few
;;;                   reads straight into them -- see DDNNF-SAVE-BINARY.  Native
;;;                   byte order, refused on a machine of the other order.
;;;
;;; DDNNF-LOAD takes either, telling them apart by the first bytes.
;;; ----------------------------------------------------------------------------

(defun ddnnf--meta-plist (circuit)
  "Everything in CIRCUIT but its nodes, as plain readable data."
  (let ((lc '()))
    (maphash (lambda (lit c) (push (list lit c) lc)) (ddnnf-leaf-cost circuit))
    (list :atoms (loop for v from 1 to (ddnnf-nvars circuit)
                       collect (aref (ddnnf-i2a circuit) v))
          :leaf-cost lc
          :clauses (ddnnf-clauses circuit)
          ;; the kept variables of a projected circuit (absent = not projected);
          ;; without it a reload would report the dropped atoms as marginal 0
          :projected (let ((p (ddnnf-projected circuit)))
                       (and p (loop for v from 1 to (ddnnf-nvars circuit)
                                    when (= 1 (sbit p v)) collect v))))))

(defmacro ddnnf--with-io-syntax (&body body)
  `(let ((*package* (find-package :common-lisp-user))
         (*print-readably* nil) (*print-pretty* nil) (*print-circle* nil)
         (*print-length* nil) (*print-level* nil)
         (*read-eval* nil) (*read-default-float-format* 'single-float))
     ,@body))

(defun ddnnf-save (circuit path)
  "Write CIRCUIT to PATH in the TEXT format (one s-expression).  Returns PATH."
  (ddnnf--with-io-syntax
    (let ((d (ddnnf-nodes circuit)))
      (with-open-file (out path :direction :output
                                :if-exists :supersede :if-does-not-exist :create)
        (format out "(:FIFO-DDNNF 1 :NVARS ~S :ROOT ~S :SCALE ~S :NODES ("
                (ddnnf-nvars circuit) (ddnnf-root circuit) (ddnnf-scale circuit))
        (dotimes (i (dns-n d))
          (unless (zerop i) (write-char #\Space out))
          (let ((ty (dns-type d i)))
            (cond ((= ty +dn-true+) (write-string "(:T)" out))
                  ((= ty +dn-false+) (write-string "(:F)" out))
                  ((= ty +dn-lit+) (format out "(:L ~D)" (dns-lit d i)))
                  (t (write-string (if (= ty +dn-and+) "(:A" "(:O") out)
                     (do-dns-kids (k d i) (write-char #\Space out) (write k :stream out))
                     (write-char #\) out)))))
        (write-char #\) out)
        (loop for (key val) on (ddnnf--meta-plist circuit) by #'cddr
              do (write-char #\Space out) (prin1 key out)
                 (write-char #\Space out) (prin1 val out))
        (write-char #\) out)
        (terpri out))))
  path)

;;; --- reading the text format -------------------------------------------------
;;; A character scanner over a large buffer: the node list of a big circuit is
;;; hundreds of millions of characters, and READ would cons it all into one list
;;; first.  Only the small values (atoms, costs, clauses) go through READ, from
;;; the text of each value.

(defstruct (dscan (:constructor make-dscan (stream)))
  stream
  (buf (make-string 1048576) :type simple-string)
  (pos 0 :type fixnum)
  (end 0 :type fixnum))

(defun dscan-refill (s)
  (setf (dscan-end s) (read-sequence (dscan-buf s) (dscan-stream s))
        (dscan-pos s) 0))

(declaim (inline dscan-peek dscan-next))
(defun dscan-peek (s)
  "The next character, or NIL at the end."
  (when (>= (dscan-pos s) (dscan-end s)) (dscan-refill s))
  (and (< (dscan-pos s) (dscan-end s)) (schar (dscan-buf s) (dscan-pos s))))

(defun dscan-next (s)
  (let ((c (dscan-peek s))) (when c (incf (dscan-pos s))) c))

(defun dscan-skip-space (s)
  (loop for c = (dscan-peek s)
        while (and c (or (char= c #\Space) (char= c #\Newline)
                         (char= c #\Tab) (char= c #\Return)))
        do (incf (dscan-pos s))))

(defun dscan-expect (s ch what)
  (dscan-skip-space s)
  (let ((c (dscan-next s)))
    (unless (eql c ch)
      (error "d-DNNF circuit file: expected ~S ~A, found ~S" ch what c))))

(defun dscan-int (s)
  "A decimal integer, after any whitespace."
  (dscan-skip-space s)
  (let ((neg nil) (v 0) (digits 0))
    (declare (type (unsigned-byte 60) v) (type fixnum digits))
    (when (eql (dscan-peek s) #\-) (setf neg t) (dscan-next s))
    (loop for c = (dscan-peek s)
          while (and c (char<= #\0 c #\9))
          do (when (> digits 17)
               (error "d-DNNF circuit file: integer of more than 18 digits"))
             (setf v (+ (* v 10) (- (char-code c) 48))) (incf digits) (dscan-next s))
    (when (zerop digits)
      (error "d-DNNF circuit file: expected an integer, found ~S" (dscan-peek s)))
    (if neg (- v) v)))

(defun dscan-datum-text (s)
  "The text of the next datum -- a balanced list, a string, or an atom -- with
strings, |...| and backslash escapes respected."
  (dscan-skip-space s)
  (with-output-to-string (o)
    (let ((depth 0))
      (loop
        (let ((c (dscan-peek s)))
          (cond ((null c) (return))
                ((and (zerop depth) (member c '(#\Space #\Tab #\Newline #\Return #\))))
                 (return))
                (t (write-char (dscan-next s) o)
                   (case c
                     (#\( (incf depth))
                     (#\) (decf depth) (when (zerop depth) (return)))
                     (#\\ (let ((e (dscan-next s))) (when e (write-char e o))))
                     ((#\" #\|)
                      (loop for d = (dscan-next s)
                            do (unless d (error "d-DNNF circuit file: unterminated ~C" c))
                               (write-char d o)
                               (cond ((eql d #\\) (let ((e (dscan-next s))) (when e (write-char e o))))
                                     ((eql d c) (return)))))))))))))

(defun dscan-read (s)
  (let ((text (dscan-datum-text s)))
    (when (zerop (length text)) (error "d-DNNF circuit file: truncated"))
    (read-from-string text)))

(defun dscan-nodes (s)
  "The :NODES list, straight into a DNODES."
  (let ((d (dns-new)) (kids '()))
    (dscan-expect s #\( "opening the node list")
    (loop
      (dscan-skip-space s)
      (when (eql (dscan-peek s) #\)) (dscan-next s) (return (dns-trim d)))
      (dscan-expect s #\( "opening a node")
      (dscan-expect s #\: "before a node type")
      (let ((tag (char-upcase (or (dscan-next s) #\?))))
        (case tag
          (#\T (dns-push d +dn-true+ 0 nil))
          (#\F (dns-push d +dn-false+ 0 nil))
          (#\L (dns-push d +dn-lit+ (dscan-int s) nil))
          ((#\A #\O)
           (setf kids '())
           (loop (dscan-skip-space s)
                 (when (eql (dscan-peek s) #\)) (return))
                 (push (dscan-int s) kids))
           (dns-push d (if (char= tag #\A) +dn-and+ +dn-or+) 0 (nreverse kids)))
          (t (error "d-DNNF circuit file: unknown node type :~C" tag))))
      (dscan-expect s #\) "closing a node"))))

(defun ddnnf--load-text (path)
  (ddnnf--with-io-syntax
    (let ((*read-default-float-format* 'double-float) (data '()) (nodes nil))
      (with-open-file (in path :direction :input)
        (let ((s (make-dscan in)))
          (dscan-expect s #\( "at the start")
          (unless (eq (dscan-read s) :fifo-ddnnf)
            (error "~A is not a FiFO d-DNNF circuit file" path))
          (let ((version (dscan-read s)))
            (unless (eql version 1)
              (error "unsupported d-DNNF circuit file version ~S in ~A" version path)))
          (loop
            (dscan-skip-space s)
            (when (eql (dscan-peek s) #\)) (return))
            (let ((key (dscan-read s)))
              (if (eq key :nodes)
                  (setf nodes (dscan-nodes s))
                  (setf (getf data key) (dscan-read s)))))))
      (unless nodes (error "~A has no :NODES" path))
      (ddnnf--assemble path nodes data))))

(defun ddnnf--assemble (path nodes data)
  "A DDNNF from NODES and the plist DATA (:nvars :root :scale :atoms :leaf-cost
:clauses :projected), after checking NODES against it."
  ;; check first: it names a bad :NVARS, which the allocations below would hit as
  ;; a bare type error
  (ddnnf--check-nodes path nodes (getf data :nvars) (getf data :root))
  (let* ((nvars (getf data :nvars))
         (a2i (make-hash-table :test 'equal))
         (i2a (make-array (1+ nvars)))
         (cost (make-hash-table :test 'eql)))
    (unless (<= (length (getf data :atoms)) nvars)
      (error "~A: ~D atoms for ~D variables" path (length (getf data :atoms)) nvars))
    (dolist (v (getf data :projected))
      (unless (and (integerp v) (<= 1 v nvars))
        (error "~A: projected variable ~S out of range 1..~D" path v nvars)))
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
                                 (dolist (v kept p) (setf (sbit p v) 1))))))))

(defun ddnnf--check-nodes (path d nvars root)
  "The evaluator indexes arrays by literal and by child id, with safety off in
its loops; a stale, edited or truncated file must fail here, by name, instead."
  (let ((n (dns-n d)) (types (dns-types d)) (lits (dns-lits d))
        (ks (dns-kstart d)) (kids (dns-kids d)))
    (declare (type fixnum n) (type dn-ids kids))
    (unless (and (integerp nvars) (>= nvars 0))
      (error "~A: bad :NVARS ~S" path nvars))
    (unless (and (integerp root) (< -1 root n))
      (error "~A: root ~S is not one of the ~D nodes" path root n))
    (unless (and (= (length types) n) (= (length lits) n) (= (length ks) (1+ n))
                 (zerop (aref ks 0)) (= (aref ks n) (length kids)))
      (error "~A: the node arrays are inconsistent (truncated?)" path))
    (dotimes (i n)
      (let ((ty (aref types i)))
        (when (> ty +dn-or+) (error "~A: node ~D has unknown type ~D" path i ty))
        (when (> (aref ks i) (aref ks (1+ i)))
          (error "~A: node ~D has a negative child count" path i))
        (cond ((>= ty +dn-and+)
               (loop for j from (aref ks i) below (aref ks (1+ i))
                     unless (< (aref kids j) i)
                       do (error "~A: node ~D has child ~S, which does not precede it"
                                 path i (aref kids j))))
              ((/= (aref ks i) (aref ks (1+ i)))
               (error "~A: leaf node ~D has children" path i))
              ((and (= ty +dn-lit+) (not (<= 1 (abs (aref lits i)) nvars)))
               (error "~A: node ~D is a leaf for literal ~S, outside 1..~D"
                      path i (aref lits i) nvars)))))))

;;; --- the binary format ------------------------------------------------------
;;;   bytes 0-7    "FIFODNB1"
;;;   then 4 words of 64 bits: #x0102030405060708 (byte order), nodes N,
;;;                children K, metadata length M
;;;   M bytes      UTF-8 text of the plist (:NVARS :ROOT :SCALE :ATOMS ...)
;;;   N bytes      types;   4N bytes  literals;   8(N+1) bytes  child offsets;
;;;   4K bytes     children
;;; each section starting on an 8-byte boundary.

(defparameter *ddnnf-binary-magic* "FIFODNB1")

(defun ddnnf--pad8 (n) (* 8 (ceiling n 8)))

(defun ddnnf--fd-io (fd vec nbytes write)
  "Read (or with WRITE, write) the first NBYTES bytes of the specialized vector
VEC from (to) file descriptor FD, looping over short transfers."
  (sb-sys:with-pinned-objects (vec)
    (let ((sap (sb-sys:vector-sap vec)) (off 0))
      (loop while (< off nbytes) do
        (let ((chunk (min (- nbytes off) (ash 1 30))))
          (multiple-value-bind (got err)
              (if write
                  (sb-unix:unix-write fd (sb-sys:sap+ sap off) 0 chunk)
                  (sb-unix:unix-read fd (sb-sys:sap+ sap off) chunk))
            (unless (and got (plusp got))
              (error "~:[reading~;writing~] a binary d-DNNF circuit failed~@[ (errno ~D)~]"
                     write (and (null got) err)))
            (incf off got)))))))

(defun ddnnf--fd-skip (fd nbytes)
  (when (plusp nbytes)
    (ddnnf--fd-io fd (make-array nbytes :element-type '(unsigned-byte 8)) nbytes nil)))

(defun ddnnf--path-ends-p (path suffix)
  (let ((p (namestring path)))
    (and (> (length p) (length suffix))
         (string-equal suffix p :start2 (- (length p) (length suffix))))))

(defun ddnnf--binary-path (path)
  "Where --save-circuit PATH puts the binary copy: x.dnnf -> x.dnnfb, x.dnnfb
itself (binary only, see DDNNF-MARGINALS), else PATH.dnnfb."
  (let ((p (namestring path)))
    (cond ((ddnnf--path-ends-p p ".dnnfb") p)
          ((ddnnf--path-ends-p p ".dnnf") (concatenate 'string p "b"))
          (t (concatenate 'string p ".dnnfb")))))

(defun ddnnf-save-binary (circuit path)
  "Write CIRCUIT to PATH in the BINARY format.  Returns PATH."
  (let* ((d (ddnnf-nodes circuit)) (n (dns-n d)) (k (aref (dns-kstart d) n))
         (meta (sb-ext:string-to-octets
                (ddnnf--with-io-syntax
                  (prin1-to-string (list* :nvars (ddnnf-nvars circuit)
                                          :root (ddnnf-root circuit)
                                          :scale (ddnnf-scale circuit)
                                          (ddnnf--meta-plist circuit))))
                :external-format :utf-8))
         (head (make-array 4 :element-type '(unsigned-byte 64)
                             :initial-contents (list #x0102030405060708 n k (length meta))))
         (offsets (make-array (1+ n) :element-type '(unsigned-byte 64))))
    (dotimes (i (1+ n)) (setf (aref offsets i) (aref (dns-kstart d) i)))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede :if-does-not-exist :create)
      (let ((fd (sb-sys:fd-stream-fd out))
            (zeros (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0)))
        (flet ((section (vec nbytes)
                 (ddnnf--fd-io fd vec nbytes t)
                 (ddnnf--fd-io fd zeros (- (ddnnf--pad8 nbytes) nbytes) t)))
          (section (sb-ext:string-to-octets *ddnnf-binary-magic* :external-format :ascii) 8)
          (section head 32)
          (section meta (length meta))
          (section (dns-types d) n)
          (section (dns-lits d) (* 4 n))
          (section offsets (* 8 (1+ n)))
          (section (dns-kids d) (* 4 k))))))
  path)

(defun ddnnf--binary-file-p (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((b (make-array 8 :element-type '(unsigned-byte 8))))
      (and (= 8 (read-sequence b in))
           (string= (map 'string #'code-char b) *ddnnf-binary-magic*)))))

(defun ddnnf--load-binary (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((fd (sb-sys:fd-stream-fd in))
          (head (make-array 4 :element-type '(unsigned-byte 64))))
      (flet ((section (vec nbytes)
               (ddnnf--fd-io fd vec nbytes nil)
               (ddnnf--fd-skip fd (- (ddnnf--pad8 nbytes) nbytes))
               vec))
        (ddnnf--fd-skip fd 8)
        (section head 32)
        (unless (= (aref head 0) #x0102030405060708)
          (error "~A was written on a machine of the other byte order" path))
        (let* ((n (aref head 1)) (k (aref head 2)) (m (aref head 3))
               (size (file-length in)))
          ;; the sizes come from the file: check them against its length before
          ;; allocating anything, so a corrupt header is an error, not a huge array
          (unless (= size (+ 40 (ddnnf--pad8 m) (ddnnf--pad8 n) (ddnnf--pad8 (* 4 n))
                             (* 8 (1+ n)) (ddnnf--pad8 (* 4 k))))
            (error "~A: binary circuit file is ~:D bytes, not what its header implies -- ~
truncated or corrupt" path size))
          (let* ((meta (section (make-array m :element-type '(unsigned-byte 8)) m))
                 (data (ddnnf--with-io-syntax
                         (let ((*read-default-float-format* 'double-float))
                           (read-from-string
                            (sb-ext:octets-to-string meta :external-format :utf-8)))))
                 (types (section (make-array n :element-type '(unsigned-byte 8)) n))
                 (lits (section (make-array n :element-type '(signed-byte 32)) (* 4 n)))
                 (offsets (section (make-array (1+ n) :element-type '(unsigned-byte 64))
                                   (* 8 (1+ n))))
                 (kids (section (make-array k :element-type '(unsigned-byte 32)) (* 4 k)))
                 (kstart (make-array (1+ n) :element-type 'fixnum)))
            (dotimes (i (1+ n))
              (let ((o (aref offsets i)))
                (unless (<= o k) (error "~A: child offset ~D past the ~D children" path o k))
                (setf (aref kstart i) o)))
            (ddnnf--assemble path (%make-dnodes :n n :types types :lits lits
                                                :kstart kstart :kids kids)
                             data)))))))

(defun ddnnf-load (path)
  "Reconstruct a circuit written by DDNNF-SAVE (text) or DDNNF-SAVE-BINARY.
Returns a DDNNF struct ready to query -- no recompilation."
  (if (ddnnf--binary-file-p path)
      (ddnnf--load-binary path)
      (ddnnf--load-text path)))

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

(defun ddnnf--leaf-weights (c clamp)
  "Every literal's leaf weight, computed once per query: a vector indexed by
LIT + NVARS (so -nvars..nvars maps to 0..2*nvars)."
  (let* ((nv (ddnnf-nvars c))
         (w (make-array (1+ (* 2 nv)) :element-type 'double-float :initial-element 1d0)))
    (loop for v from 1 to nv do
      (setf (aref w (+ nv v)) (ddnnf--leaf-weight c v clamp)
            (aref w (- nv v)) (ddnnf--leaf-weight c (- v) clamp)))
    w))

(defun ddnnf--eval (c clamp)
  "UP pass.  Returns (values Z value-vector); Z is the root value."
  (let* ((d (ddnnf-nodes c)) (n (dns-n d))
         (types (dns-types d)) (lits (dns-lits d)) (ks (dns-kstart d)) (kids (dns-kids d))
         (nv (ddnnf-nvars c))
         (lw (ddnnf--leaf-weights c clamp))
         (val (make-array n :element-type 'double-float :initial-element 0d0)))
    (declare (type (simple-array double-float (*)) val lw) (type fixnum n nv)
             (type (simple-array (unsigned-byte 8) (*)) types)
             (type (simple-array (signed-byte 32) (*)) lits)
             (type (simple-array fixnum (*)) ks) (type dn-ids kids))
    (dotimes (i n)
      (let ((ty (aref types i)))
        (setf (aref val i)
              (cond ((= ty +dn-true+) 1d0)
                    ((= ty +dn-false+) 0d0)
                    ((= ty +dn-lit+) (aref lw (+ nv (aref lits i))))
                    ((= ty +dn-and+)
                     (let ((p 1d0))
                       (declare (type double-float p))
                       (loop for j of-type fixnum from (aref ks i) below (aref ks (1+ i))
                             do (setf p (* p (aref val (aref kids j)))))
                       p))
                    (t
                     (let ((s 0d0))
                       (declare (type double-float s))
                       (loop for j of-type fixnum from (aref ks i) below (aref ks (1+ i))
                             do (incf s (aref val (aref kids j))))
                       s))))))
    (values (aref val (ddnnf-root c)) val)))

(defun ddnnf--marginals-vec (c val)
  "DOWN pass over the (smooth, deterministic) circuit.  Returns a vector ZTRUE,
1..nvars, where ZTRUE[v] is the unnormalized weight of the models with v true."
  (let* ((d (ddnnf-nodes c)) (n (dns-n d))
         (types (dns-types d)) (lits (dns-lits d)) (ks (dns-kstart d)) (kids (dns-kids d))
         (der (make-array n :element-type 'double-float :initial-element 0d0))
         (ztrue (make-array (1+ (ddnnf-nvars c)) :element-type 'double-float
                                                 :initial-element 0d0))
         ;; scratch for one AND node: the product of the values of the children
         ;; before each one
         (pre (make-array 16 :element-type 'double-float)))
    (declare (type (simple-array double-float (*)) val der ztrue pre) (type fixnum n)
             (type (simple-array (unsigned-byte 8) (*)) types)
             (type (simple-array (signed-byte 32) (*)) lits)
             (type (simple-array fixnum (*)) ks) (type dn-ids kids))
    (setf (aref der (ddnnf-root c)) 1d0)
    (loop for i of-type fixnum from (1- n) downto 0 do
      (let ((di (aref der i)) (ty (aref types i))
            (k0 (aref ks i)) (k1 (aref ks (1+ i))))
        (declare (type double-float di) (type fixnum k0 k1))
        (unless (zerop di)
          (cond
            ((= ty +dn-or+)
             (loop for j of-type fixnum from k0 below k1
                   do (incf (aref der (aref kids j)) di)))
            ((= ty +dn-and+)
             ;; d[k] += d[i] * (product of the other children's values).  Each
             ;; child's product is prefix * suffix -- the children before it times
             ;; those after -- so a node with m children costs O(m), not O(m^2),
             ;; and with no division a zero-valued sibling is still exact.
             (let ((m (- k1 k0)))
               (declare (type fixnum m))
               (when (> m (length pre))
                 (setf pre (make-array (max m (* 2 (length pre))) :element-type 'double-float)))
               (let ((p 1d0))
                 (declare (type double-float p))
                 (loop for j of-type fixnum from 0 below m
                       do (setf (aref pre j) p
                                p (* p (aref val (aref kids (+ k0 j)))))))
               (let ((s 1d0))
                 (declare (type double-float s))
                 (loop for j of-type fixnum from (1- m) downto 0 do
                   (let ((k (aref kids (+ k0 j))))
                     (incf (aref der k) (* di (aref pre j) s))
                     (setf s (* s (aref val k))))))))))))
    ;; Each model uses exactly one +v leaf (smoothness + determinism), so summing
    ;; value*derivative over the +v leaves gives Z[v=true] with no double counting.
    (dotimes (i n)
      (when (and (= (aref types i) +dn-lit+) (plusp (aref lits i)))
        (incf (aref ztrue (aref lits i)) (* (aref val i) (aref der i)))))
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
saved by DDNNF-SAVE or DDNNF-SAVE-BINARY (either format), in which case NO
recompilation happens -- or, when CIRCUIT is NIL, by compiling SCNF-FILE.
COMPILER selects the front end: :home (default) uses the built-in trace compiler;
:d4 shells out to the external d4 (d4v2) compiler (at D4) and smooths its dump.
With SAVE-CIRCUIT (a path), the base circuit is written there in the text format
for reuse on later calls, and in the binary format beside it (x.dnnf -> x.dnnfb,
see DDNNF--BINARY-PATH), which loads much faster; a path ending in .dnnfb gets
the binary format only.

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
      ;; both formats -- the text for other tools, the binary to load fast --
      ;; unless the name asks for the binary alone (x.dnnfb): writing text into a
      ;; .dnnfb would make every reload take the slow path
      (let ((bin (ddnnf--binary-path save-circuit))
            (text (not (ddnnf--path-ends-p save-circuit ".dnnfb"))))
        (when text (ddnnf-save base save-circuit))
        (ddnnf-save-binary base bin)
        (when verbose
          (if text
              (format t "; saved compiled circuit to ~A (and binary ~A)~%" save-circuit bin)
              (format t "; saved compiled circuit to ~A (binary)~%" bin)))))
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
