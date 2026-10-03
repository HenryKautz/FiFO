;;; tseitin-property.lisp -- property test for the compact (Tseitin) encoding.
;;;
;;; For random propositional formulas F over atoms A..F, instantiate F with the
;;; compact encoding ON and OFF, each through the real scnf file round trip, and
;;; check that
;;;     #models(scnf) = #models(F by its truth table)
;;; for both, counting over EVERY atom in the scnf.  A free or under-defined
;;; auxiliary atom therefore shows up as a factor of 2 -- which is exactly how the
;;; old selector failed (it was free whenever both sides of the OR held, and as an
;;; uninterned gensym it fell apart into one atom per clause on the round trip).
;;; The count is a brute-force enumeration sharing no code with FiFO's counters.
;;;
;;; It also counts the formulas that actually produced (TSEITIN ...) atoms and
;;; FAILS if there were none: a run in which the compact encoding never fired
;;; would pass vacuously.  (A first version did, because an (option
;;; *compact-encoding* 0) line SETQs the global, which then stayed off for every
;;; later instantiation in the process -- hence the per-call LET below.)
;;;
;;;   FIFO=<path to FiFO.lisp>  SEED=<n>  TRIALS=<n>  sbcl --non-interactive --load tseitin-property.lisp
;;; Exit 0 on success.

(load (or (uiop:getenv "FIFO") (error "set FIFO to the FiFO.lisp to test")))

(defparameter *atoms* '(a b c d e f))
(defvar *rs* (sb-ext:seed-random-state (parse-integer (or (uiop:getenv "SEED") "1"))))

(defun rand-formula (depth)
  (if (or (zerop depth) (< (random 1.0 *rs*) 0.2))
      (let ((a (nth (random (length *atoms*) *rs*) *atoms*)))
        (if (< (random 1.0 *rs*) 0.3) (list 'not a) a))
      (case (random 3 *rs*)
        (0 (cons 'and (loop repeat (+ 2 (random 2 *rs*)) collect (rand-formula (1- depth)))))
        (1 (cons 'or  (loop repeat (+ 2 (random 2 *rs*)) collect (rand-formula (1- depth)))))
        (t (list 'not (rand-formula (1- depth)))))))

(defun eval-formula (f env)
  (cond ((symbolp f) (gethash f env))
        ((eq (car f) 'not) (not (eval-formula (cadr f) env)))
        ((eq (car f) 'and) (every (lambda (g) (eval-formula g env)) (cdr f)))
        ((eq (car f) 'or) (some (lambda (g) (eval-formula g env)) (cdr f)))))

(defun truth-count (f)
  "Models of F over *ATOMS*, by its truth table."
  (let ((env (make-hash-table)) (n 0) (k (length *atoms*)))
    (dotimes (m (expt 2 k) n)
      (loop for a in *atoms* for i from 0 do (setf (gethash a env) (logbitp i m)))
      (when (eval-formula f env) (incf n)))))

(defun lit-true (lit env)
  (if (and (consp lit) (eq (car lit) 'not))
      (not (gethash (cadr lit) env))
      (gethash lit env)))

(defun scnf-count (clauses)
  "Models of CLAUSES over every atom in them plus any of *ATOMS* they lack (an
atom the formula mentions but simplification dropped is free in both counts)."
  (let* ((atoms (remove-duplicates
                 (append *atoms*
                         (loop for cl in clauses
                               append (mapcar (lambda (l) (if (and (consp l) (eq (car l) 'not)) (cadr l) l))
                                              (cdr cl))))
                 :test #'equal))
         (env (make-hash-table :test #'equal)) (n 0) (k (length atoms)))
    (when (> k 22) (return-from scnf-count :too-big))
    (dotimes (m (expt 2 k) n)
      (loop for a in atoms for i from 0 do (setf (gethash a env) (logbitp i m)))
      (when (every (lambda (cl) (some (lambda (l) (lit-true l env)) (cdr cl))) clauses)
        (incf n)))))

(defun instantiate-count (f compact)
  "Instantiate F (compact encoding on or off) and count the models of the scnf
READ BACK from disk.  Second value: whether any TSEITIN atom was produced."
  (let ((wff "tseitin-prop.wff") (scnf "tseitin-prop.scnf"))
    (with-open-file (s wff :direction :output :if-exists :supersede)
      (format s "~S~%" f))
    (let ((*compact-encoding* compact))
      (instantiate wff :scnfile scnf))
    (let ((clauses (with-open-file (s scnf)
                     (loop for x = (read s nil :eof) until (eq x :eof)
                           when (and (consp x) (eq (car x) 'or)) collect x))))
      (values (scnf-count clauses)
              (some (lambda (cl) (some (lambda (l) (search "TSEITIN" (princ-to-string l))) (cdr cl)))
                    clauses)))))

(let ((trials (parse-integer (or (uiop:getenv "TRIALS") "300")))
      (bad 0) (with-aux 0) (skipped 0))
  (dotimes (i trials)
    (let* ((f (rand-formula 4))
           (want (truth-count f)))
      (multiple-value-bind (on aux) (instantiate-count f t)
        (let ((off (instantiate-count f nil)))
          (when aux (incf with-aux))
          (cond ((or (eq on :too-big) (eq off :too-big)) (incf skipped))
                ((not (and (eql on want) (eql off want)))
                 (incf bad)
                 (format t "MISMATCH truth ~D compact ~A explicit ~A~%  ~S~%" want on off f)))))))
  (format t "trials ~D, with TSEITIN atoms ~D, skipped (too many atoms) ~D, mismatches ~D~%"
          trials with-aux skipped bad)
  (sb-ext:exit :code (if (and (zerop bad) (plusp with-aux)) 0 1)))
