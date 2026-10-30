;; clara-logistics-handling domain -- clara-logistics (FiFO's pddl/clara-logistics.pddl)
;; with a cost on handling a package: load and unload each cost 1.  Travel is
;; priced by the problem as before, (= (drive-cost) R) and (= (fly-cost) R) in
;; :init.
;;
;; The transfer action (a package moved straight from one vehicle to another) is
;; left out: a package still changes trucks by an unload and a load.  In SatPlan's
;; parallel encoding every transfer or unload of a package from a truck, at any
;; place, conflicts with every other through (in pkg truck), and transfer tripled
;; those actions -- on a 6x6 grid with two trucks it made the theory several times
;; larger.
;;
;; Roads and routes are STATIC: no action changes them, so pddl2fifo resolves
;; them at instantiation time and they cost no propositional variables.

(define (domain clara-logistics-handling)
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

  ;; --- loading and unloading: 1 each ----------------------------------------

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
                        (increase (total-cost) 1)))

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
                        (increase (total-cost) 1)))

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
