;; clara-logistics domain -- places, trucks, airplanes, and packages.
;;
;; Roads and routes are STATIC: no action changes them, so pddl2fifo resolves
;; them at instantiation time and they cost no propositional variables.
;;
;; Travel costs live in the problem file, not here: drive-cost and fly-cost are
;; declared below and given values per problem in :init, so the same domain
;; serves problems that price travel differently.  Loading, unloading, and
;; transferring are free.
;;
;; Both are functions of NO arguments, so one value in :init prices every drive
;; and every flight:
;;
;;     (= (drive-cost) 2) (= (fly-cost) 10)
;;
;; To price travel per leg instead, give the function arguments -- declare
;; (drive-cost ?from ?to - place) and assign each pair in :init.  That is the
;; standard IPC distance-matrix idiom, but it needs one assignment per pair.

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
        (fly-cost))

  ;; --- loading and unloading -----------------------------------------------
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
                        (in ?obj ?veh)))

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
                        (at ?obj ?loc)))

  ;; --- transfer between vehicles -------------------------------------------
  ;; Move a package directly from one vehicle to another standing at the same
  ;; place, without setting it down.

  (:action transfer
        :parameters
                (?obj - package
                 ?from ?to - vehicle
                 ?loc - place)
        :precondition
                (and    (in ?obj ?from)
                        (at ?from ?loc)
                        (at ?to ?loc))
        :effect
                (and    (not (in ?obj ?from))
                        (in ?obj ?to)))

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
