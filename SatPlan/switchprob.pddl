;; Test problem for the switches domain: turn s2 and s3 on, turn s1 off.

(define (problem switch3)
   (:domain switches)
   (:objects s1 s2 s3)
   (:init (on s1) (= (total-cost) 0))
   (:goal (and (on s2) (on s3) (not (on s1))))
   (:metric minimize (total-cost)))
