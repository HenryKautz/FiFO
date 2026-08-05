;;; Block-words domain from the Ramirez & Geffner plan-recognition
;;; benchmarks (AAAI-10), as distributed in the PUCRS goal-plan-recognition
;;; dataset (github.com/pucrs-automated-planning/goal-plan-recognition-dataset,
;;; blocks-world/block-words-aaai problems).  Blocks are labeled with letters;
;;; each candidate goal stacks a tower spelling an English word.
;;;
;;; Modified for pddl2fifo: the original declares :equality and guards
;;; stack/unstack with (not (= ?x ?y)).  FiFO does not support =, so the
;;; guards are dropped.  This is sound here: stack/unstack ?x ?x require
;;; (holding ?x) with (clear ?x), or (on ?x ?x), neither of which is
;;; reachable in the 4-operator blocks world.

(define (domain BLOCKS)
  (:requirements :strips :typing)
  (:types block)
  (:predicates (on ?x ?y - block)
	       (ontable ?x - block)
	       (clear ?x - block)
	       (handempty)
	       (holding ?x - block)
	       )

  (:action pick-up
	     :parameters (?x - block)
	     :precondition (and (clear ?x) (ontable ?x) (handempty))
	     :effect
	     (and (not (ontable ?x))
		   (not (clear ?x))
		   (not (handempty))
		   (holding ?x)))

  (:action put-down
	     :parameters (?x - block)
	     :precondition (holding ?x)
	     :effect
	     (and (not (holding ?x))
		   (clear ?x)
		   (handempty)
		   (ontable ?x)))
  (:action stack
	     :parameters (?x ?y - block)
	     :precondition (and (holding ?x) (clear ?y))
	     :effect
	     (and (not (holding ?x))
		   (not (clear ?y))
		   (clear ?x)
		   (handempty)
		   (on ?x ?y)))
  (:action unstack
	     :parameters (?x ?y - block)
	     :precondition (and (on ?x ?y) (clear ?x) (handempty))
	     :effect
	     (and (holding ?x)
		   (clear ?y)
		   (not (clear ?x))
		   (not (handempty))
		   (not (on ?x ?y)))))
