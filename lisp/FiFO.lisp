;;; FiFO.lisp

(ql:quickload :cl-ppcre :silent t)

;; SAT program used by satisfy
(defvar *solver* "kissat")

;; Abbreviations for solver names: a list of (abbreviation full-name) pairs
;; (binary lists, not an association list). When the *solver* option is given an
;; abbreviation, the *solver* variable is set to the corresponding full name.
(defvar *solver-abbreviations*
  '(("tt-glucose" "tt-open-wbo-inc-Glucose4_1")
    ("tt-intelsat" "tt-open-wbo-inc-IntelSATSolver")
    ("nuwls" "nuwls-c")))

;; Wall-clock limit in seconds for a single solver run.  NIL, 0 or -1 all mean
;; "no limit".
;; The anytime MaxSAT solvers have no time-limit flag of their own: the MaxSAT
;; Evaluation harness stops them with SIGTERM, on which they print the best
;; solution found so far (NuWLS-c installs such a handler in Main.cc, and its
;; own StarExec wrapper is just "timeout -s 15 $wl ./nuwls-c_static $1").  FiFO
;; enforces the limit the same way -- SIGTERM, then SIGKILL after a grace period
;; if the solver ignores it.
(defvar *solver-timeout* 600)

(defun solver-time-limit (timeout)
  "TIMEOUT normalised to a positive number of seconds, or NIL for no limit.
NIL, 0 and -1 all mean unlimited, so a caller can switch the limit off with
whichever of the three spellings is convenient."
  (and timeout (realp timeout) (plusp timeout) timeout))

;; MaxSAT preprocessor: NIL, or the path/name of a MaxPre 2 binary.  When set,
;; a weighted problem is preprocessed before solving and the solver's model is
;; reconstructed afterwards.  This is not optional bookkeeping: MaxPre renumbers
;; (and eliminates) variables, so a model of the preprocessed instance is
;; meaningless in the original variable space that the .map file describes.
(defvar *preprocessor* nil)

;; Techniques string for MaxPre's -techniques= option; NIL uses MaxPre's default.
(defvar *preprocessor-techniques* nil)

;; Seconds to wait after SIGTERM before resorting to SIGKILL.
(defvar *solver-kill-grace* 10)

;; Muffle warnings about common lisp style
(declaim (sb-ext:muffle-conditions cl:style-warning))

;; Default values of options
(defvar *compact-encoding* t)
(defvar *tracing* nil)

(defun trace-message (control &rest args)
  "When *tracing* is set, print a [TRACE] message and flush immediately, so that
if a long instantiation stalls or exhausts memory the last line printed shows
exactly where it was."
  (when *tracing*
    (apply #'format t control args)
    (finish-output)))
;; SatPlan time horizon read by pddl2fifo-generated wff files. Declared special
;; but intentionally left unbound: when unbound the generated alias falls back to
;; 2; (option *satplan-numslices* N) or (setq *satplan-numslices* N) sets it.
(defvar *satplan-numslices*)
(defvar Weights nil)
;; Target marginal probabilities, the input twin of Weights: a (PROBABILITY
;; <literal> <p> <gid>) carries a target marginal p in [0,1] and a tie-group id
;; <gid> (shared by every grounding of one source-wff PROBABILITY form, so the
;; learning pipeline can fit one tied weight per group).  instantiate passes these
;; through to the scnf; the learning pipeline converts them to (WEIGHT ...).
(defvar Probabilities nil)
;; Maps each source (PROBABILITY ...) form (by cons identity) to its tie-group id;
;; populated by assign-probability-gids before parsing so parse-probability can
;; stamp each grounding.  See find-probability-forms / assign-probability-gids.
(defvar *probability-gids* (make-hash-table :test #'eq))
;; Monotonic counter for the fresh auxiliary atoms (WEIGHTED-FORMULA <n>) minted
;; when weight/probability is applied to a compound formula rather than a literal
;; (see reify-formula).  Reset per parse in setup-global-env so numbering is
;; deterministic within one instantiation.  WEIGHTED-FORMULA is reserved by
;; convention (like pddl2fifo's pref-violated / ObsDone atoms) -- do NOT add it to
;; reserved-words, or parse-name would reject the very atoms reify-formula builds.
(defvar *reified-formula-counter* 0)
;; Output format for weighted cnf files: CNF (cw comment lines), WCNF-OLD
;; (old DIMACS "p wcnf" format), or WCNF (2022 DIMACS format with h lines)
(defvar *cnf-format* 'CNF)
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
    (let ((*read-eval* nil))
      (loop for sexpr = (read stream nil nil)
            while sexpr
            collect sexpr))))

(defun read-lines (filename)
  ;; Read a text file and return a list of its lines
  (with-open-file (stream filename)
    (loop for line = (read-line stream nil nil)
          while line
          collect line)))

;;; Error handling for the file-based API.  Malformed input files (missing
;;; files, unbalanced parentheses, unparseable forms, corrupt map files, ...)
;;; print a message and return NIL instead of crashing into the debugger.
;;; The dynamic variable ensures that nested calls (e.g. solve calling
;;; propositionalize) report a single message at the outermost level.

(defvar *fifo-error-context* nil)

(defmacro with-clean-errors ((operation file) &body body)
  `(if *fifo-error-context*
       (progn ,@body)
       (let ((*fifo-error-context* t))
         (handler-case (progn ,@body)
           (end-of-file ()
             (format *error-output*
                     "FiFO error while ~A ~A: unexpected end of file (unbalanced parentheses or truncated file)~%"
                     ,operation ,file)
             nil)
           ((or error storage-condition) (c)
             (format *error-output* "FiFO error while ~A ~A: ~A~%"
                     ,operation ,file c)
             nil)))))
(defun make-scratch-file-root ()
  "Generate a unique scratch file base name for this process."
  (format nil "scratch-~A-~A"
          (get-universal-time)
          (random 1000000000)))
;; File-based API: instantiate, propositionalize, interpret, satisfy, solve
;; 

(defun run-program-to-file (program args outfile &key timeout)
  "Run PROGRAM with ARGS, sending stdout to OUTFILE.  When TIMEOUT (seconds) is a
positive number and the process outlives it, send SIGTERM -- an anytime MaxSAT
solver responds by printing the best solution it has found, so the partial output
is still useful -- and escalate to SIGKILL after *solver-kill-grace* seconds.
Returns (values exit-code timed-out-p)."
  (with-open-file (out outfile :direction :output :if-exists :supersede
                               :if-does-not-exist :create)
    (let ((proc (sb-ext:run-program program args :search t :output out
                                    :error nil :wait nil))
          (timed-out nil))
      (unwind-protect
           (let ((limit (solver-time-limit timeout)))
             (when limit
               (let ((deadline (+ (get-internal-real-time)
                                  (* limit internal-time-units-per-second))))
                 (loop while (sb-ext:process-alive-p proc) do
                   (when (> (get-internal-real-time) deadline)
                     (setq timed-out t)
                     (sb-ext:process-kill proc 15)   ; SIGTERM
                     (let ((grace (+ (get-internal-real-time)
                                     (* *solver-kill-grace*
                                        internal-time-units-per-second))))
                       (loop while (and (sb-ext:process-alive-p proc)
                                        (< (get-internal-real-time) grace))
                             do (sleep 0.05)))
                     (when (sb-ext:process-alive-p proc)
                       (sb-ext:process-kill proc 9)) ; SIGKILL
                     (return))
                   (sleep 0.05)))))
        (sb-ext:process-wait proc))
      (values (sb-ext:process-exit-code proc) timed-out))))

(defun wcnf-scale-offset (wcnf-file)
  "Read the 'c weights scaled by S' / 'c weight shift offset M' comment lines a
weighted .cnf/.wcnf carries (written only when non-trivial) and return (values S
M), defaulting to 1 and 0.  The true plan cost of a solution is its raw objective
/ S + M -- so for the usual non-negative integer action costs (S=1, M=0) the raw
objective already is the true cost; this corrects it when weights were shifted
(e.g. negative costs from learned weights)."
  (let ((scale 1) (offset 0))
    (with-open-file (s wcnf-file :direction :input :if-does-not-exist nil)
      (when s
        (let ((*read-eval* nil))
          (loop for line = (read-line s nil) while line do
            (let (m)
              (cond ((setq m (nth-value 1 (cl-ppcre:scan-to-strings "scaled by\\s+(\\S+):" line)))
                     (setq scale (read-from-string (aref m 0))))
                    ((setq m (nth-value 1 (cl-ppcre:scan-to-strings "shift offset\\s+(\\S+):" line)))
                     (setq offset (read-from-string (aref m 0))))))))))
    (values scale offset)))

(defun solution-lines (file)
  "The last 's', last 'o' and last 'v' lines of a MaxSAT solver's output FILE,
returned as (values status objective model).  Any is NIL when absent."
  (let (status objective model)
    (with-open-file (s file :direction :input :if-does-not-exist nil)
      (when s
        (loop for line = (read-line s nil) while line do
          (cond ((and (>= (length line) 2) (string= "s " (subseq line 0 2)))
                  (setq status line))
                ((and (>= (length line) 2) (string= "o " (subseq line 0 2)))
                  (setq objective line))
                ((and (>= (length line) 2) (string= "v " (subseq line 0 2)))
                  (setq model line))))))
    (values status objective model)))

(defun maxpre--reconstruct (rawfile mapfile satoutfile)
  "Map the solver's model in RAWFILE back to the ORIGINAL variable numbering with
MaxPre's reconstruct mode, writing the result to SATOUTFILE.  Returns T on
success, NIL if there was nothing to reconstruct (e.g. UNSAT, or no model).

MaxPre's parser is strict in two ways this has to work around: it accepts only
\"s OPTIMUM FOUND\" as the status line -- \"s SATISFIABLE\", which is what an
anytime solver prints when it has not proved optimality, makes it report
\"Failed to parse solution\" -- and it prints an uninitialised objective if no
'o' line is present.  So the solver's output is normalised to exactly o/s/v
before the call, and the ORIGINAL status line is restored afterwards, keeping
FiFO's own SAT/UNSAT reading of the file intact."
  (multiple-value-bind (status objective model) (solution-lines rawfile)
    (unless model (return-from maxpre--reconstruct nil))
    (let ((normalized (concatenate 'string satoutfile ".in")))
      (with-open-file (s normalized :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
        (format s "~A~%s OPTIMUM FOUND~%~A~%" (or objective "o 0") model))
      (run-program-to-file *preprocessor* (list normalized "reconstruct"
                                                (format nil "-mapfile=~A" mapfile))
                           satoutfile)
      (multiple-value-bind (rstatus robjective rmodel) (solution-lines satoutfile)
        (declare (ignore rstatus))
        (unless rmodel
          (error "MaxPre could not reconstruct the solution from ~A" rawfile))
        ;; Rewrite with the solver's own status line: MaxPre always says OPTIMUM
        ;; FOUND because that is the only status it parses, which would otherwise
        ;; both overstate the result and hide the SAT/UNSAT token FiFO looks for.
        (with-open-file (s satoutfile :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
          (format s "~A~%~A~%~A~%" (or robjective objective "o 0")
                  (or status "s SATISFIABLE") rmodel))
        (delete-file normalized)
        t))))

(defun satisfy (CNFFILE &key SATOUTFILE)
  (if (null (cl-ppcre:scan "\\." CNFFILE))
      (setq CNFFILE (concatenate 'string CNFFILE ".cnf")))
  (if (not SATOUTFILE)
      (setq SATOUTFILE (replace-suffix-with-regex CNFFILE "\\..*?$" ".satout")))
  (with-clean-errors ("running the SAT solver on" CNFFILE)
    (unless (probe-file CNFFILE)
      (error "cnf file ~A does not exist" CNFFILE))
    (let ((solver-input CNFFILE)
          (solver-output SATOUTFILE)
          mapfile)
      ;; --- optional MaxPre preprocessing -------------------------------------
      (when *preprocessor*
        (unless (member *cnf-format* '(WCNF WCNF-OLD))
          (error "*preprocessor* is a MaxSAT preprocessor, but *cnf-format* is ~S;~%~
                  set (option *cnf-format* WCNF) or clear *preprocessor*"
                 *cnf-format*))
        (let ((root (replace-suffix-with-regex CNFFILE "\\..*?$" "")))
          (setq solver-input (concatenate 'string root "-pre.wcnf")
                mapfile      (concatenate 'string root "-pre.map")
                solver-output (concatenate 'string root "-pre.satout"))
          (handler-case
              (run-program-to-file *preprocessor*
                                   (append (list CNFFILE "preprocess")
                                           (when *preprocessor-techniques*
                                             (list (format nil "-techniques=~A"
                                                           *preprocessor-techniques*)))
                                           (list (format nil "-mapfile=~A" mapfile)))
                                   solver-input)
            (error (c)
              (format *error-output* "FiFO error: could not run preprocessor ~A: ~A~%"
                      *preprocessor* c)
              (return-from satisfy nil)))
          (unless (probe-file solver-input)
            (format *error-output* "FiFO error: preprocessor ~A produced no output~%"
                    *preprocessor*)
            (return-from satisfy nil))))
      ;; --- the solver --------------------------------------------------------
      (multiple-value-bind (code timed-out)
          (handler-case
              (run-program-to-file *solver* (list solver-input) solver-output
                                   :timeout *solver-timeout*)
            (error (c)
              (format *error-output* "FiFO error: could not run SAT solver ~A: ~A~%"
                      *solver* c)
              (return-from satisfy nil)))
        (declare (ignore code))
        (when timed-out
          (format t "; solver ~A stopped after the ~A s limit (*solver-timeout*);~%~
                     ; reporting the best solution it had found~%"
                  *solver* *solver-timeout*)
          (finish-output)))
      ;; --- reconstruction ----------------------------------------------------
      (when *preprocessor*
        (unless (maxpre--reconstruct solver-output mapfile SATOUTFILE)
          ;; Nothing to map back (UNSAT, or the solver produced no model): the
          ;; preprocessed output is the answer as-is.
          (uiop:copy-file solver-output SATOUTFILE)))
      (solver-verdict SATOUTFILE))))

(defun solver-verdict (satoutfile)
  "SAT, UNSAT, or NIL for the solver output in SATOUTFILE.

The DIMACS \"s\" line is authoritative and is consulted first.  Falling straight
to a substring scan of the whole file is not safe: solver banners routinely
contain the word SAT -- tt-open-wbo-inc prints \"MaxSAT Evaluation 2024\" and
\"SAT-based solver\" before it does anything -- so a run that printed a banner
and then no verdict at all (which is what a MaxSAT solver does when handed a
plain \"p cnf\" file) would be read as SAT.  On a prove form that silently turns
an entailment into a COUNTEREXAMPLE.

The scan is kept only as a fallback, for solvers that report a verdict without
an \"s\" line."
  (multiple-value-bind (status) (solution-lines satoutfile)
    (cond (status
            ;; Test UNSATISFIABLE before SATISFIABLE: one contains the other.
            (cond ((search "UNSATISFIABLE" status) 'UNSAT)
                  ((search "UNKNOWN" status) nil)   ; ran out of time, no answer
                  ((search "OPTIMUM" status) 'SAT)  ; s OPTIMUM FOUND
                  ((search "SATISFIABLE" status) 'SAT)
                  (t nil)))
          ;; No "s" line.  Scan for a verdict, but match whole words rather than
          ;; the substring "SAT", which appears in "MaxSAT" and so in the banner
          ;; of every MaxSAT solver.
          (t (verdict-by-scan satoutfile)))))

(defun verdict-by-scan (satoutfile)
  "Fallback verdict for a solver that prints no DIMACS \"s\" line: a line that
says (UN)SATISFIABLE, or one that is exactly SAT or UNSAT.  Returns NIL when the
file says neither, which includes the case of a solver that printed only its
banner."
  (with-open-file (s satoutfile :direction :input :if-does-not-exist nil)
    (when s
      (loop for line = (read-line s nil) while line do
        (let ((up (string-trim '(#\Space #\Tab #\Return) (string-upcase line))))
          (cond ((search "UNSATISFIABLE" up) (return 'UNSAT))
                ((search "SATISFIABLE" up)   (return 'SAT))
                ((string= up "UNSAT")        (return 'UNSAT))
                ((string= up "SAT")          (return 'SAT))))))))

(defun instantiate (WFFFILE &key SCNFILE STATICFILE OBSFILE)
  ;; :obsfile is a deprecated synonym for :staticfile
  (setq STATICFILE (or STATICFILE OBSFILE))
  (if (null (cl-ppcre:scan "\\.." WFFFILE))
      (setq WFFFILE (concatenate 'string WFFFILE ".wff")))
  (if (eq STATICFILE t)
      (setq STATICFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".obs")))
  (if (not SCNFILE)
      (setq SCNFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".scnf")))
  (with-clean-errors ("instantiating" WFFFILE)
    (with-open-file (INS WFFFILE :direction :input)
      (with-open-stream (OBS (if STATICFILE (open STATICFILE :direction :input) (make-concatenated-stream)))
        (with-open-file (OUTS SCNFILE :direction :output :if-exists :supersede)
          (let (CL SCHEMA STATIC-FACT)
            (let ((*current-wff-directory* (uiop:pathname-directory-pathname (truename WFFFILE)))
                  (*read-eval* nil))
              (setq CL (parse
                        (loop while (not (eql 'EOF (setq SCHEMA (read INS nil 'EOF))))
                              collect SCHEMA)
                        :static-list
                        (loop while (not (eql 'EOF (setq STATIC-FACT (read OBS nil 'EOF))))
                              collect STATIC-FACT))))
            (loop for C in CL do (format OUTS "~S~%" C))
            (loop for W in Weights do (format OUTS "~S~%" W))
            (loop for P in Probabilities do (format OUTS "~S~%" P))
            (when (and Weights (not (eql *cnf-format* 'CNF)))
              (format OUTS "(OPTION WEIGHTS ~S)~%" *cnf-format*))))))
    t))

(defun propositionalize (SCNFFILE &key CNFFILE MAPFILE)
  (if (null (cl-ppcre:scan "\\.." SCNFFILE))
      (setq SCNFFILE (concatenate 'string SCNFFILE ".scnf")))
  (with-clean-errors ("propositionalizing" SCNFFILE)
   ;; Read the scnf first so the weights format (and hence the default output
   ;; extension) is known before the output file is opened.
   (let* ((all-forms (with-open-file (WS SCNFFILE :direction :input)
                       (let ((*read-eval* nil))
                         (loop with clause
                               while (not (eql :EOF (setq clause (read WS nil :EOF))))
                               do (when (and (consp clause) (eq (car clause) 'probability))
                                    (error "~A contains (PROBABILITY ...) forms; it carries target ~
marginal probabilities, not weights, and cannot be propositionalized directly. ~
Convert it to a weight-only file first with the learning pipeline (lisp/reweight.lisp ~
or maxent.lisp)."
                                           SCNFFILE))
                                  (unless (and (consp clause)
                                               (member (car clause) '(or weight option)))
                                    (error "malformed scnf form (expected (OR ...), (WEIGHT ...), or (OPTION ...)): ~S"
                                           clause))
                               collect clause))))
          (clauses (remove-if (lambda (f) (member (car f) '(weight option))) all-forms))
          (weights (remove-if-not (lambda (f) (eql (car f) 'weight)) all-forms))
          (wformat (or (loop for f in all-forms
                             when (and (eql (car f) 'option) (eql (cadr f) 'weights))
                               return (caddr f))
                       'CNF))
          ;; WCNF-format files conventionally carry a .wcnf extension; plain and
          ;; cw-comment CNF use .cnf.
          (cnf-suffix (if (member wformat '(WCNF WCNF-OLD)) ".wcnf" ".cnf")))
     (if (not CNFFILE)
         (setq CNFFILE (replace-suffix-with-regex SCNFFILE "\\..*?$" cnf-suffix)))
     (if (not MAPFILE)
         (setq MAPFILE (replace-suffix-with-regex SCNFFILE "\\..*?$" ".map")))
     (with-open-file (CS CNFFILE :direction :output :if-exists :supersede)
       (with-open-file (MS MAPFILE :direction :output :if-exists :supersede)
         (multiple-value-bind (cnfdata mapdata numvar numclauses weightdata)
             (lit2prop clauses :weights weights)
           (cond ((or (null weightdata) (eql wformat 'CNF))
                   (format CS "p cnf ~S ~S~%" numvar numclauses)
                   (loop for c in cnfdata do (format CS "~{~D ~}0~%" c))
                   (loop for w in weightdata do (format CS "cw ~D ~A~%" (first w) (second w))))
                 ((eql wformat 'WCNF-OLD)
                   (write-wcnf-old CS cnfdata weightdata numvar))
                 ((eql wformat 'WCNF)
                   (write-wcnf CS cnfdata weightdata))
                 (t (error "Unknown weights format ~S in ~A" wformat SCNFFILE)))
           (format MS "map ~S~%" numvar)
           (loop for m in mapdata do (format MS "~{~D ~S~}~%" m))))))
   ;; Return the cnf/wcnf pathname so callers that relied on the default name
   ;; can discover which extension was chosen.
   CNFFILE))


(defun interpret (SATOUTFILE &key MAPFILE SOLNFILE (sort-by-time t))
  (if (null (cl-ppcre:scan "\\.." SATOUTFILE))
      (setq SATOUTFILE (concatenate 'string SATOUTFILE ".satout")))
  (if (not MAPFILE)
      (setq MAPFILE (replace-suffix-with-regex SATOUTFILE "\\..*?$" ".map")))
  (if (not SOLNFILE)
      (setq SOLNFILE (replace-suffix-with-regex SATOUTFILE "\\..*?$" ".soln")))
  (with-clean-errors ("interpreting" SATOUTFILE)
   (let (solndata mapdata litdata objective numvar)
    ;; Read solnfile to create solution list.  Ignore any non-integers and negative integers in solnfile.
    ;; Get list of lines of the solution
    (setq solndata (read-lines SATOUTFILE))
    ;; Decide SAT/UNSAT from the DIMACS "s" status line when present (a bare
    ;; "UNSAT" substring may legitimately appear in solver comment lines); fall
    ;; back to scanning all lines for free-form output that has no "s" line.
    (if (let ((sline (find-if (lambda (s) (cl-ppcre:scan "(?i)^s\\s" s)) solndata)))
          (if sline
              (cl-ppcre:scan "(?i)UNSAT" sline)
              (some (lambda (s) (search "UNSAT" s :test #'char-equal)) solndata)))
        (with-open-file (OS SOLNFILE :direction :output :if-exists :supersede)
          (format OS "UNSAT~%"))
        (progn ; satisfiabile case
              ;; Capture the objective from the last "o <number>" line, if any
              ;; (MaxSAT solvers print an improving o-line per incumbent solution).
              (let ((ovals (loop for line in solndata
                                 for m = (nth-value 1 (cl-ppcre:scan-to-strings "^o\\s+(-?\\d+)" line))
                                 when m collect (parse-integer (aref m 0)))))
                (when ovals (setq objective (car (last ovals)))))
              ;; Read mapfile to create mapdata list (numvar is needed to recognize
              ;; the bit-string solution format below).
              (with-open-file (MS MAPFILE :direction :input)
                (let ((*read-eval* nil))
                  (if (not (eql (read MS) 'map)) (error "Bad map file ~A" MAPFILE))
                  (setq numvar (read MS))
                  (if (not (integerp numvar)) (error "Bad map file ~A" MAPFILE))
                  (setq mapdata (loop with i with p
                                      while (not (eql :EOF (setq i (read MS nil :EOF))))
                                      do (setq p (read MS)) (if (not (integerp i)) (error "Bad map file ~A" MAPFILE))
                                      collect (list i p)))))
              ;; Determine the list of true (positive) variable numbers.  Some MaxSAT
              ;; solvers (e.g. tt-open-wbo-inc) report the model as a single "v" line
              ;; that is a bit string of length numvar, one 0/1 per variable, rather
              ;; than the DIMACS list of signed literals.
              (let* ((vlines (remove-if-not (lambda (s) (cl-ppcre:scan "^v" s)) solndata))
                     (bits (and (= (length vlines) 1)
                                (let ((content (string-trim '(#\Space #\Tab) (subseq (car vlines) 1))))
                                  (and (= (length content) numvar)
                                       (cl-ppcre:scan "^[01]+$" content)
                                       content)))))
                (if bits
                    ;; Bit-string format: character i (1-based) is the truth value of variable i.
                    (setq solndata (loop for ch across bits
                                         for v from 1
                                         when (char= ch #\1) collect v))
                    ;; DIMACS / free-form: parse the positive integers out of the v/number lines.
                    (progn
                      ;; On lines that begin with v, drop the v
                      (setq solndata (mapcar (lambda (s) (if (cl-ppcre:scan "^v" s) (subseq s 1) s)) solndata))
                      ;; Eliminate lines containing anything other than integers
                      (setq solndata (remove-if (lambda (str) (cl-ppcre:scan "[^0-9\\s-]" str)) solndata))
                      ;; Convert to a single string
                      (setq solndata (format nil "~{~a~^ ~}" solndata))
                      ;; Convert to a list of integers
                      (setq solndata (mapcar #'parse-integer (ppcre:all-matches-as-strings "-?\\d+" solndata)))
                      ;; Remove negative integers
                      (setq solndata (remove-if (lambda (x) (<= x 0)) solndata)))))
              ;; call soln2lit to create sorted list of true literals
              (setq litdata (soln2lit mapdata solndata sort-by-time))
              ;; Print list of true literals to outfile, with the objective (if any) first.
              (with-open-file (OS SOLNFILE :direction :output :if-exists :supersede)
                (format OS "SAT~%")
                (when objective (format OS "~S~%" (list '*objective* objective)))
                (format OS "~{~S~%~}" litdata)))))
   t))

(defun solve (WFFFILE &key SOLNFILE STATICFILE OBSFILE
                           (SOLVER nil solver-p)
                           (CNF-FORMAT nil cnf-format-p)
                           (PREPROCESSOR nil preprocessor-p)
                           (PREPROCESSOR-TECHNIQUES nil techniques-p)
                           (TIMEOUT nil timeout-p))
  "Solve WFFFILE end to end, writing the answer to SOLNFILE.

The solver-related keywords bind the corresponding special variables for the
duration of the call, so they need not be set globally:

  :solver       the solver executable (abbreviations in *solver-abbreviations*
                are resolved, so :solver \"nuwls\" works)
  :cnf-format   CNF, WCNF or WCNF-OLD -- a MaxSAT solver needs one of the
                weighted formats
  :preprocessor a MaxPre 2 binary to preprocess the weighted CNF with, whose
                model is reconstructed back into the original variable numbering
                afterwards; NIL for none
  :preprocessor-techniques  MaxPre's -techniques= string, NIL for its default
  :timeout      seconds before the solver is stopped with SIGTERM (NIL, 0 or -1
                for no limit); anytime MaxSAT solvers print their best solution
                so far when stopped this way

An (option ...) form inside the .wff is executed while the file is parsed and so
still has the last word, exactly as it does over a prior setq."
  ;; :obsfile is a deprecated synonym for :staticfile
  (setq STATICFILE (or STATICFILE OBSFILE))
  (let ((*solver*                  (if solver-p (resolve-solver-name SOLVER) *solver*))
        (*cnf-format*              (if cnf-format-p CNF-FORMAT *cnf-format*))
        (*preprocessor*            (if preprocessor-p PREPROCESSOR *preprocessor*))
        (*preprocessor-techniques* (if techniques-p PREPROCESSOR-TECHNIQUES
                                       *preprocessor-techniques*))
        (*solver-timeout*          (if timeout-p (solver-time-limit TIMEOUT)
                                       *solver-timeout*)))
    (solve--1 WFFFILE SOLNFILE STATICFILE)))

(defun solve--1 (WFFFILE SOLNFILE STATICFILE)
  (if (null (cl-ppcre:scan "\\.." WFFFILE))
      (setq WFFFILE (concatenate 'string WFFFILE ".wff")))
  (if (not SOLNFILE)
      (setq SOLNFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".answer")))
  (if (eq STATICFILE t)
      (setq STATICFILE (replace-suffix-with-regex WFFFILE "\\..*?$" ".obs")))
  (with-clean-errors ("solving" WFFFILE)
    (let (schemas static-facts SCHEMA STATIC-FACT)
      (let ((*read-eval* nil))
        (with-open-file (INS WFFFILE :direction :input)
          (setq schemas (loop while (not (eql 'EOF (setq SCHEMA (read INS nil 'EOF))))
                              collect SCHEMA)))
        (if STATICFILE
            (with-open-file (OBS STATICFILE :direction :input)
              (setq static-facts (loop while (not (eql 'EOF (setq STATIC-FACT (read OBS nil 'EOF))))
                                       collect STATIC-FACT)))))
      (let ((*current-wff-directory* (uiop:pathname-directory-pathname (truename WFFFILE))))
        (multiple-value-bind (result model-or-bindings) (solve-schemas schemas :static-facts static-facts)
          (with-open-file (ANSWER SOLNFILE :direction :output :if-exists :supersede)
            (format ANSWER "~a~%" result)
            (dolist (e model-or-bindings) (format ANSWER "~a~%" e)))
          result)))))

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
    (if debugp
        (format t ";;test-scnf ~S~%" scnf))
    (when (member debugp '(SAT UNSAT))
      (return-from test-scnf (values debugp nil)))
    (with-open-file (SCNF-STREAM scnf-file :direction :output :if-exists :supersede)
      (dolist (c scnf) (format SCNF-STREAM "~S~%" c))
      (dolist (w Weights) (format SCNF-STREAM "~S~%" w))
      (when (and Weights (not (eql *cnf-format* 'CNF)))
        (format SCNF-STREAM "(OPTION WEIGHTS ~S)~%" *cnf-format*)))
    (propositionalize scnf-file :cnffile cnf-file :mapfile map-file)
    (unless (satisfy cnf-file)
      (error "SAT solver ~A failed on ~A (output contains neither SAT nor UNSAT)"
             *solver* cnf-file))
    (interpret satout-file :mapfile map-file :solnfile soln-file)
    (let ((results (read-sexprs-from-file soln-file)))
      (values (car results) (cdr results)))))

(defun lit2prop (CL &key weights)
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

(defun shift-and-scale-weights (weightdata)
  ;; weightdata is a list of (signed-integer-literal weight) pairs, where a
  ;; weight is the cost incurred when the literal is true.  DIMACS wcnf
  ;; weights must be positive integers, so two transformations are applied:
  ;; 1. Shift: for each atom, subtract the minimum of its total weight when
  ;;    true and total weight when false from both, leaving at most one
  ;;    polarity with a positive weight.  The discarded total is returned as
  ;;    the offset (a constant added to every assignment's cost).
  ;; 2. Scale: multiply all weights by the smallest positive integer that
  ;;    makes them integral.
  ;; A weight w on literal L becomes the soft unit clause (not L) with weight
  ;; w, which is falsified exactly when L is true.
  ;; Returns (values soft-clauses offset scale), where each soft clause is a
  ;; (unit-literal integer-weight) pair.
  (let ((wtrue (make-hash-table)) (wfalse (make-hash-table))
        (atoms nil) (offset 0) (soft nil))
    ;; Convert weights to exact rationals up front so the shift arithmetic
    ;; below is exact (e.g. 0.7 - 0.3 is 2/5, not a float rounding artifact)
    (loop for (l w) in weightdata do
      (let ((v (abs l)))
        (pushnew v atoms)
        (if (plusp l)
            (incf (gethash v wtrue 0) (rationalize w))
            (incf (gethash v wfalse 0) (rationalize w)))))
    (dolist (v (sort atoms #'<))
      (let* ((wt (gethash v wtrue 0))
             (wf (gethash v wfalse 0))
             (m (min wt wf)))
        (incf offset m)
        (when (> wt m) (push (list (- v) (- wt m)) soft))
        (when (> wf m) (push (list v (- wf m)) soft))))
    (setq soft (nreverse soft))
    (let ((scale (reduce #'lcm (mapcar (lambda (s) (denominator (cadr s))) soft)
                         :initial-value 1)))
      (values (mapcar (lambda (s) (list (car s) (* (cadr s) scale))) soft)
              offset scale))))

(defun write-weight-comments (CS offset scale)
  (when (/= scale 1)
    (format CS "c weights scaled by ~A: true cost = solver cost / ~A~%" scale scale))
  (when (/= offset 0)
    (format CS "c weight shift offset ~A: add to unscaled cost~%" offset)))

(defun write-wcnf-old (CS cnfdata weightdata numvar)
  ;; Old DIMACS wcnf format: "p wcnf <vars> <clauses> <top>"; every clause
  ;; line begins with its weight, and hard clauses use the weight top, which
  ;; must exceed the sum of all soft weights.
  (multiple-value-bind (soft offset scale) (shift-and-scale-weights weightdata)
    (let ((top (1+ (reduce #'+ soft :key #'cadr :initial-value 0))))
      (write-weight-comments CS offset scale)
      (format CS "p wcnf ~S ~S ~S~%" numvar (+ (length cnfdata) (length soft)) top)
      (loop for c in cnfdata do (format CS "~D ~{~D ~}0~%" top c))
      (loop for s in soft do (format CS "~D ~D 0~%" (cadr s) (car s))))))

(defun write-wcnf (CS cnfdata weightdata)
  ;; New (2022) DIMACS wcnf format: no p line; hard clauses begin with "h",
  ;; soft clauses begin with their positive integer weight.
  (multiple-value-bind (soft offset scale) (shift-and-scale-weights weightdata)
    (write-weight-comments CS offset scale)
    (loop for c in cnfdata do (format CS "h ~{~D ~}0~%" c))
    (loop for s in soft do (format CS "~D ~D 0~%" (cadr s) (car s)))))


(defun soln2lit (mapdata solndata sort-by-time)
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
        ;; Compare atoms by print name so a numeric slice argument can be ordered
        ;; against a symbolic one (e.g. a non-time-indexed proposition such as
        ;; (pref-violated <name>)) without string-lessp rejecting the integer.
        ((and (atom p) (atom q)) (string-lessp (princ-to-string p) (princ-to-string q)))
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

(defun split-list (lst &key (index (floor (/ (length lst) 2))))
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
(defun solve-schemas (schemas &key static-facts observations)
  ;; :observations is a deprecated synonym for :static-facts
  (setq static-facts (or static-facts observations))
  (multiple-value-bind (prove-form rest-of-wff) (pull-out-prove schemas)
    (cond ((null prove-form)
            (test-scnf (parse schemas :static-list static-facts)))
          (t
            (let* ((vdlist (cadr prove-form))
                   (test (caddr prove-form))
                   (qbody (cadddr prove-form))
                   (assumptions (parse rest-of-wff :static-list static-facts))
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
(defvar StaticPredicates)
(defvar StaticLiterals)
;; Inverted index over the asserted static literals, used by collect to avoid
;; scanning every literal.  Keys: (predicate position value) -> list of literals
;; whose argument at POSITION equals VALUE, and (predicate :all) -> all literals
;; of PREDICATE.
(defvar StaticIndex)
(defvar Weights)
(defvar Probabilities)
;; When true, parse-formula treats static predicates as plain literals to assert
;; (used when processing static form bodies so newly derived pairs get added).
(defvar static-body-mode nil)

(defun setup-global-env ()
  ; Set up global environment
  (setq Bind (make-hash-table :test #'eql))
  (setq StaticPredicates (make-hash-table :test #'eql))
  (setq StaticLiterals (make-hash-table :test #'equal))
  (setq StaticIndex (make-hash-table :test #'equal))
  (setq Weights nil)
  (setq Probabilities nil)
  (clrhash *probability-gids*)
  (setq *reified-formula-counter* 0)
  (setf (gethash 'TRUE StaticPredicates) 1)
  (setf (gethash 'TRUE StaticLiterals) 1)
  (setf (gethash 'FALSE StaticPredicates) 1)
  (setf (gethash 'FALSE StaticLiterals) 0))

(defun parse (SCHEMA-LIST &key STATIC-LIST OBSERVATION-LIST)
  ;; :observation-list is a deprecated synonym for :static-list
  (setup-global-env)
  (parse-same-env SCHEMA-LIST :static-list (or STATIC-LIST OBSERVATION-LIST)))

(defun parse-same-env (SCHEMA-LIST &key STATIC-LIST OBSERVATION-LIST)
  (parse-statics (or STATIC-LIST OBSERVATION-LIST))
  (assign-probability-gids SCHEMA-LIST)
  (mapcar #'(lambda (c) (cons 'or c))
    (remove-valid-clauses
     (parse-schema-list SCHEMA-LIST))))

;; Global variables used by parse statics
(defvar new-static)

;;; Simple static facts (no quantifiers)
;;; Note that it sets global new-static
;;; Each clause must be a unit clause (not a disjuction).
;;; We allow a clause to be proposition (so not a list).

(defun parse-unit-statics (STATIC-LIST)
  ;; STATIC-LIST is a list of unit positive literals.  Each literal is
  ;; either an atom (a 0-ary predicate) or a list (predicate arg1 arg2 ...).
  (cond ((null STATIC-LIST) nil)
        (t
         (setf (gethash
                 (if (listp (car STATIC-LIST))
                     (caar STATIC-LIST)
                     (car STATIC-LIST))
                 StaticPredicates)
               1)
         (let ((lit (car STATIC-LIST)))
           (when (not (gethash lit StaticLiterals))
             (setf (gethash lit StaticLiterals) 1)
             (setq new-static t)
             ;; Add the newly asserted literal to the inverted index.
             (when (consp lit)
               (let ((pred (car lit)))
                 (push lit (gethash (list pred :all) StaticIndex))
                 (loop for arg in (cdr lit) for i from 1 do
                   (push lit (gethash (list pred i arg) StaticIndex)))))))
         (parse-unit-statics (cdr STATIC-LIST)))))

(defun parse-statics (STATIC-LIST)
  ;; Re-evaluate each static form until no new literals are added,
  ;; so that quantified static forms whose tests depend on earlier
  ;; static facts are fully expanded.
  (loop do
        (setq new-static nil)
        (parse-static-list STATIC-LIST)
        while new-static)
  nil)

(defun parse-static-list (STATIC-LIST)
  (cond ((null STATIC-LIST) nil)
        (t (parse-static-form (car STATIC-LIST))
           (parse-static-list (cdr STATIC-LIST)))))

(defun parse-static-form (FORM)
  ;; Parse the form to a list of clauses.  The language restricts static-form
  ;; bodies to and/all/if and positive literals, so each clause is a unit
  ;; positive literal; take the car of each clause to recover it.
  ;; static-body-mode prevents parse-formula from treating static
  ;; predicates as truth-value checks so newly derived literals get asserted.
  (let ((static-body-mode t))
    (parse-unit-statics (mapcar #'car (parse-schema FORM)))))

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
  (cond ((atom SCHEMA)
         (trace-message "[TRACE] Formula: ~S~%" SCHEMA))
        ((member (car SCHEMA) '(domain alias option static observed include weight probability)) nil)
        (t (trace-message "[TRACE] Formula: (~A ...)~%" (car SCHEMA))))
  (cond ((atom SCHEMA) (parse-formula SCHEMA))
        ((eql (car SCHEMA) 'domain) (parse-domain (cdr SCHEMA)))
        ((eql (car SCHEMA) 'alias) (parse-alias (cdr SCHEMA)))
        ((eql (car SCHEMA) 'option) (parse-option (cdr SCHEMA)))
        ;; observed is a deprecated synonym for static
        ((member (car SCHEMA) '(static observed)) (parse-statics (cdr SCHEMA)))
        ((eql (car SCHEMA) 'include) (parse-include (cadr SCHEMA)))
        ((eql (car SCHEMA) 'weight) (parse-weight (cdr SCHEMA)))
        ((eql (car SCHEMA) 'probability) (parse-probability SCHEMA))
        (t (parse-formula SCHEMA))))

(defun weight-or-probability-form-p (F)
  "True for a (weight ...) or (probability ...) schema form.  Used to reject such
forms in the or/not/implies/equiv contexts, where they have no non-degenerate
meaning (a weight/probability form contributes no clause of its own)."
  (and (consp F) (member (car F) '(weight probability))))

(defun reified-formula-atom-p (atom)
  "True for a fresh auxiliary atom (WEIGHTED-FORMULA n) minted by reify-formula.
Marginal reporters use this to suppress these internal atoms from the default
(all-atoms) listing; they still surface under --weighted-only, since P(that atom)
is exactly P(the reified formula)."
  (and (consp atom) (eq (car atom) 'WEIGHTED-FORMULA)))

(defun reify-formula (phi)
  "Reify the compound formula PHI into a fresh determined atom
A = (WEIGHTED-FORMULA n) plus the hard clauses of the biconditional A <=> PHI.
Because A is fully determined by PHI, the biconditional constrains nothing about
PHI's own atoms (it is count-neutral under weighted model counting), so P(A) =
P(PHI): attaching a weight or target marginal to A applies it exactly when PHI
holds.  The biconditional is expanded with *compact-encoding* disabled so it
introduces no gensym selector atoms -- those would not survive the scnf ~S
round-trip (each #:XXn reads back as a distinct symbol).  PHI is parsed in the
current binding environment, so this works per-grounding inside all/exists.
Returns (values A clauses)."
  (let* ((n (incf *reified-formula-counter*))
         (atom (list 'WEIGHTED-FORMULA n))
         (*compact-encoding* nil))
    (values atom (parse-equiv (list atom phi)))))

(defun parse-weight (ARGS)
  (let ((arg (car ARGS))
        (num (normalize-numeric (parse-numeric-expression (cadr ARGS)))))
    (cond ((is-literal arg)
           ;; literal argument: attach the weight directly (unchanged behavior)
           (setq Weights (append Weights (list (list 'WEIGHT (parse-literal arg) num))))
           nil)
          (t
           ;; compound formula: reify to a fresh determined atom and weight that;
           ;; the biconditional clauses become part of the hard theory
           (multiple-value-bind (atom clauses) (reify-formula arg)
             (setq Weights (append Weights (list (list 'WEIGHT atom num))))
             clauses)))))

(defun find-probability-forms (form)
  "Depth-first list of every (PROBABILITY ...) subform of FORM, in document order.
Shared by instantiate (to stamp tie-group ids) and the learning pipeline's
write-back (to map a learned weight back onto its source form), so the two agree
on the auto-assigned ids."
  (cond ((not (consp form)) nil)
        ((eq (car form) 'probability) (list form))
        (t (loop for sub in form append (find-probability-forms sub)))))

(defun probability-form-gid (form counter-cell)
  "The tie-group id of a (PROBABILITY <lit> <p> [<tie-label>]) FORM: the explicit
trailing tie-label if given (any non-nil value -- a symbol, or a structured tag
such as (:action move) that pddl2fifo uses to mark provenance), else the next auto
integer from COUNTER-CELL (a one-element list used as a mutable counter)."
  (let ((label (cadddr form)))            ; (probability lit p label)
    (if label
        label
        (incf (car counter-cell)))))

(defun assign-probability-gids (schema-list)
  "Populate *probability-gids* (cons -> tie-group id) for every (PROBABILITY ...)
form in SCHEMA-LIST, in document order.  Unlabeled forms get successive integers;
labeled forms get their label.  Same traversal the write-back uses, so ids match."
  (clrhash *probability-gids*)
  (let ((counter (list 0)))
    (dolist (form (find-probability-forms schema-list))
      (setf (gethash form *probability-gids*) (probability-form-gid form counter)))))

(defun parse-probability (SCHEMA)
  "Parse a (PROBABILITY <literal> <p> [<tie-label>]) schema into a ground
(PROBABILITY <literal> <p> <gid>) entry on the global Probabilities list, stamping
the tie-group id assigned to this source form by assign-probability-gids."
  (let* ((args (cdr SCHEMA))
         (arg (car args))
         (p (normalize-numeric (parse-numeric-expression (cadr args))))
         (gid (gethash SCHEMA *probability-gids*)))
    (unless (and (realp p) (<= 0 p) (<= p 1))
      (error "PROBABILITY target must be a probability in [0,1]: ~S" SCHEMA))
    (unless gid
      (error "internal: no tie-group id for PROBABILITY form ~S" SCHEMA))
    (cond ((is-literal arg)
           ;; literal argument: target its marginal directly (unchanged behavior)
           (setq Probabilities
                 (append Probabilities (list (list 'PROBABILITY (parse-literal arg) p gid))))
           nil)
          (t
           ;; compound formula: reify to a fresh determined atom whose marginal
           ;; equals P(formula); target that.  Biconditional clauses join the theory.
           (multiple-value-bind (atom clauses) (reify-formula arg)
             (setq Probabilities (append Probabilities (list (list 'PROBABILITY atom p gid))))
             clauses)))))

(defun resolve-solver-name (NAME)
  (let ((pair (assoc (string-downcase NAME) *solver-abbreviations* :test #'string=)))
    (if pair (cadr pair) NAME)))

(defun normalize-solver-abbreviations (PAIRS)
  (mapcar (lambda (pair)
            (list (string-downcase (string (car pair)))
                  (string (cadr pair))))
          PAIRS))

(defun parse-option (ARGS)
  (let ((opt (car ARGS)))
    ;; *solver-abbreviations* takes a raw list of pairs, which must not be run
    ;; through parse-expression, so handle it before computing val.
    (when (eql opt '*solver-abbreviations*)
      (setq *solver-abbreviations*
            (normalize-solver-abbreviations (cadr ARGS)))
      (return-from parse-option nil)))
  (let ((opt (car ARGS))
        (val (parse-expression (cadr ARGS))))
    (if (eql val 0) (setq val nil))
    (cond ((eql opt '*compact-encoding*)
            (set opt val))
          ((eql opt '*tracing*)
            (setq *tracing* val)
            (trace-message "[TRACE] Tracing enabled~%"))
          ((eql opt '*cnf-format*)
            (unless (member val '(CNF WCNF-OLD WCNF))
              (error "Unknown *cnf-format* ~S; must be CNF, WCNF-OLD, or WCNF" val))
            (setq *cnf-format* val))
          ((eql opt '*solver*)
            (setq *solver*
                  (resolve-solver-name
                    (cond ((stringp val) val)
                          ((symbolp val) (string-downcase (symbol-name val)))
                          (t (error "*solver* must be a symbol or string, not ~S" val))))))
          ((eql opt '*satplan-numslices*)
            (unless (integerp val)
              (error "*satplan-numslices* must be an integer, not ~S" val))
            (set '*satplan-numslices* val))
          ((eql opt '*solver-timeout*)
            ;; 0 and -1 both mean "no limit" (parse-option has already turned a
            ;; literal 0 into NIL); solver-time-limit normalises all three.
            (unless (or (null val) (realp val))
              (error "*solver-timeout* must be a number of seconds, not ~S" val))
            (setq *solver-timeout* (solver-time-limit val)))
          ((eql opt '*preprocessor*)
            (setq *preprocessor*
                  (cond ((null val) nil)
                        ((stringp val) val)
                        ((symbolp val) (string-downcase (symbol-name val)))
                        (t (error "*preprocessor* must be a symbol or string, not ~S" val)))))
          ((eql opt '*preprocessor-techniques*)
            (setq *preprocessor-techniques*
                  (cond ((null val) nil)
                        ((stringp val) val)
                        ((symbolp val) (symbol-name val))
                        (t (error "*preprocessor-techniques* must be a string, not ~S" val)))))
          (t (error "Unknown option ~S" opt)))
    nil))

(defun parse-include (FILENAME)
  (let* ((resolved (if *current-wff-directory*
                       (uiop:merge-pathnames* FILENAME *current-wff-directory*)
                       FILENAME))
         (*current-wff-directory* (uiop:pathname-directory-pathname resolved)))
    (trace-message "[TRACE] Include ~S~%" resolved)
    (parse-schema-list (read-sexprs-from-file resolved))))

(defun parse-domain (DEFINITION)
  (let ((vals (parse-set-expression (cadr DEFINITION))))
    (trace-message "[TRACE] Domain ~S = ~S~%" (car DEFINITION) vals)
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

(defun is-static-literal (F)
  (cond ((not (is-literal F)) nil)
        ((and (listp F) (eql (car F) 'not))
          (is-static-literal (cadr F)))
        ((listp F)
          (gethash (car F) StaticPredicates))
        (t
          (gethash F StaticPredicates))))

(defun parse-static-literal (F)
  ;; returns NIL if static literal is true and (nil) if it is false
  (cond ((and (listp F) (eql (car F) 'not))
          (if (is-true (gethash (parse-literal (cadr F)) StaticLiterals 0))
              '(())
              '()))
        (t
          (if (is-true (gethash (parse-literal F) StaticLiterals 0))
              '()
              '(())))))

(defun parse-formula (F)
  ;; (format t "entering parse ~S" F)
  (cond ((weight-or-probability-form-p F)
          (error "weight/probability may not appear inside or/not/implies/equiv: ~S" F))
        ((and (consp F) (eq (car F) 'not) (weight-or-probability-form-p (cadr F)))
          (error "weight/probability may not appear inside or/not/implies/equiv: ~S" F))
        ((and (not static-body-mode) (is-static-literal F)) (parse-static-literal F))
        ((is-literal F) (list (list (parse-literal F))))
        ((eql (car F) 'not) (parse-not (cadr F)))
        ((eql (car F) 'and) (parse-and (cdr F)))
        ((eql (car F) 'or) (parse-or (cdr F)))
        ((eql (car F) 'implies) (parse-implies (cdr F)))
        ((eql (car F) 'if) (parse-if (cadr F) (caddr F)))
        ((eql (car F) 'equiv) (parse-equiv (cdr F)))
        ((eql (car F) 'all)
          (unless (= (length F) 5)
            (error "Malformed all (expected (all <var> <domain> <test> <body>)): ~S" F))
          (parse-all (cadr F)
                     (parse-set-expression (caddr F))
                     (cadddr F)
                     (car (cddddr F))))
        ((eql (car F) 'exists)
          (unless (= (length F) 5)
            (error "Malformed exists (expected (exists <var> <domain> <test> <body>)): ~S" F))
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
        ((weight-or-probability-form-p (car FL))
          (error "weight/probability may not appear inside or/not/implies/equiv: ~S" (car FL)))
        (t (multiply-clauses (parse-schema (car FL))
                             (parse-or (cdr FL))))))

(defun multiply-clauses (L R)
  (let ((result
          (if (or (null *compact-encoding*)
                  (< (length L) 2)
                  (< (length R) 2)
                  (< (+ (length L) (length R)) 5))
              (explicit-multiply-clauses L R)
              (let ((g (gensym "XX"))) ;; g selects whether L or R must be true
                (append (mapcar #'(lambda (c) (cons g c)) R)
                        (mapcar #'(lambda (c) (cons (list 'not g) c)) L))))))
    (trace-message "[TRACE] Multiply: ~D x ~D -> ~D clauses~%"
                   (length L) (length R) (length result))
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
         (trace-message "[TRACE] ALL ~S = ~S~%" VAR (car DOM))
         (append (parse-binding VAR (car DOM) TEST BODY nil)
                 (parse-all VAR (cdr DOM) TEST BODY)))
        ;; a list of variables is specified
        (t
         (trace-message "[TRACE] ALL ~S over ~S~%" VAR DOM)
         (parse-formula (expand-multivar-all VAR DOM TEST BODY)))))


(defun parse-exists (VAR DOM TEST BODY)
  (cond ((NULL Dom) (list nil)) ;; the empty clause
        ;; a single variable is specified
        ((not (listp VAR))
         (trace-message "[TRACE] EXISTS ~S = ~S~%" VAR (car DOM))
         (multiply-clauses (parse-binding VAR (car DOM) TEST BODY (list nil))
                           (parse-exists VAR (cdr DOM) TEST BODY)))
        ;; a list of variables is specified
        (t
         (trace-message "[TRACE] EXISTS ~S over ~S~%" VAR DOM)
         (parse-formula (expand-multivar-exists VAR DOM TEST BODY)))))


(defun parse-for (VAR DOM TEST BODY)
  (cond ((null DOM) nil) ;; the empty list of clauses
        ;; a single variable is specified
        ((not (listp VAR))
         (trace-message "[TRACE] FOR ~S = ~S~%" VAR (car DOM))
         (append (parse-expression-binding VAR (car DOM) TEST BODY nil)
                 (parse-for VAR (cdr DOM) TEST BODY)))
        ;; a list of variables is specified
        (t
         (trace-message "[TRACE] FOR ~S over ~S~%" VAR DOM)
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

(defun collect-candidates (PRED VAR pat-args)
  "Candidate static literals for a (collect VAR (PRED . pat-args)) form,
narrowed via StaticIndex.  If some pattern position is a definite constraint
-- an atom other than VAR or * -- look up the (PRED position value) bucket for
the first such position; otherwise return all literals of PRED.  Every literal
that can actually match is in the returned list (the caller still verifies the
full pattern), so this never drops a valid match."
  (loop for pat in pat-args and i from 1 do
    (when (and (atom pat) (not (eq pat VAR)) (not (eq pat '*)))
      (return-from collect-candidates
        (gethash (list PRED i (parse-term pat)) StaticIndex))))
  (gethash (list PRED :all) StaticIndex))

(defun parse-collect (VAR PATTERN)
  ;; (collect VAR (pred pat+))
  ;; Iterates over the true static literals matching PATTERN and returns the
  ;; set of ground terms that VAR binds to.  Both VAR and * are wildcards;
  ;; other atoms/compounds are evaluated as terms and compared exactly.
  ;; Candidate literals come from StaticIndex rather than a full scan.
  (let ((pred (parse-name (car PATTERN)))
        (pat-args (cdr PATTERN))
        (results nil))
    (dolist (key (collect-candidates pred VAR pat-args))
      (when (and (listp key)
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
    (trace-message "[TRACE] COLLECT ~S = ~S~%" VAR results)
    results))

(defun parse-expression-binding (VAR VAL TEST BODY FAILED-TEST-RESULT)
  (let ((RESULT FAILED-TEST-RESULT))
    (with-binding VAR VAL
                  (let ((TESTVAL (parse-expression TEST)))
                    (if (is-true TESTVAL)
                        (setq RESULT (parse-expression BODY)))))
    RESULT))

(defun multivar-domain-alias (DOM)
  "Bind a fresh symbol to the already-evaluated domain DOM and return that symbol.
The inner quantifiers of an expanded multi-variable form reference the domain by
this name rather than re-embedding it as (set ...).  Re-embedding would re-parse
each domain element, re-evaluating any constant in a domain term that happens to
collide with an outer quantifier variable (now bound) and thereby corrupting the
term -- e.g. an action term (fly p a1 a2) when the quantifier variable a1 is
bound.  Referencing a bound domain symbol returns the stored list verbatim."
  (let ((sym (gensym "MVDOM")))
    (setf (gethash sym Bind) DOM)
    sym))

(defun expand-multivar-for (VARLIST DOM TEST BODY)
  (if (null VARLIST)
      BODY
      (let ((d (multivar-domain-alias DOM)))
        (labels ((build (vars)
                   (if (null (cdr vars))
                       `(for ,(car vars) ,d ,TEST ,BODY)
                       `(for ,(car vars) ,d t ,(build (cdr vars))))))
          (build VARLIST)))))


(defun expand-multivar-all (VARLIST DOM TEST BODY)
  (if (null VARLIST)
      BODY
      (let ((d (multivar-domain-alias DOM)))
        (labels ((build (vars)
                   (if (null (cdr vars))
                       `(all ,(car vars) ,d ,TEST ,BODY)
                       `(all ,(car vars) ,d t ,(build (cdr vars))))))
          (build VARLIST)))))


(defun expand-multivar-exists (VARLIST DOM TEST BODY)
  (if (null VARLIST)
      BODY
      (let ((d (multivar-domain-alias DOM)))
        (labels ((build (vars)
                   (if (null (cdr vars))
                       `(exists ,(car vars) ,d ,TEST ,BODY)
                       `(exists ,(car vars) ,d t ,(build (cdr vars))))))
          (build VARLIST)))))

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
                   ((gethash op StaticPredicates)
                     (parse-static-literal-expression EXPR))
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
          ;; Order-preserving set operations: the standard-library union /
          ;; intersection / set-difference leave result order unspecified, which
          ;; made instantiation of any domain built from them (and hence its scnf
          ;; clause order) nondeterministic across runs.  These keep the first
          ;; operand's order, with union appending only the genuinely new elements
          ;; of the second.
          ((eql op 'union)
           (append e1 (remove-if (lambda (x) (member x e1 :test #'equalp)) e2)))
          ((eql op 'intersection)
           (remove-if-not (lambda (x) (member x e2 :test #'equalp)) e1))
          ((eql op 'set-difference)
           (remove-if (lambda (x) (member x e2 :test #'equalp)) e1))
          (t (error "Parser error at ~S" op)))))

(defun parse-range (LOW HIGH)
  (let ((low (ceiling LOW)) (high (ceiling HIGH)))
    (cond ((> low high) nil)
          (t (cons low (parse-range (1+ low) high))))))

(defun parse-static-literal-expression (EXPR)
  (let* ((name (car EXPR))
         (args (map 'list #'parse-expression (cdr EXPR)))
         (key (if (null args) name (cons name args))))
    (gethash key StaticLiterals 0)))

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
