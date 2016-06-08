(set-logic QF_LIA)
(declare-fun N () Int)
(declare-range A (1 N))
(declare-fun a () (Array A Bool)) 
(declare-fun b () (Array A Bool)) 
(declare-fun c () (Array A Bool)) 
(assert (= (# ind A (=
	(select a ind)
	(select b ind)
	) N)))
(assert (= (# ind A (=
	(select a ind)
	(select c ind)
	) N)))
(assert (= (# ind A (=
	(select b ind)
	(not (select c ind))
	) N)))
(check-sat)
