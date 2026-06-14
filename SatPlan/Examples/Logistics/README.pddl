;; Logistics example -- typed STRIPS logistics domain (no action costs).
;;
;;   logistics.pddl   the domain (define (domain logistics))
;;   pb1 .. pb5       problem instances from PDDL4J
;;   pb6, pb7         small hand-written trucks+airplanes problems (this repo)
;;
;; NOTE: logistics.pddl has been modified from the original PDDL4J version so
;; that city is its own type rather than a subtype of location.  Nothing is ever
;; "at" a city or driven to a city, so making cities locations only bloated the
;; FiFO location domain.  pddl2fifo also compiles in-city (a static predicate --
;; never added or deleted) into an observed predicate, so invalid drives are
;; pruned at instantiation.  Together these shrink the multi-city instances by
;; one to two orders of magnitude.
;;
;; Because this domain has no action costs, solve these with a plain SAT solver,
;; e.g.:
;;     bash SatPlan/planner.sh SatPlan/Examples/Logistics/pb1.pddl \
;;          --numslices 8 --solver kissat
;;
;; Status with FiFO:
;;
;;   pb1 (rocket_ext.a)  -- SOLVES.  Airplanes/airports only (no trucks or
;;   pb4 (rocket_ext.b)     cities), so the instantiated encoding stays small.
;;
;;   pb6                 -- SOLVES (~2 s).  Two cities, two trucks, two
;;                          airplanes; packages start inside the trucks and are
;;                          flown to the other city's airport, all in parallel.
;;
;;   pb7                 -- SOLVES (~2 s).  Same structure as pb6 but three
;;                          cities; small thanks to the static-predicate and
;;                          city-type fixes described above.
;;
;;   pb2 (logistics.a)   -- STILL TOO LARGE for a quick demo.  Even with the
;;   pb3 (logistics.easy)   optimizations above, these full PDDL4J instances have
;;   pb5 (logistics.b)      many trucks, packages, and locations and need long
;;                          horizons (e.g. pb3 is ~100k clauses / ~37 s to build
;;                          at 12 slices), so they remain slow.
;;
;; In short: pb1, pb4, pb6, and pb7 solve quickly; pb2, pb3, and pb5 (the larger
;; PDDL4J instances) are still too large.
