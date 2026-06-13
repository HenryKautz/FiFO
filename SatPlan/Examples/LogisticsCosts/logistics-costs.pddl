;; logistics domain with action costs
;;
;; logistics-typed-length: strips + simple types + action costs
;;    based on logistics-strips-length.
;; load/unload cost 1.0, drive costs 4.0, fly costs 15.0.

(define (domain logistics-costs)
  (:requirements :strips :typing :action-costs)
  (:types
  	package location vehicle city - object
  	truck airplane - vehicle
  	airport - location)

  (:predicates
		(at ?vehicle-or-package - (either vehicle package)  ?location - location)
		(in ?package - package ?vehicle - vehicle)
		(in-city ?loc-or-truck - (either location truck) ?citys - city))

  (:functions (total-cost))

  (:action load-truck
	:parameters
		 (?obj - package
		  ?truck - truck
		  ?loc - location)
	:precondition
		(and 	(at ?truck ?loc)
			(at ?obj ?loc))
	:effect
		(and 	(not (at ?obj ?loc))
			(in ?obj ?truck)
			(increase (total-cost) 1.0)))

  (:action load-airplane
	:parameters
		(?obj - package
		 ?airplane - airplane
		 ?loc - airport)
	:precondition
		(and
			(at ?obj ?loc)
			(at ?airplane ?loc))
	:effect
   		(and 	(not (at ?obj ?loc))
			(in ?obj ?airplane)
			(increase (total-cost) 1.0)))

  (:action unload-truck
	:parameters
		(?obj - package
		 ?truck - truck
		 ?loc - location)
	:precondition
		(and    (at ?truck ?loc)
			(in ?obj ?truck))
	:effect
		(and	(not (in ?obj ?truck))
			(at ?obj ?loc)
			(increase (total-cost) 1.0)))

  (:action unload-airplane
	:parameters
		(?obj - package
		 ?airplane - airplane
		 ?loc - airport)
	:precondition
		(and	(in ?obj ?airplane)
			(at ?airplane ?loc))
	:effect
		(and
			(not (in ?obj ?airplane))
			(at ?obj ?loc)
			(increase (total-cost) 1.0)))

  (:action drive-truck
	:parameters
		(?truck - truck
		 ?loc-from - location
		 ?loc-to - location
		 ?city - city)
	:precondition
		(and 	(at ?truck ?loc-from)
			(in-city ?loc-from ?city)
			(in-city ?loc-to ?city))
	:effect
		(and 	(not (at ?truck ?loc-from))
			(at ?truck ?loc-to)
			(increase (total-cost) 4.0)))

  (:action fly-airplane
	:parameters
		(?airplane - airplane
		 ?loc-from - airport
		 ?loc-to - airport)
	:precondition
		(at ?airplane ?loc-from)
	:effect
		(and 	(not (at ?airplane ?loc-from))
		(at ?airplane ?loc-to)
		(increase (total-cost) 15.0)))
)
