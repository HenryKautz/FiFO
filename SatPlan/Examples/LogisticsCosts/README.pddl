;; LogisticsCosts example -- typed STRIPS logistics domain WITH action costs.
;;
;;   logistics-costs.pddl   the domain (define (domain logistics-costs))
;;   pb1 .. pb5             problem instances from PDDL4J (refer to logistics-costs)
;;   pb6, pb7               small hand-written trucks+airplanes problems (this repo)
;;
;; Action costs: load/unload = 1.0, drive = 4.0, fly = 15.0.  Because costs are
;; present, solve these with the default MaxSAT solver (it minimizes total cost
;; and reports it as a leading (*objective* <n>) atom), e.g.:
;;     bash SatPlan/planner.sh SatPlan/Examples/LogisticsCosts/pb6.pddl --numslices 6
;;
;; As in the Logistics domain, city is its own type (not a subtype of location)
;; and pddl2fifo compiles the static in-city predicate into an observed predicate,
;; which keeps the multi-city instances small.
;;
;; Status with FiFO (default solver tt-open-wbo-inc-Glucose4_1):
;;
;;   pb1 (rocket_ext.a)  -- SOLVES.  Airplanes/airports only (no trucks or
;;   pb4 (rocket_ext.b)     cities), so the instantiated encoding stays small.
;;
;;   pb6                 -- SOLVES (~2 s), optimal cost 44.  Two cities, two
;;                          trucks, two airplanes; packages start inside the
;;                          trucks and are flown to the other city's airport.
;;   pb7                 -- SOLVES (~10 s), optimal cost 66.  Same structure
;;                          with three cities.  (Each package costs drive 4 +
;;                          unload 1 + load 1 + fly 15 + unload 1 = 22.)
;;
;;   pb2 (logistics.a)   -- STILL TOO LARGE for a quick demo: full PDDL4J
;;   pb3 (logistics.easy)   instances with many trucks, packages, and locations
;;   pb5 (logistics.b)      that need long horizons, so they remain slow.
;;
;; In short: pb1, pb4, pb6, and pb7 solve quickly (and optimally) with costs;
;; pb2, pb3, and pb5 are still too large.
