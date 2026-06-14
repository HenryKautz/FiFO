;; pb6 -- a small trucks+airplanes logistics problem with fully parallel plans.
;;
;; Two cities, each with a start location (l) and an airport (a), one truck
;; (at l), one airplane (at a), and one package that begins INSIDE the truck.
;; Each package must end up at the OTHER city's airport (pkg1->a2, pkg2->a1).
;; The two deliveries proceed in lockstep, so the optimal plan is 5 parallel
;; action slices (6 time slices):
;;   1 drive->airport  2 unload-truck  3 load-airplane  4 fly  5 unload-airplane
;;
;; A small two-city example (pb7 is the three-city version).  With city no longer
;; a subtype of location and the static in-city predicate compiled to an observed
;; predicate, this instantiates to ~4.5k clauses in ~2 seconds.

(define (problem pb6)
  (:domain logistics)
  (:requirements :strips :typing)
  (:objects
     pkg1 pkg2   - package
     t1 t2       - truck
     p1 p2       - airplane
     l1 l2       - location
     a1 a2       - airport
     c1 c2       - city)
  (:init
     (in-city l1 c1) (in-city a1 c1)
     (in-city l2 c2) (in-city a2 c2)
     (at t1 l1) (at t2 l2)
     (at p1 a1) (at p2 a2)
     (in pkg1 t1) (in pkg2 t2))
  (:goal (and (at pkg1 a2) (at pkg2 a1)))
  )
