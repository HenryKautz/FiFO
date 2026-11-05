;; grid3x3-1: the recognition problem
;; TwoPackage/grid3x3-1.pddl with its goal written as ONE disjunction of its
;; 4 hypotheses (the same set of plans).  recognize.sh's names:
;;   at-pkg1-p1-3     (at pkg1 p1-3)   shortest horizon 6
;;   at-pkg1-p2-1     (at pkg1 p2-1)   shortest horizon 7
;;   at-pkg2-p2-1     (at pkg2 p2-1)   shortest horizon 5
;;   at-pkg2-p1-1     (at pkg2 p1-1)   shortest horizon 6
;; Recognition horizon: 7
;;   (the largest shortest horizon: every hypothesis is achievable at it)
;; Written by scripts/plan-goals.py.

(define (problem grid3x3-1)
  (:domain clara-logistics)

  (:objects
        p1-1 p1-2 p1-3 p2-1 p2-2 p2-3 p3-1 p3-2 p3-3 - place
        truck1 - truck
        pkg1 pkg2 - package)

  (:init
        ;; where everything starts
        (at pkg1 p3-3)
        (at pkg2 p2-3)
        (at truck1 p2-3)

        ;; static topology: roads within each road network,
        ;; routes between every pair of airports
        (road p2-1 p1-1)
        (road p1-1 p2-1)
        (road p1-2 p1-1)
        (road p1-1 p1-2)
        (road p2-2 p1-2)
        (road p1-2 p2-2)
        (road p1-3 p1-2)
        (road p1-2 p1-3)
        (road p2-3 p1-3)
        (road p1-3 p2-3)
        (road p3-1 p2-1)
        (road p2-1 p3-1)
        (road p2-2 p2-1)
        (road p2-1 p2-2)
        (road p3-2 p2-2)
        (road p2-2 p3-2)
        (road p2-3 p2-2)
        (road p2-2 p2-3)
        (road p3-3 p2-3)
        (road p2-3 p3-3)
        (road p3-2 p3-1)
        (road p3-1 p3-2)
        (road p3-3 p3-2)
        (road p3-2 p3-3)


        ;; prices: one value for every drive, one for every flight, one for
        ;; every load or unload
        (= (total-cost) 0)
        (= (drive-cost) 1)
        (= (fly-cost) 3)
        (= (handle-cost) 1))

  (:goal (or
        (at pkg1 p1-3)
        (at pkg1 p2-1)
        (at pkg2 p2-1)
        (at pkg2 p1-1)))

  (:metric minimize (total-cost)))
