;; A deliberately broken PDDL domain, for checking by hand that the visualizer
;; reports a domain that fails to parse (drop it on the page together with
;; examples/grid6x6-1.pddl).  The :action load below is never closed.

(define (domain clara-logistics-handling)
  (:requirements :strips :typing :action-costs)

  (:types
        place vehicle package - object
        truck airplane - vehicle)

  (:functions
        (total-cost)
        (drive-cost))

  (:action load
        :parameters
                (?obj - package
                 ?veh - vehicle
                 ?loc - place)
        :effect
                (and    (not (at ?obj ?loc))
                        (in ?obj ?veh)
                        (increase (total-cost) 1))
