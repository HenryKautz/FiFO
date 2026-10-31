;; pb1 -- smallest end-to-end exercise of the clara-logistics domain.
;;
;; Two cities, each with a post office and an airport joined by a road, and the
;; airports joined by a route.  One package starts at the Pittsburgh post office
;; and must reach the Boston post office; the only truck in Boston waits at the
;; airport, so the package has to change vehicles twice.
;;
;; The costs are single values -- one drive price, one flight price, one price
;; per load or unload for the whole problem -- which is what the argument-free
;; (drive-cost), (fly-cost) and (handle-cost) functions in the domain buy.
;;
;; Optimal plan: 10 slices, cost 20 = 2 (drive) + 10 (fly) + 2 (drive) + 6
;; handlings at 1 (the domain has no transfer: the package changes vehicles by
;; an unload and a load, twice).  Proved with EvalMaxSAT_bin; no horizon up to
;; 13 is cheaper.
;;
;;   load pkg1 truck1 pgh-po
;;   drive truck1 pgh-po pgh-air
;;   unload pkg1 truck1 pgh-air
;;   load pkg1 plane1 pgh-air
;;   fly plane1 pgh-air bos-air
;;   unload pkg1 plane1 bos-air
;;   load pkg1 truck2 bos-air
;;   drive truck2 bos-air bos-po
;;   unload pkg1 truck2 bos-po
;;
;; Run it with:
;;   bin/planner.sh SatPlan/pb1.pddl --domain pddl/clara-logistics.pddl \
;;                  --maxslices 12

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
        (= (fly-cost) 10)
        (= (handle-cost) 1))

  (:goal (at pkg1 bos-po))

  (:metric minimize (total-cost)))
