;;; ddnnf-eval-property.lisp -- property test for the circuit evaluator
;;; (ddnnf-query: the up pass, and the down pass with prefix/suffix products at
;;; AND nodes), against brute-force enumeration that shares no code with it.
;;;
;;; Each trial builds a random SMOOTH d-DNNF directly as a DDNNF struct --
;;; decision ORs (x AND A) OR (-x AND B), decomposable ANDs over a partition of
;;; the variables, leaves +v / -v / free(v) -- with random literal costs and a
;;; random evidence clamp, then compares Z and every Z[v=true] with the sums over
;;; all 2^n assignments of (weight of the assignment) for those the circuit's
;;; BOOLEAN value accepts.  Some trials force a root AND of 17+ children, so the
;;; down pass grows its 16-slot scratch arrays.  Refuses to pass vacuously: a
;;; wide AND must occur, a clamp must zero some leaf, and some marginal must lie
;;; strictly between 0 and 1.
;;;
;;; Prints "PROPERTY ok <trials> <max AND width>" or "PROPERTY FAIL ...".
(load (merge-pathnames "ddnnf.lisp" (concatenate 'string (sb-posix:getenv "FIFO_LISP") "/")))

(defvar *rs* (sb-ext:seed-random-state 20261016))
(defun rnd (n) (random n *rs*))

(defun gen (nodes vars)
  "Push nodes for a random smooth subcircuit over VARS (a list) onto NODES;
return its id."
  (labels ((add (nd) (vector-push-extend nd nodes) (1- (fill-pointer nodes)))
           (lit (l) (add (mk-dnode :lit :lit l))))
    (cond ((null vars) (add (mk-dnode :true)))
          ((null (cdr vars))
           (let ((v (car vars)))
             (case (rnd 3)
               (0 (lit v)) (1 (lit (- v)))
               (t (add (mk-dnode :or :kids (list (lit v) (lit (- v)))))))))
          ((zerop (rnd 2))            ; decision on the first variable
           (let* ((x (car vars))
                  (a (gen nodes (cdr vars))) (pa (lit x))
                  (bb (gen nodes (cdr vars))) (pb (lit (- x))))
             (add (mk-dnode :or :kids (list (add (mk-dnode :and :kids (list pa a)))
                                            (add (mk-dnode :and :kids (list pb bb))))))))
          (t                          ; decomposable split into 2..4 parts
           (let ((parts (make-array (+ 2 (rnd 3)) :initial-element nil)))
             (dolist (v vars) (push v (aref parts (rnd (length parts)))))
             (add (mk-dnode :and :kids (loop for p across parts collect (gen nodes p)))))))))

(defun make-trial (n wide)
  "A random circuit over 1..N.  WIDE: the root is an AND of one random
subcircuit over the first few variables and a leaf per remaining variable."
  (let ((nodes (make-array 64 :adjustable t :fill-pointer 0))
        (vars (loop for v from 1 to n collect v)))
    (let ((root (if wide
                    (let* ((k (+ 2 (rnd 3)))
                           (kids (cons (gen nodes (subseq vars 0 k))
                                       (loop for v in (nthcdr k vars)
                                             collect (gen nodes (list v))))))
                      (vector-push-extend (mk-dnode :and :kids kids) nodes)
                      (1- (fill-pointer nodes)))
                    (gen nodes vars)))
          (cost (make-hash-table)) (clamp (make-hash-table)))
      (loop for v from 1 to n
            do (when (< (rnd 10) 7) (setf (gethash v cost) (float (rnd 300) 1d0)))
               (when (< (rnd 10) 3) (setf (gethash (- v) cost) (float (rnd 300) 1d0)))
               (when (< (rnd 10) 2) (setf (gethash v clamp) (if (zerop (rnd 2)) 1 -1))))
      (values (make-ddnnf :nodes nodes :root root :nvars n :leaf-cost cost :scale 100d0)
              (and (plusp (hash-table-count clamp)) clamp)))))

(defun brute (c clamp)
  "Z and Z[v=true] by enumerating every assignment."
  (let* ((n (ddnnf-nvars c)) (nodes (ddnnf-nodes c)) (m (fill-pointer nodes))
         (truth (make-array m)) (z 0d0) (zt (make-array (1+ n) :initial-element 0d0)))
    (dotimes (bits (ash 1 n))
      (flet ((val (v) (logbitp (1- v) bits)))
        (unless (and clamp
                     (loop for v from 1 to n
                           thereis (let ((r (gethash v clamp)))
                                     (and r (not (eq (val v) (= r 1)))))))
          (dotimes (i m)
            (let ((nd (aref nodes i)))
              (setf (aref truth i)
                    (ecase (dn-type nd)
                      (:true t) (:false nil)
                      (:lit (let ((l (dn-lit nd))) (eq (val (abs l)) (plusp l))))
                      (:and (every (lambda (k) (aref truth k)) (dn-kids nd)))
                      (:or (some (lambda (k) (aref truth k)) (dn-kids nd)))))))
          (when (aref truth (ddnnf-root c))
            (let ((w 1d0))
              (loop for v from 1 to n
                    for cost = (gethash (if (val v) v (- v)) (ddnnf-leaf-cost c))
                    when cost do (setf w (* w (exp (- (/ cost 100d0))))))
              (incf z w)
              (loop for v from 1 to n when (val v) do (incf (aref zt v) w)))))))
    (values z zt)))

(defun max-and-width (c)
  (loop for nd across (ddnnf-nodes c)
        when (eq (dn-type nd) :and) maximize (length (dn-kids nd))))

(let ((trials 0) (widest 0) (zeroed nil) (inner nil) (fails '()))
  (dolist (spec '((40 8 nil) (40 11 nil) (6 19 t) (6 20 t)))
    (destructuring-bind (count n wide) spec
      (dotimes (i count)
        (multiple-value-bind (c clamp) (make-trial n wide)
          (multiple-value-bind (bz bzt) (brute c clamp)
            (when (plusp bz)          ; skip a clamp that rules out every model
              (incf trials)
              (setf widest (max widest (max-and-width c)))
              (when clamp (setf zeroed t))
              (multiple-value-bind (z zt) (ddnnf-query c :clamp clamp)
                (unless (< (abs (- z bz)) (* 1d-9 bz))
                  (push (list :n n :z z :brute bz) fails))
                (loop for v from 1 to n
                      for p = (/ (aref zt v) z) for bp = (/ (aref bzt v) bz)
                      do (when (< 1d-6 bp (- 1 1d-6)) (setf inner t))
                         (unless (< (abs (- p bp)) 1d-9)
                           (push (list :n n :var v :p p :brute bp) fails))))))))))
  (cond (fails (format t "PROPERTY FAIL ~D mismatches, e.g. ~S~%" (length fails) (first fails)))
        ((< widest 17) (format t "PROPERTY FAIL vacuous: widest AND has ~D children~%" widest))
        ((not zeroed) (format t "PROPERTY FAIL vacuous: no clamp zeroed a leaf~%"))
        ((not inner) (format t "PROPERTY FAIL vacuous: every marginal is 0 or 1~%"))
        (t (format t "PROPERTY ok ~D ~D~%" trials widest))))
