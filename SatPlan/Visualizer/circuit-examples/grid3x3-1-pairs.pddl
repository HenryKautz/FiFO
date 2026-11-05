;; grid3x3-1-pairs: CLARA TwoPackage grid3x3-1 (domain clara-logistics), its goal
;; replaced by ONE disjunction of four CONJUNCTIONS -- each a hypothesis about
;; where BOTH packages end up.  recognize.sh scores a conjunction through a
;; derived atom it creates, (rechyp<i>) for the i-th disjunct from 0; the
;; circuit visualizer reads (holds (rechyp<i>) H) for it.  Shortest horizons
;; (EvalMaxSAT): 6, 7, 7, 8.  Recognition horizon: 8.
;; Theory: grid3x3-1-pairs.wff; circuit: grid3x3-1-pairs.dnnf (d4, projected
;; onto the actions and the four rechyp atoms).  For tests/run-test-circuit-viz.sh.

(define (problem grid3x3-1-pairs)
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
        (and (at pkg1 p2-3) (at pkg2 p3-3))
        (and (at pkg1 p2-2) (at pkg2 p3-3))
        (and (at pkg1 p2-3) (at pkg2 p2-2))
        (and (at pkg1 p3-2) (at pkg2 p2-2))))

  (:metric minimize (total-cost)))
