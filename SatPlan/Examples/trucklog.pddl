;; Typed logistics domain for testing pddl2fifo :typing support.
;; The drive action ranges over the supertype mobile to exercise the
;; type hierarchy (truck is a subtype of mobile).

(define (domain trucklog)
   (:requirements :strips :typing :action-costs)
   (:types truck - mobile package place mobile)
   (:predicates (at ?x ?pl) (in ?pk ?tr))
   (:functions (total-cost))
   (:action load
      :parameters (?pk - package ?tr - truck ?pl - place)
      :precondition (and (at ?tr ?pl) (at ?pk ?pl))
      :effect (and (in ?pk ?tr) (not (at ?pk ?pl)) (increase (total-cost) 0.7)))
   (:action unload
      :parameters (?pk - package ?tr - truck ?pl - place)
      :precondition (and (in ?pk ?tr) (at ?tr ?pl))
      :effect (and (at ?pk ?pl) (not (in ?pk ?tr)) (increase (total-cost) 0.5)))
   (:action drive
      :parameters (?tr - mobile ?from - place ?to - place)
      :precondition (at ?tr ?from)
      :effect (and (at ?tr ?to) (not (at ?tr ?from)) (increase (total-cost) 4.5))))
