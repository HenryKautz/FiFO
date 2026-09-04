;;;; ppgen.lisp -- planning-problem generator for the clara-logistics domain.
;;;;
;;;; Generates PDDL problem files in two topologies:
;;;;
;;;;   :clique  NUMBER-CLIQUES groups of CLIQUE-SIZE places, each group fully
;;;;            connected by two-way roads, one airport per group.  Packages,
;;;;            airplanes and trucks are spread EVENLY over the groups -- any
;;;;            two groups differ by at most one -- with the place inside a
;;;;            group chosen at random.
;;;;
;;;;   :grid    an M x N grid of places, two-way roads between orthogonally
;;;;            adjacent cells.  Airports are placed to maximize the minimum
;;;;            pairwise distance between them; trucks and packages are placed
;;;;            uniformly at random, airplanes spread evenly over the airports.
;;;;
;;;; In both styles every pair of airports is joined by a two-way route, so an
;;;; airplane can reach any airport from any other, and the two travel costs are
;;;; single values: the domain declares (drive-cost) and (fly-cost) with no
;;;; arguments, so one number in :init prices every drive and every flight.
;;;;
;;;; Goals name a place for each package, drawn at random but never the package's
;;;; own starting place, so no package is already where it needs to be.
;;;;
;;;; Entry point: (ppgen &key style ... ) writes one problem to a stream.
;;;; bin/../SatPlan/ppgen.sh is the command line wrapper.

(defpackage #:ppgen (:use #:common-lisp) (:export #:ppgen #:ppgen-main))
(in-package #:ppgen)

;;; ------------------------------------------------------------------ random

(defun intern-name (fmt &rest args)
  (intern (string-upcase (apply #'format nil fmt args))))

(defvar *rng* nil "Random state used by every draw, so one seed reproduces a run.")

(defun rnd (n) (random n *rng*))

(defun pick (list) (nth (rnd (length list)) list))

(defun shuffled (list)
  "A fresh shuffled copy of LIST (Fisher-Yates)."
  (let ((v (coerce list 'vector)))
    (loop for i from (1- (length v)) downto 1
          for j = (rnd (1+ i))
          do (rotatef (aref v i) (aref v j)))
    (coerce v 'list)))

;;; -------------------------------------------------------------- even split

(defun even-split (n groups)
  "Split N items over GROUPS buckets so any two differ by at most one, with the
buckets that get the extra item chosen at random.  Returns a list of counts."
  (when (zerop groups)
    (error "Cannot distribute ~d item~:p over 0 groups" n))
  (multiple-value-bind (base extra) (floor n groups)
    (let ((counts (make-list groups :initial-element base)))
      (dolist (i (subseq (shuffled (loop for i below groups collect i)) 0 extra))
        (incf (nth i counts)))
      counts)))

;;; ------------------------------------------------------------------ clique

(defun clique-places (number-cliques clique-size)
  "Returns (values place-names airport-names places-by-clique).  Each clique gets
CLIQUE-SIZE places, exactly one of which is its airport."
  (when (< clique-size 1)
    (error "--clique-size must be at least 1, got ~d" clique-size))
  (let ((by-clique '()) (all '()) (airports '()))
    (dotimes (c number-cliques)
      (let* ((airport (intern-name "c~d-air" (1+ c)))
             (others (loop for i from 1 below clique-size
                           collect (intern-name "c~d-p~d" (1+ c) i)))
             (places (cons airport others)))
        (push airport airports)
        (setf all (append all places))
        (push places by-clique)))
    (values all (nreverse airports) (nreverse by-clique))))

(defun clique-roads (places-by-clique)
  "Two-way roads between every pair of places within each clique."
  (loop for places in places-by-clique
        nconc (loop for (a . rest) on places
                    nconc (loop for b in rest
                                collect (list a b)
                                collect (list b a)))))

;;; -------------------------------------------------------------------- grid

(defun grid-cells (rows cols)
  (loop for r from 1 to rows
        nconc (loop for c from 1 to cols collect (cons r c))))

(defun cell-name (cell) (intern-name "p~d-~d" (car cell) (cdr cell)))

(defun grid-distance (a b)
  "Manhattan distance, which is the road distance on a 4-connected grid."
  (+ (abs (- (car a) (car b))) (abs (- (cdr a) (cdr b)))))

(defun min-pairwise-distance (cells)
  (if (< (length cells) 2)
      most-positive-fixnum
      ;; NOTE the (when rest): on the last element the inner loop runs zero
      ;; times and LOOP's MINIMIZE yields 0, which would swallow the real
      ;; minimum and make every placement score 0.
      (loop for (a . rest) on cells
            when rest
              minimize (loop for b in rest minimize (grid-distance a b)))))

(defun disperse (cells k &optional (tries 200))
  "Choose K of CELLS maximizing the minimum pairwise distance.  Randomized
farthest-point insertion, restarted TRIES times, keeping the best spread -- the
result is random among equally good placements rather than a fixed corner
pattern."
  (when (> k (length cells))
    (error "Cannot place ~d airport~:p on a grid of ~d place~:p" k (length cells)))
  (when (zerop k) (return-from disperse '()))
  (let ((best nil) (best-score -1))
    (dotimes (try tries (values best best-score))
      (let ((chosen (list (pick cells))))
        (loop while (< (length chosen) k) do
          ;; every remaining cell, scored by distance to the nearest chosen one;
          ;; take a random cell among those tied for farthest
          (let* ((remaining (remove-if (lambda (c) (member c chosen :test #'equal)) cells))
                 (scored (mapcar (lambda (c)
                                   (cons c (loop for ch in chosen
                                                 minimize (grid-distance c ch))))
                                 remaining))
                 (best-d (reduce #'max scored :key #'cdr))
                 (ties (remove best-d scored :key #'cdr :test-not #'=)))
            (push (car (pick ties)) chosen)))
        (let ((score (min-pairwise-distance chosen)))
          (when (> score best-score)
            (setf best-score score best (copy-list chosen))))))))

(defun grid-roads (rows cols)
  "Two-way roads between orthogonally adjacent cells."
  (loop for r from 1 to rows
        nconc (loop for c from 1 to cols
                    nconc (let ((here (cell-name (cons r c))) (out '()))
                            (when (< c cols)
                              (let ((east (cell-name (cons r (1+ c)))))
                                (push (list here east) out)
                                (push (list east here) out)))
                            (when (< r rows)
                              (let ((south (cell-name (cons (1+ r) c))))
                                (push (list here south) out)
                                (push (list south here) out)))
                            out))))

;;; ------------------------------------------------------------------ shared

(defun routes-between (airports)
  "A two-way route between every pair of airports."
  (loop for (a . rest) on airports
        nconc (loop for b in rest collect (list a b) collect (list b a))))

(defun spread-over (items groups place-fn)
  "Assign ITEMS evenly over GROUPS, calling PLACE-FN with a group index to choose
the actual place.  Returns an alist of (item . place)."
  (let ((counts (even-split (length items) (length groups)))
        (rest items)
        (out '()))
    (loop for gi from 0
          for n in counts
          do (dotimes (i n)
               (push (cons (pop rest) (funcall place-fn gi)) out)))
    (nreverse out)))

(defun goal-places (packages starts places)
  "One goal place per package, random but never the package's own start (unless
there is only one place, when no other choice exists)."
  (mapcar (lambda (pkg)
            (let ((start (cdr (assoc pkg starts))))
              (cons pkg
                    (if (< (length places) 2)
                        (first places)
                        (let ((choices (remove start places)))
                          (pick choices))))))
          packages))

;;; ------------------------------------------------------------ preferences

(defun spaced-values (n low high)
  "N values equally spaced from LOW to HIGH inclusive: (low) for n=1, (low high)
for n=2, (low mid high) for n=3, and so on.  Integers stay integers so the
generated file reads cleanly."
  (cond ((<= n 0) '())
        ((= n 1) (list low))
        (t (loop for i below n
                 collect (let ((v (+ low (/ (* i (- high low)) (1- n)))))
                           (if (and (rationalp v) (not (integerp v)))
                               (let ((f (float v)))
                                 ;; keep a short decimal rather than a ratio
                                 (if (= f (fround f)) (round f) f))
                               v))))))

(defun preference-name (package) (intern-name "deliver-~a" package))

;;; ---------------------------------------------------------- goal cardinality

(defun combinations (list k)
  "All K-element subsets of LIST, in order."
  (cond ((zerop k) (list '()))
        ((null list) '())
        (t (append (mapcar (lambda (c) (cons (first list) c))
                           (combinations (rest list) (1- k)))
                   (combinations (rest list) k)))))

(defun at-most-forms (atoms n)
  "Forbid any N+1 of ATOMS from holding together, which is exactly \"at most N of
them hold\".  One (not (and ...)) per (N+1)-subset -- C(m, n+1) forms, which is
why N is capped at 3: the count grows as m^(n+1)."
  (when (< n (length atoms))
    (mapcar (lambda (subset) (format nil "(not (and ~{~a~^ ~}))" subset))
            (combinations atoms (1+ n)))))

;;; ------------------------------------------------------------------- emit

(defun write-problem (stream &key name domain place-names airport-names roads routes
                                  trucks airplanes packages
                                  truck-at airplane-at package-at goals
                                  drive-cost fly-cost header parameters pref-weights
                                  maxgoals)
  (let ((*print-case* :downcase))
    (format stream ";; ~a~%" name)
    (dolist (line header) (format stream ";; ~a~%" line))
    (format stream ";;~%;; Generated by ppgen.sh -- edit the generator, not this file.~%")
    (format stream ";; Every setting used, defaults included; re-run with these to reproduce it:~%;;~%")
    (loop for (flag . value) in parameters
          do (format stream ";;   ~a ~a~%" flag value))
    (terpri stream)
    (format stream "(define (problem ~(~a~))~%  (:domain ~(~a~))~%~%" name domain)
    ;; objects: plain places, airports, then the movers
    (format stream "  (:objects~%")
    (let ((plain (remove-if (lambda (p) (member p airport-names)) place-names)))
      (when plain
        (format stream "        ~{~(~a~)~^ ~} - place~%" plain))
      (when airport-names
        (format stream "        ~{~(~a~)~^ ~} - airport~%" airport-names))
    (when trucks
      (format stream "        ~{~(~a~)~^ ~} - truck~%" trucks))
    (when airplanes
      (format stream "        ~{~(~a~)~^ ~} - airplane~%" airplanes))
    (format stream "        ~{~(~a~)~^ ~} - package)~%~%" packages))
    ;; init
    (format stream "  (:init~%        ;; where everything starts~%")
    (dolist (pa package-at)  (format stream "        (at ~(~a~) ~(~a~))~%" (car pa) (cdr pa)))
    (dolist (ta truck-at)    (format stream "        (at ~(~a~) ~(~a~))~%" (car ta) (cdr ta)))
    (dolist (aa airplane-at) (format stream "        (at ~(~a~) ~(~a~))~%" (car aa) (cdr aa)))
    (format stream "~%        ;; static topology: roads within each road network,~%")
    (format stream "        ;; routes between every pair of airports~%")
    (dolist (r roads)  (format stream "        (road ~(~a~) ~(~a~))~%" (first r) (second r)))
    (terpri stream)
    (dolist (r routes) (format stream "        (route ~(~a~) ~(~a~))~%" (first r) (second r)))
    (format stream "~%        ;; travel prices: one value for every drive, one for every flight~%")
    (format stream "        (= (total-cost) 0)~%")
    (format stream "        (= (drive-cost) ~a)~%" drive-cost)
    (format stream "        (= (fly-cost) ~a))~%~%" fly-cost)
    ;; goal: a conjunction of every delivery, or -- with preferences -- a
    ;; disjunction that requires ONE of them, each disjunct carrying a weight
    ;; charged when it is not the one achieved.
    (let* ((atoms (mapcar (lambda (g) (format nil "(at ~(~a~) ~(~a~))" (car g) (cdr g)))
                          goals))
           (cap (when maxgoals (at-most-forms atoms maxgoals))))
      (if pref-weights
          (format stream "  (:goal (and~%        ~a~{~%        ~a~}~{~%        ~a~}))~%~%"
                  (if (rest atoms)
                      (format nil "(or ~{~a~^ ~})" atoms)
                      (first atoms))
                  (loop for g in goals
                        for a in atoms
                        for w in pref-weights
                        collect (format nil "(preference ~(~a~) ~a ~a)"
                                        (preference-name (car g)) a w))
                  cap)
          (format stream "  (:goal (and~{~%        ~a~}~{~%        ~a~}))~%~%" atoms cap)))
    (format stream "  (:metric minimize (total-cost)))~%")))

;;; ------------------------------------------------------------------- main

(defun clock-seed ()
  "An integer seed derived from the clock, so an unseeded run is still recorded
in the generated file and can be reproduced exactly."
  (mod (+ (* 1000 (get-universal-time)) (mod (get-internal-real-time) 1000))
       (expt 2 31)))

(defun ppgen (&key (style :clique) clique-size number-cliques rows cols airports
                   trucks airplanes packages (drive-cost 1) (fly-cost 3)
                   pref-low pref-high maxgoals
                   seed (domain "clara-logistics") name
                   (stream *standard-output*))
  "Generate one clara-logistics problem.  See the file header for the two styles."
  (when (and packages (< packages 1))
    (error "--packages must be at least 1: a problem with no packages has an empty goal"))
  (when (and (or pref-low pref-high) (not (and pref-low pref-high)))
    (error "--preferences needs both bounds: 'none', or a low and a high value"))
  ;; The cap is encoded as one (not (and ...)) per (N+1)-subset of the goals, so
  ;; its size grows as packages^(N+1); 3 is where that stays reasonable.
  (when (and maxgoals (> maxgoals 3))
    (error "--maxgoals is capped at 3, got ~d: the at-most-N goal constraint needs ~
            one clause per (N+1)-subset of the goals, which blows up beyond that"
           maxgoals))
  (when (and maxgoals (< maxgoals 1))
    (error "--maxgoals must be at least 1, got ~d" maxgoals))
  ;; Capping the deliveries only makes sense once the goal is a disjunction: the
  ;; default goal demands every package be delivered, which a cap can only
  ;; contradict (or, at maxgoals = packages, say nothing at all).
  (when (and maxgoals (not pref-low))
    (error "--maxgoals needs --preferences.~%  ~
            The default goal requires EVERY package to be delivered, so a cap on ~
            how many are delivered is either contradictory or vacuous.~%  ~
            Use --preferences <L> <H> to make the goal a disjunction first."))
  ;; An unseeded run still gets a definite seed, which is written into the file.
  (setf seed (or seed (clock-seed)))
  (setf *rng* (sb-ext:seed-random-state seed))
  (let (place-names airport-names roads header
        truck-at airplane-at package-at)
    (ecase style
      (:clique
       (unless (and clique-size number-cliques)
         (error "clique style needs --clique-size and --number-cliques"))
       (when (< number-cliques 1)
         (error "--number-cliques must be at least 1, got ~d" number-cliques))
       (setf trucks    (or trucks number-cliques)
             airplanes (or airplanes number-cliques)
             packages  (or packages number-cliques))
       (multiple-value-bind (all airs by-clique)
           (clique-places number-cliques clique-size)
         (setf place-names all airport-names airs
               roads (clique-roads by-clique)
               header (list (format nil "~d clique~:p of ~d place~:p, fully connected by roads;"
                                    number-cliques clique-size)
                            (format nil "one airport per clique, all airports joined by routes.")
                            (format nil "~d truck~:p, ~d airplane~:p, ~d package~:p, spread evenly over the cliques."
                                    trucks airplanes packages)))
         (let ((truck-names  (loop for i from 1 to trucks collect (intern-name "truck~d" i)))
               (plane-names  (loop for i from 1 to airplanes collect (intern-name "plane~d" i)))
               (pkg-names    (loop for i from 1 to packages collect (intern-name "pkg~d" i))))
           ;; packages and trucks: even over cliques, random place inside
           (setf package-at (spread-over pkg-names by-clique
                                         (lambda (gi) (pick (nth gi by-clique))))
                 truck-at   (spread-over truck-names by-clique
                                         (lambda (gi) (pick (nth gi by-clique)))))
           ;; airplanes: even over the airports (one per clique)
           (setf airplane-at (spread-over plane-names airport-names
                                          (lambda (gi) (nth gi airport-names))))
           (setf trucks truck-names airplanes plane-names packages pkg-names))))
      (:grid
       (unless (and rows cols)
         (error "grid style needs --dimensions <M> <N>"))
       (when (or (< rows 1) (< cols 1))
         (error "--dimensions must be positive, got ~d x ~d" rows cols))
       (setf airports  (or airports 2)
             trucks    (or trucks airports)
             airplanes (or airplanes airports)
             packages  (or packages airports))
       (let* ((cells (grid-cells rows cols))
              (air-cells (disperse cells airports))
              (spread (min-pairwise-distance air-cells)))
         (setf place-names (mapcar #'cell-name cells)
               airport-names (mapcar #'cell-name air-cells)
               roads (grid-roads rows cols)
               header (list (format nil "~d x ~d grid of places, roads between adjacent cells;"
                                    rows cols)
                            (format nil "~d airport~:p placed to maximize their minimum separation~@[ (~d)~];"
                                    airports (and (> airports 1) spread))
                            (format nil "~d truck~:p and ~d package~:p placed at random, ~d airplane~:p over the airports."
                                    trucks packages airplanes)))
         (let ((truck-names (loop for i from 1 to trucks collect (intern-name "truck~d" i)))
               (plane-names (loop for i from 1 to airplanes collect (intern-name "plane~d" i)))
               (pkg-names   (loop for i from 1 to packages collect (intern-name "pkg~d" i))))
           (setf truck-at   (mapcar (lambda (t*) (cons t* (pick place-names))) truck-names)
                 package-at (mapcar (lambda (p) (cons p (pick place-names))) pkg-names)
                 airplane-at (spread-over plane-names airport-names
                                          (lambda (gi) (nth gi airport-names))))
           (setf trucks truck-names airplanes plane-names packages pkg-names)))))
    (let* ((goals (goal-places packages package-at place-names))
           ;; Default: as many as there are packages, i.e. no constraint at all.
           ;; A cap below that is only meaningful once the goal is a disjunction:
           ;; a conjunctive goal demands every delivery, so "at most N" with
           ;; N < packages is unsatisfiable by construction.
           (cap (or maxgoals (length goals)))
           (effective-cap (when (< cap (length goals)) cap))
           (weights (when pref-low
                      (shuffled (spaced-values (length goals) pref-low pref-high))))
           (parameters
             (append (list (cons "--style" (string-downcase (symbol-name style))))
                     (ecase style
                       (:clique (list (cons "--clique-size" clique-size)
                                      (cons "--number-cliques" number-cliques)))
                       (:grid   (list (cons "--dimensions"
                                            (format nil "~d ~d" rows cols))
                                      (cons "--airports" (length airport-names)))))
                     (list (cons "--trucks" (length trucks))
                           (cons "--airplanes" (length airplanes))
                           (cons "--packages" (length packages))
                           (cons "--drive-cost" drive-cost)
                           (cons "--fly-cost" fly-cost)
                           (cons "--preferences"
                                 (if pref-low
                                     (format nil "~a ~a" pref-low pref-high)
                                     "none"))
                           (cons "--maxgoals" cap)
                           (cons "--seed" seed)))))
      (write-problem stream
                   :name (or name (format nil "~(~a~)-problem" style))
                   :domain domain
                   :place-names place-names :airport-names airport-names
                   :roads roads :routes (routes-between airport-names)
                   :trucks trucks :airplanes airplanes :packages packages
                   :truck-at truck-at :airplane-at airplane-at :package-at package-at
                   :goals goals
                   :drive-cost drive-cost :fly-cost fly-cost
                   :header header :parameters parameters
                   :pref-weights weights :maxgoals effective-cap))
    (values)))
