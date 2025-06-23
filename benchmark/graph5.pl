% --- Edge Facts (Undirected Edges) ---
edge(n0, n1).
edge(n1, n2).
edge(n2, n3).
edge(n3, n4).

% --- Path Rules ---
path(X, Y) :- edge(X, Y).
path(X, Y) :- edge(X, Z), path(Z, Y), X \= Y.