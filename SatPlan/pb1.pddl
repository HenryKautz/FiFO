;; pb1 -- smallest end-to-end exercise of the clara-logistics domain.
;;
;; Two cities, each with a post office and an airport joined by a road, and the
;; airports joined by a route.  One package starts at the Pittsburgh post office
;; and must reach the Boston post office; the only truck in Boston waits at the
;; airport, so the package has to change vehicles twice.
;;
;; Both travel costs are single values -- one drive price and one flight price
;; for the whole problem -- which is what the argument-free (drive-cost) and
;; (fly-cost) functions in the domain buy.
;;
;; Optimal plan: 8 slices, cost 14 = 2 (drive) + 10 (fly) + 2 (drive).
;;
;;   load pkg1 truck1 pgh-po
;;   drive truck1 pgh-po pgh-air
;;   transfer pkg1 truck1 plane1 pgh-air
;;   fly plane1 pgh-air bos-air
;;   transfer pkg1 plane1 truck2 bos-air
;;   drive truck2 bos-air bos-po
;;   unload pkg1 truck2 bos-po
;;
;; Run it with:
;;   bin/planner.sh SatPlan/pb1.pddl --domain SatPlan/clara-logistics.pddl \
;;                  --maxslices 9

(define (problem pb1)
  (:domain clara-logistics)

  (:objects
        pgh-po bos-po - place
        pgh-air bos-air - airport
        truck1 truck2 - truck
        plane1 - airplane
        pkg1 - package)

  (:init
        ;; where everything starts
        (at pkg1 pgh-po)
        (at truck1 pgh-po)
        (at truck2 bos-air)
        (at plane1 pgh-air)

        ;; static topology -- roads and routes are stated in both directions,
        ;; since each predicate is one-way as declared in the domain
        (road pgh-po pgh-air) (road pgh-air pgh-po)
        (road bos-air bos-po) (road bos-po bos-air)
        (route pgh-air bos-air) (route bos-air pgh-air)

        ;; travel prices: one value each, for every drive and every flight
        (= (total-cost) 0)
        (= (drive-cost) 2)
        (= (fly-cost) 10))

  (:goal (at pkg1 bos-po))

  (:metric minimize (total-cost)))
