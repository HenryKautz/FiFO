;; pb7 -- the three-city version of pb6 (trucks + airplanes, fully parallel).
;;
;; Three cities, each with a start location (l) and an airport (a), one truck
;; (at l), one airplane (at a), and one package that begins INSIDE the truck.
;; Each package must end up at the airport of the next city (c1->c2->c3->c1).
;; All three deliveries proceed in lockstep, so the optimal plan is 5 parallel
;; action slices (6 time slices):
;;   1 drive->airport  2 unload-truck  3 load-airplane  4 fly  5 unload-airplane
;;
;; This used to be impractical for FiFO, but two changes make it small now:
;; (1) city is no longer a subtype of location, and (2) pddl2fifo turns the
;; static in-city predicate into an observed predicate, so invalid drives are
;; pruned at instantiation.  It now instantiates to ~4k clauses in ~2 seconds
;; (the same order as the two-city pb6).

(define (problem pb7)
  (:domain logistics-costs)
  (:requirements :strips :typing)
  (:objects
     pkg1 pkg2 pkg3   - package
     t1 t2 t3         - truck
     p1 p2 p3         - airplane
     l1 l2 l3         - location
     a1 a2 a3         - airport
     c1 c2 c3         - city)
  (:init
     (in-city l1 c1) (in-city a1 c1)
     (in-city l2 c2) (in-city a2 c2)
     (in-city l3 c3) (in-city a3 c3)
     (at t1 l1) (at t2 l2) (at t3 l3)
     (at p1 a1) (at p2 a2) (at p3 a3)
     (in pkg1 t1) (in pkg2 t2) (in pkg3 t3))
  (:goal (and (at pkg1 a2) (at pkg2 a3) (at pkg3 a1)))
  )
