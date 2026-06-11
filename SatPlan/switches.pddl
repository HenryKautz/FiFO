;; Toy domain for testing pddl2fifo: switches that can be turned on and off.
;; Exercises :strips, :negative-preconditions, and :action-costs.

(define (domain switches)
   (:requirements :strips :negative-preconditions :action-costs)
   (:predicates (on ?x))
   (:functions (total-cost))
   (:action turn-on
      :parameters (?x)
      :precondition (not (on ?x))
      :effect (and (on ?x) (increase (total-cost) 1)))
   (:action turn-off
      :parameters (?x)
      :precondition (on ?x)
      :effect (and (not (on ?x)) (increase (total-cost) 2))))
