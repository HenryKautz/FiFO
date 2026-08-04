;; pbq1: exercises the PDDL 3.0 con-GD grammar end to end.
;;
;;   - quantified goal: every package must end up at some airport
;;     (forall over a type, exists over a subtype)
;;   - quantified trajectory constraint with a static guard: every truck
;;     must always be at some location of city pgh (in-city is static,
;;     so the guard is resolved at instantiation time)
;;   - forall-wrapped preference with a :metric violation weight: prefer
;;     every package to finish at bos-airport (not achievable at the
;;     minimal horizon, so the answer reports the violation)
;;
;; pkg1 starts at the pgh post office and must be trucked to pgh-airport;
;; pkg2 already sits at pgh-airport.

(define (problem pbq1)
  (:domain logistics-prefs)
  (:objects pkg1 - package
	    pkg2 - package
	    truck1 - truck
	    plane1 - airplane
	    pgh-po - location
	    pgh-airport - airport
	    bos-airport - airport
	    pgh - city
	    bos - city)
  (:init (in-city pgh-po pgh)
	 (in-city pgh-airport pgh)
	 (in-city bos-airport bos)
	 (in-city truck1 pgh)
	 (at truck1 pgh-po)
	 (at plane1 pgh-airport)
	 (at pkg1 pgh-po)
	 (at pkg2 pgh-airport))
  (:goal (forall (?p - package)
	   (exists (?l - airport)
	     (at ?p ?l))))
  (:constraints (and
	 (forall (?t - truck)
	   (always (exists (?l - location)
	     (and (in-city ?l pgh) (at ?t ?l)))))
	 (preference all-packages-to-bos
	   (forall (?p - package)
	     (at-end (at ?p bos-airport))))))
  (:metric minimize (+ (total-cost)
		       (* 20 (is-violated all-packages-to-bos))))
  )
