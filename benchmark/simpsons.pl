parent(bart, homer).
parent(bart, marg).
parent(lisa, homer).
parent(lisa, marg).
parent(homer, abraham).
parent(marg, jackie).

male(bart).
male(homer).
male(abraham).

female(lisa).
female(marg).
female(jackie).

ancestor(Child, Ancestor) :- parent(Child, Ancestor).
ancestor(Child, Ancestor) :- parent(Child, Parent), ancestor(Parent, Ancestor).
