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
;;;;   (cv-load "<circuit>" "<problem.pddl>")
;;;;       load a circuit saved by marginals.sh --save-circuit (text or binary);
;;;;       take the problem's hypotheses by recognize.sh's rule (the disjuncts of
;;;;       the goal's one (or ...), recognition-goal.lisp) and resolve each to
;;;;       (HOLDS <hypothesis> H), H the highest slice of any HOLDS atom in the
;;;;       circuit; evaluate once without evidence (Z and every atom's
;;;;       true-weight, kept for P(E|h)).
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
(defvar *cv-prior* nil "P(h) per hypothesis (:null when absent), computed at load.")

(defun cv--weight (zt z v neg)
  "The weight of the models where hypothesis variable V holds -- or, NEG, where
it does not: Z minus its true-weight."
  (if neg (- z (aref zt v)) (aref zt v)))

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

(defun cv--obj (&rest plist)
  "A JSON object: (cv--obj :key value ...).  Marked, so that no plain list --
say a list of probabilities starting with :null -- is ever taken for one."
  (cons :object plist))

(defun cv--json (x out)
  "Write X as JSON: (:object k v ...) an object (see CV--OBJ), any other list or
vector an array, :null/:true/:false the literals."
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
        ((and (consp x) (eq (car x) :object))
         (write-char #\{ out)
         (loop for (k v) on (cdr x) by #'cddr for first = t then nil
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
  "Reply with the object PLIST.  The whole line is built first, so an encoding
error never leaves half a reply in the pipe (the error then replies instead)."
  (let ((line (with-output-to-string (s) (cv--json (cons :object plist) s))))
    (format t "~&@@REPLY ~A~%" line)
    (finish-output)))

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

(defun cv--goal-lines (goal)
  "GOAL's conjuncts as lines of literals, split as the page splits the goal
(goalLines in src/problem.ts): nested ANDs flattened, preferences dropped, an
(or ...) its disjuncts, anything else a line of one.  Unlike the page, an
(or ...) of negations only is dropped as an exclusivity clause -- but only when
some other (or ...) is there for it to accompany; otherwise it is a line of
hypotheses like any other (as rg--classify takes a lone one)."
  (let ((conj '()))
    (labels ((flatten (g)
               (cond ((rg--head= g "AND") (mapc #'flatten (rest g)))
                     ((rg--head= g "PREFERENCE"))
                     (t (push g conj)))))
      (flatten goal))
    (setf conj (nreverse conj))
    (let ((sets-p (some (lambda (c) (and (rg--head= c "OR") (not (rg--all-negations-p c)))) conj)))
      (loop for c in conj
            unless (and sets-p (rg--all-negations-p c))
              collect (if (rg--head= c "OR") (rest c) (list c))))))

(defun cv--literal-atom (g)
  "Goal literal G as (values atom negated): (not A) gives A and T; NIL when
G is neither a ground atom nor its negation."
  (cond ((rg--atom-p g) (values g nil))
        ((and (rg--head= g "NOT") (= 2 (length g)) (rg--atom-p (second g)))
         (values (second g) t))
        (t (values nil nil))))

(defun cv--hypotheses (problem)
  "The hypotheses of the PDDL PROBLEM file as (values lines note): LINES a list
of lists of goal forms, each list one set of alternatives.

recognize.sh's own rule comes first (lisp/recognition-goal.lisp, rg--classify):
the disjuncts of the goal's ONE (or ...), exclusivity clauses dropped,
preferences ignored -- one line.  A goal it refuses (a conjunction of several
(or ...) sets, a hard goal beside the set) is shown literal by literal instead,
one line per conjunct, and NOTE says why; rg--die, which would exit the process,
signals for this."
  (let ((old (fdefinition 'rg--die))
        (goal (rg--goal (rg--read problem))))
    (unless goal (error "the problem has no goal, so there are no hypotheses"))
    (handler-case
        (unwind-protect
             (progn
               (setf (fdefinition 'rg--die)
                     (lambda (fmt &rest args)
                       (error "~A" (let ((*print-pretty* nil)) (format nil "~?" fmt args)))))
               (values (list (values (rg--classify goal))) :null))
          (setf (fdefinition 'rg--die) old))
      (error (e)
        (values (cv--goal-lines goal)
                (format nil "recognize.sh would refuse this goal (~A); each goal literal is ~
shown with its own probability, and the uniform-prior column normalizes within each line"
                        (substitute #\Space #\Newline (princ-to-string e))))))))

(defun cv-load (path problem)
  "Load the circuit at PATH and the hypotheses of PROBLEM.  Everything is
computed first; the globals change only once all of it has succeeded, so a
failed load leaves the previous circuit in place, whole."
  (let ((start (get-internal-real-time)) (note :null))
  (multiple-value-bind (lines why) (cv--hypotheses problem)
   (setf note why)
   (let* ((circuit (ddnnf-load path))
         (h (let ((*cv* circuit)) (cv--horizon)))
         (a2i (ddnnf-a2i circuit))
         (proj (ddnnf-projected circuit))
         (hyps (loop for line in lines for group from 0
                     nconc (loop for g in line
                                 ;; an atom hypothesis is (HOLDS atom H), a negated
                                 ;; one its complement; a compound one --
                                 ;; recognize.sh gives it a derived atom -- is not
                                 ;; looked up
                                 collect (multiple-value-bind (a neg) (cv--literal-atom g)
                                           (let* ((atom (and h a (list 'holds a h)))
                                                  (v (and atom (gethash atom a2i))))
                                             (list (cv--text g) atom
                                                   (and v (or (null proj) (= 1 (sbit proj v))) v)
                                                   group neg)))))))
    (multiple-value-bind (z zt) (ddnnf-query circuit)
      (setf *cv* circuit *cv-path* path *cv-hyps* hyps *cv-z0* z *cv-zt0* zt
            *cv-prior* (loop for (nil nil v nil neg) in hyps
                             collect (if v (/ (cv--weight zt z v neg) z) :null))))))
  (cv--reply
   (list :ok :true
         :path (namestring path)
         :nvars (ddnnf-nvars *cv*)
         :nodes (dns-n (ddnnf-nodes *cv*))
         :projected (let ((p (ddnnf-projected *cv*))) (if p (count 1 p) :null))
         :horizon (or (cv--horizon) :null)
         :z0 *cv-z0*
         :actions (cv--count-actions)
         :note note
         :hypotheses (loop for (g atom v group neg) in *cv-hyps*
                           collect (cv--obj :goal g
                                            :atom (cond ((null atom) :null)
                                                        (neg (cv--text (list 'not atom)))
                                                        (t (cv--text atom)))
                                            :present (if v :true :false)
                                            :group group))
         :ms (round (* 1000 (- (get-internal-real-time) start))
                    internal-time-units-per-second)))))

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
              (problem (push (cv--obj :literal text :reason problem) refused))
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
                     (prior *cv-prior*)
                     (marg (loop for (nil nil v nil neg) in *cv-hyps*
                                 collect (if v (/ (cv--weight zt z v neg) z) :null)))
                     ;; P(E|h) = Z(E,h) / Z(h)
                     (lik (loop for (nil nil v nil neg) in *cv-hyps*
                                for zh = (and v (cv--weight *cv-zt0* *cv-z0* v neg))
                                collect (if (and zh (plusp zh))
                                            (/ (cv--weight zt z v neg) zh)
                                            :null)))
                     ;; the likelihoods normalized within each line of alternatives
                     (lsum (make-hash-table))
                     (post (progn
                             (loop for (nil nil nil group) in *cv-hyps* for l in lik
                                   unless (eq l :null)
                                     do (incf (gethash group lsum 0) l))
                             (loop for (nil nil nil group) in *cv-hyps* for l in lik
                                   collect (cond ((eq l :null) :null)
                                                 ((plusp (gethash group lsum 0))
                                                  (/ l (gethash group lsum)))
                                                 (t :null))))))
                (cv--reply (list :ok :true :unsat :false :z z :z0 *cv-z0* :pe (/ z *cv-z0*)
                                 :prior prior :marginal marg :likelihood lik :posterior post
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
