;; Typed logistics test problem: same task as SatPlan/logistics.wff.

(define (problem trucklog3)
   (:domain trucklog)
   (:objects p1 p2 p3 - package t1 t2 - truck l1 l2 l3 - place)
   (:init (at p1 l1) (at p2 l2) (at p3 l3) (at t1 l1) (at t2 l2)
          (= (total-cost) 0))
   (:goal (and (at p1 l2) (at p3 l2) (at p2 l1)))
   (:metric minimize (total-cost)))
