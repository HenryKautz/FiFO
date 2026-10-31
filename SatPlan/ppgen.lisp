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
;;;; airplane can reach any airport from any other, and the costs are single
;;;; values: the domain declares (drive-cost), (fly-cost) and (handle-cost) with
;;;; no arguments, so one number in :init prices every drive, every flight, and
;;;; every load or unload.
;;;;
;;;; Goals name a place for each package, drawn at random but never the package's
;;;; own starting place, so no package is already where it needs to be.  Three
;;;; independent options shape the goal:
;;;;
;;;;   :destinations N  each package gets N distinct destinations, any one of
;;;;                    which delivers it; at most one can ever hold, since a
;;;;                    package is at exactly one place.
;;;;   :require         "all" (default): every package must be delivered;
;;;;                    "some": at least one must.
;;;;   :pref-low/high   every goal also becomes a preference, its weight drawn
;;;;                    from L..H and charged when the goal does not hold.
;;;;
;;;; Preferences are refused when every goal is forced -- "all" with one
;;;; destination -- since the weights could not change the plan.
;;;;
;;;; :packages 0 generates the simpler problem with NO packages, whose goals send
;;;; each truck to a destination instead -- within its own clique in the clique
;;;; style, since roads never leave one.  Airplanes default to none there.  Every
;;;; goal option above applies unchanged, per truck rather than per package.
;;;;
;;;; :knockout N deletes N percent of the roads of each road network -- each
;;;; clique, or the whole grid -- while keeping it connected: a random spanning
;;;; tree is kept and random other roads are added back.  If the tree alone is
;;;; more than (100-N)% of the roads, N is refused.
;;;;
;;;; :mindist N and :maxdist M (grid only, either or both) start every goal
;;;; object -- the packages, or with :packages 0 the trucks -- at the origin
;;;; p1-1, and draw its destinations only from places at least N and at most M
;;;; steps from it: the breadth-first distance over roads and airport routes for
;;;; a package, over roads alone for a truck, which cannot fly.  N = M puts every
;;;; destination at exactly N steps.  Too few such places for an object's
;;;; distinct destinations is an error.
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
  ;; No groups is fine with nothing to place (a grid with no airports and so no
  ;; airplanes); checked before any draw, so other runs keep their random stream.
  (when (zerop groups)
    (if (zerop n)
        (return-from even-split '())
        (error "Cannot distribute ~d item~:p over 0 groups" n)))
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

(defun knockout-random-state (seed)
  "The knockout's own random state.  A VECTOR seed, so it never coincides with the
main stream's integer seeding: SEED's low two 32-bit words, a marker word, then
any higher words -- all of SEED counts, so seeds differing above bit 64 still
knock out different roads, while a seed below 2^64 gets the same state it always
did (knockout files made before this replay byte for byte)."
  (let ((high (loop for s = (ash seed -64) then (ash s -32)
                    while (plusp s) collect (ldb (byte 32 0) s))))
    (sb-ext:seed-random-state
     (coerce (list* (ldb (byte 32 0) seed) (ldb (byte 32 32) seed) #x4b4f high)
             '(vector (unsigned-byte 32))))))

(defun knockout-roads (roads networks percent seed)
  "ROADS with PERCENT of each network's two-way roads removed, every network still
connected.  NETWORKS is a list of place lists (one per clique, or the grid's
places).  Returns (values kept-roads kept-edges total-edges)."
  (let* ((*rng* (knockout-random-state seed))
         (edges (road-edges roads))
         ;; each place's network, so splitting the edges is one linear pass (a
         ;; MEMBER per endpoint was quadratic: ~10^8 comparisons on a 100x100 grid)
         (net-of (let ((h (make-hash-table)))
                   (loop for places in networks for i from 0
                         do (dolist (p places) (setf (gethash p h) i)))
                   h))
         (net-edges (let ((v (make-array (length networks) :initial-element '())))
                      (dolist (e edges)
                        (let ((i (gethash (first e) net-of)))
                          (when (and i (eql i (gethash (second e) net-of)))
                            (push e (aref v i)))))
                      (map 'list #'nreverse v)))
         (per-net (mapcar #'cons networks net-edges))
         (total (length edges)))
    ;; The spanning tree is each network's floor: fewer roads cannot keep it
    ;; connected.  Checked PER NETWORK -- a global check would let a small,
    ;; tight network borrow slack from a large one, and its keep would then fall
    ;; below its own tree.  M is the binding network's tree/E (with equal
    ;; cliques, the same as the overall ratio).
    (let ((m (loop for (places . es) in per-net
                   for tree = (max 0 (1- (length places)))
                   when es maximize (/ (* 100 tree) (length es)))))
      (when (and m (> m (- 100 percent)))
        (error "Knockout value set too high, ~a% required to maintain connectivity"
               (if (integerp m) m (format nil "~,1f" (float m))))))
    (let ((kept (make-hash-table :test #'equal)) (n-kept 0))
      (loop for (places . es) in per-net
            for keep = (floor (* (length es) (- 100 percent)) 100)
            for tree = (spanning-tree places es)
            for in-tree = (let ((h (make-hash-table :test #'equal)))
                            (dolist (e tree h) (setf (gethash e h) t)))
            ;; filtered in the edges' own order, which feeds the shuffle and so
            ;; must be fixed for a seed to replay
            for others = (shuffled (remove-if (lambda (e) (gethash e in-tree)) es))
            do (dolist (e (append tree (subseq others 0 (- keep (length tree)))))
                 (setf (gethash e kept) t)
                 (incf n-kept)))
      ;; the original road order, so only the knocked-out lines differ
      (values (remove-if-not (lambda (r) (or (gethash r kept) (gethash (reverse r) kept)))
                             roads)
              n-kept total))))

;;; ----------------------------------------------------------------- oneway
;;;
;;; :oneway N turns N percent of each road network's two-way roads (those left
;;; after --knockout) into one-way roads, each in a random direction, while
;;; keeping every place reachable from every other.  Roads are tried in random
;;; order; dropping the direction u->v keeps the network strongly connected
;;; exactly when u can still reach v without it (any route through u->v can then
;;; go round), so each candidate costs one search, usually a short one.  When a
;;; direction cannot go, the other is tried; when neither can (a bridge, whose
;;; loss would cut the network in two), the road stays two-way.  If too few roads
;;; can be made one-way, every one that can is, and the header says how many.
;;;
;;; Like --knockout it draws from its OWN random state, derived from the seed, so
;;; the rest of the instance is identical with and without --oneway.

(defun oneway-random-state (seed)
  "The one-way pass's own random state: as KNOCKOUT-RANDOM-STATE, with its own
marker word, so the two passes never draw the same numbers."
  (let ((high (loop for s = (ash seed -64) then (ash s -32)
                    while (plusp s) collect (ldb (byte 32 0) s))))
    (sb-ext:seed-random-state
     (coerce (list* (ldb (byte 32 0) seed) (ldb (byte 32 32) seed) #x4f57 high)
             '(vector (unsigned-byte 32))))))

(defun oneway-roads (roads networks percent seed)
  "ROADS with PERCENT of each network's two-way roads made one-way, every network
still strongly connected.  Returns (values roads n-oneway n-two-way n-wanted)."
  (let* ((*rng* (oneway-random-state seed))
         (edges (road-edges roads))
         (net-of (let ((h (make-hash-table)))
                   (loop for places in networks for i from 0
                         do (dolist (p places) (setf (gethash p h) i)))
                   h))
         (adj (make-hash-table))
         (present (make-hash-table :test #'equal))
         (removed (make-hash-table :test #'equal))
         (n-oneway 0) (n-wanted 0) (n-two-way 0))
    (dolist (r roads)
      (setf (gethash r present) t)
      (push (second r) (gethash (first r) adj)))
    (labels ((reaches (from to)
               ;; breadth-first over the roads as they now stand, stopping at TO
               (let ((seen (make-hash-table))
                     (queue (make-array 16 :adjustable t :fill-pointer 0)) (head 0))
                 (setf (gethash from seen) t)
                 (vector-push-extend from queue)
                 (loop while (< head (fill-pointer queue))
                       do (let ((x (aref queue head)))
                            (incf head)
                            (when (eq x to) (return-from reaches t))
                            (dolist (y (gethash x adj))
                              (unless (gethash y seen)
                                (setf (gethash y seen) t)
                                (vector-push-extend y queue)))))
                 nil))
             (drop (u v)
               ;; remove u->v; keep the removal if u still reaches v
               (setf (gethash u adj) (remove v (gethash u adj) :count 1))
               (if (reaches u v)
                   (progn (setf (gethash (list u v) removed) t) t)
                   (progn (push v (gethash u adj)) nil))))
      (loop for i from 0 below (length networks)
            for es = (remove-if-not (lambda (e)
                                      (and (eql (gethash (first e) net-of) i)
                                           (eql (gethash (second e) net-of) i)
                                           (gethash (list (second e) (first e)) present)))
                                    edges)
            for want = (floor (* (length es) percent) 100)
            do (incf n-two-way (length es))
               (incf n-wanted want)
               (loop with made = 0
                     for e in (shuffled es)
                     while (< made want)
                     do (destructuring-bind (a b) (if (zerop (random 2 *rng*)) e (reverse e))
                          (when (or (drop a b) (drop b a))
                            (incf made)
                            (incf n-oneway))))))
    (values (remove-if (lambda (r) (gethash r removed)) roads)
            n-oneway n-two-way n-wanted)))

;;; ------------------------------------------------------- mindist, maxdist

(defun bfs-distances (origin edges)
  "Steps from ORIGIN to every place reachable over EDGES, a list of directed (a b)
pairs, by breadth-first search.  Returns a hash table place -> distance; a place
that cannot be reached is absent."
  (let ((adj (make-hash-table)) (dist (make-hash-table))
        (queue (make-array 16 :adjustable t :fill-pointer 0)) (head 0))
    (dolist (e edges) (push (second e) (gethash (first e) adj)))
    (setf (gethash origin dist) 0)
    (vector-push-extend origin queue)
    (loop while (< head (fill-pointer queue))
          do (let* ((x (aref queue head)) (d (gethash x dist)))
               (incf head)
               (dolist (y (gethash x adj))
                 (unless (gethash y dist)
                   (setf (gethash y dist) (1+ d))
                   (vector-push-extend y queue)))))
    dist))

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
  "PER-OBJECT goal places for each of OBJECTS (the packages, or with --packages 0
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
                  (error "--destinations ~d needs ~d distinct destination~:p per ~
                          ~a, but only ~d place~:p ~:[are~;is~] available once a ~
                          ~a's own starting place is excluded"
                         per-object per-object kind (length choices)
                         (= 1 (length choices)) kind))
                ;; The one-destination case makes one draw per object, not a
                ;; shuffle, so the rest of the random stream does not depend on
                ;; the number of places.
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

;;; ----------------------------------------------------------------- require
;;;
;;; :require says which goal OBJECTS must reach a destination.  An object with
;;; several destinations reaches its goal when any one holds (only one can, since
;;; it is at one place), so its goal is the (or ...) of its destinations.
;;;
;;;   all   every object: one (or ...) per object -- the default
;;;   some  at least one object: a single (or ...) over every destination

(defun parse-require (spec)
  "SPEC, as given to --require (a string or symbol): returns :ALL or :SOME."
  (let ((s (string-downcase (string spec))))
    (cond ((string= s "all") :all)
          ((string= s "some") :some)
          (t (error "--require takes all or some, got '~a'" spec)))))

(defun or-form (atoms)
  "The disjunction of ATOMS, or the atom itself when there is only one."
  (if (rest atoms) (format nil "(or ~{~a~^ ~})" atoms) (first atoms)))

(defun required-forms (groups require)
  "The hard goal forms for REQUIRE (:all or :some) over GROUPS, a list of
(object atom ...)."
  (ecase require
    (:all  (mapcar (lambda (g) (or-form (rest g))) groups))
    (:some (list (or-form (loop for g in groups append (rest g)))))))

;;; ------------------------------------------------------------------- emit

(defun goal-groups (goals atoms weights)
  "Regroup the flat goal list by goal object, preserving order: one
(object (atom . weight) ...) entry per object.  WEIGHTS may be NIL, in which
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
                                  drive-cost fly-cost handle-cost header parameters pref-weights
                                  (require :all) (goal-verb "deliver"))
  (let ((*print-case* :downcase))
    (format stream ";; ~a~%" name)
    (dolist (line header) (format stream ";; ~a~%" line))
    (format stream ";;~%;; Generated by ppgen.sh -- edit the generator, not this file.~%")
    (format stream ";; Every setting used, defaults included; re-run with these to reproduce it:~%;;~%")
    ;; a NIL value would be a bare flag
    (loop for (flag . value) in parameters
          do (format stream ";;   ~a~@[ ~a~]~%" flag value))
    (terpri stream)
    (format stream "(define (problem ~(~a~))~%  (:domain ~(~a~))~%~%" name domain)
    ;; objects: plain places, airports, then the movers.  Each line is emitted
    ;; only when non-empty -- with --packages 0 there are no packages, and an
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
    (format stream "~%        ;; prices: one value for every drive, one for every flight, one for~%")
    (format stream "        ;; every load or unload~%")
    (format stream "        (= (total-cost) 0)~%")
    (format stream "        (= (drive-cost) ~a)~%" drive-cost)
    (format stream "        (= (fly-cost) ~a)~%" fly-cost)
    (format stream "        (= (handle-cost) ~a))~%~%" handle-cost)
    ;; goal: the hard forms for REQUIRE, then with PREF-WEIGHTS one preference
    ;; per goal, its weight charged when that goal does not hold.
    (let* ((atoms (mapcar (lambda (g) (format nil "(at ~(~a~) ~(~a~))" (car g) (cdr g)))
                          goals))
           (groups (goal-groups goals atoms pref-weights)))
      (format stream "  (:goal (and~{~%        ~a~}~{~%        ~a~}))~%~%"
              (required-forms (mapcar (lambda (grp) (cons (first grp) (mapcar #'car (rest grp))))
                                      groups)
                              require)
              (when pref-weights
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
                                                  a w))))))
    (format stream "  (:metric minimize (total-cost)))~%")))

;;; ------------------------------------------------------------------- main

(defun clock-seed ()
  "An integer seed derived from the clock, so an unseeded run is still recorded
in the generated file and can be reproduced exactly."
  (mod (+ (* 1000 (get-universal-time)) (mod (get-internal-real-time) 1000))
       (expt 2 31)))

(defun ppgen (&key (style :clique) clique-size number-cliques rows cols airports
                   trucks airplanes packages (drive-cost 1) (fly-cost 3) (handle-cost 1)
                   pref-low pref-high (destinations 1) (require "all")
                   (knockout 0) (oneway 0) mindist maxdist
                   seed (domain "clara-logistics") name
                   (stream *standard-output*)
              ;; No packages: the goals move the trucks instead.  (An empty goal
              ;; is never generated, so --packages 0 has no other meaning.)
              &aux (truck-goals (and packages (zerop packages))))
  "Generate one clara-logistics problem.  See the file header for the two styles.
PACKAGES 0 makes the goals send TRUCKS to destinations instead of delivering
packages: airplanes then default to none (they would only add idle actions,
though AIRPLANES may still ask for some), and every goal option applies per
truck.  DESTINATIONS is the number of alternatives per goal object; REQUIRE
(all or some) whether every object must reach one or at least one; PREF-LOW..PREF-HIGH
weights every goal as a preference.  KNOCKOUT (0-100) deletes that percent of
each road network's roads, keeping it connected.  MINDIST and MAXDIST (grid
only, either or both) start the goal objects at the origin p1-1 and send them
only to places at least MINDIST and at most MAXDIST steps away."
  (unless (and (integerp knockout) (<= 0 knockout 100))
    (error "--knockout must be an integer from 0 to 100, got ~a" knockout))
  (unless (and (integerp oneway) (<= 0 oneway 100))
    (error "--oneway must be an integer from 0 to 100, got ~a" oneway))
  (loop for (flag value) in (list (list "--mindist" mindist) (list "--maxdist" maxdist))
        when value
          do (unless (and (integerp value) (>= value 1))
               (error "~a must be an integer of at least 1, got ~a" flag value))
             (unless (eq style :grid)
               (error "~a applies to grid style only: it measures from the grid's ~
                       origin p1-1" flag)))
  (when (and mindist maxdist (< maxdist mindist))
    (error "--maxdist ~d is below --mindist ~d: no place is that far and that near"
           maxdist mindist))
  (loop for (flag value) in (list (list "--trucks" trucks) (list "--airplanes" airplanes)
                                  (list "--packages" packages))
        when (and value (not (and (integerp value) (>= value 0))))
          do (error "~a must be a non-negative integer, got ~a" flag value))
  (when (and truck-goals trucks (< trucks 1))
    (error "--packages 0 sends the trucks to destinations, so it needs at least one ~
            truck: with none the goal is empty"))
  (when (and (or pref-low pref-high) (not (and pref-low pref-high)))
    (error "--preferences needs both bounds: 'none', or a low and a high value"))
  (unless (and (integerp destinations) (>= destinations 1))
    (error "--destinations must be at least 1, got ~a" destinations))
  (setf require (parse-require require))
  ;; An unseeded run still gets a definite seed, which is written into the file.
  (setf seed (or seed (clock-seed)))
  (setf *rng* (sb-ext:seed-random-state seed))
  (let (place-names airport-names roads header
        truck-at airplane-at package-at
        ;; the places a TRUCK can be sent to: its own road network (set per style)
        truck-places-fn
        ;; the road networks, as place lists: one per clique, or the whole grid
        networks
        ;; with --mindist/--maxdist, the grid origin every goal object starts at
        origin)
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
       (when (or mindist maxdist)
         (setf origin (cell-name '(1 . 1))))
       (let* ((cells (grid-cells rows cols))
              (air-cells (disperse cells airports))
              (spread (min-pairwise-distance air-cells)))
         (setf place-names (mapcar #'cell-name cells)
               airport-names (mapcar #'cell-name air-cells)
               roads (grid-roads rows cols)
               networks (list place-names)
               header (list (format nil "~d x ~d grid of places, roads between adjacent cells;"
                                    rows cols)
                            (if (zerop airports)
                                "no airports;"
                                (format nil "~d airport~:p placed to maximize their minimum separation~@[ (~d)~];"
                                        airports (and (> airports 1) spread)))
                            ;; the goal objects start at the origin with
                            ;; --mindist/--maxdist, the rest at random
                            (cond ((not origin)
                                   (format nil "~d truck~:p and ~d package~:p placed at random, ~
                                                ~d airplane~:p over the airports."
                                           trucks packages airplanes))
                                  (truck-goals
                                   (format nil "~d truck~:p at the origin ~(~a~), ~d airplane~:p ~
                                                over the airports."
                                           trucks origin airplanes))
                                  (t
                                   (format nil "~d truck~:p placed at random, ~d package~:p at ~
                                                the origin ~(~a~), ~d airplane~:p over the airports."
                                           trucks packages origin airplanes)))))
         (let ((truck-names (loop for i from 1 to trucks collect (intern-name "truck~d" i)))
               (plane-names (loop for i from 1 to airplanes collect (intern-name "plane~d" i)))
               (pkg-names   (loop for i from 1 to packages collect (intern-name "pkg~d" i))))
           (setf truck-at   (mapcar (lambda (t*) (cons t* (pick place-names))) truck-names)
                 package-at (mapcar (lambda (p) (cons p (pick place-names))) pkg-names)
                 airplane-at (spread-over plane-names airport-names
                                          (lambda (gi) (nth gi airport-names))))
           ;; --mindist/--maxdist: the goal objects all start at the origin.
           ;; Their random starts were still drawn above, so every later draw is
           ;; the one it would be without them.
           (when origin
             (flet ((at-origin (alist) (mapcar (lambda (a) (cons (car a) origin)) alist)))
               (if truck-goals
                   (setf truck-at (at-origin truck-at))
                   (setf package-at (at-origin package-at)))))
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
    ;; --oneway: after --knockout (it turns some of the roads that remain), from
    ;; its own random state.  0 does nothing, keeping recorded seeds identical.
    (when (plusp oneway)
      (multiple-value-bind (kept n-oneway n-two-way n-wanted)
          (oneway-roads roads networks oneway seed)
        (when (< n-oneway n-wanted)
          (format *error-output* "ppgen: --oneway ~d asked for ~d one-way road~:p, but only ~d ~
                                  can be made one-way without cutting a place off; made ~d.~%"
                  oneway n-wanted n-oneway n-oneway))
        (setf roads kept
              header (append header
                             (list (format nil "One-way ~d%: ~d of ~d two-way roads made one-way~
                                                ~:[~*~; (all that could be: ~d were asked for)~], each ~
                                                in a random direction, so every place can still ~
                                                reach every other~:[~; within its clique~]."
                                           oneway n-oneway n-two-way (< n-oneway n-wanted) n-wanted
                                           (eq style :clique)))))))
    (when truck-goals
      (setf header
            (append header
                    (list (format nil "No packages: the goal sends each truck to a destination~
                                       ~:[~; within its own clique~]."
                                  (eq style :clique))))))
    ;; What the goals move: the packages, or with --packages 0 the trucks.
    ;; Everything below -- destinations, preferences, --require -- is the same
    ;; for either kind of goal object.
    (let ((kind (if truck-goals "truck" "package"))
          (goal-objects (if truck-goals trucks packages))
          (goal-starts (if truck-goals truck-at package-at))
          (goal-places-fn (if truck-goals
                              truck-places-fn
                              (let ((all place-names)) (lambda (p) (declare (ignore p)) all))))
          (routes (routes-between airport-names)))
    (unless goal-objects
      (error "there are no ~as to set goals for, so the goal would be empty" kind))
    ;; --mindist/--maxdist: keep only the destinations within the distance
    ;; range from the origin.  The distance is over the roads that survived
    ;; --knockout, plus the airport routes when a package can fly -- not for a
    ;; truck, and not when there are no airplanes or no routes (one airport).
    ;; Every goal object starts at the origin, so one eligible set serves them
    ;; all.  The origin itself (distance 0) is never eligible: it is every
    ;; object's start.
    (when origin
      (let* ((flies (and airplanes routes (not truck-goals)))
             (dist (bfs-distances origin (if flies (append roads routes) roads)))
             (farthest (loop for d being the hash-values of dist maximize d))
             (nearest (or mindist 1))
             (eligible (remove-if-not (lambda (p)
                                        (let ((d (gethash p dist)))
                                          (and d (>= d nearest)
                                               (or (null maxdist) (<= d maxdist)))))
                                      place-names))
             (range (cond ((null maxdist) (format nil "at least ~d step~:p" mindist))
                          ((null mindist) (format nil "at most ~d step~:p" maxdist))
                          ((= mindist maxdist) (format nil "exactly ~d step~:p" maxdist))
                          (t (format nil "~d to ~d steps" mindist maxdist))))
             (flags (format nil "~@[--mindist ~d~]~:[~; ~]~@[--maxdist ~d~]"
                            mindist (and mindist maxdist) maxdist)))
        (when (< (length eligible) destinations)
          (error "~a: only ~d place~:p ~:[are~;is~] ~a from the origin ~(~a~) by ~
                  road~:[ or flight~;~] (the farthest is ~d), but each ~a needs ~d ~
                  distinct destination~:p"
                 flags (length eligible) (= 1 (length eligible)) range
                 origin (not flies) farthest kind destinations))
        (setf goal-places-fn (lambda (obj) (declare (ignore obj)) eligible)
              header (append header
                             (list (format nil "Every destination is ~a from the origin by ~
                                                road~:[ or flight~;~] (~d place~:p qualify)."
                                           range (not flies) (length eligible)))))))
    (let ((n (length goal-objects)))
      ;; With one destination, a goal that must hold is forced: weights on it
      ;; cannot change the plan.  That is every goal under --require all, and
      ;; under --require some when there is only one object.
      (when (and pref-low (= destinations 1) (or (eq require :all) (= n 1)))
        (error "~:[--require all with one destination~*~;--require some with a single ~a~] ~
                makes every goal mandatory, so preference weights cannot change the ~
                plan.~%  Use ~:[--require some to make the goals optional, or~;more ~as, or~] ~
                --destinations N for weighted alternatives."
               (eq require :some) kind (eq require :some) kind))
      (when (> destinations 1)
        (setf header
              (append header
                      (list (format nil "~d destinations per ~a; reaching any one of them ~
                                         counts."
                                    destinations kind)))))
      (when (and (eq require :some) (> n 1))
        (setf header
              (append header
                      (list (format nil "At least one of the ~d ~as must reach a destination."
                                    n kind))))))
    (let* ((goals (goal-places goal-objects goal-starts goal-places-fn destinations kind))
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
                           (cons "--handle-cost" handle-cost)
                           (cons "--preferences"
                                 (if pref-low
                                     (format nil "~a ~a" pref-low pref-high)
                                     "none"))
                           (cons "--destinations" destinations)
                           (cons "--require" (string-downcase require)))
                     ;; these are recorded only when set
                     (when (plusp knockout) (list (cons "--knockout" knockout)))
                     (when (plusp oneway) (list (cons "--oneway" oneway)))
                     (when mindist (list (cons "--mindist" mindist)))
                     (when maxdist (list (cons "--maxdist" maxdist)))
                     (list (cons "--seed" seed)))))
      (write-problem stream
                   :name (or name (format nil "~(~a~)-problem" style))
                   :domain domain
                   :place-names place-names :airport-names airport-names
                   :roads roads :routes routes
                   :trucks trucks :airplanes airplanes :packages packages
                   :truck-at truck-at :airplane-at airplane-at :package-at package-at
                   :goals goals
                   :drive-cost drive-cost :fly-cost fly-cost :handle-cost handle-cost
                   :header header :parameters parameters
                   :pref-weights weights :require require
                   :goal-verb (if truck-goals "reach" "deliver"))))
    (values)))
