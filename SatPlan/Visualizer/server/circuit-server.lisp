;;;; circuit-server.lisp -- the Lisp side of the circuit visualizer's server.
;;;;
;;;; Loaded after FiFO.lisp and ddnnf.lisp; (cv-serve) then reads one command
;;;; per line from standard input and answers each with any number of log lines
;;;; followed by exactly one line
;;;;
;;;;     @@REPLY <json>
;;;;
;;;; Commands (only these; nothing else is evaluated):
;;;;
;;;;   (cv-load "<circuit>" ("(at pkg1 p1-3)" ...))
;;;;       load a circuit saved by marginals.sh --save-circuit (text or binary)
;;;;       and resolve each goal literal to its hypothesis atom (HOLDS <goal> H),
;;;;       H the highest slice of any HOLDS atom in the circuit; evaluate once
;;;;       without evidence (Z and every atom's true-weight, kept for P(E|h)).
;;;;   (cv-actions)
;;;;       the OCCURS atoms the circuit keeps, for entering evidence by hand.
;;;;   (cv-query ("(occurs (drive truck1 p2-3 p3-3) 1)" "(not (occurs ...))" ...))
;;;;       clamp those unit literals and evaluate: per hypothesis P(h|E), and the
;;;;       likelihood P(E|h) = Z(E,h)/Z(h) normalized over the hypotheses.
;;;;   (cv-quit)
;;;;
;;;; Only unit literals over atoms the circuit keeps can be clamped; anything
;;;; else (an ordering form, a compound formula, a projected-away atom) would
;;;; need a recompile and is refused, with the reason.  See CIRCUIT-PLAN.md.

(defvar *cv* nil "The loaded DDNNF circuit.")
(defvar *cv-path* nil)
(defvar *cv-hyps* nil "One (goal-text atom var-or-nil) per hypothesis, in order.")
(defvar *cv-z0* nil "Z of the circuit without evidence.")
(defvar *cv-zt0* nil "Every variable's true-weight without evidence.")

;;; ------------------------------------------------------------------ JSON

(defun cv--json-string (s out)
  (write-char #\" out)
  (loop for c across s
        do (case c
             (#\" (write-string "\\\"" out))
             (#\\ (write-string "\\\\" out))
             (#\Newline (write-string "\\n" out))
             (#\Tab (write-string "\\t" out))
             (t (if (< (char-code c) 32)
                    (format out "\\u~4,'0X" (char-code c))
                    (write-char c out)))))
  (write-char #\" out))

(defun cv--json (x out)
  "Write X as JSON: a plist with keyword keys is an object, :null/nil-as-false
by key convention is handled by the caller, a vector or list an array."
  (cond ((eq x :null) (write-string "null" out))
        ((eq x :true) (write-string "true" out))
        ((eq x :false) (write-string "false" out))
        ((stringp x) (cv--json-string x out))
        ((integerp x) (format out "~D" x))
        ((realp x)
         (let ((d (coerce x 'double-float)))
           (if (or (sb-ext:float-infinity-p d) (sb-ext:float-nan-p d))
               (write-string "null" out)
               ;; ~E keeps full precision and stays valid JSON (1.5e-300, 2.0e+30)
               (let ((*read-default-float-format* 'double-float))
                 (write-string (substitute #\e #\d (format nil "~,16,3E" d)) out)))))
        ((and (consp x) (keywordp (car x)))
         (write-char #\{ out)
         (loop for (k v) on x by #'cddr for first = t then nil
               do (unless first (write-char #\, out))
                  (cv--json-string (string-downcase (symbol-name k)) out)
                  (write-char #\: out)
                  (cv--json v out))
         (write-char #\} out))
        ((or (listp x) (vectorp x))
         (write-char #\[ out)
         (let ((first t))
           (map nil (lambda (e)
                      (unless first (write-char #\, out))
                      (setf first nil)
                      (cv--json e out))
                x))
         (write-char #\] out))
        (t (cv--json-string (princ-to-string x) out))))

(defun cv--reply (plist)
  (format t "~&@@REPLY ")
  (cv--json plist *standard-output*)
  (terpri)
  (finish-output))

(defun cv--text (atom)
  "An atom as lower-case text, the way the page and PDDL write it."
  (let ((*print-case* :downcase)) (prin1-to-string atom)))

;;; ----------------------------------------------------------------- atoms

(defun cv--read (text)
  "TEXT read as one s-expression in CL-USER, with *read-eval* off."
  (let ((*read-eval* nil) (*package* (find-package "COMMON-LISP-USER")))
    (read-from-string text)))

(defun cv--kept-p (var)
  (let ((proj (ddnnf-projected *cv*)))
    (or (null proj) (= 1 (sbit proj var)))))

(defun cv--horizon ()
  "The highest slice of any (HOLDS fluent s) atom in the circuit's map."
  (let ((h nil))
    (maphash (lambda (atom v)
               (declare (ignore v))
               (when (and (consp atom) (string= (symbol-name (first atom)) "HOLDS")
                          (integerp (third atom)))
                 (setf h (max (or h 0) (third atom)))))
             (ddnnf-a2i *cv*))
    h))

;;; -------------------------------------------------------------- commands

(defun cv-load (path goals)
  (let ((start (get-internal-real-time)))
    (setf *cv* (ddnnf-load path) *cv-path* path)
    (let* ((h (cv--horizon))
           (a2i (ddnnf-a2i *cv*)))
      (setf *cv-hyps*
            (loop for g in goals
                  for atom = (and h (list 'holds (cv--read g) h))
                  for v = (and atom (gethash atom a2i))
                  collect (list g atom (and v (cv--kept-p v) v))))
      (multiple-value-bind (z zt) (ddnnf-query *cv*)
        (setf *cv-z0* z *cv-zt0* zt))
      (cv--reply
       (list :ok :true
             :path (namestring path)
             :nvars (ddnnf-nvars *cv*)
             :nodes (dns-n (ddnnf-nodes *cv*))
             :projected (let ((p (ddnnf-projected *cv*))) (if p (count 1 p) :null))
             :horizon (or h :null)
             :z0 *cv-z0*
             :actions (cv--count-actions)
             :hypotheses (loop for (g atom v) in *cv-hyps*
                               collect (list :goal g
                                             :atom (if atom (cv--text atom) :null)
                                             :present (if v :true :false)))
             :ms (round (* 1000 (- (get-internal-real-time) start))
                        internal-time-units-per-second))))))

(defun cv--occurs-p (atom)
  (and (consp atom) (string= (symbol-name (first atom)) "OCCURS")))

(defun cv--count-actions ()
  (let ((n 0))
    (maphash (lambda (atom v) (when (and (cv--occurs-p atom) (cv--kept-p v)) (incf n)))
             (ddnnf-a2i *cv*))
    n))

(defun cv-actions ()
  (let ((out '()))
    (maphash (lambda (atom v) (when (and (cv--occurs-p atom) (cv--kept-p v))
                                (push (cv--text atom) out)))
             (ddnnf-a2i *cv*))
    (cv--reply (list :ok :true :actions (sort out #'string<)))))

(defun cv--literal (text)
  "TEXT as (values var sign problem): SIGN +1/-1; PROBLEM a reason it cannot be
clamped (then VAR is NIL), :unknown when the atom is not in the circuit."
  (let ((form (handler-case (cv--read text)
                (error () (return-from cv--literal (values nil nil "cannot be read"))))))
    (let* ((neg (and (consp form) (string= (symbol-name (first form)) "NOT")))
           (atom (if neg (second form) form)))
      (cond ((not (consp atom))
             (values nil nil "is not an atom"))
            ((member (symbol-name (first atom))
                     '("AND" "OR" "NOT" "IMPLIES" "EQUIV" "OCCUR-IN-ORDER" "ALL" "EXISTS")
                     :test #'string=)
             (values nil nil (format nil "is an (~(~A~) ...) form, not a single literal: ~
it would need the circuit recompiled with it, which this page does not do"
                                     (symbol-name (first atom)))))
            (t
             (let ((v (gethash atom (ddnnf-a2i *cv*))))
               (cond ((null v) (values nil nil :unknown))
                     ((not (cv--kept-p v))
                      (values nil nil "names an atom this projected circuit dropped: it would need a recompile"))
                     (t (values v (if neg -1 1) nil)))))))))

(defun cv-query (literals)
  (unless *cv* (return-from cv-query (cv--reply (list :error "no circuit loaded"))))
  (let ((start (get-internal-real-time))
        (clamp (make-hash-table)) (unknown '()) (refused '()) (conflict nil))
    (dolist (text literals)
      (multiple-value-bind (v sign problem) (cv--literal text)
        (cond ((eq problem :unknown) (push text unknown))
              (problem (push (list :literal text :reason problem) refused))
              (t (let ((old (gethash v clamp)))
                   (when (and old (/= old sign)) (setf conflict t))
                   (setf (gethash v clamp) sign))))))
    (if (or unknown refused)
        (cv--reply (list :ok :false :unknown (nreverse unknown) :refused (nreverse refused)))
        (multiple-value-bind (z val) (if conflict (values 0d0 nil) (ddnnf--eval *cv* clamp))
          (if (<= z 0d0)
              (cv--reply (list :ok :true :unsat :true :z 0 :z0 *cv-z0* :pe 0
                               :ms (round (* 1000 (- (get-internal-real-time) start))
                                          internal-time-units-per-second)))
              (let* ((zt (ddnnf--marginals-vec *cv* val))
                     (marg (loop for (g atom v) in *cv-hyps*
                                 collect (if v (/ (aref zt v) z) :null)))
                     (lik (loop for (g atom v) in *cv-hyps*
                                collect (if (and v (plusp (aref *cv-zt0* v)))
                                            (/ (aref zt v) (aref *cv-zt0* v))
                                            :null)))
                     (lsum (reduce #'+ (remove :null lik)))
                     (post (loop for l in lik
                                 collect (cond ((eq l :null) :null)
                                               ((plusp lsum) (/ l lsum))
                                               (t :null)))))
                (cv--reply (list :ok :true :unsat :false :z z :z0 *cv-z0* :pe (/ z *cv-z0*)
                                 :marginal marg :likelihood lik :posterior post
                                 :ms (round (* 1000 (- (get-internal-real-time) start))
                                            internal-time-units-per-second)))))))))

;;; ------------------------------------------------------------------ loop

(defun cv-serve ()
  (loop
    (let ((form (handler-case (let ((*read-eval* nil)
                                    (*package* (find-package "COMMON-LISP-USER")))
                                (read *standard-input* nil :eof))
                  (error (e) (cv--reply (list :error (format nil "unreadable command: ~A" e)))
                    nil))))
      (cond ((eq form :eof) (return))
            ((null form))
            ((not (and (consp form) (symbolp (first form))))
             (cv--reply (list :error "a command is a list")))
            (t
             (let ((op (symbol-name (first form))))
               (handler-case
                   (cond ((string= op "CV-QUIT") (cv--reply (list :ok :true)) (return))
                         ((string= op "CV-LOAD") (cv-load (second form) (third form)))
                         ((string= op "CV-ACTIONS") (cv-actions))
                         ((string= op "CV-QUERY") (cv-query (second form)))
                         (t (cv--reply (list :error (format nil "unknown command ~A" op)))))
                 (error (e)
                   (cv--reply (list :error (format nil "~A" e)))))))))))
