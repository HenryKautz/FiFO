;;;; plearn.lisp -- end-to-end PDDL weight learning.
;;;;
;;;; Load after FiFO.lisp, pddl2fifo.lisp, and reweight.lisp (plus maxent.lisp for
;;;; :maxent).  learn-pddl translates a PDDL problem+domain to a wff, instantiates
;;;; it, learns weights for the (:probability ...) specs, and writes copies of the
;;;; domain (and instance) files with each :probability replaced by its learned
;;;; :cost.  The tie-group ids that pddl2fifo stamps -- (:action <name>) for an
;;;; action -- are recomputed here from the source files, so each learned weight is
;;;; mapped back onto the construct it came from.

;;; ---- spec -> integer cost --------------------------------------------------

(defun pl--spec->cost (spec scale what)
  "Integer cost for a learned tie-group SPEC ((:theta r) | (:hard 0/1)): the
cost-when-true round(scale*r).  A certainty has no finite cost -- error."
  (cond ((null spec)
         (error "no learned weight for ~a (it had no probability in the .scnf)" what))
        ((eq (first spec) :theta) (round (* scale (second spec))))
        (t (error "~a has a certainty probability (p=0 or 1); it cannot become a finite :cost"
                  what))))

;;; ---- domain rewrite: action :probability -> :cost --------------------------

(defun pl--plist-prob->cost (plist w)
  "Copy an action body PLIST, replacing the :probability slot with :cost W."
  (loop for (k v) on plist by #'cddr
        if (eq k :probability) append (list :cost w)
        else append (list k v)))

(defun pl--rewrite-action (action-form gid->spec scale)
  "Rewrite (:action NAME ... :probability p ...) to (... :cost w ...) using the
learned weight for tie group (:action NAME); other actions are returned unchanged."
  (let ((name (second action-form)) (body (cddr action-form)))
    (if (getf body :probability)
        (list* :action name
               (pl--plist-prob->cost
                 body (pl--spec->cost (gethash (list :action name) gid->spec)
                                      scale (format nil "action ~a" name))))
        action-form)))

(defun pl--rewrite-domain-define (define-form gid->spec scale)
  "Rewrite every :action section of a (define (domain ...) ...) form."
  (list* (first define-form) (second define-form)
         (mapcar (lambda (sec)
                   (if (and (consp sec) (eq (first sec) :action))
                       (pl--rewrite-action sec gid->spec scale)
                       sec))
                 (cddr define-form))))

(defun pl--has-action-probability-p (define-form)
  (some (lambda (sec) (and (consp sec) (eq (first sec) :action)
                           (getf (cddr sec) :probability)))
        (cddr define-form)))

;;; ---- instance rewrite: preference / :fluent-cost :probability -> weight ----

(defun pl--instance-has-probability-p (form)
  "True if FORM (anywhere) has a (preference ... :probability ...) or
(:fluent-cost ... :probability ...)."
  (cond ((not (consp form)) nil)
        ((and (eq (car form) 'preference) (eq (fourth form) :probability)) t)
        ((and (eq (car form) :fluent-cost) (eq (third form) :probability)) t)
        (t (some #'pl--instance-has-probability-p form))))

(defun pl--rewrite-instance-form (form gid->spec scale)
  "Recursively rewrite (preference name body :probability p) -> (preference name
body w) and (:fluent-cost lit :probability p) -> (:fluent-cost lit w), using the
learned weight for tie group (:pref name) / (:fluent lit)."
  (cond ((not (consp form)) form)
        ((and (eq (car form) 'preference) (eq (fourth form) :probability))
         (let ((name (second form)) (body (third form)))
           (list 'preference name body
                 (pl--spec->cost (gethash (list :pref name) gid->spec) scale
                                 (format nil "preference ~a" name)))))
        ((and (eq (car form) :fluent-cost) (eq (third form) :probability))
         (let ((lit (second form)))
           (list :fluent-cost lit
                 (pl--spec->cost (gethash (list :fluent lit) gid->spec) scale
                                 (format nil "fluent-cost ~s" lit)))))
        (t (mapcar (lambda (x) (pl--rewrite-instance-form x gid->spec scale)) form))))

;;; ---- writing a PDDL file ---------------------------------------------------

(defun pl--write-pddl (define-form out-path)
  "Pretty-print a single PDDL (define ...) form to OUT-PATH (s-expression form;
comments and original spacing are not preserved)."
  (with-open-file (out out-path :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
    (let ((*print-case* :downcase) (*print-pretty* t) (*print-right-margin* 90))
      (write define-form :stream out))
    (terpri out))
  out-path)

(defun pl--default-out (path suffix)
  (cl-ppcre:regex-replace "\\.[^.]*$" (namestring path)
                          (concatenate 'string suffix ".pddl")))

(defun pl--domain-path (problem-path domain-file)
  "Resolve the domain file: DOMAIN-FILE if given, else <domain-name>.pddl next to
the problem (from its (:domain ...) form)."
  (if domain-file
      (pathname domain-file)
      (let* ((pdef (find-define (read-pddl-file problem-path) "PROBLEM" problem-path))
             (dname (second (get-section pdef :domain))))
        (merge-pathnames (make-pathname :name (string-downcase (symbol-name dname)) :type "pddl")
                         problem-path))))

;;; ---- driver ----------------------------------------------------------------

(defun learn-pddl (problem-file
                   &key domain-file (method :log-odds) (scale 100) (numslices 3)
                        satplan-path domain-out problem-out (verbose t))
  "Translate PROBLEM-FILE (+ its domain) to a wff, instantiate it at NUMSLICES,
learn weights for every (:probability ...) spec -- action slots in the domain and
preference / :fluent-cost specs in the instance -- with METHOD (:log-odds or
:maxent), and write copies of whichever files carried probabilities with each
:probability replaced by the learned cost/weight.  Returns (values domain-out
problem-out) for the files written (NIL where nothing was)."
  (let* ((problem-path (pathname problem-file))
         (root (pathname-name problem-path))
         (scnf (merge-pathnames (make-pathname :name root :type "scnf") problem-path))
         (rwout (merge-pathnames (make-pathname :name (concatenate 'string root "_reweighted")
                                                :type "scnf") problem-path))
         (dom-path (pl--domain-path problem-path domain-file))
         (ddef (find-define (read-pddl-file dom-path) "DOMAIN" dom-path))
         (pdef (find-define (read-pddl-file problem-path) "PROBLEM" problem-path))
         (has-action (pl--has-action-probability-p ddef))
         (has-instance (pl--instance-has-probability-p pdef)))
    (unless (or has-action has-instance)
      (when verbose (format t "No (:probability ...) specs found; nothing to learn.~%"))
      (return-from learn-pddl (values nil nil)))
    ;; 1. PDDL -> wff
    (let ((wff (apply #'pddl2fifo (namestring problem-path)
                      (append (when domain-file (list :domain-file domain-file))
                              (when satplan-path (list :satplan-path satplan-path))))))
      ;; 2. instantiate at the (small) learning horizon
      (setq *satplan-numslices* numslices)
      (instantiate (namestring wff) :scnfile (namestring scnf))
      ;; 3. learn -> gid -> spec
      (multiple-value-bind (out gid->spec)
          (ecase method
            (:log-odds (reweight (namestring scnf) :out-file (namestring rwout) :scale scale))
            (:maxent   (maxent-reweight (namestring scnf) :out-file (namestring rwout)
                                        :scale scale :verbose verbose)))
        (declare (ignore out))
        ;; 4. write the learned copies of whichever files had probabilities
        (let ((dout (when has-action (or domain-out (pl--default-out dom-path "_learned"))))
              (pout (when has-instance (or problem-out (pl--default-out problem-path "_learned")))))
          (when has-action
            (pl--write-pddl (pl--rewrite-domain-define ddef gid->spec scale) dout)
            (when verbose (format t "Learned domain:  ~A~%" dout)))
          (when has-instance
            (pl--write-pddl (pl--rewrite-instance-form pdef gid->spec scale) pout)
            (when verbose (format t "Learned problem: ~A~%" pout)))
          (when verbose (format t "Reweighted SCNF: ~A~%" rwout))
          (values dout pout))))))
