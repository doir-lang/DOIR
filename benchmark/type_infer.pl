% --- Entity type assignments ---
type_of(a, i32).
type_of(b, i32).

% --- Function type of 'add': ([T], [T]) -> [T] ---
function_types(add, [i32, i32, i32]).

% --- Function call setup ---
call_entity(call, add).
arguments(call, [a, b]).

% --- Rule: typecheck_function(Function, Call) ---
% Ensures the function has the correct type signature and that argument types match
typecheck_function(Function, Call) :-
    function_types(Function, FuncType),
    split_tail(FuncType, ParamTypes),
    arguments(Call, Args),
    map_arg_types(Args, ArgTypes),
    ParamTypes = ArgTypes.

% --- Helper: Get argument types ---
map_arg_types([], []).
map_arg_types([Arg | Rest], [Type | RestTypes]) :-
    type_of(Arg, Type),
    map_arg_types(Rest, RestTypes).

% --- Helper: Split function type into parameter types and return type ---
% E.g., split_tail([T, T, T], [T, T]) gives [T, T] as ParamTypes (last is return type)
split_tail([_Last], []).
split_tail([Head | Tail], [Head | ResultTail]) :-
    split_tail(Tail, ResultTail).
