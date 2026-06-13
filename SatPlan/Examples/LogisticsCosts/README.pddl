;; LogisticsCosts example -- typed STRIPS logistics domain WITH action costs.
;;
;;   logistics-costs.pddl   the domain (define (domain logistics-costs))
;;   pb1 .. pb5             problem instances (copies referring to logistics-costs)
;;
;; Action costs: load/unload = 1.0, drive = 4.0, fly = 15.0.  Because costs are
;; present, solve these with the default MaxSAT solver (it minimizes total cost
;; and reports it as a leading (*objective* <n>) atom), e.g.:
;;     bash SatPlan/planner.sh SatPlan/Examples/LogisticsCosts/pb1.pddl --numslices 8
;;
;; Status with FiFO:
;;
;;   pb1 (rocket_ext.a)  -- SOLVES.  Airplanes/airports only (no trucks or
;;   pb4 (rocket_ext.b)     cities), so the instantiated encoding stays small.
;;
;;   pb2 (logistics.a)   -- TOO LARGE for FiFO at present.  These are full
;;   pb3 (logistics.easy)   multi-city logistics instances (trucks + cities +
;;   pb5 (logistics.b)      airplanes); the SatPlan instantiation explodes
;;                          (drive-truck ranges over location x location x city,
;;                          plus frame axioms over many fluents x time slices),
;;                          exhausting memory / not finishing in reasonable time.
;;
;; In short: only the rocket-style problems pb1 and pb4 currently solve;
;; pb2, pb3, and pb5 are too large.
