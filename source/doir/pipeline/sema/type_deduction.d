/// `sema.deduceTypes`: solves the module's type variables, one level per round.
///
/// Two flavors, and the pass does them in this order on each entity it visits.
/// A call's `deduced` parameters are *solved, not supplied* (D-Deduce): they
/// are absent from the call site, so `f(x)` against `(T: deduced type, v: T)`
/// arrives an argument short and leaves elaborated to `f(tau, x)`. A `_` in
/// type position is a hole `introduceTypeVariables` flagged, and is solved from
/// whatever the entity was assigned - which for a call means its return type,
/// and a `-> T` return type means whatever `T` was just solved to. That
/// dependency is the reason the two are one pass rather than two: they have to
/// happen in this order, on the same entity, and a schedule that could name
/// them separately could get that wrong.
///
/// This runs *inside* the comptime fixpoint rather than before it, and that is
/// the whole design. In DOIR a type is a comptime value - `pi32 : type =
/// type.pointer(i32)`, and even `compiler.byte` is a `compiler.base_type` call
/// waiting to be folded - so the type a hole should take is very often the
/// result of a call that has not been evaluated yet. Solving therefore depends
/// on evaluation; and by D-Deduce, evaluation depends on solving, because a
/// solved `deduced` parameter becomes a comptime *argument* to the call it was
/// solved for. Neither can be a phase that finishes before the other starts, so
/// the schedule alternates them and stops when a round changes nothing.
///
/// Elaboration is first-order unification, each variable fixed by its first
/// solution. A later argument disagreeing with that solution makes the call
/// ill-formed - which is what gives `is_equal(a, b)` its same-type constraint
/// without a where-clause - but this pass does not say so: it substitutes the
/// solution in and `sema.typeCheck` compares the arguments against it, after
/// comptime, when a type has settled enough for S-Struct to decide. Deciding
/// agreement from in here would mean deciding it in the middle of the fixpoint,
/// where half the types are still unfolded calls and `sema.typesAgree` answers
/// "no idea".
///
/// The pass is deliberately *monotone*: a variable goes from unsolved to
/// solved and never back - a call is elaborated once, and its own argument
/// count is the record of whether it has been. The comptime half of the same
/// fixpoint is not (C-Call sets and clears the flag), and @comptime notes that
/// its termination already rests on the call graph being acyclic; a second
/// non-monotone operator in the same loop would have nothing at all holding it
/// up.
module doir.pipeline.sema.type_deduction;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.systems : fixedPointChanged;

import doir.pipeline.sema.type_variables : isTypeVariable;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Deduced parameters
// ---------------------------------------------------------------------------

/// The entity that stands for `ft`'s parameter number `index` - the
/// declaration inside the function type's own block, which is what a later
/// parameter's `: T` and a `-> T` resolve to.
///
/// `canonicalize.materializeFunctionTypeParameters` is what gives a function
/// type that block, and only gives it one when the type refers to its own
/// parameters. A `deduced` parameter nothing refers to has nothing to solve it
/// from, so its absence here is the same answer as an unsolved variable.
private EntityId parameterEntity(ref Module mod, EntityId ft, size_t index) @trusted {
	if (!hasComponent!Block(mod, ft)) return invalidEntity;

	auto block = &getComponent!Block(mod, ft);
	foreach (i; 0 .. daLength(block.related)) {
		immutable e = block.related[i];
		if (!hasComponent!FunctionParameter(mod, e)) continue;
		if (getComponent!FunctionParameter(mod, e).index == index) return e;
	}
	return invalidEntity;
}

/// The declared type of `e`, or `invalidEntity` when it has none yet.
private EntityId declaredType(ref Module mod, EntityId e) {
	if (e == invalidEntity) return invalidEntity;
	e = resolveAlias(mod, e);
	if (!hasComponent!TypeOf(mod, e)) return invalidEntity;
	return resolveAlias(mod, getComponent!TypeOf(mod, e).related[0]);
}

/// One call's solution set: the parameter position each variable was declared
/// at, the entity that stands for it, and what it has been fixed to so far.
/// Three parallel lists rather than one of structs, because that is what a
/// libfp dynarray is convenient for.
private struct Solutions {
	size_t* positions = null;
	EntityId* variables = null;
	EntityId* values = null;
}

private void free(ref Solutions s) @trusted {
	if (s.positions !is null) { fp.dynarray.free(s.positions); s.positions = null; }
	if (s.variables !is null) { fp.dynarray.free(s.variables); s.variables = null; }
	if (s.values !is null) { fp.dynarray.free(s.values); s.values = null; }
}

private bool solved(ref Solutions s) @trusted {
	foreach (i; 0 .. daLength(s.values))
		if (s.values[i] == invalidEntity) return false;
	return true;
}

/// Matches a declared parameter type against what was actually passed for it,
/// binding any variable it reaches to the first thing that reaches it.
///
/// Structural descent is over `Pointer` only. Everything else a parameter type
/// can be - a name, a call that comptime has not folded - either *is* a
/// variable or is opaque to a first-order matcher, and guessing inside one
/// would bind a variable to the wrong half of it.
private void unify(ref Module mod, ref Solutions s, EntityId pattern, EntityId actual) @trusted {
	if (pattern == invalidEntity || actual == invalidEntity) return;
	pattern = resolveAlias(mod, pattern);
	actual = resolveAlias(mod, actual);

	foreach (i; 0 .. daLength(s.variables)) {
		if (s.variables[i] != pattern) continue;
		if (s.values[i] == invalidEntity) s.values[i] = actual;
		return;
	}

	if (hasComponent!Pointer(mod, pattern) && hasComponent!Pointer(mod, actual))
		unify(mod, s, getComponent!Pointer(mod, pattern).related[0],
			getComponent!Pointer(mod, actual).related[0]);
}


/// The function type `subtree` calls, if it is a call with deduced parameters
/// left to solve.
private EntityId deducibleCallee(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return invalidEntity;
	if (!hasComponent!FunctionInputs(mod, subtree)) return invalidEntity;

	immutable decl = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (!(hasComponent!TypeOf(mod, decl) || hasComponent!LookupTypeOf(mod, decl)))
		return invalidEntity;

	auto declType = typeOfLookup(mod, decl);
	if (!declType.resolved()) return invalidEntity;

	immutable ft = resolveTypeModifications(mod, declType.entity());
	if (ft == invalidEntity) return invalidEntity;
	if (!hasComponent!FunctionInputs(mod, ft)) return invalidEntity;

	immutable deduced = deducedParameterCount(mod, ft);
	if (deduced == 0) return invalidEntity;

	// The argument count *is* the record of whether this call has been
	// elaborated: short by exactly the deduced parameters means it has not, and
	// anything else is either done or an arity error `sema.functionArity`
	// reports.
	immutable declCount = daLength(getComponent!FunctionInputs(mod, ft).related);
	if (declCount < deduced) return invalidEntity;
	if (daLength(getComponent!FunctionInputs(mod, subtree).related) != declCount - deduced)
		return invalidEntity;

	return ft;
}

/// Solves `subtree`'s call, if it has deduced parameters left to solve, and
/// writes the solutions in as arguments.
private void deduceArguments(ref Module mod, EntityId subtree) @trusted {
	immutable ft = deducibleCallee(mod, subtree);
	if (ft == invalidEntity) return;

	auto params = &getComponent!FunctionInputs(mod, ft);
	immutable declCount = daLength(params.related);

	Solutions s;
	scope(exit) free(s);
	foreach (i; 0 .. declCount) {
		if (!isDeducedParameter(mod, ft, i)) continue;
		immutable variable = parameterEntity(mod, ft, i);
		if (variable == invalidEntity) return; // nothing stands for it to be solved
		fp.dynarray.pushBack(s.positions, i);
		fp.dynarray.pushBack(s.variables, variable);
		fp.dynarray.pushBack(s.values, invalidEntity);
	}

	auto args = &getComponent!FunctionInputs(mod, subtree);

	// Forward: the supplied arguments fill the positions that are not deduced,
	// in order.
	size_t supplied = 0;
	foreach (i; 0 .. declCount) {
		if (isDeducedParameter(mod, ft, i)) continue;
		unify(mod, s, params.related[i], declaredType(mod, args.related[supplied++]));
	}

	// Backward: the call entity *is* the register being assigned, so its
	// declared type is the expected type. A register declared `_` has none, and
	// then there is nothing to read - which is why `cast(x)` under a hole is
	// undeducible however many rounds it gets.
	unify(mod, s, resolvedReturnTypeOf(mod, ft), declaredType(mod, subtree));

	if (!solved(s)) return;

	// Splice each solution in at the position it was solved for. Ascending
	// order is what makes this a plain insert: every position below the one
	// being filled already holds what it will hold.
	auto stored = &getComponent!FunctionInputs(mod, subtree).related;
	foreach (i; 0 .. daLength(s.positions))
		fp.dynarray.insert(*stored, s.positions[i], s.values[i]);

	// The call now has a comptime argument it did not have, and a `-> T` read
	// off it now answers.
	fixedPointChanged() = true;
}


// ---------------------------------------------------------------------------
// Holes
// ---------------------------------------------------------------------------

/// The return type of whatever `e` calls, or `invalidEntity` if `e` is not a
/// call or the callee has no function type yet.
private EntityId calleeReturnType(ref Module mod, EntityId e) @trusted {
	if (!hasComponent!Call(mod, e)) return invalidEntity;

	immutable decl = resolveAlias(mod, getComponent!Call(mod, e).related[0]);
	auto declType = typeOfLookup(mod, decl);
	if (!declType.resolved()) return invalidEntity;

	immutable ft = resolveTypeModifications(mod, declType.entity());
	if (ft == invalidEntity) return invalidEntity;

	// `-> T`, where `T` is one of the callee's own parameters: a hole on
	// `_ : _ = return(x)` reads the *solved* type off the call, not the
	// parameter declaration every call through the type shares.
	return typeAtCallSite(mod, e, ft, resolvedReturnTypeOf(mod, ft));
}

/// The type of what `e`'s block yields, for `%2 : _ = { ... yield(%1) }`.
///
/// Only a direct child is considered. A yield nested inside a sub-block belongs
/// to that block, not to this one, and the walk reaches it on its own turn.
private EntityId yieldedType(ref Module mod, EntityId e) @trusted {
	if (!hasComponent!Block(mod, e)) return invalidEntity;

	immutable yield = resolveCached(mod, "compiler.indicate_yield", e);
	if (yield == invalidEntity) return invalidEntity;

	auto block = &getComponent!Block(mod, e);
	foreach (i; 0 .. daLength(block.related)) {
		immutable child = block.related[i];
		if (!hasComponent!Call(mod, child)) continue;
		if (resolveAlias(mod, getComponent!Call(mod, child).related[0]) != yield) continue;
		if (!hasComponent!FunctionInputs(mod, child)) continue;

		auto inputs = &getComponent!FunctionInputs(mod, child);
		if (daLength(inputs.related) == 0) continue;

		immutable value = resolveAlias(mod, inputs.related[0]);
		if (!hasComponent!TypeOf(mod, value)) continue;
		return getComponent!TypeOf(mod, value).related[0];
	}
	return invalidEntity;
}

/// What `e`'s hole should be filled with, or `invalidEntity` while nothing in
/// the module says yet.
///
/// Every source here is *forward*: the type is read off whatever the entity was
/// assigned. D-Deduce's backward direction - reading the expected type off the
/// register being assigned - has nothing to give a hole, because the hole *is*
/// that register's declared type. A literal under a hole (`%1 : _ = 1`) is
/// exactly that case, and so stays unsolved for `sema.typeCheck` to report.
private EntityId solveHole(ref Module mod, EntityId e) {
	immutable fromCall = calleeReturnType(mod, e);
	if (fromCall != invalidEntity) return fromCall;

	return yieldedType(mod, e);
}


// ---------------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------------

bool deduceTypes(ref Module mod, EntityId subtree) @trusted {
	// Before the hole below, which may be reading a `-> T` off this very call.
	deduceArguments(mod, subtree);

	if (!flagsSet(mod, subtree, Flags.TypeVariable)) return true;

	immutable solution = solveHole(mod, subtree);
	if (solution == invalidEntity) return true;

	// Solving a hole to another unsolved variable settles nothing, and writing
	// it would break monotonicity: the entity would look solved while its type
	// was still a variable, and nothing would come back to finish it.
	if (isTypeVariable(mod, solution)) return true;

	getComponent!Flags(mod, subtree).flags &= ~cast(ushort) Flags.TypeVariable;
	addComponent!TypeOf(mod, subtree).related[0] = solution;

	// Something downstream of this entity may now be solvable in turn.
	fixedPointChanged() = true;
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
	import tests.pipeline_helper;
}

unittest { // a hole on a call takes the callee's return type
	auto r = compile("%1 : compiler.byte = 1\n%2 : _ = compiler.emit(%1)\n");
	scope(exit) freeModule(r.mod);
	diagnostics().clear();

	immutable two = find(r.mod, r.root, "%2");
	assert(two != invalidEntity);
	assert(!flagsSet(r.mod, two, Flags.TypeVariable));
	assert(hasComponent!TypeOf(r.mod, two));
}

unittest {
	// A hole with nothing to read the type off stays a variable. Solving it to
	// *something* would be worse than leaving it: `sema.typeCheck` reports the
	// leftover, which is the diagnostic the author can act on.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable e = pushCommon(f.mod, f.root, internIn(f.mod, "hole"));
	addComponent!Number(f.mod, e).value = 1;
	getOrAddComponent!Flags(f.mod, e).flags |= Flags.TypeVariable;

	assert(deduceTypes(f.mod, e));
	assert(flagsSet(f.mod, e, Flags.TypeVariable));
	assert(!hasComponent!TypeOf(f.mod, e));
}

unittest { // a solved hole asks the fixpoint for another round
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	auto block = BlockBuilder(f.root, &f.mod);
	immutable one = pushNumber(block, internIn(f.mod, "one"), byte_, 1);

	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);
	EntityId[1] args = [one];
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, emit, args[]);
	removeComponent!TypeOf(f.mod, call);
	getOrAddComponent!Flags(f.mod, call).flags |= Flags.TypeVariable;

	fixedPointChanged() = false;
	assert(deduceTypes(f.mod, call));
	assert(fixedPointChanged());
	assert(hasComponent!TypeOf(f.mod, call));
}

unittest { // forward: the argument's type is spliced in as the solution
	auto r = compile(
		"f : (T: deduced type, v: T) -> T\n"
		~ "%1 : compiler.byte = 1\n"
		~ "%2 : compiler.byte = f(%1)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable call = find(r.mod, r.root, "%2");
	assert(call != invalidEntity);

	auto args = &getComponent!FunctionInputs(r.mod, call);
	assert(daLength(args.related) == 2);
	assert(resolveAlias(r.mod, args.related[0])
		== find(r.mod, r.root, "compiler.byte"));
}

unittest { // backward: the declared type of the register solves the return type
	auto r = compile(
		"cast : (Tin: deduced type, in: Tin, Tout: deduced type) -> Tout\n"
		~ "%1 : compiler.byte = 1\n"
		~ "%2 : compiler.pointer_sized = cast(%1)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable call = find(r.mod, r.root, "%2");
	assert(call != invalidEntity);

	auto args = &getComponent!FunctionInputs(r.mod, call);
	assert(daLength(args.related) == 3);
	assert(resolveAlias(r.mod, args.related[0]) == find(r.mod, r.root, "compiler.byte"));
	assert(resolveAlias(r.mod, args.related[2]) == find(r.mod, r.root, "compiler.pointer_sized"));
}

unittest {
	// A variable is fixed by its *first* solution and a second argument through
	// it does not rebind it. That is what makes `eq(a, b)` an implicit same-type
	// constraint - the second argument is then checked against the first's type
	// rather than against `T`, which is `sema.typeCheck`'s half of the rule.
	auto r = compile(
		"eq : (T: deduced type, a: T, b: T) -> compiler.byte\n"
		~ "%1 : compiler.byte = 1\n"
		~ "%2 : compiler.pointer_sized = 2\n"
		~ "%3 : compiler.byte = eq(%1, %2)\n");
	scope(exit) freeModule(r.mod);
	diagnostics().clear();

	auto args = &getComponent!FunctionInputs(r.mod, find(r.mod, r.root, "%3"));
	assert(daLength(args.related) == 3);
	assert(resolveAlias(r.mod, args.related[0]) == find(r.mod, r.root, "compiler.byte"));
}

unittest {
	// A variable nothing solves leaves the call alone rather than inventing an
	// argument; `sema.typeCheck` is what reports the leftover.
	auto r = compile(
		"unsolvable : (T: deduced type, v: compiler.byte) -> compiler.byte\n"
		~ "%1 : compiler.byte = 1\n"
		~ "%2 : compiler.byte = unsolvable(%1)\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a call with nothing deduced about it is not touched
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	auto block = BlockBuilder(f.root, &f.mod);
	immutable one = pushNumber(block, internIn(f.mod, "one"), byte_, 1);

	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);
	EntityId[1] args = [one];
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, emit, args[]);

	assert(deduceTypes(f.mod, call));
	assert(daLength(getComponent!FunctionInputs(f.mod, call).related) == 1);
}
