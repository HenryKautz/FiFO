;; Derived-predicate demo: a disjunctive goal over two towers, where one
;; disjunct is the nullary derived predicate (spells-ab) = (and (on a b)
;; (ontable b) (clear-d a)), and clear-d is a parameterized derived predicate
;; with a quantified body.  The marginal of (HOLDS (SPELLS-AB) numslices)
;; reads the probability of that disjunct directly.
(define (problem pb1) (:domain blocks-dp)
  (:objects a b c - block)
  (:init (handempty) (ontable a) (ontable b) (ontable c) (clear a) (clear b) (clear c))
  (:goal (or (spells-ab) (and (on b a) (ontable a)))))
