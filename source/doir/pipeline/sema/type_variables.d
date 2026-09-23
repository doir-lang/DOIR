/// `sema.introduceTypeVariables`: turns every `_` written in type position
/// into a `TypeVariable` of that site's own.
///
/// `_` resolves, like any other name, to the builtin type entity named `_`
/// (`interface_.buildBuiltinBlock`). One entity shared by every hole in the
/// module is a placeholder and not an answer - two holes in one file are two
/// different types - so this pass runs once the lookups are resolved and swaps
/// each reference to it for a per-site tag the solver can fill in
/// independently.
///
/// Introduction is pure syntax: it reads no value, folds nothing, and only ever
/// adds tags. That is why it sits here, before comptime, rather than inside the
/// fixpoint that solves what it introduces - `sema.deduceTypes` is the half
/// that has to interleave with evaluation, and it is much easier to reason
/// about when every variable in the module already exists before it starts.
module doir.pipeline.sema.type_variables;

import ecrs.storage : EntityId, invalidEntity;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// The builtin `_` type - what a hole resolves to before this pass reaches it.
///
/// Cached per module (`resolveCached`), since every entity in the walk asks.
EntityId inferencePlaceholder(ref Module mod, EntityId root) {
	return resolveCached(mod, "_", root);
}

/// Whether `type` is still unsolved: a variable this pass introduced, the
/// shared placeholder it has not reached yet, or a `deduced` parameter that
/// this call site has not solved.
///
/// The third is why a hole on `_ : _ = return(x)` waits: what a `-> T` names
/// before `deduceTypes` elaborates the call is the parameter declaration every
/// call through that type shares, which is not an answer about *this* one
/// (D-Deduce).
bool isTypeVariable(ref Module mod, EntityId type) {
	if (type == invalidEntity) return false;
	type = resolveAlias(mod, type);
	if (hasComponent!TypeVariable(mod, type)) return true;

	if (!hasComponent!FunctionParameter(mod, type)) return false;
	if (!hasComponent!TypeOf(mod, type)) return false;
	return resolveAlias(mod, getComponent!TypeOf(mod, type).related[0]) == deducedType(mod, type);
}

/// Whether `e`'s own type is unknown - it is a hole, or it has no type at all.
bool typeIsUnknown(ref Module mod, EntityId e) {
	if (hasComponent!TypeVariable(mod, e)) return true;
	if (!hasComponent!TypeOf(mod, e)) return false;
	return isTypeVariable(mod, getComponent!TypeOf(mod, e).related[0]);
}


bool introduceTypeVariables(ref Module mod, EntityId subtree) @trusted {
	immutable placeholder = inferencePlaceholder(mod, subtree);
	if (placeholder == invalidEntity) return true;

	// The placeholder itself keeps its name and its `TypeDefinition`; tagging it
	// is what lets `isTypeVariable` answer for a hole this walk has not reached.
	if (subtree == placeholder) {
		if (!hasComponent!TypeVariable(mod, subtree))
			addComponent!TypeVariable(mod, subtree);
		return true;
	}

	if (!hasComponent!TypeOf(mod, subtree)) return true;
	if (getComponent!TypeOf(mod, subtree).related[0] != placeholder) return true;

	// `_` on a declaration that *is* a type (`x : _ = type { ... }`) says the
	// same thing `x : type` does, so it is not a hole - there is nothing for a
	// solver to find that the entity does not already say about itself.
	if (hasComponent!TypeDefinition(mod, subtree)) {
		removeComponent!TypeOf(mod, subtree);
		return true;
	}

	removeComponent!TypeOf(mod, subtree);
	addComponent!TypeVariable(mod, subtree);
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
	import tests.pipeline_helper;
}

unittest { // a hole becomes a variable of its own rather than the shared `_`
	auto r = compile("%1 : compiler.byte = 1\n%2 : _ = compiler.emit(%1)\n");
	scope(exit) freeModule(r.mod);
	diagnostics().clear();

	// Whatever `%2` ends up with, it is not the one placeholder entity every
	// other hole in the module would have shared.
	immutable two = find(r.mod, r.root, "%2");
	assert(two != invalidEntity);
	if (hasComponent!TypeOf(r.mod, two))
		assert(getComponent!TypeOf(r.mod, two).related[0]
			!= inferencePlaceholder(r.mod, r.root));
}

unittest { // the placeholder is tagged, so `isTypeVariable` answers for it
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable placeholder = inferencePlaceholder(f.mod, f.root);
	assert(placeholder != invalidEntity);
	assert(introduceTypeVariables(f.mod, placeholder));
	assert(isTypeVariable(f.mod, placeholder));
}

unittest { // a `_` on something that is itself a type is not a hole
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable placeholder = inferencePlaceholder(f.mod, f.root);
	auto block = BlockBuilder(f.root, &f.mod);
	auto typeBuilder = pushType(block, internIn(f.mod, "t"));
	immutable t = typeBuilder.end();
	addComponent!TypeOf(f.mod, t).related[0] = placeholder;

	assert(introduceTypeVariables(f.mod, t));
	assert(!hasComponent!TypeVariable(f.mod, t));
	assert(!hasComponent!TypeOf(f.mod, t));
}
