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
;;;; own starting place, so no package is already where it needs to be.  With
;;;; :goals-per-package N each package instead gets N distinct destinations, any
;;;; one of which delivers it; at most one can ever hold, since a package is at
;;;; exactly one place.  :min-hard-goals 1 then makes reaching one of its own
;;;; destinations a hard requirement for every package, rather than leaving the
;;;; single global disjunction preferences normally impose.
;;;;
;;;; :truck-goals generates the simpler problem with NO packages, whose goals
;;;; send each truck to a destination instead -- within its own clique in the
;;;; clique style, since roads never leave one.  Airplanes default to none there.
;;;; Every goal option above applies unchanged, per truck rather than per package.
;;;;
;;;; :knockout N deletes N percent of the roads of each road network -- each
;;;; clique, or the whole grid -- while keeping it connected: a random spanning
;;;; tree is kept and random other roads are added back.  If the tree alone is
;;;; more than (100-N)% of the roads, N is refused.
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

;;; ---------------------------------------------------------------- knockout
;;;
;;; :knockout N deletes N percent of the roads while keeping every road network
;;; (each clique, or the whole grid) connected.  It works the other way round:
;;; keep a random SPANNING TREE of each network, then add random other roads back
;;; until floor(E * (100-N) / 100) of the network's E roads remain.  A road here
;;; is the two-way pair, so knocking one out removes both (road a b) and
;;; (road b a).
;;;
;;; The draws come from their OWN random state, derived from the seed, so the
;;; rest of the instance -- airports, starts, goals, weights -- is identical with
;;; and without --knockout: only the road lines differ.

(defun road-edges (roads)
  "The two-way edges of ROADS, one (a b) per unordered pair, in first-seen order."
  (let ((seen (make-hash-table :test #'equal)) (out '()))
    (dolist (r roads (nreverse out))
      (let ((key (if (string< (symbol-name (first r)) (symbol-name (second r)))
                     r (reverse r))))
        (unless (gethash key seen)
          (setf (gethash key seen) t)
          (push key out))))))

(defun spanning-tree (nodes edges)
  "A random spanning tree of (NODES, EDGES): Kruskal over the edges in shuffled
order.  Draws from *RNG*.  Errors if the network is not connected, which no
style generates."
  (let ((parent (make-hash-table)))
    (dolist (n nodes) (setf (gethash n parent) n))
    (labels ((root (n) (let ((p (gethash n parent)))
                         (if (eq p n) n (setf (gethash n parent) (root p))))))
      (let ((tree (loop for e in (shuffled edges)
                        for ra = (root (first e)) for rb = (root (second e))
                        unless (eq ra rb)
                          do (setf (gethash ra parent) rb)
                          and collect e)))
        (unless (= (length tree) (max 0 (1- (length nodes))))
          (error "internal: a road network is not connected"))
        tree))))

(defun knockout-roads (roads networks percent seed)
  "ROADS with PERCENT of each network's two-way roads removed, every network still
connected.  NETWORKS is a list of place lists (one per clique, or the grid's
places).  Returns (values kept-roads kept-edges total-edges)."
  (let* ((*rng* (sb-ext:seed-random-state
                 (make-array 3 :element-type '(unsigned-byte 32)
                               :initial-contents (list (ldb (byte 32 0) seed)
                                                       (ldb (byte 32 32) seed)
                                                       #x4b4f))))
         (edges (road-edges roads))
         (per-net (mapcar (lambda (places)
                            (cons places
                                  (remove-if-not (lambda (e) (and (member (first e) places)
                                                                  (member (second e) places)))
                                                 edges)))
                          networks))
         (tree-size (loop for (places) in per-net sum (max 0 (1- (length places)))))
         (total (length edges)))
    ;; The spanning trees are the floor: fewer roads than that cannot keep every
    ;; network connected.
    (when (> (* 100 tree-size) (* (- 100 percent) total))
      (let ((m (/ (* 100 tree-size) total)))
        (error "Knockout value set too high, ~a% required to maintain connectivity"
               (if (integerp m) m (format nil "~,1f" (float m))))))
    (let ((kept (make-hash-table :test #'equal)) (n-kept 0))
      (loop for (places . net-edges) in per-net
            for keep = (floor (* (length net-edges) (- 100 percent)) 100)
            for tree = (spanning-tree places net-edges)
            ;; remove-if, not set-difference: its order is unspecified, and the
            ;; order feeds the shuffle, so it must be fixed for a seed to replay
            for others = (shuffled (remove-if (lambda (e) (member e tree :test #'equal))
                                              net-edges))
            do (dolist (e (append tree (subseq others 0 (- keep (length tree)))))
                 (setf (gethash e kept) t)
                 (incf n-kept)))
      ;; the original road order, so only the knocked-out lines differ
      (values (remove-if-not (lambda (r) (or (gethash r kept) (gethash (reverse r) kept)))
                             roads)
              n-kept total))))

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

(defun goal-places (objects starts places-fn &optional (per-object 1) (kind "package"))
  "PER-OBJECT goal places for each of OBJECTS (the packages, or with --truck-goals
the trucks), random but never the object's own start (unless only one place is
available, when no other choice exists), and all distinct within an object.
PLACES-FN maps an object to the places it could be sent to: every place for a
package, but only its own road network for a truck, which cannot leave it.
KIND names the objects in messages.  Returns (object . place) pairs in object
order, each object's destinations consecutive."
  (loop for obj in objects
        nconc (let* ((start (cdr (assoc obj starts)))
                     (places (funcall places-fn obj))
                     (choices (if (< (length places) 2)
                                  places
                                  (remove start places))))
                (when (> per-object (length choices))
                  (error "--goals-per-package ~d needs ~d distinct destination~:p per ~
                          ~a, but only ~d place~:p ~:[are~;is~] available once a ~
                          ~a's own starting place is excluded"
                         per-object per-object kind (length choices)
                         (= 1 (length choices)) kind))
                ;; The one-destination case draws exactly as it always did, so a
                ;; recorded seed still reproduces its file byte for byte.
                (if (= per-object 1)
                    (list (cons obj (pick choices)))
                    (mapcar (lambda (p) (cons obj p))
                            (subseq (shuffled choices) 0 per-object))))))

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

(defun preference-name (object &optional index (verb "deliver"))
  "Names the preference for one goal: deliver-pkg1 for a package, reach-truck1
for a truck (VERB).  An object with several destinations needs them told apart:
deliver-pkg1-1, deliver-pkg1-2, ..."
  (if index
      (intern-name "~a-~a-~d" verb object index)
      (intern-name "~a-~a" verb object)))

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

(defun or-form (atoms)
  "The disjunction of ATOMS, or the atom itself when there is only one."
  (if (rest atoms) (format nil "(or ~{~a~^ ~})" atoms) (first atoms)))

(defun goal-groups (goals atoms weights)
  "Regroup the flat goal list by package, preserving order: one
(package (atom . weight) ...) entry per package.  WEIGHTS may be NIL, in which
case every weight is NIL."
  (let ((out '()))
    (loop for g in goals
          for a in atoms
          for w in (or weights (make-list (length atoms)))
          do (let ((cell (assoc (car g) out)))
               (if cell
                   (push (cons a w) (cdr cell))
                   (push (list (car g) (cons a w)) out))))
    (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
            (nreverse out))))

(defun write-problem (stream &key name domain place-names airport-names roads routes
                                  trucks airplanes packages
                                  truck-at airplane-at package-at goals
                                  drive-cost fly-cost header parameters pref-weights
                                  maxgoals hard-per-package (goal-verb "deliver"))
  (let ((*print-case* :downcase))
    (format stream ";; ~a~%" name)
    (dolist (line header) (format stream ";; ~a~%" line))
    (format stream ";;~%;; Generated by ppgen.sh -- edit the generator, not this file.~%")
    (format stream ";; Every setting used, defaults included; re-run with these to reproduce it:~%;;~%")
    ;; a NIL value is a bare flag (--truck-goals)
    (loop for (flag . value) in parameters
          do (format stream ";;   ~a~@[ ~a~]~%" flag value))
    (terpri stream)
    (format stream "(define (problem ~(~a~))~%  (:domain ~(~a~))~%~%" name domain)
    ;; objects: plain places, airports, then the movers.  Each line is emitted
    ;; only when non-empty -- with --truck-goals there are no packages, and an
    ;; empty "- package" line is not PDDL -- and the list closes after the last.
    (format stream "  (:objects")
    (let ((plain (remove-if (lambda (p) (member p airport-names)) place-names)))
      (loop for (names type) in (list (list plain "place") (list airport-names "airport")
                                      (list trucks "truck") (list airplanes "airplane")
                                      (list packages "package"))
            when names
              do (format stream "~%        ~{~(~a~)~^ ~} - ~a" names type)))
    (format stream ")~%~%")
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
    ;; charged when it is not the one achieved.  HARD-PER-PACKAGE replaces that
    ;; single disjunction with one per package, so each package must reach one of
    ;; its own destinations regardless of cost; the global disjunction it stands
    ;; in for is implied by any one of them, so it is not also emitted.
    (let* ((atoms (mapcar (lambda (g) (format nil "(at ~(~a~) ~(~a~))" (car g) (cdr g)))
                          goals))
           (cap (when maxgoals (at-most-forms atoms maxgoals)))
           (groups (goal-groups goals atoms pref-weights)))
      (if pref-weights
          (format stream "  (:goal (and~{~%        ~a~}~{~%        ~a~}~{~%        ~a~}))~%~%"
                  (if hard-per-package
                      (mapcar (lambda (grp) (or-form (mapcar #'car (rest grp)))) groups)
                      (list (or-form atoms)))
                  (loop for grp in groups
                        nconc (loop for (a . w) in (rest grp)
                                    for i from 1
                                    collect (format nil "(preference ~(~a~) ~a ~a)"
                                                    (preference-name
                                                     (first grp)
                                                     ;; index only when there is
                                                     ;; more than one to tell apart
                                                     (when (rest (rest grp)) i)
                                                     goal-verb)
                                                    a w)))
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
                   (goals-per-package 1) (min-hard-goals 0)
                   truck-goals (knockout 0)
                   seed (domain "clara-logistics") name
                   (stream *standard-output*))
  "Generate one clara-logistics problem.  See the file header for the two styles.
With TRUCK-GOALS the goals send TRUCKS to destinations instead of delivering
packages: there are no packages, airplanes default to none (they would only add
idle actions, though AIRPLANES may still ask for some), and every goal option --
preferences, maxgoals, goals-per-package -- applies per truck.  KNOCKOUT (0-100)
deletes that percent of each road network's roads, keeping it connected."
  (unless (and (integerp knockout) (<= 0 knockout 100))
    (error "--knockout must be an integer from 0 to 100, got ~a" knockout))
  (cond
    (truck-goals
     (when (and packages (> packages 0))
       (error "--truck-goals generates a problem with NO packages (the goals move ~
               trucks), so --packages ~d contradicts it; drop --packages" packages))
     (when (and trucks (< trucks 1))
       (error "--truck-goals needs at least one truck: with none the goal is empty")))
    ((and packages (< packages 1))
     (error "--packages must be at least 1: a problem with no packages has an empty goal ~
             (use --truck-goals for goals that move trucks instead)")))
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
  (when (< goals-per-package 1)
    (error "--goals-per-package must be at least 1, got ~d" goals-per-package))
  (unless (member min-hard-goals '(0 1))
    (error "--goals-per-package's second value is the minimum number of HARD goals ~
            per package, and must be 0 or 1, got ~d" min-hard-goals))
  ;; Alternative destinations only mean something once the goal is a disjunction:
  ;; a conjunctive goal would demand the package be in N places at once.
  (when (and (> goals-per-package 1) (not pref-low))
    (error "--goals-per-package ~d needs --preferences.~%  ~
            The default goal is a conjunction of every goal, so ~d destinations ~
            for one ~a would require it to be in ~d places at once.~%  ~
            Use --preferences <L> <H> to make the goal a disjunction first."
           goals-per-package goals-per-package (if truck-goals "truck" "package")
           goals-per-package))
  (when (and (= min-hard-goals 1) (not pref-low))
    (error "--goals-per-package's hard-goal minimum needs --preferences.~%  ~
            Without preferences every delivery is already required, so demanding ~
            one per package says nothing."))
  ;; An unseeded run still gets a definite seed, which is written into the file.
  (setf seed (or seed (clock-seed)))
  (setf *rng* (sb-ext:seed-random-state seed))
  (let (place-names airport-names roads header
        truck-at airplane-at package-at
        ;; the places a TRUCK can be sent to: its own road network (set per style)
        truck-places-fn
        ;; the road networks, as place lists: one per clique, or the whole grid
        networks)
    (ecase style
      (:clique
       (unless (and clique-size number-cliques)
         (error "clique style needs --clique-size and --number-cliques"))
       (when (< number-cliques 1)
         (error "--number-cliques must be at least 1, got ~d" number-cliques))
       (setf trucks    (or trucks number-cliques)
             airplanes (or airplanes (if truck-goals 0 number-cliques))
             packages  (or packages (if truck-goals 0 number-cliques)))
       (multiple-value-bind (all airs by-clique)
           (clique-places number-cliques clique-size)
         (setf place-names all airport-names airs
               roads (clique-roads by-clique)
               networks by-clique
               header (list (format nil "~d clique~:p of ~d place~:p, ~
                                         ~:[fully connected by roads~;connected by roads~];"
                                    number-cliques clique-size (plusp knockout))
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
           ;; Roads never leave a clique, so a truck can only be sent somewhere
           ;; in the clique it starts in -- anywhere else is unreachable.
           (setf truck-places-fn
                 (lambda (truck)
                   (let ((start (cdr (assoc truck truck-at))))
                     (find-if (lambda (c) (member start c)) by-clique))))
           (setf trucks truck-names airplanes plane-names packages pkg-names))))
      (:grid
       (unless (and rows cols)
         (error "grid style needs --dimensions <M> <N>"))
       (when (or (< rows 1) (< cols 1))
         (error "--dimensions must be positive, got ~d x ~d" rows cols))
       (setf airports  (or airports 2)
             trucks    (or trucks airports)
             airplanes (or airplanes (if truck-goals 0 airports))
             packages  (or packages (if truck-goals 0 airports)))
       (let* ((cells (grid-cells rows cols))
              (air-cells (disperse cells airports))
              (spread (min-pairwise-distance air-cells)))
         (setf place-names (mapcar #'cell-name cells)
               airport-names (mapcar #'cell-name air-cells)
               roads (grid-roads rows cols)
               networks (list place-names)
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
           ;; The grid is one connected road network: a truck can reach any place.
           (let ((all place-names))
             (setf truck-places-fn (lambda (truck) (declare (ignore truck)) all)))
           (setf trucks truck-names airplanes plane-names packages pkg-names)))))
    ;; After everything else is drawn, and from its own random state, so the
    ;; instance is otherwise the same as without --knockout.  0 does nothing at
    ;; all, keeping recorded seeds byte-identical.
    (when (plusp knockout)
      (multiple-value-bind (kept n-kept total)
          (knockout-roads roads networks knockout seed)
        (setf roads kept
              header (append header
                             (list (format nil "Knockout ~d%: ~d of ~d roads kept -- a random spanning ~
                                                tree~:[~;s~] plus random others, so every place ~
                                                stays reachable by road~:[~; within its clique~]."
                                           knockout n-kept total
                                           (eq style :clique) (eq style :clique)))))))
    (when truck-goals
      (setf header
            (append header
                    (list (format nil "No packages: the goal sends each truck to a destination~
                                       ~:[~; within its own clique~]."
                                  (eq style :clique))))))
    ;; What the goals move: the packages, or with --truck-goals the trucks.
    ;; Everything below -- destinations, preferences, the cap, the hard-goal
    ;; minimum -- is the same for either kind of goal object.
    (let ((kind (if truck-goals "truck" "package"))
          (goal-objects (if truck-goals trucks packages))
          (goal-starts (if truck-goals truck-at package-at))
          (goal-places-fn (if truck-goals
                              truck-places-fn
                              (let ((all place-names)) (lambda (p) (declare (ignore p)) all)))))
    (when (> goals-per-package 1)
      (setf header
            (append header
                    (list (if (= min-hard-goals 1)
                              (format nil "~d destinations per ~a, one of which each must reach."
                                      goals-per-package kind)
                              (format nil "~d destinations per ~a, any one of which ~
                                           ~:[delivers it~;it may reach~]."
                                      goals-per-package kind truck-goals))))))
    ;; An object is at exactly one place, so at most one of its destinations can
    ;; hold; requiring one per object therefore pins the total at exactly the
    ;; object count, and any cap below that is unsatisfiable by construction.
    (when (and maxgoals (= min-hard-goals 1) (< maxgoals (length goal-objects)))
      (error "--maxgoals ~d contradicts the hard-goal minimum: each of the ~d ~as ~
              must reach one of its destinations and can satisfy at most one goal, so ~
              exactly ~d goals hold."
             maxgoals (length goal-objects) kind (length goal-objects)))
    (let* ((goals (goal-places goal-objects goal-starts goal-places-fn goals-per-package kind))
           ;; Default: as many goals as there are, i.e. no constraint at all.
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
                           (cons "--goals-per-package"
                                 (format nil "~d ~d" goals-per-package min-hard-goals)))
                     ;; a bare flag, recorded only when set: its absence is the
                     ;; default (package goals), which replays as-is
                     (when truck-goals (list (cons "--truck-goals" nil)))
                     ;; Only recorded when it was actually given: its "unset"
                     ;; value is "no cap", which has no spelling on the command
                     ;; line -- --maxgoals is capped at 3 and demands
                     ;; --preferences, so writing the default back out would
                     ;; produce a settings block that will not replay.
                     (when maxgoals (list (cons "--maxgoals" cap)))
                     ;; recorded only when set, so a file made without it is
                     ;; byte-identical to one from before the option existed
                     (when (plusp knockout) (list (cons "--knockout" knockout)))
                     (list (cons "--seed" seed)))))
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
                   :pref-weights weights :maxgoals effective-cap
                   :hard-per-package (= min-hard-goals 1)
                   :goal-verb (if truck-goals "reach" "deliver"))))
    (values)))
