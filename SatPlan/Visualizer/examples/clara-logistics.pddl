;; clara-logistics domain -- places, trucks, airplanes, and packages.
;;
;; Roads and routes are STATIC: no action changes them, so pddl2fifo resolves
;; them at instantiation time and they cost no propositional variables.
;;
;; Costs live in the problem file, not here: drive-cost, fly-cost and
;; handle-cost are declared below and given values per problem in :init, so the
;; same domain serves problems that price actions differently.  A drive costs
;; drive-cost, a flight fly-cost, and a load or an unload handle-cost each
;; (ppgen.sh writes 1 unless told otherwise).  Every problem must assign all
;; three -- pddl2fifo refuses an action cost with no value:
;;
;;     (= (drive-cost) 2) (= (fly-cost) 10) (= (handle-cost) 1)
;;
;; All three are functions of NO arguments, so one value prices every action of
;; its kind.  To price travel per leg instead, give the function arguments --
;; declare (drive-cost ?from ?to - place) and assign each pair in :init.  That is
;; the standard IPC distance-matrix idiom, but it needs one assignment per pair.
;;
;; There is no transfer action (a package moved straight from one vehicle to
;; another): a package changes vehicles by an unload and a load.  In SatPlan's
;; parallel encoding every transfer or unload of a package from a vehicle, at any
;; place, conflicts with every other through (in pkg vehicle), and transfer
;; tripled those actions -- on a 6x6 grid with two trucks it made the theory
;; several times larger.

(define (domain clara-logistics)
  (:requirements :strips :typing :action-costs
                 :disjunctive-preconditions :preferences)

  (:types
        place vehicle package - object
        truck airplane - vehicle
        airport - place)

  (:predicates
        (at ?vehicle-or-package - (either vehicle package) ?place - place)
        (in ?package - package ?vehicle - vehicle)
        ;; Static topology.  Both are one-way as written: state each direction
        ;; separately in the problem if travel is symmetric.
        (road ?from ?to - place)
        (route ?from ?to - airport))

  (:functions
        (total-cost)
        (drive-cost)
        (fly-cost)
        (handle-cost))

  ;; --- loading and unloading: handle-cost each ------------------------------
  ;; One pair of actions covers trucks and airplanes alike, since both are
  ;; vehicles and loading has no airport requirement.

  (:action load
        :parameters
                (?obj - package
                 ?veh - vehicle
                 ?loc - place)
        :precondition
                (and    (at ?veh ?loc)
                        (at ?obj ?loc))
        :effect
                (and    (not (at ?obj ?loc))
                        (in ?obj ?veh)
                        (increase (total-cost) (handle-cost))))

  (:action unload
        :parameters
                (?obj - package
                 ?veh - vehicle
                 ?loc - place)
        :precondition
                (and    (at ?veh ?loc)
                        (in ?obj ?veh))
        :effect
                (and    (not (in ?obj ?veh))
                        (at ?obj ?loc)
                        (increase (total-cost) (handle-cost))))

  ;; --- travel ---------------------------------------------------------------

  (:action drive
        :parameters
                (?truck - truck
                 ?from ?to - place)
        :precondition
                (and    (at ?truck ?from)
                        (road ?from ?to))
        :effect
                (and    (not (at ?truck ?from))
                        (at ?truck ?to)
                        (increase (total-cost) (drive-cost))))

  (:action fly
        :parameters
                (?airplane - airplane
                 ?from ?to - airport)
        :precondition
                (and    (at ?airplane ?from)
                        (route ?from ?to))
        :effect
                (and    (not (at ?airplane ?from))
                        (at ?airplane ?to)
                        (increase (total-cost) (fly-cost)))))
