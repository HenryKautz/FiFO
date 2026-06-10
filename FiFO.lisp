;;; FiFO.lisp

(ql:quickload :cl-ppcre :silent t)

;; SAT program used by satisfy
(defvar sat-solver "kissat")

;; Muffle warnings about common lisp style
(declaim (sb-ext:muffle-conditions cl:style-warning))

;; Default values of options
(defvar compact-encoding t)
(defvar tracep nil)
(defvar Weights nil)
(defvar binary-functions '(eq neq = > < >= <= member
                              union intersection set-difference + - * div rem mod ** bit
                              range))
(defvar interpreted-functions (append '(not and or lisp set alldiff collect) binary-functions))
(defvar logical-connectives '(not and or implies if equiv all exists))
(defvar reserved-words (append interpreted-functions logical-connectives))

(defvar debugp nil)

;; Directory of the .wff file currently being parsed, used to resolve (include "...") paths
(defvar *current-wff-directory* nil)

;;;
;;; Utility functions
;;;

(defun replace-suffix-with-regex (string pattern replacement)
  "Replace the PATTERN at the end of STRING with REPLACEMENT.
  PATTERN should be a regex matching the suffix."
  (if (cl-ppcre:scan pattern string :end (length string))
      (cl-ppcre:regex-replace pattern string replacement)
      string))

(defun file-contains-string-p (search-string filename)
  "Check if a file contains a given string using grep."
  (let ((exit-code (nth-value 2
                    (uiop:run-program
                      (list "grep" "-q" search-string filename)
                      :ignore-error-status t
                      :output nil :error-output nil))))
    (zerop exit-code)))

(defun read-sexprs-from-file (filename)
  "Reads all s-expressions from the file and returns them as a list."
  (with-open-file (stream filename :direction :input)
    (loop for sexpr = (read stream nil nil)
          while sexpr
          collect sexpr)))

(defun read-lines (filename)
  ;; Read a text file and return a list of its lines
  (with-open-file (stream filename)
    (loop for line = (read-line stream nil nil)
          while line
          collect line)))
(defun make-scratch-file-root ()
  "Generate a unique scratch file base name for this process."
  (format nil "scratch-~A-~A"
          (get-universal-time)
          (random 1000000000)))
;; File-based API: instantiate, propositionalize, interpret, satisfy, solve
;; 

(defun satisfy (CNFFILE &optional SATOUTFILE)
  (if (null (cl-ppcre:scan "\\." CNFFILE))
      (setq CNFFILE (concatenate 'string CNFFILE ".cnf")))
  (if (not SATOUTFILE)
      (setq SATOUTFILE (replace-suffix-with-regex CNFFILE "\\..*?$" ".satout")))
  (handler-case
      (uiop:run-program (list sat-solver CNFFILE)
                        :output SATOUTFILE :ignore-error-status t)
    (error () (return-from satisfy nil)))
  ;; Check UNSAT first since SAT is a substring of UNSAT/UNSATISFIABLE.
  (cond ((file-contains-string-p "UNSAT" SATOUTFILE) 'UNSAT)
        ((file-contains-string-p "SAT" SATOUTFILE) 'SAT)
        (t nil)))

(defun instantiate (WFFFILE &optional SCNFILE OBSFILE)
  (if (null (cl-ppcre:scan "\\.." WFFFILE))
      (setq WFFFILE (concatenate 'string WFFFILE ".wff")))
  (if (eq OBSFILE t)
      (setq OBSFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".obs")))
  (if (not SCNFILE)
      (setq SCNFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".scnf")))
  (with-open-file (INS WFFFILE :direction :input)
    (with-open-stream (OBS (if OBSFILE (open OBSFILE :direction :input) (make-concatenated-stream)))
      (with-open-file (OUTS SCNFILE :direction :output :if-exists :supersede)
        (let (CL SCHEMA OBSERVATION)
          (let ((*current-wff-directory* (uiop:pathname-directory-pathname (truename WFFFILE))))
            (setq CL (parse
                      (loop while (not (eql 'EOF (setq SCHEMA (read INS nil 'EOF))))
                            collect SCHEMA)
                      (loop while (not (eql 'EOF (setq OBSERVATION (read OBS nil 'EOF))))
                            collect OBSERVATION))))
          (loop for C in CL do (format OUTS "~S~%" C))
          (loop for W in Weights do (format OUTS "~S~%" W)))))))

(defun propositionalize (SCNFFILE &optional CNFFILE MAPFILE)
  (if (null (cl-ppcre:scan "\\.." SCNFFILE))
      (setq SCNFFILE (concatenate 'string SCNFFILE ".scnf")))
  (if (not CNFFILE)
      (setq CNFFILE (replace-suffix-with-regex SCNFFILE "\\..*?$" ".cnf")))
  (if (not MAPFILE)
      (setq MAPFILE (replace-suffix-with-regex SCNFFILE "\\..*?$" ".map")))
  (with-open-file (WS SCNFFILE :direction :input)
    (with-open-file (CS CNFFILE :direction :output :if-exists :supersede)
      (with-open-file (MS MAPFILE :direction :output :if-exists :supersede)
        (let* ((all-forms (loop with clause
                                while (not (eql :EOF (setq clause (read WS nil :EOF))))
                                collect clause))
               (clauses (remove-if (lambda (f) (eql (car f) 'weight)) all-forms))
               (weights (remove-if-not (lambda (f) (eql (car f) 'weight)) all-forms)))
          (multiple-value-bind (cnfdata mapdata numvar numclauses weightdata)
              (lit2prop clauses weights)
            (format CS "p cnf ~S ~S~%" numvar numclauses)
            (loop for c in cnfdata do (format CS "~{~D ~}0~%" c))
            (loop for w in weightdata do (format CS "cw ~D ~A~%" (first w) (second w)))
            (format MS "map ~S~%" numvar)
            (loop for m in mapdata do (format MS "~{~D ~S~}~%" m))))))))


(defun interpret (SATOUTFILE &optional MAPFILE SOLNFILE SORT_BY_LAST_ARGUMENT)
  (if (null (cl-ppcre:scan "\\.." SATOUTFILE))
      (setq SATOUTFILE (concatenate 'string SATOUTFILE ".satout")))
  (if (not MAPFILE)
      (setq MAPFILE (replace-suffix-with-regex SATOUTFILE "\\..*?$" ".map")))
  (if (not SOLNFILE)
      (setq SOLNFILE (replace-suffix-with-regex SATOUTFILE "\\..*?$" ".soln")))
  (let (solndata mapdata litdata)
    ;; Read solnfile to create solution list.  Ignore any non-integers and negative integers in solnfile.
    ;; Get list of lines of the solution
    (setq solndata (read-lines SATOUTFILE))
    (if (some (lambda (s) (search "UNSAT" s :test #'char-equal)) solndata)
        (with-open-file (OS SOLNFILE :direction :output :if-exists :supersede)
          (format OS "UNSAT~%"))
        (progn ; satisfiabile case
              ;; On lines that begin with v, drop the v
              (setq solndata (mapcar (lambda (s) (if (cl-ppcre:scan "^v" s) (subseq s 1) s)) solndata))
              ;; Eliminate lines containing anything other than integers
              (setq solndata (remove-if (lambda (str) (cl-ppcre:scan "[^0-9\\s-]" str)) solndata))
              ;; Convert to a single string
              (setq solndata (format nil "~{~a~^ ~}" solndata))
              ;; Convert to a list of integers
              (setq solndata (mapcar #'parse-integer (ppcre:all-matches-as-strings "-?\\d+" solndata)))
              ;; Remove negative integers
              (setq solndata (remove-if (lambda (x) (<= x 0)) solndata))
              ;; Read mapfile to create mapdata list
              (with-open-file (MS MAPFILE :direction :input)
                (if (not (eql (read MS) 'map)) (error "Bad map file"))
                (if (not (integerp (read MS))) (error "Bad map file"))
                (setq mapdata (loop with i with p
                                    while (not (eql :EOF (setq i (read MS nil :EOF))))
                                    do (setq p (read MS)) (if (not (integerp i)) (error "Bad map file"))
                                    collect (list i p))))
              ;; call soln2lit to create sorted list of true literals
              (setq litdata (soln2lit mapdata solndata sort_by_last_argument))
              ;; Print list of true literals to outfile
              (with-open-file (OS SOLNFILE :direction :output :if-exists :supersede)
                (format OS "SAT~%")
                (format OS "~{~S~%~}" litdata))))))

(defun solve (WFFFILE &optional SOLNFILE OBSFILE)
  (if (null (cl-ppcre:scan "\\.." WFFFILE))
      (setq WFFFILE (concatenate 'string WFFFILE ".wff")))
  (if (not SOLNFILE)
      (setq SOLNFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".answer")))
  (if (eq OBSFILE t)
      (setq OBSFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".obs")))
  (let (schemas observations SCHEMA OBSERVATION)
    (with-open-file (INS WFFFILE :direction :input)
      (setq schemas (loop while (not (eql 'EOF (setq SCHEMA (read INS nil 'EOF))))
                          collect SCHEMA)))
    (if OBSFILE
        (with-open-file (OBS OBSFILE :direction :input)
          (setq observations (loop while (not (eql 'EOF (setq OBSERVATION (read OBS nil 'EOF))))
                                   collect OBSERVATION))))
    (let ((*current-wff-directory* (uiop:pathname-directory-pathname (truename WFFFILE))))
      (multiple-value-bind (result model-or-bindings) (solve-schemas schemas observations)
        (with-open-file (ANSWER SOLNFILE :direction :output :if-exists :supersede)
          (format ANSWER "~a~%" result)
          (dolist (e model-or-bindings) (format ANSWER "~a~%" e)))))))

;;;
;;; Lisp API
;;;

(defvar scratch-file (make-scratch-file-root))

;;; Returns SAT or UNSAT, list of true literals in model
(defun test-scnf (scnf)
  (let ((scnf-file (format nil "~a.scnf" scratch-file))
        (cnf-file (format nil "~a.cnf" scratch-file))
        (satout-file (format nil "~a.satout" scratch-file))
        (soln-file (format nil "~a.soln" scratch-file))
        (map-file (format nil "~a.map" scratch-file)))
    (labels ((cleanup-scratch-files ()
               (unless tracep
                 (dolist (file (list scnf-file cnf-file satout-file soln-file map-file))
                   (when (probe-file file)
                     (delete-file file))))))
      (if debugp
          (format t ";;test-scnf ~S~%" scnf))
      (when (member debugp '(SAT UNSAT))
        (return-from test-scnf (values debugp nil)))
      (unwind-protect
           (progn
             (with-open-file (SCNF-STREAM scnf-file :direction :output :if-exists :supersede)
               (dolist (c scnf) (format SCNF-STREAM "~S~%" c))
               (dolist (w Weights) (format SCNF-STREAM "~S~%" w)))
             (propositionalize scnf-file cnf-file map-file)
             (satisfy cnf-file)
             (interpret satout-file map-file soln-file)
             (let ((results (read-sexprs-from-file soln-file)))
               (values (car results) (cdr results))))
        (cleanup-scratch-files)))))

(defun lit2prop (CL &optional weights)
  (let ((cnfdata nil) (mapdata nil) (weightdata nil)
        (numvar 0) (numclauses (length CL))
        (hash (make-hash-table :test #'equal)))
    (flet ((ensure-prop (lit)
             (let ((prop (if (is-proposition lit) lit (cadr lit))))
               (unless (nth-value 1 (gethash prop hash))
                 (incf numvar)
                 (setf (gethash prop hash) numvar))))
           (lit-to-int (lit)
             (if (is-proposition lit)
                 (gethash lit hash)
                 (- (gethash (cadr lit) hash)))))
      ;; Index all propositions from clauses
      (loop for clause in CL do
              (loop for lit in (cdr clause) do (ensure-prop lit)))
      ;; Index propositions from weight literals (may not appear in any clause)
      (loop for w in weights do (ensure-prop (cadr w)))
      ;; Translate clauses
      (setq cnfdata (loop for clause in CL
                          collect (loop for lit in (cdr clause)
                                        collect (lit-to-int lit))))
      ;; Translate weights to (integer number) pairs
      (setq weightdata (loop for w in weights
                             collect (list (lit-to-int (cadr w)) (caddr w))))
      ;; Build map table
      (maphash #'(lambda (key val) (push (list val key) mapdata)) hash)
      (setq mapdata (sort mapdata #'< :key #'car))
      (values cnfdata mapdata numvar numclauses weightdata))))


(defun soln2lit (mapdata solndata &optional sort-by-time)
  ;; return a list of propositions
  (let ((hash (make-hash-table)) proplist)
    (loop for pair in mapdata do (setf (gethash (car pair) hash) (cadr pair)))
    (setq proplist (loop for i in solndata collect (gethash i hash)))
    (setq proplist (sort proplist (if sort-by-time #'time-ordering #'alpha-ordering)))
    proplist))

(defun alpha-ordering (p q)
  (string-lessp (format nil "~s" p) (format nil "~s" q)))

(defun time-order-r (p q)
  (cond ((and (integerp p) (integerp q)) (< p q))
        ((and (atom p) (atom q)) (string-lessp p q))
        ((atom p) t)
        ((atom q) nil)
        ((equal (car p) (car q)) (time-order-r (cdr p) (cdr q)))
        (t (time-order-r (car p) (car q)))))

(defun time-ordering (p q)
  (time-order-r (if (atom p) p (reverse p))
                (if (atom q) q (reverse q))))


;;;
;;; Answer extraction
;;;

(defun split-list (lst &optional (index (floor (/ (length lst) 2))))
  (let ((list1 (subseq lst 0 index))
        (list2 (subseq lst index)))
    (values list1 list2)))

;; found == ((var1 term1) (var2 term2) ...)
;; notfound == ((var1 term11 term12 ...) (var2 term21 term22 ...) ...)
;; test == the test from the prove form
;; qbody == the body of the prove form
;; assumptions == the scnf of the wff minus the prove form
;; returns
;; if successful -  (BINDINGS (var1 term1) (var2 term2) ...)
;; if unsuccessful - nil

(defun term-search (found notfound test qbody assumptions)
  (if debugp
      (format t "::term-search :found=~S :notfound=~S :test=~S :qbody=~S :assumptions=~S~%"
              found notfound test qbody assumptions))
  (cond
   ;; All variables found: unwrap single-element domain lists back to atoms for output
   ((null notfound) `(BINDINGS ,@(mapcar (lambda (e) (list (car e) (caadr e))) found)))
   (t (let* ((var (caar notfound))
             (dom (cadar notfound))
             ;; construct-query expects (var (term...)) for both found and notfound
             (query (construct-query (append found notfound) test qbody))
             (wff (append (mapcar (lambda (c) (cons 'or c)) (parse-schema query))
                          assumptions))
             (result (test-scnf wff)))
        (if debugp
            (format t "::term-search :var=~S :dom=~S :query=~S :wff=~S :result=~S~%"
                    var dom query wff result))
        (cond ((eq result 'SAT) nil)
              ((= (length dom) 1)
                ;; Store (var (term)) so construct-query can splice the domain correctly
                (term-search (cons (list var (list (car dom))) found) (cdr notfound) test qbody assumptions))
              (t (multiple-value-bind (dom1 dom2) (split-list dom)
                   (or (term-search found (cons (list var dom1) (cdr notfound)) test qbody assumptions)
                       (term-search found (cons (list var dom2) (cdr notfound)) test qbody assumptions)))))))))

(defun construct-query (var-doms test qbody)
  (cond ((null var-doms) `(not (if ,test ,qbody)))
        (t `(all ,(caar var-doms) (set ,@(cadar var-doms)) true
                 ,(construct-query (cdr var-doms) test qbody)))))

(defun ut-construct-query ()
  (setup-global-env)
  (parse-same-env '((domain bird (set robin cardinal crow)) (domain fruit (set apple berry banana))))
  (let ((answ (construct-query '((x (robin cardinal crow)) (y (robin cardinal crow)))
                               '(neq x y)
                               '(or (bigger x y) (bigger y x)))))
    answ))


(defun pull-out-prove (wff)
  (let ((pred (lambda (s) (and (listp s) (eq (car s) 'prove)))))
    (values (find-if pred wff)
            (remove-if pred wff))))


(defun expand-var-domain-list (vdlist)
  ;; Take a list like ((x Person) ((y z) Job)) and produce
  ;; ((x <values-of-Person>) (y <values-of-Job>) (z <values-of-Job>))
  (cond ((null vdlist) nil)
        ((null (caar vdlist)) (expand-var-domain-list (cdr vdlist)))
        ;; Multi-var form like ((x y z) <domain>) -- peel off the first var.
        ((listp (caar vdlist))
         (expand-var-domain-list
          `((,(caaar vdlist) ,(cadar vdlist))
            (,(cdaar vdlist) ,(cadar vdlist))
            ,@(cdr vdlist))))
        (t (cons (list (caar vdlist) (parse-set-expression (cadar vdlist)))
                 (expand-var-domain-list (cdr vdlist))))))


;; returns, matching the output labels documented in README.md:
;;   No prove form:
;;     'SAT, model            (positive literals in symbolic form)
;;     'UNSAT, nil
;;   Has prove form:
;;     'COUNTEREXAMPLE, model (theory + negated conclusion is satisfiable)
;;     'PROVEN, bindings      (theory entails conclusion; answer extraction succeeded)
;;     'NOANSWER, nil         (theory entails conclusion; answer extraction failed)
(defun solve-schemas (schemas &optional observations)
  (multiple-value-bind (prove-form rest-of-wff) (pull-out-prove schemas)
    (cond ((null prove-form)
            (test-scnf (parse schemas observations)))
          (t
            (let* ((vdlist (cadr prove-form))
                   (test (caddr prove-form))
                   (qbody (cadddr prove-form))
                   (assumptions (parse rest-of-wff observations))
                   (notfound (expand-var-domain-list vdlist)))
              ;; First check whether the theory plus the negation of the prove
              ;; conclusion is satisfiable.  If SAT, that model is a counterexample.
              ;; If UNSAT, the theory entails the conclusion and we attempt answer
              ;; extraction.
              (multiple-value-bind (sat-result model)
                  (test-scnf (append (mapcar (lambda (c) (cons 'or c))
                                             (parse-schema (construct-query notfound test qbody)))
                                     assumptions))
                (cond ((eq sat-result 'SAT)
                        (values 'COUNTEREXAMPLE model))
                      (t
                        (let* ((bindings (term-search nil notfound test qbody assumptions)))
                          (cond ((null bindings) (values 'NOANSWER nil))
                                (t (values 'PROVEN (cdr bindings)))))))))))))

;;;
;;; Parsing 
;;;

; Global variables
(defvar Bind)
(defvar ObservedPredicates)
(defvar ObservedLiterals)
(defvar Weights)
;; When true, parse-formula treats observed predicates as plain literals to assert
;; (used when processing observation form bodies so newly derived pairs get added).
(defvar observation-body-mode nil)

(defun setup-global-env ()
  ; Set up global environment
  (setq Bind (make-hash-table :test #'eql))
  (setq ObservedPredicates (make-hash-table :test #'eql))
  (setq ObservedLiterals (make-hash-table :test #'equal))
  (setq Weights nil)
  (setf (gethash 'TRUE ObservedPredicates) 1)
  (setf (gethash 'TRUE ObservedLiterals) 1)
  (setf (gethash 'FALSE ObservedPredicates) 1)
  (setf (gethash 'FALSE ObservedLiterals) 0))

(defun parse (SCHEMA-LIST &optional OBSERVATION-LIST)
  (setup-global-env)
  (parse-same-env SCHEMA-LIST OBSERVATION-LIST))

(defun parse-same-env (SCHEMA-LIST &optional OBSERVATION-LIST)
  (parse-observations OBSERVATION-LIST)
  (mapcar #'(lambda (c) (cons 'or c))
    (remove-valid-clauses
     (parse-schema-list SCHEMA-LIST))))

;; Global variables used by parse observations
(defvar new-observation)

;;; Simple observations (no quantifiers)
;;; Note that it sets global new-observation
;;; Each clause must be a unit clause (not a disjuction).
;;; We allow a clause to be proposition (so not a list).

(defun parse-unit-observations (OBSERVATION-LIST)
  ;; OBSERVATION-LIST is a list of unit positive literals.  Each literal is
  ;; either an atom (a 0-ary predicate) or a list (predicate arg1 arg2 ...).
  (cond ((null OBSERVATION-LIST) nil)
        (t
         (setf (gethash
                 (if (listp (car OBSERVATION-LIST))
                     (caar OBSERVATION-LIST)
                     (car OBSERVATION-LIST))
                 ObservedPredicates)
               1)
         (let ((oldvalue (gethash (car OBSERVATION-LIST) ObservedLiterals)))
           (if (not oldvalue)
               (progn
                 (setf (gethash (car OBSERVATION-LIST) ObservedLiterals) 1)
                 (setq new-observation t))))
         (parse-unit-observations (cdr OBSERVATION-LIST)))))

(defun parse-observations (OBSERVATION-LIST)
  ;; Re-evaluate each observation form until no new literals are added,
  ;; so that quantified observations whose tests depend on earlier
  ;; observations are fully expanded.
  (loop do
        (setq new-observation nil)
        (parse-observation-list OBSERVATION-LIST)
        while new-observation)
  nil)

(defun parse-observation-list (OBSERVATION-LIST)
  (cond ((null OBSERVATION-LIST) nil)
        (t (parse-observation-form (car OBSERVATION-LIST))
           (parse-observation-list (cdr OBSERVATION-LIST)))))

(defun parse-observation-form (FORM)
  ;; Parse the form to a list of clauses.  The language restricts observation
  ;; bodies to and/all/if and positive literals, so each clause is a unit
  ;; positive literal; take the car of each clause to recover it.
  ;; observation-body-mode prevents parse-formula from treating observed
  ;; predicates as truth-value checks so newly derived literals get asserted.
  (let ((observation-body-mode t))
    (parse-unit-observations (mapcar #'car (parse-schema FORM)))))

;; Recursive version of remove-valid-clauses blew up recursion stack
;;
;; (defun remove-valid-clauses (CL)
;;  (cond ((null CL) nil)
;;	((valid (car CL)) (remove-valid-clauses (cdr CL)))
;;	(t (cons (car CL) (remove-valid-clauses (cdr CL))))))

(defun remove-valid-clauses (CL)
  (let (answer)
    (dolist (c CL)
      (if (null (valid c))
          (setq answer (cons c answer))))
    answer))

(defun valid (C)
  (cond ((null C) nil)
        ((member (complement-literal (car C)) (cdr C) :test #'equal) t)
        (t (valid (cdr C)))))

(defun complement-literal (L)
  (cond ((atom L) (list 'not L))
        ((eql (car L) 'not) (cadr L))
        (t (list 'not L))))

(defun parse-schema-list (SCHEMA-LIST)
  (cond ((null SCHEMA-LIST) nil)
        (t (append (parse-schema (car SCHEMA-LIST))
             (parse-schema-list (cdr SCHEMA-LIST))))))

(defun parse-schema (SCHEMA)
  (when tracep
    (cond ((atom SCHEMA)
           (format t "[TRACE] Formula: ~S~%" SCHEMA))
          ((member (car SCHEMA) '(domain alias option observed include weight)) nil)
          (t (format t "[TRACE] Formula: (~A ...)~%" (car SCHEMA)))))
  (cond ((atom SCHEMA) (parse-formula SCHEMA))
        ((eql (car SCHEMA) 'domain) (parse-domain (cdr SCHEMA)))
        ((eql (car SCHEMA) 'alias) (parse-alias (cdr SCHEMA)))
        ((eql (car SCHEMA) 'option) (parse-option (cdr SCHEMA)))
        ((eql (car SCHEMA) 'observed) (parse-observations (cdr SCHEMA)))
        ((eql (car SCHEMA) 'include) (parse-include (cadr SCHEMA)))
        ((eql (car SCHEMA) 'weight) (parse-weight (cdr SCHEMA)))
        (t (parse-formula SCHEMA))))

(defun parse-weight (ARGS)
  (let ((lit (parse-literal (car ARGS)))
        (num (normalize-numeric (parse-numeric-expression (cadr ARGS)))))
    (setq Weights (append Weights (list (list 'WEIGHT lit num))))
    nil))

(defun parse-option (ARGS)
  (let ((opt (car ARGS))
        (val (parse-expression (cadr ARGS))))
    (if (eql val 0) (setq val nil))
    (cond ((eql opt 'compact-encoding)
            (set opt val))
          ((eql opt 'trace)
            (setq tracep val)
            (when tracep (format t "[TRACE] Tracing enabled~%")))
          (t (error "Cannot parse option ~S" ARGS)))
    nil))

(defun parse-include (FILENAME)
  (let* ((resolved (if *current-wff-directory*
                       (uiop:merge-pathnames* FILENAME *current-wff-directory*)
                       FILENAME))
         (*current-wff-directory* (uiop:pathname-directory-pathname resolved)))
    (when tracep (format t "[TRACE] Include ~S~%" resolved))
    (parse-schema-list (read-sexprs-from-file resolved))))

(defun parse-domain (DEFINITION)
  (let ((vals (parse-set-expression (cadr DEFINITION))))
    (when tracep (format t "[TRACE] Domain ~S = ~S~%" (car DEFINITION) vals))
    (setf (gethash (car DEFINITION) Bind) vals)
    nil))

(defun parse-alias (DEFINITION)
  (setf (gethash (car DEFINITION) Bind) (parse-expression (cadr DEFINITION)))
  nil)

(defmacro with-binding (VAR VAL &rest BODY)
  `(multiple-value-bind (oldvalue oldvalueexists) (gethash ,VAR Bind)
     (setf (gethash ,VAR Bind) ,VAL)
     (prog1 (progn ,@BODY)
       (if oldvalueexists
           (setf (gethash ,VAR Bind) oldvalue)
           (remhash ,VAR Bind)))))

(defun is-bound (VAR)
  (nth-value 1 (gethash VAR Bind)))

(defun binding-of (VAR)
  (gethash VAR Bind))

(defun is-observed-literal (F)
  (cond ((not (is-literal F)) nil)
        ((and (listp F) (eql (car F) 'not))
          (is-observed-literal (cadr F)))
        ((listp F)
          (gethash (car F) ObservedPredicates))
        (t
          (gethash F ObservedPredicates))))

(defun parse-observed-literal (F)
  ;; returns NIL if observed literal is true and (nil) if it is false
  (cond ((and (listp F) (eql (car F) 'not))
          (if (is-true (gethash (parse-literal (cadr F)) ObservedLiterals 0))
              '(())
              '()))
        (t
          (if (is-true (gethash (parse-literal F) ObservedLiterals 0))
              '()
              '(())))))

(defun parse-formula (F)
  ;; (format t "entering parse ~S" F)
  (cond ((and (not observation-body-mode) (is-observed-literal F)) (parse-observed-literal F))
        ((is-literal F) (list (list (parse-literal F))))
        ((eql (car F) 'not) (parse-not (cadr F)))
        ((eql (car F) 'and) (parse-and (cdr F)))
        ((eql (car F) 'or) (parse-or (cdr F)))
        ((eql (car F) 'implies) (parse-implies (cdr F)))
        ((eql (car F) 'if) (parse-if (cadr F) (caddr F)))
        ((eql (car F) 'equiv) (parse-equiv (cdr F)))
        ((eql (car F) 'all)
          (parse-all (cadr F)
                     (parse-set-expression (caddr F))
                     (cadddr F)
                     (car (cddddr F))))
        ((eql (car F) 'exists)
          (parse-exists (cadr F)
                        (parse-set-expression (caddr F))
                        (cadddr F)
                        (car (cddddr F))))
        (t (error "Cannot parse formula ~S" F))))

(defun parse-if (test body)
  (cond ((is-false (parse-numeric-expression test)) nil)
        (t (parse-schema body))))

(defun parse-not (F)
  ;; F is not a literal, that case is handled in parse-formula
  ;; (format t "entering parse-not ~S" F)
  (let ((op (car F)))
    (cond ((eql op 'not) (parse-formula (cadr F)))
          ((eql op 'and) (parse-formula (cons 'or (negate-list (cdr F)))))
          ((eql op 'or) (parse-formula (cons 'and (negate-list (cdr F)))))
          ((eql op 'implies) (parse-formula (list 'and (cadr F) (list 'not (caddr F)))))
          ((eql op 'if) (cond ((is-true (parse-numeric-expression (cadr F))) (parse-formula `(not ,(caddr F))))
                              (t nil)))
          ((eql op 'equiv) (append (parse-formula `(or ,(cadr F) ,(caddr F)))
                             (parse-formula `(or (not ,(cadr F)) (not ,(caddr F))))))
          ((eql op 'all) (parse-formula `(exists ,(cadr F) ,(caddr F) ,(cadddr F) (not ,(car (cddddr F))))))
          ((eql op 'exists) (parse-formula `(all ,(cadr F) ,(caddr F) ,(cadddr F) (not ,(car (cddddr F))))))
          (t (error "Cannot parse negation ~S" F)))))

(defun negate-list (L)
  (cond ((null L) nil)
        (t (cons (list 'not (car L)) (negate-list (cdr L))))))

(defun parse-implies (FL)
  (if (not (= (length FL) 2)) (error "Cannot parse implication ~S" FL))
  (parse-or (cons (list 'not (car FL)) (cdr FL))))

(defun parse-equiv (FL)
  (if (not (= (length FL) 2)) (error "Cannot parse equivalence ~S" FL))
  (append (parse-implies FL)
    (parse-formula `(implies ,(cadr FL) ,(car FL)))))

(defun is-literal (F)
  (or (is-proposition F)
      (and (eql 'not (car F)) (is-proposition (cadr F)))))

(defun is-proposition (F)
  (or (atom F)
      (not (member (car F) logical-connectives))))

(defun parse-and (FL) ;; and just appends the clauses
  (parse-schema-list FL))

(defun parse-or (FL)
  (cond ((null FL) (list nil)) ;; empty OR is the empty clause
        (t (multiply-clauses (parse-schema (car FL))
                             (parse-or (cdr FL))))))

(defun multiply-clauses (L R)
  (let ((result
          (if (or (null compact-encoding)
                  (< (length L) 2)
                  (< (length R) 2)
                  (< (+ (length L) (length R)) 5))
              (explicit-multiply-clauses L R)
              (let ((g (gensym "XX"))) ;; g selects whether L or R must be true
                (append (mapcar #'(lambda (c) (cons g c)) R)
                        (mapcar #'(lambda (c) (cons (list 'not g) c)) L))))))
    (when tracep
      (format t "[TRACE] Multiply: ~D x ~D -> ~D clauses~%"
              (length L) (length R) (length result)))
    result))

(defun merge-clauses (C1 C2)
  (remove-duplicates (append C1 C2) :test #'equal))

; Reduce stack requirements - rewrite following two recursive functions
;  as a single iterative function.
;
;(defun explicit-multiply-clauses (L R)
;  (cond ((null L) nil)
;	(t (append (multiply-one-clause (car L) R)
;		   (explicit-multiply-clauses (cdr L) R)))))
;
;(defun multiply-one-clause (C R)
;  (cond ((null R) nil)
;	(t (append (list (merge-clauses C (car R)))
;		   (multiply-one-clause C (cdr R))))))


(defun explicit-multiply-clauses (L R)
  (let (answer)
    (dolist (lclause L)
      (setq answer (cons (multiply-one-clause lclause R) answer)))
    (mapcan #'copy-list answer)))

(defun multiply-one-clause (C R)
  (let (answer)
    (dolist (rclause R)
      (setq answer (cons (merge-clauses C rclause) answer)))
    answer))

(defun parse-all (VAR DOM TEST BODY)
  (cond ((null DOM) nil) ;; the empty list of clauses
        ;; a single variable is specified
        ((not (listp VAR))
         (when tracep (format t "[TRACE] ALL ~S = ~S~%" VAR (car DOM)))
         (append (parse-binding VAR (car DOM) TEST BODY nil)
                 (parse-all VAR (cdr DOM) TEST BODY)))
        ;; a list of variables is specified
        (t
         (when tracep (format t "[TRACE] ALL ~S over ~S~%" VAR DOM))
         (parse-formula (expand-multivar-all VAR DOM TEST BODY)))))


(defun parse-exists (VAR DOM TEST BODY)
  (cond ((NULL Dom) (list nil)) ;; the empty clause
        ;; a single variable is specified
        ((not (listp VAR))
         (when tracep (format t "[TRACE] EXISTS ~S = ~S~%" VAR (car DOM)))
         (multiply-clauses (parse-binding VAR (car DOM) TEST BODY (list nil))
                           (parse-exists VAR (cdr DOM) TEST BODY)))
        ;; a list of variables is specified
        (t
         (when tracep (format t "[TRACE] EXISTS ~S over ~S~%" VAR DOM))
         (parse-formula (expand-multivar-exists VAR DOM TEST BODY)))))


(defun parse-for (VAR DOM TEST BODY)
  (cond ((null DOM) nil) ;; the empty list of clauses
        ;; a single variable is specified
        ((not (listp VAR))
         (when tracep (format t "[TRACE] FOR ~S = ~S~%" VAR (car DOM)))
         (append (parse-expression-binding VAR (car DOM) TEST BODY nil)
                 (parse-for VAR (cdr DOM) TEST BODY)))
        ;; a list of variables is specified
        (t
         (when tracep (format t "[TRACE] FOR ~S over ~S~%" VAR DOM))
         (parse-expression (expand-multivar-for VAR DOM TEST BODY)))))

(defun collect-match-term (VAR pat term)
  ;; Match pattern PAT against ground TERM.
  ;; VAR is the wildcard to capture; * is an anonymous wildcard.
  ;; Returns: term bound to VAR, :no-binding (matched without VAR), or :fail.
  (cond
    ((eq pat VAR)
     term)
    ((eq pat '*)
     :no-binding)
    ((or (atom pat) (member (car pat) interpreted-functions))
     ;; Constant or interpreted expression: evaluate and compare
     (if (equal (parse-term pat) term) :no-binding :fail))
    ((and (listp term)
          (eq (parse-name (car pat)) (car term))
          (= (length (cdr pat)) (length (cdr term))))
     ;; Uninterpreted compound term: recurse into arguments
     (let ((var-val :unset))
       (loop for p in (cdr pat) and t2 in (cdr term) do
         (let ((result (collect-match-term VAR p t2)))
           (cond
             ((eq result :fail) (return-from collect-match-term :fail))
             ((not (eq result :no-binding))
              (if (eq var-val :unset)
                  (setq var-val result)
                  (unless (equal var-val result)
                    (return-from collect-match-term :fail)))))))
       (if (eq var-val :unset) :no-binding var-val)))
    (t :fail)))

(defun parse-collect (VAR PATTERN)
  ;; (collect VAR (pred pat+))
  ;; Iterates over all true observed literals matching PATTERN and returns the
  ;; set of ground terms that VAR binds to.  Both VAR and * are wildcards;
  ;; other atoms/compounds are evaluated as terms and compared exactly.
  (let ((pred (parse-name (car PATTERN)))
        (pat-args (cdr PATTERN))
        (results nil))
    (maphash
      (lambda (key val)
        (when (and (= val 1)
                   (listp key)
                   (eq (car key) pred)
                   (= (length (cdr key)) (length pat-args)))
          (let ((var-val :unset)
                (match-ok t))
            (loop for pat in pat-args and term in (cdr key)
                  while match-ok do
              (let ((result (collect-match-term VAR pat term)))
                (cond
                  ((eq result :fail) (setq match-ok nil))
                  ((not (eq result :no-binding))
                   (if (eq var-val :unset)
                       (setq var-val result)
                       (unless (equal var-val result)
                         (setq match-ok nil)))))))
            (when (and match-ok (not (eq var-val :unset)))
              (pushnew var-val results :test #'equal)))))
      ObservedLiterals)
    (when tracep (format t "[TRACE] COLLECT ~S = ~S~%" VAR results))
    results))

(defun parse-expression-binding (VAR VAL TEST BODY FAILED-TEST-RESULT)
  (let ((RESULT FAILED-TEST-RESULT))
    (with-binding VAR VAL
                  (let ((TESTVAL (parse-expression TEST)))
                    (if (is-true TESTVAL)
                        (setq RESULT (parse-expression BODY)))))
    RESULT))

(defun expand-multivar-for (VARLIST DOM TEST BODY)
  (cond ((null VARLIST) BODY)
        ((null (cdr VARLIST))
          `(for ,(car VARLIST) (set ,@DOM) ,TEST ,BODY))
        (t
          `(for ,(car VARLIST) (set ,@DOM) t
                ,(expand-multivar-for (cdr VARLIST) DOM TEST BODY)))))


(defun expand-multivar-all (VARLIST DOM TEST BODY)
  (cond ((null VARLIST) BODY)
        ((null (cdr VARLIST))
          `(all ,(car VARLIST) (set ,@DOM) ,TEST ,BODY))
        (t
          `(all ,(car VARLIST) (set ,@DOM) t
                ,(expand-multivar-all (cdr VARLIST) DOM TEST BODY)))))


(defun expand-multivar-exists (VARLIST DOM TEST BODY)
  (cond ((null VARLIST) BODY)
        ((null (cdr VARLIST))
          `(exists ,(car VARLIST) (set ,@DOM) ,TEST ,BODY))
        (t
          `(exists ,(car VARLIST) (set ,@DOM) t
                   ,(expand-multivar-exists (cdr VARLIST) DOM TEST BODY)))))

(defun is-false (x)
  (or (null x) (and (numberp x) (zerop x))))

(defun is-true (x)
  (not (is-false x)))

(defun parse-binding (VAR VAL TEST BODY FAILED-TEST-RESULT)
  (let ((RESULT FAILED-TEST-RESULT))
    (with-binding VAR VAL
                  (let ((TESTVAL (parse-expression TEST)))
                    (if (is-true TESTVAL)
                        (setq RESULT (parse-schema BODY)))))
    RESULT))

(defun parse-set-expression (EXPR)
  (let ((answ (parse-expression EXPR)))
    (if (not (listp answ)) (error "Set expected instead of ~S" EXPR))
    answ))

(defun parse-numeric-expression (EXPR)
  (let ((answ (parse-expression EXPR)))
    (if (not (numberp answ)) (error "Number expected instead of ~S" EXPR))
    answ))

(defun parse-name (EXPR)
  (if (or (null EXPR)
          (numberp EXPR)
          (listp EXPR)
          (member EXPR reserved-words))
      (error "Symbol expected instead of ~S" EXPR))
  EXPR)

(defun parse-or-expression (EXPR)
  (cond ((null EXPR) 0)
        ((is-true (parse-expression (car EXPR))) 1)
        (t (parse-or-expression (cdr EXPR)))))

(defun parse-and-expression (EXPR)
  (cond ((null EXPR) 1)
        ((is-false (parse-expression (car EXPR))) 0)
        (t (parse-and-expression (cdr EXPR)))))

(defun evaluate-lisp-expression (EXPR)
  (maphash #'set Bind)
  (eval EXPR))

(defun all-different (symbols)
  (cond ((null symbols) t)
        ((null (cdr symbols)) t)
        (t (and (not (member (car symbols) (cdr symbols) :test #'equalp))
                (all-different (cdr symbols))))))

(defun parse-expression (EXPR)
  (cond ((and (symbolp EXPR) (not (null EXPR)) (is-bound EXPR)) (binding-of EXPR))
        ((eql EXPR 'true) 1)
        ((eql EXPR 'false) 0)
        ((atom EXPR) EXPR)
        (t (let ((op (car EXPR)))
             (cond ((eql op 'not) (if (is-true (parse-expression (cadr EXPR))) 0 1))
                   ((eql op 'and) (parse-and-expression (cdr EXPR)))
                   ((eql op 'or) (parse-or-expression (cdr EXPR)))
                   ((eql op 'set) (parse-enumerated-set (cdr EXPR)))
                   ((eql op 'for) (parse-for (cadr EXPR) (parse-set-expression (caddr EXPR))
                                             (cadddr EXPR) (car (cddddr EXPR))))
                   ((eql op 'collect) (parse-collect (cadr EXPR) (caddr EXPR)))
                   ((eql op 'alldiff) (all-different (mapcar #'parse-expression (cdr EXPR))))
                   ((gethash op ObservedPredicates)
                     (parse-observed-literal-expression EXPR))
                   ((eql op 'lisp)
                     (evaluate-lisp-expression (cadr EXPR)))
                   ((and (member op binary-functions) (= (length EXPR) 3))
                     (parse-binary-expression op (cadr EXPR) (caddr EXPR)))
                   (t (error "Parser error at ~S" EXPR)))))))

(defun parse-binary-expression (op LEFT RIGHT)
  (let ((e1 (parse-expression LEFT)) (e2 (parse-expression RIGHT)))
    (cond ((eql op 'member) (if (member e1 e2 :test #'equalp) 1 0))
          ((or (eql op 'eq) (eql op '=)) (if (equalp E1 E2) 1 0))
          ((eql op 'neq) (if (equalp E1 E2) 0 1))
          ((eql op '<) (if (< e1 e2) 1 0))
          ((eql op '>) (if (> e1 e2) 1 0))
          ((eql op '<=) (if (<= e1 e2) 1 0))
          ((eql op '>=) (if (>= e1 e2) 1 0))
          ((eql op '+) (+ e1 e2))
          ((eql op '-) (- e1 e2))
          ((eql op '*) (* e1 e2))
          ((eql op 'bit) (logand 1 (ash e2 (- 1 e1))))
          ((eql op '**) (expt e1 e2))
          ((eql op 'div) (floor (/ e1 e2)))
          ((eql op 'rem) (- e1 (* e2 (floor (/ e1 e2)))))
          ((eql op 'mod) (mod e1 e2))
          ((eql op 'range) (parse-range e1 e2))
          ((eql op 'union) (union e1 e2 :test #'equalp))
          ((eql op 'intersection) (intersection e1 e2 :test #'equalp))
          ((eql op 'set-difference) (set-difference e1 e2 :test #'equalp))
          (t (error "Parser error at ~S" op)))))

(defun parse-range (LOW HIGH)
  (let ((low (ceiling LOW)) (high (ceiling HIGH)))
    (cond ((> low high) nil)
          (t (cons low (parse-range (1+ low) high))))))

(defun parse-observed-literal-expression (EXPR)
  (let* ((name (car EXPR))
         (args (map 'list #'parse-expression (cdr EXPR)))
         (key (if (null args) name (cons name args))))
    (gethash key ObservedLiterals 0)))

(defun parse-enumerated-set (EXPR)
  (cond ((null EXPR) nil)
        (t (cons (parse-term (car EXPR))
                 (parse-enumerated-set (cdr EXPR))))))

(defun parse-literal (LIT)
  (cond ((and (listp LIT) (eq (car LIT) 'not))
          (list 'not (parse-proposition (cadr LIT))))
        (t (parse-proposition LIT))))

(defun parse-proposition (P)
  (cond ((null P) (error "Unexpected empty set"))
        ((atom P) P)
        (t (let ((name (parse-name (car P)))
                 (args (parse-terms (cdr P))))
             (if (null args) name (cons name args))))))

(defun parse-terms (TERMS)
  (cond ((null TERMS) nil)
        (t (cons (parse-term (car TERMS)) (parse-terms (cdr TERMS))))))

(defun normalize-numeric (x)
  ;; Coerce float-valued integers (e.g. 2.0) to plain integers for clean output.
  (if (and (floatp x) (= x (floor x)))
      (floor x)
      x))

(defun parse-term (TERM)
  (cond ((or (atom TERM) (member (car TERM) interpreted-functions))
          (normalize-numeric (parse-expression TERM)))
        (t (cons (parse-name (car TERM))
                 (parse-terms (cdr TERM))))))
