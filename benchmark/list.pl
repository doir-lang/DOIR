% Append relation for list of lists
append_lists([], L, L).
append_lists([H|T], L2, [H|R]) :- append_lists(T, L2, R).

% Query example:
% ?- append_lists([[a], [b]], [[c], [d]], X).