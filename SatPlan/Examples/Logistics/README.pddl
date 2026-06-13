;; Logistics example -- typed STRIPS logistics domain (no action costs).
;;
;;   logistics.pddl   the domain (define (domain logistics))
;;   pb1 .. pb5       problem instances from PDDL4J
;;   pb6, pb7         small hand-written trucks+airplanes problems (this repo)
;;
;; NOTE: logistics.pddl has been modified from the original PDDL4J version so
;; that city is its own type rather than a subtype of location.  Nothing is ever
;; "at" a city or driven to a city, so making cities locations only bloated the
;; FiFO location domain; removing it shrinks every instance roughly 3x.
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
;;   pb7                 -- LARGE (~113k clauses, ~1 min to instantiate).  Same
;;                          structure as pb6 but three cities; builds but is slow.
;;
;;   pb2 (logistics.a)   -- TOO LARGE for FiFO at present.  These are full
;;   pb3 (logistics.easy)   multi-city logistics instances (trucks + cities +
;;   pb5 (logistics.b)      airplanes); the SatPlan instantiation explodes
;;                          (drive-truck ranges over location x location x city,
;;                          plus frame axioms over many fluents x time slices),
;;                          exhausting memory / not finishing in reasonable time.
;;
;; In short: pb1, pb4, and pb6 solve quickly; pb7 builds but is slow; pb2, pb3,
;; and pb5 are too large.
